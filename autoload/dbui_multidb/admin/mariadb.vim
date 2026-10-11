" The mariadb administration provider: the "Users" and "Roles" categories of the
" drawer's "Administration" section.
"
" MariaDB keeps logins and roles apart with an explicit column, so there is none
" of MySQL 8's guesswork here: a row of mysql.user with is_role = 'Y' is a role,
" anything else is an account. What the user view does NOT carry is whether an
" account is locked - MariaDB keeps that in the JSON each mysql.global_priv row
" holds in its Priv column - so the locked flag is read out of that JSON, and the
" statements that need it join the two catalogs on Host and User.
"
" Role membership lives in mysql.roles_mapping (MySQL calls it role_edges and
" stores the two halves in the opposite order): Host and User are the account a
" role is granted to, Role is the role. Roles themselves are stored in mysql.user
" with an empty Host, so a role is named by its bare name everywhere: SHOW GRANTS
" FOR 'role' and DROP ROLE 'role' take no host.
"
" The account password is never written in SQL here. It is the connection's own,
" and db#adapter#mariadb#interactive passes it to the client. The one literal
" secret in this file is "new-password" on the Reset password leaf, a placeholder
" for a human to replace.
"
" Every leaf only pre-fills a query buffer and the destructive ones ask first
" (see dbui_multidb#admin). Every <leaf> function takes the connection and the
" entity name and returns the statement of one leaf; returning '' (or not
" defining the function at all) hides that leaf.
"
" As with mysql, the client has no field-separator switch, so the list statements
" build their own "|"-separated rows with concat_ws(), every column wrapped in
" ifnull() because concat_ws() skips NULL and a skipped column would shift the
" rest of the row.
"
" An account is 'user'@'host'; the drawer's entity name joins the two with "@",
" the way SHOW GRANTS writes them, because a tree path cannot carry the quotes. A
" user name may contain "@" while a host never does, so the name is split at the
" LAST "@" and a name without one means "this user on any host".

" ---------------------------------------------------------------------------
" Helpers
" ---------------------------------------------------------------------------

function! s:sql(lines) abort
  return join(a:lines, "\n")
endfunction

" A value as a MariaDB string literal: 'value', with any inner ' doubled.
function! s:literal(value) abort
  return "'" . substitute(a:value, "'", "''", 'g') . "'"
endfunction

" The two halves of an account entity name, as [user, host].
function! s:account(name) abort
  let at = strridx(a:name, '@')
  if at < 0
    return [a:name, '%']
  endif
  return [strpart(a:name, 0, at), strpart(a:name, at + 1)]
endfunction

" An account entity name as MariaDB writes accounts in a statement: 'user'@'host'.
function! s:account_spec(name) abort
  let [user, host] = s:account(a:name)
  return s:literal(user) . '@' . s:literal(host)
endfunction

" A role entity name as MariaDB writes one in a statement: roles are named by their
" bare name, with no host part (SHOW GRANTS FOR 'role', DROP ROLE 'role').
function! s:role_spec(name) abort
  return s:literal(a:name)
endfunction

" "active", "locked" or "expired", from the two flags MariaDB keeps apart: the
" password_expired column of the user view, and account_locked out of the
" global_priv JSON.
function! s:status(password_expired, locked) abort
  if a:locked ==# '1'
    return 'locked'
  endif
  return a:password_expired ==# 'Y' ? 'expired' : 'active'
endfunction

" The account_locked flag of an account, read from the JSON MariaDB keeps in
" mysql.global_priv.Priv. JSON_VALUE() answers '1' when the key is present and
" true and '' otherwise. The statements that use this join mysql.user u against
" mysql.global_priv g.
function! s:locked() abort
  return "IFNULL(JSON_VALUE(g.Priv, '$.account_locked'), '')"
endfunction

" The join every account-listing statement shares: the user view for the account
" columns and global_priv for the locked flag the view does not expose.
function! s:user_from() abort
  return [
        \ 'FROM mysql.user u',
        \ 'JOIN mysql.global_priv g ON g.Host = u.Host AND g.User = u.User',
        \ ]
endfunction

" ---------------------------------------------------------------------------
" Provider
" ---------------------------------------------------------------------------

