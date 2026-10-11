" The sqlserver administration provider: the "Logins" and "Server roles"
" categories of the drawer's "Administration" section.
"
" SQL Server has no users at the server level: what a connection can be is a
" login (a SQL login, a Windows login or a Windows group) or a server role, and
" the server calls them that. The categories are still the drawer's Users and
" Roles, so the section's state keys, its leaf functions and its labels are the
" ones of every other provider; only the label the tree shows is overridden, by
" answering dbui_multidb#admin#supports() with a string per category.
"
" Both catalogs are server-wide. A SQL Server connection is usually a server node
" whose child databases each draw a section, and every one of them shows the same
" logins and the same server roles, because that is what they are.
"
" The statements are written for SQL Server 2016 and later: sys.server_principals
" and sys.server_role_members for the principal catalogs, sys.sql_logins for what
" only a SQL login has, sys.server_permissions for its grants, sys.dm_exec_sessions
" for its sessions, sys.schemas for what it owns.
"
" Every leaf only pre-fills a query buffer and the destructive ones ask first
" (see dbui_multidb#admin). Every <leaf> function takes the connection and the
" entity name and returns the statement of one leaf; returning '' (or not
" defining the function at all) hides that leaf.
"
" Server principal names are the names SQL Server itself uses, backslashes and
" spaces included: 'NT AUTHORITY\SYSTEM' is a login, and several built-in roles
" are called '##MS_Something##'. They are written as string literals (N'...',
" with any inner ' doubled) everywhere a value is meant, and as identifiers
" ([...], with any inner ] doubled) where a statement names the principal it acts
" on.

" ---------------------------------------------------------------------------
" Helpers
" ---------------------------------------------------------------------------

function! s:sql(lines) abort
  return join(a:lines, "\n")
endfunction

" A name as a T-SQL string literal: N'name', with any inner ' doubled. The N is
" not decoration: server principal names are nvarchar, and a Windows name that is
" not plain ASCII has to survive the round trip.
function! s:literal(name) abort
  return "N'" . substitute(a:name, "'", "''", 'g') . "'"
endfunction

" A name as a T-SQL identifier: [name], with any inner ] doubled.
function! s:ident(name) abort
  return '[' . substitute(a:name, ']', ']]', 'g') . ']'
endfunction

" "active", "group" or "disabled", which is what a login's type and its disabled
" flag say about it.
function! s:login_status(type_desc, is_disabled) abort
  if a:is_disabled ==# '1'
    return 'disabled'
  endif
  return a:type_desc ==# 'WINDOWS_GROUP' ? 'group' : 'active'
endfunction

" Which server roles cannot be dropped is not in an entity name and not in the
" answer of a leaf builder, which only sees the connection and the name. It is
" remembered here while the Roles category is listed, which is what happens
" before any role entity can be drawn at all. Keyed by connection, because the
" drawer can hold several servers and two of them may have a role of the same
" name; keyed to a copy, so a second listing replaces the first and a role that
" is gone does not keep its old answer.
let s:fixed_roles = {}

function! s:connection_key(db) abort
  return get(a:db, 'url', '') . "\n" . get(a:db, 'name', '')
endfunction

function! s:remember_fixed_roles(db, roles) abort
  let s:fixed_roles[s:connection_key(a:db)] = a:roles
endfunction

" True for a role that cannot be dropped: the fixed roles the server ships with,
" and public, which SQL Server reports as not fixed and still refuses to drop.
function! s:fixed_role(db, name) abort
  return get(get(s:fixed_roles, s:connection_key(a:db), {}), a:name, 0)
endfunction

" ---------------------------------------------------------------------------
" Provider
" ---------------------------------------------------------------------------

" Strings, because the drawer would say "Users" and "Roles" where the server says
" "Logins" and "Server roles". Both catalogs are readable by any login, and this
" runs while the drawer is drawn, so it is a static answer and never connects.
function! dbui_multidb#admin#sqlserver#supports(_) abort
  return {'users': 'Logins', 'roles': 'Server roles'}
endfunction

" The argv that runs one statement and prints one line per row. -h -1 drops the
" column headers, -W trims the trailing blanks a fixed-width answer would carry
" and -s '|' is the field separator, which is the one the section's parser reads.
" -b makes the client exit non-zero when a statement fails, which is what turns a
" failing category into an error instead of an empty list; SET NOCOUNT ON keeps
" the "N rows affected" line out of the rows.
function! dbui_multidb#admin#sqlserver#query_argv(db, sql) abort
  let url = dbui_multidb#url#resolve(get(a:db, 'url', ''))
  if empty(url)
    throw 'Could not resolve the administration connection URL'
  endif

  return db#adapter#sqlserver#interactive(url)
        \ + ['-b', '-h', '-1', '-W', '-s', '|', '-Q', 'SET NOCOUNT ON; ' . a:sql]
