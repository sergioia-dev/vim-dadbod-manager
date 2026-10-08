" Connection URL helpers for vim-dadbod-manager.
"
" Everything here is defensive: a malformed URL must never throw, because these
" helpers run while the dbui drawer is being rendered.

" db#resolve() with the scheme canonicalisation applied by vim-dadbod. Returns
" an empty string when the URL cannot be resolved at all.
function! dbui_multidb#url#resolve(url) abort
  try
    let resolved = db#resolve(a:url)
  catch /.*/
    return ''
  endtry
  return type(resolved) ==# type('') ? resolved : ''
endfunction

function! dbui_multidb#url#scheme(url) abort
  try
    return get(db#url#parse(a:url), 'scheme', '')
  catch /.*/
    return ''
  endtry
endfunction

" Rebuild an already resolved URL so that it points at another database.
"
" Query parameters are intentionally preserved: they carry credentials options
" and TLS settings (sslmode, channel_binding, ssl, encrypt,
" trustServerCertificate, ...) that must survive into every child connection.
"
" For the supported schemes the database is always taken from the path
" component: postgresql's canonicalize maps dbname= into path, and sqlserver's
" canonicalize absorbs ";database=..." into path, so the path is authoritative
" and there is no parameter left to disagree with it.
function! dbui_multidb#url#with_database(resolved, name) abort
  let parsed = db#url#parse(a:resolved)
  if has_key(parsed, 'opaque') && !has_key(parsed, 'path')
    if parsed.opaque =~# '^//[^/]*$'
      " host only, e.g. scheme://host
      let parsed.opaque .= '/' . a:name
    else
      " replace the last segment, e.g. scheme:relative/path
      let parsed.opaque = substitute(parsed.opaque, '[^/]*$', a:name, '')
    endif
  else
    let parsed.path = '/' . a:name
  endif
  return db#url#format(parsed)
endfunction
