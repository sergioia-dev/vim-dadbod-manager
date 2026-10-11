" The postgresql administration provider: the "Users" and "Roles" categories of
" the drawer's "Administration" section.
"
" Candidates are read from pg_roles, which every PostgreSQL user can read.
" pg_authid (the password hashes) is deliberately never queried, and no statement
" here is ever executed by the section itself: every leaf only pre-fills a query
" buffer, and the destructive ones ask first (see dbui_multidb#admin).
"
" Identifiers are double quoted and string literals single quoted, with the
" quoting character doubled, so a role named "o'brien" still produces usable SQL.
"
" Every <leaf>_<section> function takes the connection and the entity name and
" returns the SQL of one leaf. Returning '' (or not defining the function) hides
" that leaf for that provider.
"
" All the statements are written for a stock PostgreSQL server: pg_roles for the
" catalog, pg_auth_members for memberships, information_schema for table grants,
" pg_stat_activity for sessions.

function! s:sql(lines) abort
  return join(a:lines, "\n")
endfunction

" A role name as a PostgreSQL identifier: "name", with any inner " doubled.
function! s:ident(name) abort
  return '"' . substitute(a:name, '"', '""', 'g') . '"'
endfunction

" A role name as a PostgreSQL string literal: 'name', with any inner ' doubled.
function! s:literal(value) abort
  return "'" . substitute(a:value, "'", "''", 'g') . "'"
endfunction

" The category -> truthy dict of dbui_multidb#admin#supports(). Both categories
" read pg_roles, which needs nothing special of the login, and this runs while
" the drawer is drawn, so it is a static answer and never connects.
function! dbui_multidb#admin#postgresql#supports(_) abort
  return {'users': 1, 'roles': 1}
endfunction

" The argv that runs one statement and prints one line per row, fields separated
" by "|": the same unaligned, tuples-only shape vim-dadbod's own adapters read.
function! dbui_multidb#admin#postgresql#query_argv(db, sql) abort
  let url = dbui_multidb#url#resolve(get(a:db, 'url', ''))
  if empty(url)
    throw 'Could not resolve the administration connection URL'
  endif

  return db#adapter#postgresql#interactive(url)
        \ + ['--no-psqlrc', '-tA', '-F', '|', '-v', 'ON_ERROR_STOP=1', '-c', a:sql]
endfunction

" "rolvaliduntil" as psql prints it: 'infinity' and an empty string are never
" expired, anything before now is. The values are compared as text, which is
" right for the ISO-like 'YYYY-MM-DD HH:MM:SS' prefix psql emits.
function! dbui_multidb#admin#postgresql#expired(validuntil) abort
  if empty(a:validuntil) || a:validuntil ==# 'infinity' || !exists('*strftime')
    return 0
  endif
  return a:validuntil < strftime('%Y-%m-%d %H:%M:%S')
endfunction

function! dbui_multidb#admin#postgresql#user_status(superuser, canlogin, validuntil) abort
  if a:superuser
    return 'superuser'
  endif
  if dbui_multidb#admin#postgresql#expired(a:validuntil)
    return 'expired'
  endif
  return a:canlogin ? 'active' : 'group'
endfunction

function! s:users_sql() abort
  return s:sql([
        \ 'SELECT rolname, rolsuper, rolcanlogin, rolvaliduntil::text',
        \ 'FROM pg_roles',
        \ 'WHERE rolcanlogin',
        \ 'ORDER BY rolname',
        \ ])
endfunction

function! s:roles_sql() abort
  return s:sql([
        \ 'SELECT rolname, rolsuper, rolcanlogin',
        \ 'FROM pg_roles',
        \ 'ORDER BY rolname',
        \ ])
endfunction

