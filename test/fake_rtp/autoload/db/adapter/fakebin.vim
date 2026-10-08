" Minimal vim-dadbod adapter for a connection whose client binary is missing.
"
" A real server configured with a client that is not installed (sqlcmd, psql,
" mariadb, ...) fails inside vim-dadbod's db#systemlist(), which lets Neovim
" raise the very error this plugin has to translate:
"
"   Vim(let):E475: Invalid value for argument cmd: 'sqlcmd' is not executable
"
" Running a binary that does not exist reproduces that error verbatim, so the
" suite tests against Neovim's own message instead of a hand-written copy of it.

function! db#adapter#fakebin#complete_database(url) abort
  call add(g:dbui_multidb_test_calls, {'fn': 'complete_database', 'url': a:url})
  return db#systemlist([g:dbui_multidb_test_binary])
endfunction

" db#connect() insists on an executable before it will short-circuit on
" auth_input, so hand it a harmless one.
function! db#adapter#fakebin#interactive(url) abort
  return ['sh', '-c', 'cat']
endfunction

function! db#adapter#fakebin#auth_input() abort
  return v:false
endfunction