endfunction

" The logins: the principal types a connection can be made with. Server roles are
" type R and are the other category; the certificates and keys SQL Server keeps
" as principals are types of their own and are not logins a human manages.
function! s:logins_sql() abort
  return s:sql([
        \ 'SELECT name, type_desc, is_disabled',
        \ 'FROM sys.server_principals',
        \ "WHERE type IN ('S', 'U', 'G')",
        \ 'ORDER BY name',
        \ ])
endfunction

function! s:roles_sql() abort
  return s:sql([
        \ 'SELECT name, is_fixed_role',
        \ 'FROM sys.server_principals',
        \ "WHERE type = 'R'",
        \ 'ORDER BY name',
        \ ])
endfunction

function! dbui_multidb#admin#sqlserver#list_users(db) abort
  let users = []
  for row in dbui_multidb#admin#query(a:db, s:logins_sql())
    if empty(row) || empty(row[0])
      continue
    endif
    call add(users, {
          \ 'name': row[0],
          \ 'status': s:login_status(get(row, 1, ''), get(row, 2, '')),
          \ })
  endfor
  return users
endfunction

" The server roles, fixed ones included: sysadmin is the role that matters most
" on most servers, and hiding it would hide who can do everything.
function! dbui_multidb#admin#sqlserver#list_roles(db) abort
  let roles = []
  let fixed = {}
  for row in dbui_multidb#admin#query(a:db, s:roles_sql())
    if empty(row) || empty(row[0])
      continue
    endif
    let name = row[0]
    if get(row, 1, '') ==# '1' || name ==# 'public'
      let fixed[name] = 1
    endif
    call add(roles, {
          \ 'name': name,
          \ 'status': get(fixed, name, 0) ? 'fixed' : 'user-defined',
          \ })
  endfor
  call s:remember_fixed_roles(a:db, fixed)
  return roles
endfunction

" ---------------------------------------------------------------------------
" Logins
" ---------------------------------------------------------------------------

function! dbui_multidb#admin#sqlserver#user_list(db, name) abort
  return s:sql([
        \ 'SELECT name, type_desc, is_disabled',
        \ 'FROM sys.server_principals',
        \ 'WHERE name = ' . s:literal(a:name),
        \ ])
endfunction

" What a login is: its type, whether it can connect, and the SQL-login settings
" of it. The left join is what makes one statement describe a Windows login (no
" row in sys.sql_logins, so the right half is empty) and a SQL login alike.
function! dbui_multidb#admin#sqlserver#user_attributes(db, name) abort
  return s:sql([
        \ 'SELECT sp.name, sp.type_desc, sp.is_disabled, sp.default_database_name,',
        \ '       sl.default_database_name, sl.default_language_name,',
        \ '       sl.is_policy_checked, sl.is_expiration_checked,',
        \ '       sl.password_last_changed, sp.create_date, sp.modify_date',
        \ 'FROM sys.server_principals sp',
        \ 'LEFT JOIN sys.sql_logins sl ON sl.principal_id = sp.principal_id',
        \ 'WHERE sp.name = ' . s:literal(a:name),
        \ ])
endfunction

" The principal id and the SID, which is what a login is to the server itself.
function! dbui_multidb#admin#sqlserver#user_identity(db, name) abort
  return s:sql([
        \ 'SELECT principal_id, sid, name, type_desc, create_date, modify_date',
        \ 'FROM sys.server_principals',
        \ 'WHERE name = ' . s:literal(a:name),
        \ ])
endfunction

" The server roles this login is a member of. SUSER_ID() is what makes the
" statement work for a name with backslashes in it: the name is a literal, not
" something the statement has to parse as a path.
function! dbui_multidb#admin#sqlserver#user_roles(db, name) abort
  return s:sql([
        \ 'SELECT r.name AS role_name',
        \ 'FROM sys.server_role_members m',
        \ 'JOIN sys.server_principals r ON r.principal_id = m.role_principal_id',
        \ 'WHERE m.member_principal_id = SUSER_ID(' . s:literal(a:name) . ')',
        \ 'ORDER BY r.name',
        \ ])
endfunction

" The permissions granted or denied to this login directly. What it has through
" its roles is the Effective access leaf.
function! dbui_multidb#admin#sqlserver#user_grants(db, name) abort
  return s:sql([
        \ 'SELECT class_desc, permission_name, state_desc',
        \ 'FROM sys.server_permissions',
        \ 'WHERE grantee_principal_id = SUSER_ID(' . s:literal(a:name) . ')',
        \ 'ORDER BY permission_name',
        \ ])
endfunction