" Both categories read catalogs the connection's own login may see, and this runs
" while the drawer is drawn, so it is a static answer and never connects.
function! dbui_multidb#admin#mariadb#supports(_) abort
  return {'users': 1, 'roles': 1}
endfunction

" The argv that runs one statement and prints one line per row. -N drops the
" column headers and -B is batch mode; the rows are separated by the statement
" itself, not by the client.
function! dbui_multidb#admin#mariadb#query_argv(db, sql) abort
  let url = dbui_multidb#url#resolve(get(a:db, 'url', ''))
  if empty(url)
    throw 'Could not resolve the administration connection URL'
  endif

  return db#adapter#mariadb#interactive(url) + ['-N', '-B', '-e', a:sql]
endfunction

function! s:users_sql() abort
  return s:sql([
        \ "SELECT CONCAT_WS('|', u.User, u.Host, IFNULL(u.password_expired, ''), "
        \ . s:locked() . ')',
        \ ] + s:user_from() + [
        \ "WHERE IFNULL(u.is_role, 'N') <> 'Y'",
        \ 'ORDER BY u.User, u.Host',
        \ ])
endfunction

function! s:roles_sql() abort
  return s:sql([
        \ 'SELECT User',
        \ 'FROM mysql.user',
        \ "WHERE is_role = 'Y'",
        \ 'ORDER BY User',
        \ ])
endfunction

" The accounts someone can connect as, as the server-side principal names MariaDB
" itself uses.
function! dbui_multidb#admin#mariadb#list_users(db) abort
  let users = []
  for row in dbui_multidb#admin#query(a:db, s:users_sql())
    if empty(row) || empty(row[0])
      continue
    endif
    call add(users, {
          \ 'name': row[0] . '@' . get(row, 1, ''),
          \ 'status': s:status(get(row, 2, ''), get(row, 3, '')),
          \ })
  endfor
  return users
endfunction

" The roles: the rows of mysql.user MariaDB marks with is_role = 'Y'. A role is a
" bare name, not an account, so its host is not carried in the entity name.
function! dbui_multidb#admin#mariadb#list_roles(db) abort
  let roles = []
  for row in dbui_multidb#admin#query(a:db, s:roles_sql())
    if empty(row) || empty(row[0])
      continue
    endif
    call add(roles, {'name': row[0], 'status': 'role'})
  endfor
  return roles
endfunction

" ---------------------------------------------------------------------------
" Users
" ---------------------------------------------------------------------------

" Every host this user name exists on: one name can be several accounts, and the
" entity is only one of them.
function! dbui_multidb#admin#mariadb#user_list(db, name) abort
  let [user; __] = s:account(a:name)
  return s:sql([
        \ "SELECT CONCAT_WS('|', u.User, u.Host, IFNULL(u.password_expired, ''), "
        \ . s:locked() . ')',
        \ ] + s:user_from() + [
        \ 'WHERE u.User = ' . s:literal(user),
        \ 'ORDER BY u.Host',
        \ ])
endfunction

function! dbui_multidb#admin#mariadb#user_attributes(db, name) abort
  let [user, host] = s:account(a:name)
  return s:sql([
        \ "SELECT CONCAT_WS('|', u.User, u.Host, IFNULL(u.plugin, ''), IFNULL(u.password_expired, ''),",
        \ '       ' . s:locked() . ',',
        \ "       IFNULL(JSON_VALUE(g.Priv, '$.password_last_changed'), ''))",
        \ ] + s:user_from() + [
        \ 'WHERE u.User = ' . s:literal(user) . ' AND u.Host = ' . s:literal(host),
        \ ])
endfunction

" The CREATE USER statement that would rebuild this account, which is how MariaDB
" shows an account's identity: its authentication plugin, its lock and its expiry.
function! dbui_multidb#admin#mariadb#user_identity(db, name) abort
  return 'SHOW CREATE USER ' . s:account_spec(a:name)
endfunction

" The roles granted to this account. roles_mapping reads role -> grantee: Host
" and User are the account, Role is the role it holds.
function! dbui_multidb#admin#mariadb#user_roles(db, name) abort
  let [user, host] = s:account(a:name)
  return s:sql([
        \ 'SELECT Role',
        \ 'FROM mysql.roles_mapping',
        \ 'WHERE User = ' . s:literal(user) . ' AND Host = ' . s:literal(host),
        \ 'ORDER BY Role',
        \ ])
