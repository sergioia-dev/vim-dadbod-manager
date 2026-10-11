" The mongodb administration provider: the "Users" category of the drawer's
" "Administration" section.
"
" MongoDB has no roles the section could list as the Roles category: user-defined
" roles exist (db.getRoles()), but they are per-database permission bundles, not
" the principal-holding groups SQL's roles are, so they are not shown. Only Users
" is claimed.
"
" MongoDB users live in a database, and it is not necessarily the one the URL
" names. The credentials a mongodb connection logs in with are usually stored in
" the admin database, which the URL spells out with ?authSource=admin; listing
" the URL's own database instead would show an empty category on most
" connections. So this provider reads and writes the database the connection
" authenticates against: the authSource parameter, or the URL's database, or
" admin when neither names one.
"
" Every leaf only pre-fills a query buffer and the destructive ones ask first
" (see dbui_multidb#admin). Every <leaf> function takes the connection and the
" entity name and returns the statement of one leaf; returning '' (or not
" defining the function at all) hides that leaf.
"
" The statements are JavaScript, which is the language vim-dadbod's mongodb
" adapter declares for its buffers. mongosh prints nothing unless the script
" prints, so the category list prints its own "|"-separated rows and the leaves
" printjson() the answer they open. A name is written as a JavaScript string
" literal, so a user name with a quote or a backslash in it stays one argument.
" The one literal secret here is "new-password" on the Reset password leaf, a
" placeholder for a human to replace.

" ---------------------------------------------------------------------------
" Helpers
" ---------------------------------------------------------------------------

function! s:sql(lines) abort
  return join(a:lines, "\n")
endfunction

" A value as a JavaScript string literal: "value", with any inner " or \ escaped.
function! s:js(value) abort
  return '"' . substitute(a:value, '["\\]', '\\\0', 'g') . '"'
endfunction

" The database whose users the section lists, as described in the header.
function! s:auth_database(db) abort
  let url = dbui_multidb#url#resolve(get(a:db, 'url', ''))
  if empty(url)
    throw 'Could not resolve the administration connection URL'
  endif
  let parsed = db#url#parse(url)

  let source = get(get(parsed, 'params', {}), 'authSource', '')
  if !empty(source)
    return source
  endif

  let path = substitute(get(parsed, 'path', ''), '^/\+\|/\+$', '', 'g')
  let database = substitute(path, '^.*/', '', '')
  return empty(database) ? 'admin' : database
endfunction

" db.getSiblingDB(<name>), the expression that picks the database a statement
" runs against regardless of which database the connection is on.
function! s:getdb(db) abort
  return 'db.getSiblingDB(' . s:js(s:auth_database(a:db)) . ')'
endfunction

" ---------------------------------------------------------------------------
" Provider
" ---------------------------------------------------------------------------

" A static answer: the users catalog is readable by the connection's own login,
" and this runs while the drawer is drawn, never connects.
function! dbui_multidb#admin#mongodb#supports(_) abort
  return {'users': 1}
endfunction

" The argv that runs one script and prints one line per row, or the object a
" leaf opens. --quiet keeps mongosh's own notices out of the rows.
function! dbui_multidb#admin#mongodb#query_argv(db, sql) abort
  let url = dbui_multidb#url#resolve(get(a:db, 'url', ''))
  if empty(url)
    throw 'Could not resolve the administration connection URL'
  endif

  return db#adapter#mongodb#interactive(url) + ['--quiet', '--eval', a:sql]
endfunction

" The script that prints the users of the authentication database, one
" "name|role@db,role@db" line each. getUsers() is not a cursor: it is a command
" result whose "users" field holds the account documents, so the script maps over
" that.
function! s:list_script(db) abort
  return s:getdb(a:db) . '.getUsers().users.forEach(function (u) { print([u.user, (u.roles || []).map(function (r) { return r.role + "@" + r.db }).join(",")].join("|")) })'
endfunction

function! dbui_multidb#admin#mongodb#list_users(db) abort
  let users = []
  for row in dbui_multidb#admin#query(a:db, s:list_script(a:db))
    if empty(row) || empty(row[0])
      continue
    endif
    let roles = get(row, 1, '')
    call add(users, {
          \ 'name': row[0],
          \ 'status': empty(roles) ? 'no roles' : roles,
          \ })
  endfor
  return users
endfunction

" ---------------------------------------------------------------------------
" Users
" ---------------------------------------------------------------------------

" One database holds each user name once, so the List leaf of other providers has
" nothing to list here and is hidden.
function! dbui_multidb#admin#mongodb#user_list(_db, _name) abort
  return ''
endfunction

" The account document, the same shape getUsers() holds: name, roles, the
" authentication mechanisms it accepts and its customData.
function! dbui_multidb#admin#mongodb#user_attributes(db, name) abort
  return 'printjson(' . s:getdb(a:db) . '.getUser(' . s:js(a:name) . '))'
endfunction

function! dbui_multidb#admin#mongodb#user_identity(_db, _name) abort
  return ''
endfunction

function! dbui_multidb#admin#mongodb#user_roles(db, name) abort
  return s:getdb(a:db) . '.getUser(' . s:js(a:name)
        \ . ').roles.forEach(function (r) { print(r.role + "@" + r.db) })'
endfunction

" A user holds roles, not privileges, and its effective permissions depend on the
" roles it has on the database it is acting on, so there is no one statement that
" answers it for every database at once.
function! dbui_multidb#admin#mongodb#user_grants(_db, _name) abort
  return ''
endfunction

function! dbui_multidb#admin#mongodb#user_effective_access(_db, _name) abort
  return ''
endfunction

function! dbui_multidb#admin#mongodb#user_dependencies(_db, _name) abort
  return ''
endfunction

" The operations this user is running or has run recently, read from the current
" operations of the whole server, which is the closest MongoDB comes to a session
" table: effectiveUsers is the field a query authenticated as this user carries.
function! dbui_multidb#admin#mongodb#user_activity(db, name) abort
  return s:getdb(a:db)
        \ . '.aggregate([{ $currentOp: { allUsers: true } }, { $match: { "effectiveUsers.user": '
        \ . s:js(a:name) . ' } }]).forEach(function (o) { printjson(o) })'
endfunction

" MongoDB has no way to deny a login without also taking the roles away, so the
" Lock leaf of other providers has no honest statement here and is hidden.
function! dbui_multidb#admin#mongodb#user_lock(_db, _name) abort
  return ''
endfunction

" A reset has to name a new password, so the statement carries a placeholder for
" a human to replace.
function! dbui_multidb#admin#mongodb#user_reset_password(db, name) abort
  return s:getdb(a:db) . '.updateUser(' . s:js(a:name) . ', { pwd: "new-password" })'
endfunction

function! dbui_multidb#admin#mongodb#user_drop(db, name) abort
  return s:getdb(a:db) . '.dropUser(' . s:js(a:name) . ')'
endfunction
