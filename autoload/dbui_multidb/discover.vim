" Database discovery for vim-dadbod-manager.
"
" Discovery is synchronous and cached per master connection inside the master's
" own db dict, so the drawer can be re-rendered (BufEnter, toggle, redraw)
" without ever touching the network again.

let s:state_key = 'dbui_multidb_children'

function! dbui_multidb#discover#state_key() abort
  return s:state_key
endfunction

function! s:dedupe(list) abort
  let seen = {}
  let out = []
  for item in a:list
    let lkey = tolower(item)
    if !has_key(seen, lkey)
      let seen[lkey] = 1
      call add(out, item)
    endif
  endfor
  return out
endfunction

function! s:filter_names(names, exclude) abort
  let out = []
  for name in a:names
    if empty(name)
      continue
    endif
    let skip = 0
    for pattern in a:exclude
      if name =~? pattern
        let skip = 1
        break
      endif
    endfor
    if !skip
      call add(out, name)
    endif
  endfor
  return s:dedupe(out)
endfunction

" The error vim-dadbod raises when the client binary of an adapter is not
" installed. Neovim always names the real binary, even when the adapter runs it
" through "env" (sqlserver does that to pass SQLCMDPASSWORD), so the capture is
" the command the user has to install. The "Vim(let):" prefix is the command
" that was running when the error was raised.
let s:missing_client = 'E475: Invalid value for argument cmd: ''\(.\{-}\)'' is not executable'

" Turn the exception a failed adapter raised into something actionable.
"
" A missing client binary (sqlcmd here, psql or mariadb in another shell) is by
" far the most common failure and vim-dadbod reports it as
"
"   Vim(let):E475: Invalid value for argument cmd: 'sqlcmd' is not executable
"
" which is an implementation detail, not a diagnosis. The "Vim(<command>):"
" prefix of every other exception is dropped for the same reason.
function! s:friendly_error(error) abort
  let match = matchlist(a:error, s:missing_client)
  if !empty(match)
    return printf('%s is not installed', match[1])
  endif
  let error = substitute(a:error, '^Vim([^)]*):', '', '')
  return empty(error) ? 'Discovery failed' : error
endfunction

" Ask vim-dadbod's adapter for the database (or schema) names hidden behind a
" connection URL. Returns {'names': [...], 'error': '...'} and never throws.
function! dbui_multidb#discover#names(url, ...) abort
  let cfg = dbui_multidb#config#get()
  let resolved = dbui_multidb#url#resolve(a:url)
  if empty(resolved)
    return {'names': [], 'error': 'Could not resolve the connection URL'}
  endif

  let scheme = dbui_multidb#url#scheme(resolved)
  if !db#adapter#supports(resolved, 'complete_database')
    return {'names': [], 'error': printf('%s does not support database discovery', empty(scheme) ? 'This connection' : '"' . scheme . '"')}
  endif

  if cfg.notify && !get(g:, 'db_ui_disable_info_notifications', 0)
    call dbui_multidb#notify#info(printf('Discovering databases for %s...', a:0 ? a:1 : scheme))
  endif

  try
    let names = db#adapter#call(resolved, 'complete_database', [resolved], [])
  catch /.*/
    return {'names': [], 'error': s:friendly_error(v:exception)}
  endtry

  if type(names) !=# type([])
    return {'names': [], 'error': 'The adapter returned an unexpected result'}
  endif

  let names = s:filter_names(names, cfg.exclude)
  if cfg.sort
    call sort(names, 'i')
  endif

  return {'names': names, 'error': ''}
endfunction

" Keys that must not be deleted from drawer.dbui.dbs because an open query
" buffer still points at them (db_ui#statusline indexes dbs by key).
function! s:is_referenced(key_name) abort
  for info in getbufinfo({'variables': 1})
    if get(get(info, 'variables', {}), 'dbui_db_key_name', '') ==# a:key_name
      return 1
    endif
  endfor
  return 0
endfunction

" Forget the discovered children of one master, reaping them from dbui.dbs.
function! dbui_multidb#discover#invalidate_one(drawer, db) abort
  let state = get(a:db, s:state_key, {})
  for key_name in get(state, 'keys', [])
    if has_key(a:drawer.dbui.dbs, key_name) && !s:is_referenced(key_name)
      call remove(a:drawer.dbui.dbs, key_name)
    endif
  endfor
  if has_key(a:db, s:state_key)
    call remove(a:db, s:state_key)
  endif
  return a:db
endfunction

" Forget every discovered child in the drawer.
function! dbui_multidb#discover#invalidate(drawer) abort
  for db in values(get(a:drawer.dbui, 'dbs', {}))
    if get(db, 'is_child', 0)
      continue
    endif
    call dbui_multidb#discover#invalidate_one(a:drawer, db)
  endfor
  return a:drawer
endfunction

" Children of a master, discovering them if needed and materialising them into
" drawer.dbui.dbs. Returns the cached state dict for the master.
"
" opts:
"   force           refresh even when a cached result exists
"   retry_on_error  rediscover when the cached result is an error (expansion)
function! dbui_multidb#discover#children(drawer, db, ...) abort
  let opts = get(a:, 1, {})
  let cfg = dbui_multidb#config#get()
  let state = get(a:db, s:state_key, {})
  let force = get(opts, 'force', 0) || !cfg.cache
  let retry = get(opts, 'retry_on_error', 0)

  if !empty(state) && !force && (empty(get(state, 'error', '')) || !retry)
    return state
  endif

  call dbui_multidb#discover#invalidate_one(a:drawer, a:db)

  let resolved = dbui_multidb#url#resolve(a:db.url)
  let result = empty(resolved)
        \ ? {'names': [], 'error': 'Could not resolve the connection URL'}
        \ : dbui_multidb#discover#names(resolved, a:db.name)

  let state = {
        \ 'keys': [],
        \ 'error': result.error,
        \ 'items': result.names,
        \ }
  if empty(result.error)
    for name in result.names
      let entry = dbui_multidb#entry#build(a:drawer.dbui, a:db, resolved, name)
      let a:drawer.dbui.dbs[entry.key_name] = entry
      call add(state.keys, entry.key_name)
    endfor
  endif

  let a:db[s:state_key] = state

  " Report the failure here rather than in the drawer: this is the one place
  " that runs exactly once per discovery attempt. Plain redraws reuse the cached
  " state and stay silent, while expanding the node again retries and notifies
  " again.
  if !empty(state.error)
    call dbui_multidb#notify#warning(printf('vim-dadbod-manager: %s: %s', a:db.name, state.error))
  endif

  return state
endfunction