endfunction

function! dbui_multidb#admin#mariadb#user_grants(db, name) abort
  return 'SHOW GRANTS FOR ' . s:account_spec(a:name)
endfunction

" MariaDB has no counterpart of "the privileges this account would really have",
" short of impersonating it, so the leaf is hidden rather than answered with
" something that means less than its label says.
function! dbui_multidb#admin#mariadb#user_effective_access(_db, _name) abort
  return ''
endfunction

" An account owns nothing in MariaDB: schemas belong to databases, not to users.
function! dbui_multidb#admin#mariadb#user_dependencies(_db, _name) abort
  return ''
endfunction

" The sessions this user name is connected as. information_schema.processlist is
" the same table SHOW PROCESSLIST fills, and one account can have several hosts,
" so the host is not filtered on.
function! dbui_multidb#admin#mariadb#user_activity(db, name) abort
  let [user; __] = s:account(a:name)
  return s:sql([
        \ "SELECT CONCAT_WS('|', ID, USER, IFNULL(HOST, ''), IFNULL(DB, ''), COMMAND, TIME, IFNULL(STATE, ''), IFNULL(INFO, ''))",
        \ 'FROM information_schema.processlist',
        \ 'WHERE USER = ' . s:literal(user),
        \ 'ORDER BY ID',
        \ ])
endfunction

function! dbui_multidb#admin#mariadb#user_lock(db, name) abort
  return 'ALTER USER ' . s:account_spec(a:name) . ' ACCOUNT LOCK'
endfunction

" A reset has to name a new password, so the statement carries a placeholder for
" a human to replace.
function! dbui_multidb#admin#mariadb#user_reset_password(db, name) abort
  return 'ALTER USER ' . s:account_spec(a:name)
        \ . " IDENTIFIED BY 'new-password'"
endfunction

function! dbui_multidb#admin#mariadb#user_drop(db, name) abort
  return 'DROP USER ' . s:account_spec(a:name)
endfunction

" ---------------------------------------------------------------------------
" Roles
" ---------------------------------------------------------------------------

function! dbui_multidb#admin#mariadb#role_list(db, name) abort
  return s:sql([
        \ 'SELECT User',
        \ 'FROM mysql.user',
        \ "WHERE is_role = 'Y' AND User = " . s:literal(a:name),
        \ ])
endfunction

function! dbui_multidb#admin#mariadb#role_attributes(db, name) abort
  return s:sql([
        \ "SELECT CONCAT_WS('|', User, IFNULL(is_role, ''), IFNULL(plugin, ''), IFNULL(password_expired, ''))",
        \ 'FROM mysql.user',
        \ "WHERE is_role = 'Y' AND User = " . s:literal(a:name),
        \ ])
endfunction

" MariaDB has no SHOW CREATE ROLE; a role is a row of mysql.user, which the
" Attributes leaf already describes.
function! dbui_multidb#admin#mariadb#role_identity(_db, _name) abort
  return ''
endfunction

" Who holds this role. roles_mapping reads role -> grantee, so the members are the
" Host and User of the rows this role is the Role of.
function! dbui_multidb#admin#mariadb#role_members(db, name) abort
  return s:sql([
        \ "SELECT CONCAT(User, '@', Host) AS member",
        \ 'FROM mysql.roles_mapping',
        \ 'WHERE Role = ' . s:literal(a:name),
        \ 'ORDER BY User, Host',
        \ ])
endfunction

function! dbui_multidb#admin#mariadb#role_grants(db, name) abort
  return 'SHOW GRANTS FOR ' . s:role_spec(a:name)
endfunction

function! dbui_multidb#admin#mariadb#role_dependencies(_db, _name) abort
  return ''
endfunction

" A role cannot log in, so there is no login to lock or to give a password to;
" the two leaves the users category has are hidden here.
function! dbui_multidb#admin#mariadb#role_lock(_db, _name) abort
  return ''
endfunction

function! dbui_multidb#admin#mariadb#role_reset_password(_db, _name) abort
  return ''
endfunction

function! dbui_multidb#admin#mariadb#role_drop(db, name) abort
  return 'DROP ROLE ' . s:literal(a:name)
endfunction
