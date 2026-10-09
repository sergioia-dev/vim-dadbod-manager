" Configuration access for vim-dadbod-manager.
"
" Values are read lazily on every use, so the g:dbui_multidb_* variables (or a
" call to dbui_multidb#setup()) may be set at any time after the plugin loads.

function! dbui_multidb#config#defaults() abort
  return {
        \ 'masters': [],
        \ 'exclude': [],
        \ 'sort': 1,
        \ 'cache': 1,
        \ 'notify': 1,
        \ 'server_icons': {},
        \ 'backup_section': 1,
        \ 'backup_dir': '~/dbui-backups',
        \ 'backup_commands': {},
        \ 'backup_options': {},
        \ 'backup_server_dirs': {},
        \ 'backup_runner': '',
        \ 'backup_echo_command': 0,
        \ }
endfunction

" Coerce a user supplied value into a list. Accepts a real list or a
" comma separated string (handy from a :let inside a ftplugin).
function! dbui_multidb#config#as_list(value) abort
  if type(a:value) ==# type([])
    let list = copy(a:value)
  elseif type(a:value) ==# type('')
    let list = split(a:value, ',')
  else
    return []
  endif
  return filter(map(list, 'type(v:val) ==# type("") ? trim(v:val) : v:val'), '!empty(v:val)')
endfunction

" Returns the effective configuration with all defaults applied.
function! dbui_multidb#config#get() abort
  let cfg = dbui_multidb#config#defaults()
  for key in keys(cfg)
    if exists('g:dbui_multidb_' . key)
      let cfg[key] = get(g:, 'dbui_multidb_' . key)
    endif
  endfor
  let cfg.masters = dbui_multidb#config#as_list(cfg.masters)
  let cfg.exclude = dbui_multidb#config#as_list(cfg.exclude)
  return cfg
endfunction

" Normalise an options dict into the g:dbui_multidb_* variables.
function! dbui_multidb#config#set(opts) abort
  for key in keys(dbui_multidb#config#defaults())
    if !has_key(a:opts, key)
      continue
    endif
    let value = a:opts[key]
    if key ==# 'masters' || key ==# 'exclude'
      let value = dbui_multidb#config#as_list(value)
    endif
    call extend(g:, {'dbui_multidb_' . key: value}, 'force')
  endfor
endfunction
