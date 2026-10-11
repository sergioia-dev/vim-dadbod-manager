" The mysql administration provider: the "Users" and "Roles" categories of the
" drawer's "Administration" section.
"
" This reads MySQL 8, where logins and roles live in the same table: a role is
" an account that cannot be logged in as. MySQL 8 has no column that says which
" is which (bug #84244), so the discriminator used here is the shape CREATE ROLE
" leaves behind - the account is locked, its password is expired and it has no
" authentication string. The system accounts MySQL ships with (mysql.sys and the
" rest) are locked as well but keep their authentication string, so they are
" listed as the accounts they are. A normal account is simply unlocked, so the
" filter is stable for a server nobody has hand-edited mysql.user on.
"
" MariaDB keeps roles differently (mysql.user is a view over global_priv with an
" is_role column) and vim-dadbod reaches it through a mariadb:// URL of its own.
" This provider does not claim that scheme: a mariadb connection draws no
" Administration section, rather than a section of failing statements.
"
" The account password is never written in SQL here. It is the connection's own,
" and db#adapter#mysql#interactive passes it to the client. The one literal
" secret in this file is "new-password" on the Reset password leaf, which is a
" placeholder for a human to replace.
"
" Every leaf only pre-fills a query buffer and the destructive ones ask first
" (see dbui_multidb#admin). Every <leaf> function takes the connection and the
" entity name and returns the statement of one leaf; returning '' (or not
" defining the function at all) hides that leaf.
"
" mysql's client cannot be asked for another field separator the way psql (-F) or
" sqlcmd (-s) can, so the two list statements build their own "|"-separated rows
" with concat_ws(), and its result goes through the section's parser unchanged.
" Every column of those rows is wrapped in ifnull(), because concat_ws() skips
" NULL and a skipped column would silently shift the rest of the row.
"
" An account is 'user'@'host' in MySQL; the drawer's entity name joins the two
" with "@", the way SHOW GRANTS writes it, because a tree path cannot carry the
" quotes. A user name may contain "@" while a host never does, so the name is
" split at the LAST "@" and a name without one means "this user on any host".

" ---------------------------------------------------------------------------
" Helpers
" ---------------------------------------------------------------------------

function! s:sql(lines) abort
  return join(a:lines, "\n")
endfunction

" A value as a MySQL string literal: 'value', with any inner ' doubled.
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

" An account entity name as MySQL writes accounts in a statement: 'user'@'host'.
function! s:account_spec(name) abort
  let [user, host] = s:account(a:name)
  return s:literal(user) . '@' . s:literal(host)
endfunction

" What CREATE ROLE leaves in mysql.user. Kept in one place because both list
" statements are two halves of the same question, and a server where the two
" disagree would show an account in both categories or in neither.
function! s:role_filter() abort
  return "account_locked = 'Y' AND password_expired = 'Y'"
        \ . " AND ifnull(authentication_string, '') = ''"
endfunction

" What CREATE USER leaves: everything that is not role-shaped, which is what the
" system accounts of a stock server are.
function! s:user_filter() abort
  return 'NOT (' . s:role_filter() . ')'
endfunction

" "active", "locked" or "expired", as MySQL describes an account's login state.
function! s:account_status(account_locked, password_expired) abort
  if a:account_locked ==# 'Y'
    return 'locked'
  endif
  return a:password_expired ==# 'Y' ? 'expired' : 'active'
endfunction

" ---------------------------------------------------------------------------
" Provider
" ---------------------------------------------------------------------------

" Both categories read mysql.user, which needs no privilege beyond the one the
" connection already has: it is the connection's own account row set. This runs
" while the drawer is drawn, so it is a static answer and never connects.
function! dbui_multidb#admin#mysql#supports(_) abort
  return {'users': 1, 'roles': 1}
endfunction

" The argv that runs one statement and prints one line per row. -N drops the
" column headers and -B is batch mode, which is what keeps the answer to one line
" per row; the rows are separated by the statement itself, not by the client.
function! dbui_multidb#admin#mysql#query_argv(db, sql) abort
  let url = dbui_multidb#url#resolve(get(a:db, 'url', ''))
  if empty(url)
    throw 'Could not resolve the administration connection URL'
  endif

  return db#adapter#mysql#interactive(url) + ['-N', '-B', '-e', a:sql]