" What this login can really do at the server level, its roles included. There is
" no catalog view for the effective permissions of another principal, so the
" statement becomes it for the length of one batch and asks for its own. Running
" it needs the IMPERSONATE permission on the login, which the server says so
" about if it is missing.
function! dbui_multidb#admin#sqlserver#user_effective_access(db, name) abort
  return 'EXECUTE AS LOGIN = ' . s:literal(a:name)
        \ . '; SELECT permission_name FROM sys.fn_my_permissions(NULL, ''SERVER'')'
        \ . '; REVERT'
endfunction

" What this login owns: schemas are owned by principals, and a login that owns
" one cannot simply be dropped.
function! dbui_multidb#admin#sqlserver#user_dependencies(db, name) abort
  return s:sql([
        \ 'SELECT s.name AS owned_schema',
        \ 'FROM sys.schemas s',
        \ 'WHERE s.principal_id = SUSER_ID(' . s:literal(a:name) . ')',
        \ 'ORDER BY s.name',
        \ ])
endfunction

function! dbui_multidb#admin#sqlserver#user_activity(db, name) abort
  return s:sql([
        \ 'SELECT session_id, login_name, status, host_name, program_name',
        \ 'FROM sys.dm_exec_sessions',
        \ 'WHERE login_name = ' . s:literal(a:name),
        \ 'AND is_user_process = 1',
        \ 'ORDER BY session_id',
        \ ])
endfunction

function! dbui_multidb#admin#sqlserver#user_lock(db, name) abort
  return 'ALTER LOGIN ' . s:ident(a:name) . ' DISABLE'
endfunction

" A reset has to name a new password, so the statement carries a placeholder for
" a human to replace. A Windows login has no password of its own, and the server
" says so if this is written for one.
function! dbui_multidb#admin#sqlserver#user_reset_password(db, name) abort
  return 'ALTER LOGIN ' . s:ident(a:name)
        \ . " WITH PASSWORD = N'new-password'"
endfunction

function! dbui_multidb#admin#sqlserver#user_drop(db, name) abort
  return 'DROP LOGIN ' . s:ident(a:name)
endfunction

" ---------------------------------------------------------------------------
" Server roles
" ---------------------------------------------------------------------------

function! dbui_multidb#admin#sqlserver#role_list(db, name) abort
  return s:sql([
        \ 'SELECT name, is_fixed_role',
        \ 'FROM sys.server_principals',
        \ 'WHERE name = ' . s:literal(a:name),
        \ ])
endfunction

function! dbui_multidb#admin#sqlserver#role_attributes(db, name) abort
  return s:sql([
        \ 'SELECT name, type_desc, is_fixed_role, create_date, modify_date',
        \ 'FROM sys.server_principals',
        \ 'WHERE name = ' . s:literal(a:name),
        \ ])
endfunction

function! dbui_multidb#admin#sqlserver#role_identity(db, name) abort
  return s:sql([
        \ 'SELECT principal_id, sid, name, type_desc',
        \ 'FROM sys.server_principals',
        \ 'WHERE name = ' . s:literal(a:name),
        \ ])
endfunction

" The logins and roles this role holds. One role can be a member of another, and
" both are principals, so the members are read from the same catalog as a login's
" roles.
function! dbui_multidb#admin#sqlserver#role_members(db, name) abort
  return s:sql([
        \ 'SELECT m.name AS member_name',
        \ 'FROM sys.server_role_members rm',
        \ 'JOIN sys.server_principals m ON m.principal_id = rm.member_principal_id',
        \ 'WHERE rm.role_principal_id = SUSER_ID(' . s:literal(a:name) . ')',
        \ 'ORDER BY m.name',
        \ ])
endfunction

function! dbui_multidb#admin#sqlserver#role_grants(db, name) abort
  return s:sql([
        \ 'SELECT class_desc, permission_name, state_desc',
        \ 'FROM sys.server_permissions',
        \ 'WHERE grantee_principal_id = SUSER_ID(' . s:literal(a:name) . ')',
        \ 'ORDER BY permission_name',
        \ ])
endfunction

function! dbui_multidb#admin#sqlserver#role_dependencies(db, name) abort
  return s:sql([
        \ 'SELECT s.name AS owned_schema',
        \ 'FROM sys.schemas s',
        \ 'WHERE s.principal_id = SUSER_ID(' . s:literal(a:name) . ')',
        \ 'ORDER BY s.name',
        \ ])
endfunction

" A role is not a login: there is nothing to disable and no password to set, so
" the two leaves the logins category has are hidden here.
function! dbui_multidb#admin#sqlserver#role_lock(_db, _name) abort
  return ''
endfunction

function! dbui_multidb#admin#sqlserver#role_reset_password(_db, _name) abort
  return ''
endfunction

" The Drop leaf follows the Roles listing: the fixed roles of a server cannot be
" dropped, and offering the statement for one would only produce an error.
function! dbui_multidb#admin#sqlserver#role_drop(db, name) abort
  if s:fixed_role(a:db, a:name)
    return ''
  endif
  return 'DROP ROLE ' . s:ident(a:name)
endfunction
