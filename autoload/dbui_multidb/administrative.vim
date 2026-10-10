" The per-database "Backups" section of the drawer.
"
" Every expanded database backed up client-side gets one, below whatever
" vim-dadbod-ui drew for it (Schemas, Tables, saved queries): a level 1 toggle
" that expands into the backup files of that connection (newest first) and a
" final "New backup" leaf whose <CR> starts a job (see dbui_multidb#backup).
"
" Server-side schemes write on the database host, where this editor can neither
" list, restore nor delete anything, so they get no section at all.
"
" Two upstream behaviours carry the section:
"
"   * s:drawer.toggle_line() flips ".expanded" on the dict it finds under the
"     item type on the database entry, so the state has to live in a dict on the
"     entry named exactly like the item type. It also means the section needs no
"     patch of its own: the entry dict lives in drawer.dbui.dbs across renders.
"   * s:drawer.add() takes the level, so the section nests under a database that
"     was already drawn at level 1 (a discovered child of a server node).
"
" The state is seeded even when the section is hidden: a missing key would make
" the toggle a silent no-op instead of an error.
let s:type = 'dbui_multidb_backups'
let s:new_type = 'dbui_multidb_new_backup'
let s:file_type = 'dbui_multidb_backup_file'

" The state of one database's section, seeded on the entry if it is not there.
function! dbui_multidb#administrative#state(db) abort
  if !has_key(a:db, s:type) || type(a:db[s:type]) !=# type({})
    let a:db[s:type] = {'expanded': 0}
  endif
  return a:db[s:type]
endfunction

" The toggle icon.
"
" Icons are read out of g:db_ui_icons rather than through the drawer's
" get_toggle_icon(): that one indexes the icon tables by item type and throws
" E716 for a type vim-dadbod-ui does not know about. A theme that defines
" db_ui_icons.expanded.dbui_multidb_backups wins, then a flat
" db_ui_icons.backups, then the "tables" icon, which is the same mark
" vim-dadbod-ui puts on the section a database's contents hang off.
function! dbui_multidb#administrative#icon(expanded) abort
  let icons = get(g:, 'db_ui_icons', {})
  if type(icons) !=# type({})
    return ''
  endif

  let bucket = get(icons, a:expanded ? 'expanded' : 'collapsed', {})
  if type(bucket) !=# type({})
    let bucket = {}
  endif

  for icon in [get(bucket, s:type, ''), get(icons, 'backups', ''), get(bucket, 'tables', ''), get(icons, 'tables', '')]
    if type(icon) ==# type('') && !empty(icon)
      return icon
    endif
  endfor

  return ''
endfunction

" The icon of the "New backup" leaf: the same mark as vim-dadbod-ui's own "New
" query" action, so the section reads as one more thing a connection offers.
function! dbui_multidb#administrative#new_icon() abort
  let icons = get(g:, 'db_ui_icons', {})
  if type(icons) !=# type({})
    return ''
  endif
  let icon = get(icons, 'new_query', '')
  return type(icon) ==# type('') ? icon : ''
endfunction

" The backup file entry under the cursor, or an empty dict when the cursor is
" somewhere else. The delete_line/rename_line patches use it to know whether the
" line is theirs.
function! dbui_multidb#administrative#backup_item(drawer) abort
  let item = a:drawer.get_current_item()
  if type(item) !=# type({}) || get(item, 'type', '') !=# s:file_type
    return {}
  endif
  return item
endfunction

" The items of one database's section, in the exact shape s:drawer.add()
" stores: the "Backups (N)" toggle at base_level, and, when the section is
" expanded, "New backup" and every backup file one level below it. Pure: it
" neither touches the drawer nor the buffer, so a render and an in-place
" refresh build the section the same way.
function! dbui_multidb#administrative#section_items(db, base_level) abort
  let state = dbui_multidb#administrative#state(a:db)
  let entries = dbui_multidb#backup#list(a:db)
  let items = [{
        \ 'label': printf('Backups (%d)', len(entries)),
        \ 'action': 'toggle',
        \ 'type': s:type,
        \ 'icon': dbui_multidb#administrative#icon(state.expanded),
        \ 'dbui_db_key_name': a:db.key_name,
        \ 'level': a:base_level,
        \ 'expanded': state.expanded,
        \ }]
  if !state.expanded
    return items
  endif

  call add(items, {
        \ 'label': 'New backup',
        \ 'action': 'call_method',
        \ 'type': s:new_type,
        \ 'icon': dbui_multidb#administrative#new_icon(),
        \ 'dbui_db_key_name': a:db.key_name,
        \ 'level': a:base_level + 1,
        \ })
  for entry in entries
    call add(items, {
          \ 'label': entry.label,
          \ 'action': 'call_method',
          \ 'type': s:file_type,
          \ 'icon': '',
          \ 'dbui_db_key_name': a:db.key_name,
          \ 'level': a:base_level + 1,
          \ 'dbui_backup_file': entry.path,
          \ 'dbui_backup_prefix': entry.prefix,
          \ 'dbui_backup_label': entry.label,
          \ })
  endfor
  return items
endfunction

