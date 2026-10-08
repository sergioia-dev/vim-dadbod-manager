" vim-dadbod-manager: turn a vim-dadbod-ui connection into a
" server -> databases -> tables tree.
"
" Public API. Nothing here is called automatically except through the
" commands and autocmds defined in plugin/dbui_multidb.vim.

" Options (all optional):
"   masters       list of g:dbs connection names to turn into server nodes
"   exclude       regexes; discovered database names matching any are hidden
"   sort          1 (default) sorts discovered names case-insensitively
"   cache         0 rediscovers on every expansion (default 1)
"   notify        1 (default) shows an info notification while discovering
"   server_icons  {'server_expanded': .., 'server_collapsed': ..}
function! dbui_multidb#setup(opts) abort
  call dbui_multidb#config#set(a:opts)
  return dbui_multidb#patch#apply()
endfunction

" True when a dbui entry is one of the configured server nodes.
function! dbui_multidb#is_master(db) abort
  if type(a:db) !=# type({}) || get(a:db, 'is_child', 0)
    return 0
  endif
  let name = get(a:db, 'name', '')
  if empty(name)
    return 0
  endif
  for master in dbui_multidb#config#get().masters
    if !empty(master) && name ==? master
      return 1
    endif
  endfor
  return 0
endfunction

function! dbui_multidb#masters() abort
  return dbui_multidb#config#get().masters
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
    call drawer.redraw()
  endif

  return 1
endfunction

" Report what the plugin is doing, for troubleshooting from :DBManagerInfo.
function! dbui_multidb#info() abort
  let cfg = dbui_multidb#config#get()
  let lines = [
        \ 'vim-dadbod-manager',
        \ printf('  masters:       %s', empty(cfg.masters) ? '(none configured)' : join(cfg.masters, ', ')),
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
    for master in cfg.masters
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
  return filter(copy(dbui_multidb#masters()), 'v:val =~? "^' . escape(a:arglead, '^$~.*[]\\') . '"')
endfunction