" The logins: the roles someone can actually connect as.
function! dbui_multidb#admin#postgresql#list_users(db) abort
  let users = []
  for row in dbui_multidb#admin#query(a:db, s:users_sql())
    if empty(row) || empty(row[0])
      continue
    endif
    call add(users, {
          \ 'name': row[0],
          \ 'status': dbui_multidb#admin#postgresql#user_status(
          \     get(row, 1, '') ==# 't',
          \     get(row, 2, '') ==# 't',
          \     get(row, 3, '')),
          \ })
  endfor
  return users
endfunction

" Every role, login or not: the group roles a login can be a member of show up
" here.
function! dbui_multidb#admin#postgresql#list_roles(db) abort
  let roles = []
  for row in dbui_multidb#admin#query(a:db, s:roles_sql())
    if empty(row) || empty(row[0])
      continue
    endif
    let superuser = get(row, 1, '') ==# 't'
    let canlogin = get(row, 2, '') ==# 't'
    call add(roles, {
          \ 'name': row[0],
          \ 'status': superuser ? 'superuser' : (canlogin ? 'login' : 'group'),
          \ })
  endfor
  return roles
endfunction

" ---------------------------------------------------------------------------
" Users
" ---------------------------------------------------------------------------

function! dbui_multidb#admin#postgresql#user_list(db, name) abort
  return s:sql([
        \ 'SELECT rolname, rolsuper, rolcanlogin, rolvaliduntil',
        \ 'FROM pg_roles',
        \ 'WHERE rolname = ' . s:literal(a:name),
        \ ])
endfunction

function! dbui_multidb#admin#postgresql#user_attributes(db, name) abort
  return s:sql([
        \ 'SELECT rolname, rolsuper, rolinherit, rolcreaterole, rolcreatedb,',
        \ '       rolcanlogin, rolreplication, rolbypassrls, rolconnlimit, rolvaliduntil',
        \ 'FROM pg_roles',
        \ 'WHERE rolname = ' . s:literal(a:name),
        \ ])
endfunction

function! dbui_multidb#admin#postgresql#user_identity(db, name) abort
  return s:sql([
        \ 'SELECT rolname, oid, rolvaliduntil',
        \ 'FROM pg_roles',
        \ 'WHERE rolname = ' . s:literal(a:name),
        \ ])
endfunction

" The roles granted to this user.
function! dbui_multidb#admin#postgresql#user_roles(db, name) abort
  return s:sql([
        \ 'SELECT r.rolname AS granted_role, m.admin_option',
        \ 'FROM pg_auth_members m',
        \ 'JOIN pg_roles r ON r.oid = m.roleid',
        \ 'JOIN pg_roles u ON u.oid = m.member',
        \ 'WHERE u.rolname = ' . s:literal(a:name),
        \ 'ORDER BY r.rolname',
        \ ])
endfunction

function! dbui_multidb#admin#postgresql#user_grants(db, name) abort
  return s:sql([
        \ 'SELECT table_schema, table_name, privilege_type, is_grantable',
        \ 'FROM information_schema.role_table_grants',
        \ 'WHERE grantee = ' . s:literal(a:name),
        \ 'ORDER BY table_schema, table_name, privilege_type',
        \ ])
endfunction

" What the user can reach through the roles it is a member of: the grants held by
" those roles, which is the part of its access that is not granted to it directly.
function! dbui_multidb#admin#postgresql#user_effective_access(db, name) abort
  return s:sql([
        \ 'SELECT g.grantee AS via_role, g.table_schema, g.table_name, g.privilege_type',
        \ 'FROM information_schema.role_table_grants g',
        \ 'WHERE g.grantee IN (',
        \ '  SELECT r.rolname',
        \ '  FROM pg_auth_members m',
        \ '  JOIN pg_roles r ON r.oid = m.roleid',
        \ '  JOIN pg_roles u ON u.oid = m.member',
        \ '  WHERE u.rolname = ' . s:literal(a:name),
        \ ')',
        \ 'ORDER BY g.grantee, g.table_schema, g.table_name, g.privilege_type',
        \ ])
