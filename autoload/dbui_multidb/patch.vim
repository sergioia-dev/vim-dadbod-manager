" The dbui drawer patch.
"
" vim-dadbod-ui's drawer is a plain dict whose methods are Funcrefs stored on
" the instance returned by db_ui#drawer#get(), and db_ui#dbui#render() is
" therefore patchable from the outside without forking the plugin:
"
"   * add_db      draws a configured connection as a server node and, when it
"                 is expanded, its discovered databases as child nodes
"   * toggle_db   triggers discovery when a server node is expanded
"   * populate    skips discovery for server nodes (they are containers, not
"                 connections)
"   * render      drops the cached discoveries when its opts ask for dbs
"   * redraw      drops the cached discoveries from any cursor position, so R
"                 re-queries every expanded server rather than only the
"                 tables of the node under the cursor
"
" The originals are kept on the instance under "dbui_multidb_orig_*" so the
" patch stays a thin wrapper over upstream behaviour.
"
" The replacements are defined with the "dict" attribute and installed with
" function(name, drawer): only a dict function gets "self", a plain Funcref
" stored on a dict does not (E121).

function! dbui_multidb#patch#methods() abort
  return ['add_db', 'toggle_db', 'populate', 'render', 'delete_line', 'rename_line', 'redraw']
endfunction

" Methods that must exist for the patch to be applicable.
function! dbui_multidb#patch#requirements() abort
  return dbui_multidb#patch#methods() + ['add', 'get_toggle_icon']
endfunction

function! dbui_multidb#patch#is_patched(drawer) abort
  return type(a:drawer) ==# type({}) && !empty(a:drawer) && get(a:drawer, 'dbui_multidb_patched', 0)
endfunction

" Install the patch on the live drawer instance. Idempotent, and safe to call
" before the drawer exists (returns 0 then).
function! dbui_multidb#patch#apply() abort
  try
    let drawer = db_ui#drawer#get()
  catch /.*/
    return 0
  endtry

  if type(drawer) !=# type({}) || empty(drawer)
    return 0
  endif
  if dbui_multidb#patch#is_patched(drawer)
    return 1
  endif

  for method in dbui_multidb#patch#requirements()
    if !has_key(drawer, method)
      call dbui_multidb#notify#error(printf(
            \ 'vim-dadbod-manager: vim-dadbod-ui is missing the "%s" method; server nodes disabled.',
            \ method))
      return 0
    endif
  endfor

  for method in dbui_multidb#patch#methods()
    let drawer['dbui_multidb_orig_' . method] = drawer[method]
    let drawer[method] = function('dbui_multidb#patch#' . method, drawer)
  endfor
  let drawer.dbui_multidb_new_backup = function('dbui_multidb#administrative#new_backup', drawer)
  let drawer.dbui_multidb_backup_file = function('dbui_multidb#administrative#backup_file', drawer)
  let drawer.dbui_multidb_patched = 1

  return 1
endfunction

function! dbui_multidb#patch#master_icon(drawer, db) abort
  let icons = dbui_multidb#config#get().server_icons
  let fallback = a:drawer.get_toggle_icon('db', a:db)
  if type(icons) !=# type({})
    return fallback
  endif
  if a:db.expanded
    let icon = get(icons, 'server_expanded', fallback)
  else
    let icon = get(icons, 'server_collapsed', fallback)
  endif
  return type(icon) ==# type('') ? icon : fallback
endfunction