endfunction

function! s:users_sql() abort
  return s:sql([
        \ "SELECT concat_ws('|', user, host, account_locked, password_expired)",
        \ 'FROM mysql.user',
        \ 'WHERE ' . s:user_filter(),
        \ 'ORDER BY user, host',
        \ ])
endfunction

function! s:roles_sql() abort
  return s:sql([
        \ "SELECT concat_ws('|', user, host)",
        \ 'FROM mysql.user',
        \ 'WHERE ' . s:role_filter(),
        \ 'ORDER BY user, host',
        \ ])
endfunction

" The accounts someone can connect as, as the server-side principal names MySQL
" itself uses.
function! dbui_multidb#admin#mysql#list_users(db) abort
  let users = []
  for row in dbui_multidb#admin#query(a:db, s:users_sql())
    if empty(row) || empty(row[0])
      continue
    endif
    call add(users, {
          \ 'name': row[0] . '@' . get(row, 1, ''),
          \ 'status': s:account_status(get(row, 2, ''), get(row, 3, '')),
          \ })
  endfor
  return users
endfunction

" The roles: the same table, the other half of the filter.
function! dbui_multidb#admin#mysql#list_roles(db) abort
  let roles = []
  for row in dbui_multidb#admin#query(a:db, s:roles_sql())
    if empty(row) || empty(row[0])
      continue
    endif
    let name = row[0] . '@' . get(row, 1, '')
    call add(roles, {'name': name, 'status': 'role'})
  endfor
  return roles
endfunction

" ---------------------------------------------------------------------------
" Users
" ---------------------------------------------------------------------------

" Every host this user name exists on: one name can be several accounts in
" MySQL, and the entity is only one of them.
function! dbui_multidb#admin#mysql#user_list(db, name) abort
  let [user; __] = s:account(a:name)
  return s:sql([
        \ "SELECT concat_ws('|', user, host, account_locked)",
        \ 'FROM mysql.user',
        \ 'WHERE user = ' . s:literal(user),
        \ 'ORDER BY host',
        \ ])
endfunction

function! dbui_multidb#admin#mysql#user_attributes(db, name) abort
  let [user, host] = s:account(a:name)
  return s:sql([
        \ "SELECT concat_ws('|', user, host, plugin, account_locked,",
        \ "       password_expired, ifnull(password_last_changed, ''),",
        \ "       ifnull(password_lifetime, ''))",
        \ 'FROM mysql.user',
        \ 'WHERE user = ' . s:literal(user) . ' AND host = ' . s:literal(host),
        \ ])
endfunction

" The CREATE USER statement that would rebuild this account, which is how MySQL
" shows an account's identity: its authentication plugin and its options.
function! dbui_multidb#admin#mysql#user_identity(db, name) abort
  return 'SHOW CREATE USER ' . s:account_spec(a:name)
endfunction

" The roles granted to this account. mysql.role_edges reads role -> grantee:
" from_user is the role, to_user the account that holds it.
function! dbui_multidb#admin#mysql#user_roles(db, name) abort
  let [user, host] = s:account(a:name)
  return s:sql([
        \ "SELECT concat(from_user, '@', from_host) AS granted_role",
        \ 'FROM mysql.role_edges',
        \ 'WHERE to_user = ' . s:literal(user)
        \ . ' AND to_host = ' . s:literal(host),
        \ 'ORDER BY from_user, from_host',
        \ ])
endfunction

" The account's own privileges and its granted roles: MySQL merges both into the
" SHOW GRANTS answer, so there is one leaf for the two of them.
function! dbui_multidb#admin#mysql#user_grants(db, name) abort
  return 'SHOW GRANTS FOR ' . s:account_spec(a:name)
endfunction

" MySQL has no counterpart of "the privileges this account would really have",
" short of impersonating it, so the leaf is hidden rather than answered with
" something that means less than its label says.
function! dbui_multidb#admin#mysql#user_effective_access(_db, _name) abort
  return ''