endfunction

" What dropping the role moves out from under the objects it owns.
function! dbui_multidb#admin#postgresql#user_dependencies(db, name) abort
  return s:sql([
        \ 'SELECT n.nspname AS schema, c.relname AS object, c.relkind AS kind',
        \ 'FROM pg_class c',
        \ 'JOIN pg_namespace n ON n.oid = c.relnamespace',
        \ 'JOIN pg_roles r ON r.oid = c.relowner',
        \ 'WHERE r.rolname = ' . s:literal(a:name),
        \ 'ORDER BY n.nspname, c.relname',
        \ ])
endfunction

function! dbui_multidb#admin#postgresql#user_activity(db, name) abort
  return s:sql([
        \ 'SELECT pid, usename, application_name, client_addr, state, query_start',
        \ 'FROM pg_stat_activity',
        \ 'WHERE usename = ' . s:literal(a:name),
        \ 'ORDER BY query_start',
        \ ])
endfunction

function! dbui_multidb#admin#postgresql#user_lock(db, name) abort
  return 'ALTER ROLE ' . s:ident(a:name) . ' NOLOGIN'
endfunction

" There is no password to invent, so the leaf pre-fills the removal of the
" password; the user replaces NULL with a literal when they mean to set one.
function! dbui_multidb#admin#postgresql#user_reset_password(db, name) abort
  return 'ALTER ROLE ' . s:ident(a:name) . ' PASSWORD NULL'
endfunction

function! dbui_multidb#admin#postgresql#user_drop(db, name) abort
  return 'DROP ROLE ' . s:ident(a:name)
endfunction

" ---------------------------------------------------------------------------
" Roles
"
" A role is the same catalog row as a user, so the leaves that only read the
" catalog delegate to the user ones; only the membership listing differs.
" ---------------------------------------------------------------------------

function! dbui_multidb#admin#postgresql#role_list(db, name) abort
  return s:sql([
        \ 'SELECT rolname, rolsuper, rolcanlogin, rolvaliduntil',
        \ 'FROM pg_roles',
        \ 'WHERE rolname = ' . s:literal(a:name),
        \ ])
endfunction

function! dbui_multidb#admin#postgresql#role_attributes(db, name) abort
  return dbui_multidb#admin#postgresql#user_attributes(a:db, a:name)
endfunction

function! dbui_multidb#admin#postgresql#role_identity(db, name) abort
  return dbui_multidb#admin#postgresql#user_identity(a:db, a:name)
endfunction

" The roles that are members of this role.
function! dbui_multidb#admin#postgresql#role_members(db, name) abort
  return s:sql([
        \ 'SELECT m.rolname AS member, a.admin_option',
        \ 'FROM pg_auth_members a',
        \ 'JOIN pg_roles r ON r.oid = a.roleid',
        \ 'JOIN pg_roles m ON m.oid = a.member',
        \ 'WHERE r.rolname = ' . s:literal(a:name),
        \ 'ORDER BY m.rolname',
        \ ])
endfunction

function! dbui_multidb#admin#postgresql#role_grants(db, name) abort
  return dbui_multidb#admin#postgresql#user_grants(a:db, a:name)
endfunction

function! dbui_multidb#admin#postgresql#role_dependencies(db, name) abort
  return dbui_multidb#admin#postgresql#user_dependencies(a:db, a:name)
endfunction

function! dbui_multidb#admin#postgresql#role_lock(db, name) abort
  return dbui_multidb#admin#postgresql#user_lock(a:db, a:name)
endfunction

function! dbui_multidb#admin#postgresql#role_reset_password(db, name) abort
  return dbui_multidb#admin#postgresql#user_reset_password(a:db, a:name)
endfunction

function! dbui_multidb#admin#postgresql#role_drop(db, name) abort
  return dbui_multidb#admin#postgresql#user_drop(a:db, a:name)
endfunction
