" The redis administration provider: the "Users" category of the drawer's
" "Administration" section.
"
" Redis has exactly one principal catalog: the ACL users. The command categories
" ACL CAT lists (read, write, admin, dangerous and the rest) are fixed command
" groups, not things a user can be created from or granted, so there is no Roles
" category here; only Users is claimed.
"
" A redis connection is never a server node - its adapter does not answer
" complete_database - so the section hangs directly off the connection, not under
" a list of database children.
"
" Every leaf only pre-fills a query buffer and the destructive ones ask first
" (see dbui_multidb#admin). Every <leaf> function takes the connection and the
" entity name and returns the command of one leaf; returning '' (or not defining
" the function at all) hides that leaf.
"
" The statements are redis-cli commands. The client's own pretty printing (the
" numbered "1) ..." form it uses on a terminal) is turned off with --raw, because
" the list parser reads one resource per line and the numbers would otherwise
" leak into the rows. A name is written as one command word, and the ACL command
" language has no way to quote a name with whitespace in it, so a leaf that would
" have to is hidden instead of building an ambiguous command.

" ---------------------------------------------------------------------------
" Helpers
" ---------------------------------------------------------------------------

" A name as one ACL command word, or '' when the name cannot be one: an ACL
" username is a single whitespace-delimited token, so a name with whitespace in
" it cannot be written as an argument. A leaf that answers '' is hidden, which is
" the honest thing for such a name.
function! s:name(name) abort
  return empty(a:name) || a:name =~# '\s' ? '' : a:name
endfunction

" ---------------------------------------------------------------------------
" Provider
" ---------------------------------------------------------------------------

" A static answer: the ACL catalog is readable by the connection's own login, and
" this runs while the drawer is drawn, never connects.
function! dbui_multidb#admin#redis#supports(_) abort
  return {'users': 1}
endfunction

" The argv that runs one command. --raw is explicit because the pretty printer is
" what a client on a terminal gets, and vim-dadbod's environment does not promise
" one kind of tty or the other. The command arrives as one string, so it is split
" into its words; no redis leaf needs an argument that contains whitespace.
function! dbui_multidb#admin#redis#query_argv(db, sql) abort
  let url = dbui_multidb#url#resolve(get(a:db, 'url', ''))
  if empty(url)
    throw 'Could not resolve the administration connection URL'
  endif

  return db#adapter#redis#interactive(url) + ['--raw'] + split(a:sql)
endfunction

" The ACL users. ACL LIST prints one "user <name> <on|off> <flags...>" per line;
" the name is the word after "user" and the state is the on/off word, found as a
" word rather than by position so a future change to the flag order cannot break
" it.
function! dbui_multidb#admin#redis#list_users(db) abort
  let users = []
  for row in dbui_multidb#admin#query(a:db, 'ACL LIST')
    let line = empty(row) ? '' : row[0]
    let name = matchstr(line, '^user \zs\S\+')
    if empty(name)
      continue
    endif
    let words = split(line, ' ')
    call add(users, {
          \ 'name': name,
          \ 'status': index(words, 'on') >= 0 ? 'on' : 'off',
          \ })
  endfor
  return users
endfunction

" ---------------------------------------------------------------------------
" Users
" ---------------------------------------------------------------------------

function! dbui_multidb#admin#redis#user_list(_db, _name) abort
  return ''
endfunction

" The account as ACL GETUSER describes it: its flags, key patterns and command
" rules, one field per line.
function! dbui_multidb#admin#redis#user_attributes(db, name) abort
  let name = s:name(a:name)
  return empty(name) ? '' : 'ACL GETUSER ' . name
endfunction

function! dbui_multidb#admin#redis#user_identity(_db, _name) abort
  return ''
endfunction

" A user has no roles in redis: the command categories it may run are reported by
" ACL GETUSER as its command rules, which is the Attributes leaf.
function! dbui_multidb#admin#redis#user_roles(_db, _name) abort
  return ''
endfunction

function! dbui_multidb#admin#redis#user_grants(_db, _name) abort
  return ''
endfunction

function! dbui_multidb#admin#redis#user_effective_access(_db, _name) abort
  return ''
endfunction

function! dbui_multidb#admin#redis#user_dependencies(_db, _name) abort
  return ''
endfunction

" The connected clients. Redis reports these server-wide and CLIENT LIST has no
" per-user filter in every version, so the leaf is the whole list and the user's
" lines are the ones whose user= field names it.
function! dbui_multidb#admin#redis#user_activity(_db, _name) abort
  return 'CLIENT LIST'
endfunction

function! dbui_multidb#admin#redis#user_lock(db, name) abort
  let name = s:name(a:name)
  return empty(name) ? '' : 'ACL SETUSER ' . name . ' off'
endfunction

" A reset here means "forget the passwords": the next time this user wants to
" connect it must set one, because the nopass state is gone and no password
" remains. There is no way to set a password to a known value from the command
" line, which is why the reset takes no new password.
function! dbui_multidb#admin#redis#user_reset_password(db, name) abort
  let name = s:name(a:name)
  return empty(name) ? '' : 'ACL SETUSER ' . name . ' resetpass'
endfunction

function! dbui_multidb#admin#redis#user_drop(db, name) abort
  let name = s:name(a:name)
  return empty(name) ? '' : 'ACL DELUSER ' . name
endfunction