endfunction

" An account owns nothing in MySQL: schemas belong to databases, not to users.
function! dbui_multidb#admin#mysql#user_dependencies(_db, _name) abort
  return ''
endfunction

" The sessions this user name is connected as. information_schema.processlist is
" the same table SHOW PROCESSLIST fills, and one account can have several hosts,
" so the host is not filtered on.
function! dbui_multidb#admin#mysql#user_activity(db, name) abort
  let [user; __] = s:account(a:name)
  return s:sql([
        \ "SELECT concat_ws('|', id, user, ifnull(host, ''), ifnull(db, ''),",
        \ "       command, time, ifnull(state, ''), ifnull(info, ''))",
        \ 'FROM information_schema.processlist',
        \ 'WHERE user = ' . s:literal(user),
        \ 'ORDER BY id',
        \ ])
endfunction

function! dbui_multidb#admin#mysql#user_lock(db, name) abort
  return 'ALTER USER ' . s:account_spec(a:name) . ' ACCOUNT LOCK'
endfunction

" A reset has to name a new password, so the statement carries a placeholder for
" a human to replace; unlike PostgreSQL there is no "remove the password" form
" that would need no secret.
function! dbui_multidb#admin#mysql#user_reset_password(db, name) abort
  return 'ALTER USER ' . s:account_spec(a:name)
        \ . " IDENTIFIED BY 'new-password'"
endfunction

function! dbui_multidb#admin#mysql#user_drop(db, name) abort
  return 'DROP USER ' . s:account_spec(a:name)
endfunction

" ---------------------------------------------------------------------------
" Roles
" ---------------------------------------------------------------------------

function! dbui_multidb#admin#mysql#role_list(db, name) abort
  let [user, host] = s:account(a:name)
  return s:sql([
        \ "SELECT concat_ws('|', user, host, account_locked)",
        \ 'FROM mysql.user',
        \ 'WHERE user = ' . s:literal(user) . ' AND host = ' . s:literal(host),
        \ ])
endfunction

function! dbui_multidb#admin#mysql#role_attributes(db, name) abort
  let [user, host] = s:account(a:name)
  return s:sql([
        \ "SELECT concat_ws('|', user, host, plugin, account_locked,",
        \ "       password_expired, ifnull(password_last_changed, ''))",
        \ 'FROM mysql.user',
        \ 'WHERE user = ' . s:literal(user) . ' AND host = ' . s:literal(host),
        \ ])
endfunction

" A role is an account, and MySQL has no SHOW CREATE ROLE that would describe
" one as a role.
function! dbui_multidb#admin#mysql#role_identity(_db, _name) abort
  return ''
endfunction

" Who holds this role. mysql.role_edges reads role -> grantee, so the members are
" the to_ columns of the rows this role is the from_ of.
function! dbui_multidb#admin#mysql#role_members(db, name) abort
  let [user, host] = s:account(a:name)
  return s:sql([
        \ "SELECT concat(to_user, '@', to_host) AS member",
        \ 'FROM mysql.role_edges',
        \ 'WHERE from_user = ' . s:literal(user)
        \ . ' AND from_host = ' . s:literal(host),
        \ 'ORDER BY to_user, to_host',
        \ ])
endfunction

function! dbui_multidb#admin#mysql#role_grants(db, name) abort
  return 'SHOW GRANTS FOR ' . s:account_spec(a:name)
endfunction

function! dbui_multidb#admin#mysql#role_dependencies(_db, _name) abort
  return ''
endfunction

" A role cannot log in, so there is no login to lock or to give a password to;
" the two leaves the users category has are hidden here.
function! dbui_multidb#admin#mysql#role_lock(_db, _name) abort
  return ''
endfunction

function! dbui_multidb#admin#mysql#role_reset_password(_db, _name) abort
  return ''
endfunction

function! dbui_multidb#admin#mysql#role_drop(db, name) abort
  return 'DROP ROLE ' . s:account_spec(a:name)
endfunction