" Render a server node, and its discovered databases when it is expanded.
"
" A failed discovery leaves no line behind: the reason is delivered as a
" notification instead (see dbui_multidb#discover#children) and the server node
" carries vim-dadbod-ui's own connection_error icon, the same mark upstream uses
" for a connection that did not work. Discovery therefore runs before the node is
" added, so the icon is drawn in the same pass that found the failure.
function! dbui_multidb#patch#add_db(db) abort dict
  if !dbui_multidb#is_master(a:db)
    let result = self.dbui_multidb_orig_add_db(a:db)
    call dbui_multidb#administrative#append(self, a:db)
    return result
  endif

  let state = a:db.expanded ? dbui_multidb#discover#children(self, a:db) : {}

  let label = a:db.name
  if !empty(get(state, 'error', ''))
    let label .= ' ' . g:db_ui_icons.connection_error
  endif
  if self.show_details
    let label .= printf(' (%s - %s)', a:db.scheme, a:db.source)
  endif
  call self.add(label, 'toggle', 'db', dbui_multidb#patch#master_icon(self, a:db), a:db.key_name, 0, {'expanded': a:db.expanded})
  if !a:db.expanded
    return a:db
  endif

  if !empty(state.error)
    " Already reported through a notification while discovering above.
    return a:db
  endif
  if empty(state.keys)
    call self.add('" No databases found', 'noaction', 'help', '', a:db.key_name, 1)
    return a:db
  endif

  call self.add(printf('" Databases (%d)', len(state.keys)), 'noaction', 'help', '', a:db.key_name, 1)

  for key_name in state.keys
    if !has_key(self.dbui.dbs, key_name)
      continue
    endif
    " Children are rendered by upstream code, then indented one level so the
    " tree reads server -> database -> schema -> table.
    let start = len(self.content)
    call self.add_db(self.dbui.dbs[key_name])
    for i in range(start, len(self.content) - 1)
      let self.content[i].level += 1
    endfor
  endfor

  return a:db
endfunction

function! dbui_multidb#patch#toggle_db(db) abort dict
  if !dbui_multidb#is_master(a:db)
    return self.dbui_multidb_orig_toggle_db(a:db)
  endif
  " Expansion is the user asking for up-to-date contents, so a previous
  " discovery failure is retried here. The connection itself is never opened.
  if a:db.expanded
    call dbui_multidb#discover#children(self, a:db, {'retry_on_error': 1})
  endif
  return a:db
endfunction

function! dbui_multidb#patch#populate(db) abort dict
  if dbui_multidb#is_master(a:db)
    return a:db
  endif
  return self.dbui_multidb_orig_populate(a:db)
endfunction

function! dbui_multidb#patch#render(...) abort dict
  let opts = get(a:, 1, {})
  if get(opts, 'dbs', 0)
    call dbui_multidb#discover#invalidate(self)
  endif
  if a:0
    return self.dbui_multidb_orig_render(a:1)
  endif
  return self.dbui_multidb_orig_render()
endfunction

" R must re-discover the database list behind every expanded server, not just
" re-populate tables: it is the user asking for up-to-date contents. Upstream's
" redraw() is cursor-dependent, and the render it picks for a database or table
" node looks the entry up in dbui.dbs by key, which invalidate() has just
" removed (E716). Refresh the whole drawer instead, exactly like R on a server
" node, so the outcome no longer depends on where the cursor happens to be.
function! dbui_multidb#patch#redraw() abort dict
  call dbui_multidb#discover#invalidate(self)
  return self.render({'dbs': 1, 'queries': 1})
endfunction

" d on a backup file entry deletes the file; any other line keeps upstream
" behaviour (the originals are stored under dbui_multidb_orig_*).
function! dbui_multidb#patch#delete_line() abort dict
  let item = dbui_multidb#administrative#backup_item(self)
  if !empty(item)
    return dbui_multidb#administrative#delete_file(self, item)
  endif
  return self.dbui_multidb_orig_delete_line()
endfunction

" r on a backup file entry renames the file; any other line keeps upstream
" behaviour.
function! dbui_multidb#patch#rename_line() abort dict
  let item = dbui_multidb#administrative#backup_item(self)
  if !empty(item)
    return dbui_multidb#administrative#rename_file(self, item)
  endif
  return self.dbui_multidb_orig_rename_line()
endfunction
