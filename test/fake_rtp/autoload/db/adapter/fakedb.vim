" Minimal vim-dadbod adapter used by the test suite.
"
" It implements just enough of the adapter contract for vim-dadbod and
" vim-dadbod-ui to treat "fakedb://..." as a real connection: the database list
" comes from a variable instead of a server, and connecting is a no-op.

function! db#adapter#fakedb#complete_database(url) abort
  call add(g:dbui_multidb_test_calls, {'fn': 'complete_database', 'url': a:url})
  return copy(g:dbui_multidb_test_dbs)
endfunction

function! db#adapter#fakedb#tables(url) abort
  return copy(get(g:, 'dbui_multidb_test_tables', []))
endfunction

" db#connect() insists on an executable before it will short-circuit on
" auth_input, so hand it a harmless one.
function! db#adapter#fakedb#interactive(url) abort
  return ['sh', '-c', 'cat']
endfunction

" Returning v:false tells db#connect() that no authentication round trip is
" needed, so it returns the URL untouched. db#adapter#call() passes no
" arguments here, which is why this one takes none.
function! db#adapter#fakedb#auth_input() abort
  return v:false
endfunction
