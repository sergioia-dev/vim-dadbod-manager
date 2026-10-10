" vim-dadbod-manager: turn a vim-dadbod-ui connection into a
" server -> databases -> tables tree.
"
" Public API. Nothing here is called automatically except through the
" commands and autocmds defined in plugin/dbui_multidb.vim.

" Options (all optional):
"   masters       names of g:dbs connections to force into server nodes;
"                 empty (the default) auto-detects them, see
"                 dbui_multidb#discoverable()
"   exclude       regexes; discovered database names matching any are hidden
"   sort          1 (default) sorts discovered names case-insensitively
"   cache         0 rediscovers on every expansion (default 1)
"   notify        1 (default) shows an info notification while discovering
"   server_icons  {'server_expanded': .., 'server_collapsed': ..}
function! dbui_multidb#setup(opts) abort
  call dbui_multidb#config#set(a:opts)
  return dbui_multidb#patch#apply()
endfunction

" The database a connection implicitly talks to when its URL names none. A
" scheme listed here auto-promotes when its URL either names no database or
" names exactly this default; a URL pinned to any other database stays a plain
" connection. A scheme that implements complete_database but is absent from the
" map still auto-promotes, but only when its URL names no database at all.
let s:default_databases = {
      \ 'sqlserver': 'master',
      \ 'postgresql': 'postgres',
      \ 'clickhouse': 'default',
      \ }

" The database named by a resolved URL's path, or an empty string when it names
" none. Only the last segment matters: postgresql, mysql, mariadb, sqlserver,
" clickhouse and snowflake all put the database there.
function! s:url_database(parsed) abort
  let path = substitute(get(a:parsed, 'path', ''), '^/\+\|/\+$', '', 'g')
  return substitute(path, '^.*/', '', '')
endfunction

" True when a connection can be a server node without being named in
" g:dbui_multidb_masters: its adapter can list the databases behind it
" (complete_database) and its URL does not pin it to a single database. A URL
" that names the scheme's own default database (sqlserver/master,
" postgresql/postgres, clickhouse/default) counts as unpinned, because that is
" the connection a user points at the whole server. Never throws, because it
" runs on every connection while the drawer is rendered.
function! dbui_multidb#discoverable(db) abort
  if type(a:db) !=# type({})
    return 0
  endif
  let resolved = dbui_multidb#url#resolve(get(a:db, 'url', ''))
  if empty(resolved)
    return 0
  endif
  try
    if !db#adapter#supports(resolved, 'complete_database')
      return 0
    endif
    let parsed = db#url#parse(resolved)
  catch /.*/
    return 0
  endtry
  let database = s:url_database(parsed)
  if empty(database)
    return 1
  endif
  let scheme = tolower(get(parsed, 'scheme', ''))
  return has_key(s:default_databases, scheme) && database ==? s:default_databases[scheme]
endfunction

" True when a dbui entry is a server node.
"
" A non-empty g:dbui_multidb_masters is explicit mode: that list is the whole
" truth and nothing is auto-detected. When it is empty, a connection is a
" server when dbui_multidb#discoverable() says so. Discovered databases are
" children, never servers.
function! dbui_multidb#is_master(db) abort
  if type(a:db) !=# type({}) || get(a:db, 'is_child', 0)
    return 0
  endif
  let name = get(a:db, 'name', '')
  if empty(name)
    return 0
  endif
  let masters = dbui_multidb#config#get().masters
  if !empty(masters)
    for master in masters
      if !empty(master) && name ==? master
        return 1
      endif
    endfor
    return 0
  endif
  return dbui_multidb#discoverable(a:db)
endfunction

function! dbui_multidb#masters() abort
  return dbui_multidb#config#get().masters
endfunction

" The names a user can pass to :DBManagerRefresh, used for command completion.
" In explicit mode that is the configured list; in auto mode every server node
" currently present, preferring the drawer (whose entries carry the resolved
" URL) and falling back to g:dbs, where only string URLs can be inspected.
function! dbui_multidb#server_names() abort
  let masters = dbui_multidb#config#get().masters
  if !empty(masters)
    return copy(masters)
  endif
  let names = []
  let drawer = db_ui#drawer#get()
  if type(drawer) ==# type({}) && !empty(drawer)
    for db in values(get(get(drawer, 'dbui', {}), 'dbs', {}))
      if dbui_multidb#is_master(db)
        call add(names, db.name)
      endif
    endfor
  else
    for [name, url] in items(get(g:, 'dbs', {}))
      if type(url) ==# type('') && dbui_multidb#discoverable({'name': name, 'url': url})
        call add(names, name)
      endif
    endfor
  endif
  return sort(names, 'i')
