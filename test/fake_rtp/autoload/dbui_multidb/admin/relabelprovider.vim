" Test-only administration provider that answers supports() with every shape a
" provider can: a number (yes, with the category's own name), a non-empty string
" (yes, and this string is the drawer label) and an empty string (no).
"
" s:test_admin_relabel uses it to pin the seam between supports() and the drawer
" - a category renamed by a string, one switched off, and one the drawer does not
" know - without depending on a real provider. It lives in fake_rtp so its
" autoload-pattern name matches its script path (E746), which a function defined
" inside the spec file could not.

function! dbui_multidb#admin#relabelprovider#supports(_db) abort
  return {'users': 'Logins', 'roles': '', 'extra': 1}
endfunction
