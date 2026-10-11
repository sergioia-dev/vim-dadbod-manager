" Test-only administration provider whose query_argv hands back whatever the
" test has set in g:dbui_multidb_test_argv.
"
" s:test_admin_query_errors uses it to exercise dbui_multidb#admin#query's
" missing-client and failing-client error paths without running a real client.
" It lives in fake_rtp so its autoload-pattern name matches its script path
" (E746), which a function defined inside the spec file could not.

function! dbui_multidb#admin#failprovider#query_argv(db, sql) abort
  return g:dbui_multidb_test_argv
endfunction