" Append the section to a database the drawer just drew. Called by the add_db
" patch, so a:db is the real entry from drawer.dbui.dbs and the returned state
" survives a re-render. Returns 1 when the section was added, 0 when the
" configuration or the scheme turns it off, or the database is collapsed.
function! dbui_multidb#administrative#append(drawer, db) abort
  call dbui_multidb#administrative#state(a:db)
  if empty(get(dbui_multidb#config#get(), 'backup_section', 1))
    return 0
  endif
  " The section belongs to an expanded database only: a collapsed node keeps
  " the exact shape vim-dadbod-ui draws for it.
  if !get(a:db, 'expanded', 0)
    return 0
  endif
  " Server-side schemes write on the database host; there is nothing to list.
  if !dbui_multidb#backup#is_local(a:db)
    return 0
  endif

  call extend(a:drawer.content, dbui_multidb#administrative#section_items(a:db, 1))
  return 1
endfunction

" Rewrite one database's section inside a drawer that has already been drawn:
" remove the old toggle and its subtree, insert the rebuilt items at the same
" position, then repaint the buffer. The rest of the tree is left exactly as it
" is, so no other node is re-toggled, re-discovered or collapsed. Returns 0
" when the database has no section in the drawer (it is collapsed, or this is
" not the drawer the section was appended to).
function! dbui_multidb#administrative#replace_section(drawer, db) abort
  let content = a:drawer.content
  let index = -1
  let level = 0
  let i = 0
  while i < len(content)
    let item = content[i]
    if get(item, 'type', '') ==# s:type && get(item, 'dbui_db_key_name', '') ==# a:db.key_name
      let index = i
      let level = item.level
      break
    endif
    let i += 1
  endwhile
  if index < 0
    return 0
  endif

  " The subtree: every following item deeper than the toggle, up to the next
  " item at the toggle's level or above.
  let last = index + 1
  while last < len(content) && content[last].level > level
    let last += 1
  endwhile

  call remove(content, index, last - 1)
  call extend(content, dbui_multidb#administrative#section_items(a:db, level), index)
  call dbui_multidb#administrative#repaint(a:drawer)
  return 1
endfunction

" Rebuild the drawer buffer from its content exactly like render() does,
" without rebuilding the content itself. Used after replace_section(): the new
" items have to be shown, but the tree must stay as it is. Returns 0 when the
" drawer is not open.
function! dbui_multidb#administrative#repaint(drawer) abort
  let restore_win = a:drawer.focus()
  if &filetype !=? 'dbui'
    return 0
  endif

  let view = winsaveview()
  let lines = map(copy(a:drawer.content), 'repeat(" ", shiftwidth() * v:val.level).v:val.icon.(!empty(v:val.icon) ? " " : "").v:val.label')
  setlocal modifiable
  silent 1,$delete _
  call setline(1, lines)
  setlocal nomodifiable
  call winrestview(view)

  if restore_win
    wincmd p
  endif
  return 1
endfunction

" <CR> on the "New backup" leaf, dispatched by the drawer to the instance method
" of the same name as the item type (see s:drawer.toggle_line()). The item under
" the cursor names the database, which is all the context the job needs.
function! dbui_multidb#administrative#new_backup() abort dict
  let item = self.get_current_item()
  if type(item) !=# type({})
    return 0
  endif

  let db = get(self.dbui.dbs, get(item, 'dbui_db_key_name', ''), {})
  if type(db) !=# type({}) || empty(db)
    call dbui_multidb#notify#error('vim-dadbod-manager: no database to back up here.')
    return 0
  endif

  return dbui_multidb#backup#start(db)
endfunction

" <CR> on a backup file entry: restore it into the database it came from.
function! dbui_multidb#administrative#backup_file() abort dict
  let item = dbui_multidb#administrative#backup_item(self)
  if empty(item)
    return 0
  endif

  let db = get(self.dbui.dbs, get(item, 'dbui_db_key_name', ''), {})
  if type(db) !=# type({}) || empty(db)
    call dbui_multidb#notify#error('vim-dadbod-manager: no database to restore into here.')
    return 0
  endif

  return dbui_multidb#backup#restore(db, get(item, 'dbui_backup_file', ''))
endfunction

" d on a backup file entry: delete the file (and the log next to it) after a
" confirmation.
function! dbui_multidb#administrative#delete_file(drawer, item) abort
  let db = get(a:drawer.dbui.dbs, get(a:item, 'dbui_db_key_name', ''), {})
  if type(db) !=# type({}) || empty(db)
    call dbui_multidb#notify#error('vim-dadbod-manager: no database for this backup file.')
    return 0
  endif
  if !dbui_multidb#backup#delete_file(db, get(a:item, 'dbui_backup_file', ''))
    return 0
  endif
  call a:drawer.render()
  return 1
endfunction

" r on a backup file entry: rename the file, keeping its prefix and extension.
function! dbui_multidb#administrative#rename_file(drawer, item) abort
  let db = get(a:drawer.dbui.dbs, get(a:item, 'dbui_db_key_name', ''), {})
  if type(db) !=# type({}) || empty(db)
    call dbui_multidb#notify#error('vim-dadbod-manager: no database for this backup file.')
    return 0
  endif

  let label = get(a:item, 'dbui_backup_label', '')
  try
    let new_label = db_ui#utils#input('Backup name: ', label)
  catch /.*/
    call dbui_multidb#notify#error(v:exception)
    return 0
  endtry
  if empty(new_label) || new_label ==# label
    return 0
  endif

  if !dbui_multidb#backup#rename_file(get(a:item, 'dbui_backup_file', ''), new_label, get(a:item, 'dbui_backup_prefix', ''))
    return 0
  endif
  call a:drawer.render()
  return 1
endfunction