endfunction

" Drop cached discoveries so that the next expansion (or an immediate redraw of
" an already expanded server node) queries the server again.
"
" Without an argument every server node is refreshed; with one, that single
" server node (by connection name or key) is refreshed.
function! dbui_multidb#refresh(...) abort
  let target = a:0 ? a:1 : ''

  let drawer = db_ui#drawer#get()
  if type(drawer) !=# type({}) || empty(drawer)
    return 0
  endif
  if !dbui_multidb#patch#is_patched(drawer)
    call dbui_multidb#patch#apply()
  endif

  let dbs = get(get(drawer, 'dbui', {}), 'dbs', {})
  if empty(dbs)
    return 0
  endif

  if empty(target)
    call dbui_multidb#discover#invalidate(drawer)
  else
    let found = []
    for db in values(dbs)
      if dbui_multidb#is_master(db) && (db.name ==? target || db.key_name ==# target)
        call dbui_multidb#discover#invalidate_one(drawer, db)
        call add(found, db.name)
      endif
    endfor
    if empty(found)
      call dbui_multidb#notify#warning(printf('vim-dadbod-manager: no server node named "%s"', target))
      return 0
    endif
  endif

  if drawer.is_opened()
    " A plain re-render re-discovers only what was invalidated above: redraw()
    " would invalidate every server again, which is not what a targeted refresh
    " asks for.
    call drawer.render({'queries': 1})
  endif

  return 1
endfunction

" Report what the plugin is doing, for troubleshooting from :DBManagerInfo.
function! dbui_multidb#info() abort
  let cfg = dbui_multidb#config#get()
  let lines = [
        \ 'vim-dadbod-manager',
        \ printf('  masters:       %s', empty(cfg.masters) ? '(auto-detect)' : join(cfg.masters, ', ')),
        \ printf('  exclude:       %s', empty(cfg.exclude) ? '(none)' : join(cfg.exclude, ', ')),
        \ printf('  sort:          %s', cfg.sort ? 'on' : 'off'),
        \ printf('  cache:         %s', cfg.cache ? 'on' : 'off'),
        \ printf('  notify:        %s', cfg.notify ? 'on' : 'off'),
        \ ]

  let drawer = db_ui#drawer#get()
  if type(drawer) !=# type({}) || empty(drawer)
    call add(lines, '  drawer:        not open')
  else
    call add(lines, printf('  drawer:        %s', drawer.is_opened() ? 'open' : 'closed'))
    call add(lines, printf('  patch:         %s', dbui_multidb#patch#is_patched(drawer) ? 'installed' : 'NOT installed'))
    let dbs = get(get(drawer, 'dbui', {}), 'dbs', {})
    for master in dbui_multidb#server_names()
      let match = {}
      for db in values(dbs)
        if !get(db, 'is_child', 0) && db.name ==? master
          let match = db
          break
        endif
      endfor
      if empty(match)
        call add(lines, printf('  - %s: not in the drawer (check g:dbs)', master))
        continue
      endif
      let state = get(match, dbui_multidb#discover#state_key(), {})
      if empty(state)
        call add(lines, printf('  - %s: not discovered yet', master))
      elseif !empty(state.error)
        call add(lines, printf('  - %s: error: %s', master, state.error))
      else
        call add(lines, printf('  - %s: %d database(s): %s', master, len(state.keys), join(get(state, 'items', []), ', ')))
      endif
    endfor
  endif

  call dbui_multidb#notify#info(lines)
  return lines
endfunction

function! dbui_multidb#complete_masters(arglead, cmdline, cursorpos) abort
  return filter(copy(dbui_multidb#server_names()), 'v:val =~? "^' . escape(a:arglead, '^$~.*[]\\') . '"')
endfunction
