" The per-database "Administration" section of the drawer.
"
" Every expanded database whose scheme has an administration provider gets one,
" between what vim-dadbod-ui drew for it (Schemas, Tables, saved queries) and the
" "Backups" section: a level 1 toggle that expands into the category toggles the
" provider serves ("Users", "Roles") and, under those, one toggle per entity plus
" the actions that act on it.
"
" A provider is a per-scheme function-name prefix registered with
" dbui_multidb#admin#register(), e.g. 'dbui_multidb#admin#postgresql#'. It
" answers three questions:
"
"   <prefix>supports(db)              category name -> truthy when it can be served
"   <prefix>list_<category>(db)       [{ 'name': ..., 'status': ... }, ...]
"   <prefix><leaf>_<section>(db, name) the SQL of one leaf, or '' to hide the leaf
"
" supports() runs while the drawer is being drawn, so it has to be cheap and must
" not touch the database: it is a static answer for the scheme, not a probe. The
" list_* functions are the only ones that connect, once per category, on the
" category's first expansion.
"
" Read-only leaves are ordinary query items: they reuse db_ui#query#open(), so the
" SQL lands in a real query buffer under the connection, pre-filled and never
" executed. Destructive leaves are separated from the read-only ones by a rule and
" go through dbui_multidb#admin#confirm() before their buffer is opened.
"
" Two upstream behaviours carry the section, exactly like the Backups one:
"
"   * s:drawer.toggle_line() flips ".expanded" on the dict it finds under the item
"     type on the database entry, so every state has to live in a dict on the
"     entry -- the section's in a dict named like the top-level type, a
"     category's and an entity's under a "->" path, which is what
"     s:drawer.get_nested() walks. An entity name therefore cannot contain "->".
"   * s:drawer.add() takes the level, so the section nests under a database that
"     was already drawn at level 1 (a discovered child of a server node).
"
" The state is seeded even when the section is hidden: a missing key would make
" the toggle a silent no-op instead of an error.
let s:type = 'dbui_multidb_administration'
let s:danger_type = 'dbui_multidb_admin_danger'
let s:type_path = s:type . '->'

" The rule between an entity's read-only actions and its destructive ones.
let s:separator = repeat('─', 24)

" The known categories and their leaves. A leaf is one action under one entity:
" <leaf>_<suffix> is looked up on the provider. A provider hides a leaf it cannot
" offer by not defining the function or by returning an empty string from it.
let s:categories = [
      \ {'name': 'users', 'label': 'Users', 'prefix': 'user',
      \  'leaves': [
      \    {'suffix': 'list', 'label': 'List'},
      \    {'suffix': 'attributes', 'label': 'Attributes'},
      \    {'suffix': 'identity', 'label': 'Identity'},
      \    {'suffix': 'roles', 'label': 'Roles'},
      \    {'suffix': 'grants', 'label': 'Grants'},
      \    {'suffix': 'effective_access', 'label': 'Effective access'},
      \    {'suffix': 'dependencies', 'label': 'Dependencies'},
      \    {'suffix': 'activity', 'label': 'Activity'},
      \  ],
      \  'danger': [
      \    {'suffix': 'lock', 'label': 'Lock'},
      \    {'suffix': 'reset_password', 'label': 'Reset password'},
      \    {'suffix': 'drop', 'label': 'Drop'},
      \  ]},
      \ {'name': 'roles', 'label': 'Roles', 'prefix': 'role',
      \  'leaves': [
      \    {'suffix': 'list', 'label': 'List'},
      \    {'suffix': 'attributes', 'label': 'Attributes'},
      \    {'suffix': 'identity', 'label': 'Identity'},
      \    {'suffix': 'members', 'label': 'Members'},
      \    {'suffix': 'grants', 'label': 'Grants'},
      \    {'suffix': 'dependencies', 'label': 'Dependencies'},
      \  ],
      \  'danger': [
      \    {'suffix': 'lock', 'label': 'Lock'},
      \    {'suffix': 'reset_password', 'label': 'Reset password'},
      \    {'suffix': 'drop', 'label': 'Drop'},
      \  ]},
      \ ]

" The providers of this installation: scheme -> function-name prefix. Rebuilt
" here so a reload restores the built-in providers and forgets the rest.
let s:providers = {}

function! dbui_multidb#admin#register(scheme, prefix) abort
  if empty(a:prefix)
    call remove(s:providers, a:scheme)
    return
  endif
  let s:providers[a:scheme] = a:prefix
endfunction

" The providers that ship with the plugin: function-name prefix -> the schemes
" that prefix answers to. A provider is listed next to every scheme whose URLs
" that prefix answers to. vim-dadbod gives mysql:// and mariadb:// connections
" their own adapters, and each scheme has its own provider because the two
" servers keep their catalogs differently.
" Their autoload files are not sourced here: calling into a provider prefix
" loads its file on first use, and a provider that is never used is never read.
let s:builtin = {
      \ 'dbui_multidb#admin#postgresql#': ['postgresql'],
      \ 'dbui_multidb#admin#mysql#': ['mysql'],
      \ 'dbui_multidb#admin#mariadb#': ['mariadb'],
      \ 'dbui_multidb#admin#sqlserver#': ['sqlserver'],
      \ 'dbui_multidb#admin#mongodb#': ['mongodb'],
      \ 'dbui_multidb#admin#redis#': ['redis'],
      \ }

function! s:register_builtins() abort
  for [prefix, schemes] in items(s:builtin)
    for scheme in schemes
      call dbui_multidb#admin#register(scheme, prefix)
    endfor
  endfor
endfunction

call s:register_builtins()

" Forget every registered provider and reload the built-in ones. Mainly for
" tests, but also the way to drop a provider a plugin added.
function! dbui_multidb#admin#reset() abort
  let s:providers = {}
  call s:register_builtins()
endfunction

" The categories a provider can serve, in the drawer's order.
function! dbui_multidb#admin#categories() abort
  return s:categories
endfunction

" The function-name prefix of the provider of a database, or '' when its scheme
" has none.
function! dbui_multidb#admin#provider(db) abort
  let scheme = dbui_multidb#url#scheme(get(a:db, 'url', ''))
  return get(s:providers, scheme, '')
endfunction

" The categories a database's provider can serve, as the provider's category ->
" answer dict. A number means yes, with the category's own name. A non-empty
" string means yes and names the category for the drawer, which is how a server
" that calls its users something else - SQL Server and its logins - says so.
" An empty answer means "draw no section". A provider that throws is treated as
" absent, so a broken provider hides its section instead of aborting the render.
"
" The autoload of the provider prefix is only triggered by calling into it, and
" the function does not exist before that, so a missing prefix has to surface as
" E117 caught here rather than be probed with exists().
function! dbui_multidb#admin#supports(db) abort
  let prefix = dbui_multidb#admin#provider(a:db)
  if empty(prefix)
    return {}
  endif

  try
    let supported = call(prefix . 'supports', [a:db])
  catch /.*/
    return {}
  endtry

  if type(supported) !=# type({})
    return {}
  endif
  " 'v:val' would be read as a Number, so the label string of a renamed
  " category ('Logins', 'Server roles') would be a zero and drop it.
  return filter(supported, '!empty(v:val)')
endfunction

" The metadata of every category a database's provider serves, in the drawer's
" order. The copies are what keeps a provider from writing into the table every
" render shares: a provider that renames a category answers with a string, and
" that name belongs to this answer alone.
function! dbui_multidb#admin#categories_for(db) abort
  let supported = dbui_multidb#admin#supports(a:db)

  let categories = []
  for category in s:categories
    let answer = get(supported, category.name, 0)
    " An empty answer is a no; a label string is a yes and must not be read
    " as a number ('Logins' would be a zero and skip the category).
    if empty(answer)
      continue
    endif
    if type(answer) ==# type('') && !empty(answer)
      call add(categories, extend(copy(category), {'label': answer}))
    else
      call add(categories, copy(category))
    endif
  endfor
  return categories
endfunction

" The icon of a toggle of the section. Read out of g:db_ui_icons rather than
" through the drawer's get_toggle_icon(), which indexes the icon tables by item
" type and throws E716 for a type vim-dadbod-ui does not know about. A theme
" that defines db_ui_icons.expanded.dbui_multidb_administration wins, then a flat
" db_ui_icons.administration, then the "tables" icon, which is the same mark
" vim-dadbod-ui puts on the section a database's contents hang off.
function! dbui_multidb#admin#icon(expanded) abort
  let icons = get(g:, 'db_ui_icons', {})
  if type(icons) !=# type({})
    return ''
  endif

  let bucket = get(icons, a:expanded ? 'expanded' : 'collapsed', {})
  if type(bucket) !=# type({})
    let bucket = {}
  endif

  for icon in [get(bucket, s:type, ''), get(icons, 'administration', ''), get(bucket, 'tables', ''), get(icons, 'tables', '')]
    if type(icon) ==# type('') && !empty(icon)
      return icon
    endif
  endfor

  return ''
endfunction

" The state of one database's section, seeded on the entry if it is not there.
function! dbui_multidb#admin#state(db) abort
  if !has_key(a:db, s:type) || type(a:db[s:type]) !=# type({})
    let a:db[s:type] = {'expanded': 0}
  endif
  return a:db[s:type]
endfunction

" The state of one category, seeded on the section state if it is not there.
" "items" holds one entry per entity, in the shape the entity toggle needs.
function! dbui_multidb#admin#category_state(state, name) abort
  if !has_key(a:state, a:name) || type(a:state[a:name]) !=# type({})
    let a:state[a:name] = {'expanded': 0, 'loaded': 0, 'list': [], 'items': {}, 'error': ''}
  endif
  return a:state[a:name]
endfunction

" A category's list, fetched from the provider on the first expansion and then
" kept. On failure the category is kept with the error in ".error" and no
" entities, so the drawer shows one broken node rather than losing the section.
function! dbui_multidb#admin#load_category(db, category, state) abort
  if a:state.loaded
    return a:state
  endif
  let a:state.loaded = 1
  let a:state.error = ''

  let prefix = dbui_multidb#admin#provider(a:db)
  if empty(prefix)
    return a:state
  endif

  try
    let entities = call(prefix . 'list_' . a:category.name, [a:db])
  catch /.*/
    let a:state.error = v:exception
    return a:state
  endtry

  if type(entities) !=# type([])
    let a:state.error = 'the provider returned no list'
    return a:state
  endif

  let a:state.list = filter(copy(entities), 'type(v:val) ==# type({}) && !empty(get(v:val, "name", ""))')
  return a:state
endfunction

" name -> status, or "name" alone when the provider has no status for it.
function! dbui_multidb#admin#entity_label(entity) abort
  let name = get(a:entity, 'name', '')
  let status = get(a:entity, 'status', '')
  return empty(status) ? name : printf('%s (%s)', name, status)
endfunction

" One leaf of an entity: its SQL as the provider builds it, or '' when the
" provider does not offer it (missing function, empty string, or an exception).
function! dbui_multidb#admin#leaf_sql(db, category, leaf, name) abort
  let prefix = dbui_multidb#admin#provider(a:db)
  if empty(prefix)
    return ''
  endif

  try
    let sql = call(prefix . a:category.prefix . '_' . a:leaf.suffix, [a:db, a:name])
  catch /.*/
    return ''
  endtry

  return type(sql) ==# type('') ? sql : ''
endfunction

" The items of one database's section, in the exact shape s:drawer.add() stores:
" the "Administration" toggle at base_level, and, when the section is expanded,
" its category toggles one level below, and so on. Pure: it neither touches the
" drawer nor the buffer, so a render and an in-place refresh build the section
" the same way.
"
" The section's own label carries no count: nothing has been listed yet at that
" point, and listing every category to count it would mean connecting for a
" collapsed node. A category gains its count once it has been expanded.
function! dbui_multidb#admin#section_items(db, base_level) abort
  let state = dbui_multidb#admin#state(a:db)
  let items = [{
        \ 'label': 'Administration',
        \ 'action': 'toggle',
        \ 'type': s:type,
        \ 'icon': dbui_multidb#admin#icon(state.expanded),
        \ 'dbui_db_key_name': a:db.key_name,
        \ 'level': a:base_level,
        \ 'expanded': state.expanded,
        \ }]
  if !state.expanded
    return items
  endif

  for category in dbui_multidb#admin#categories_for(a:db)
    call extend(items, dbui_multidb#admin#category_items(a:db, category, state, a:base_level + 1))
  endfor
  return items
endfunction

" The items of one category: its toggle, and, when expanded, one toggle per
" entity.
function! dbui_multidb#admin#category_items(db, category, state, base_level) abort
  let state = dbui_multidb#admin#category_state(a:state, a:category.name)
  if state.expanded && !state.loaded
    call dbui_multidb#admin#load_category(a:db, a:category, state)
  endif

  let label = a:category.label
  if !empty(state.error)
    let label .= ' ' . state.error
  elseif state.loaded
    let label = printf('%s (%d)', a:category.label, len(state.list))
  endif

  let items = [{
        \ 'label': label,
        \ 'action': 'toggle',
        \ 'type': s:type_path . a:category.name,
        \ 'icon': dbui_multidb#admin#icon(state.expanded),
        \ 'dbui_db_key_name': a:db.key_name,
        \ 'level': a:base_level,
        \ 'expanded': state.expanded,
        \ }]
  if !state.expanded
    return items
  endif

  if !empty(state.error)
    call add(items, {
          \ 'label': 'Unavailable',
          \ 'action': 'noaction',
          \ 'type': 'help',
          \ 'icon': '',
          \ 'dbui_db_key_name': a:db.key_name,
          \ 'level': a:base_level + 1,
          \ })
    return items
  endif

  for entity in state.list
    call extend(items, dbui_multidb#admin#entity_items(a:db, a:category, state, entity, a:base_level + 1))
  endfor
  return items
endfunction

" The items of one entity: its toggle, and, when expanded, its read-only leaves,
" a rule and its destructive leaves.
function! dbui_multidb#admin#entity_items(db, category, state, entity, base_level) abort
  let name = get(a:entity, 'name', '')
  if empty(name)
    return []
  endif

  let path = s:type_path . a:category.name . '->items->' . name
  if !has_key(a:state.items, name) || type(a:state.items[name]) !=# type({})
    let a:state.items[name] = {'expanded': 0}
  endif
  let entity_state = a:state.items[name]

  let items = [{
        \ 'label': dbui_multidb#admin#entity_label(a:entity),
        \ 'action': 'toggle',
        \ 'type': path,
        \ 'icon': dbui_multidb#admin#icon(entity_state.expanded),
        \ 'dbui_db_key_name': a:db.key_name,
        \ 'level': a:base_level,
        \ 'expanded': entity_state.expanded,
        \ }]
  if !entity_state.expanded
    return items
  endif

  let read_only = []
  for leaf in a:category.leaves
    let sql = dbui_multidb#admin#leaf_sql(a:db, a:category, leaf, name)
    if empty(sql)
      continue
    endif
    call add(read_only, dbui_multidb#admin#leaf_item(a:db, leaf, name, sql, a:base_level + 1))
  endfor

  let destructive = []
  for leaf in a:category.danger
    let sql = dbui_multidb#admin#leaf_sql(a:db, a:category, leaf, name)
    if empty(sql)
      continue
    endif
    call add(destructive, dbui_multidb#admin#danger_item(a:db, leaf, name, sql, a:base_level + 1))
  endfor

  " The rule only earns its line when there is something on both sides of it.
  if !empty(read_only) && !empty(destructive)
    call add(read_only, {
          \ 'label': s:separator,
          \ 'action': 'noaction',
          \ 'type': 'help',
          \ 'icon': '',
          \ 'dbui_db_key_name': a:db.key_name,
          \ 'level': a:base_level + 1,
          \ })
  endif

  return items + read_only + destructive
endfunction

" One read-only leaf. Its shape is the one s:query.open() reads: "table" and
" "label" name the query buffer, "content" fills it, and "type" is not "query"
" nor "buffer" so the table-helper path is taken. It is never executed by us.
function! dbui_multidb#admin#leaf_item(db, leaf, name, sql, level) abort
  return {
        \ 'label': a:leaf.label,
        \ 'action': 'open',
        \ 'type': 'table',
        \ 'icon': '',
        \ 'dbui_db_key_name': a:db.key_name,
        \ 'level': a:level,
        \ 'table': a:name,
        \ 'schema': '',
        \ 'content': a:sql,
        \ }
endfunction

" One destructive leaf. It is a call_method item: the drawer dispatches it to
" the instance method named like its type, which is dbui_multidb#admin#danger().
" It carries everything s:query.open() needs, because danger() opens the very
" same kind of buffer once the confirmation passed.
function! dbui_multidb#admin#danger_item(db, leaf, name, sql, level) abort
  return {
        \ 'label': a:leaf.label,
        \ 'action': 'call_method',
        \ 'type': s:danger_type,
        \ 'icon': '',
        \ 'dbui_db_key_name': a:db.key_name,
        \ 'level': a:level,
        \ 'table': a:name,
        \ 'schema': '',
        \ 'content': a:sql,
        \ 'dbui_admin_confirm': printf('%s %s in database %s?', a:leaf.label, a:name, a:db.name),
        \ }
endfunction

" Append the section to a database the drawer just drew. Called by the add_db
" patch, so a:db is the real entry from drawer.dbui.dbs and the returned state
" survives a re-render. Returns 1 when the section was added, 0 when the
" configuration turns it off, the scheme has no provider, or the database is
" collapsed.
function! dbui_multidb#admin#append(drawer, db) abort
  call dbui_multidb#admin#state(a:db)
  if empty(get(dbui_multidb#config#get(), 'admin_section', 1))
    return 0
  endif
  " The section belongs to an expanded database only: a collapsed node keeps
  " the exact shape vim-dadbod-ui draws for it.
  if !get(a:db, 'expanded', 0)
    return 0
  endif
  if empty(dbui_multidb#admin#supports(a:db))
    return 0
  endif

  call extend(a:drawer.content, dbui_multidb#admin#section_items(a:db, 1))
  return 1
endfunction

" Ask a yes/no question and answer whether the user said yes. Wrapped so tests
" can stub the dialog; confirm() is not stubbable.
function! dbui_multidb#admin#confirm(question) abort
  return confirm(a:question, "&Yes\n&No", 2, 'Warning') == 1
endfunction

" <CR> on a destructive leaf, dispatched by the drawer to the instance method of
" the same name as the item type (see s:drawer.toggle_line()). The confirmation
" comes first and is the only reason this is not an ordinary "open" leaf: the
" statement is a DDL change on the server. Cancel leaves the connection as it was.
function! dbui_multidb#admin#danger() abort dict
  let item = self.get_current_item()
  if type(item) !=# type({}) || get(item, 'type', '') !=# s:danger_type
    return 0
  endif

  if !dbui_multidb#admin#confirm(get(item, 'dbui_admin_confirm', 'Run this statement?'))
    return 0
  endif

  return self.get_query().open(item, 'edit')
endfunction

" The client that would run an argv, or '' when none can be named: the first
" element that is neither env, nor a VAR=VAL environment setting, nor an option.
function! s:client(argv) abort
  for arg in a:argv
    if arg ==# 'env' || arg =~# '=' || arg =~# '^-'
      continue
    endif
    return arg
  endfor
  return ''
endfunction

" Run an argv (list form, so no shell) and return a dict of its stdout lines,
" stderr lines and exit status. The list form of systemlist() merges stderr into
" the output, so a client's warning (mariadb's "deprecated program name", say)
" would leak into the rows; the job API keeps the two streams apart, so the rows
" stay clean and a real error can be reported instead of listed.
"
" This mirrors db#systemlist()'s env handling: an argv may start with env and
" VAR=VAL pairs (the sqlserver adapter passes SQLCMDPASSWORD that way).
function! s:run(argv) abort
  if !has('nvim')
    return {'out': systemlist(a:argv), 'err': [], 'status': v:shell_error}
  endif

  let result = {'out': [''], 'err': [''], 'status': -1}
  let cmd = copy(a:argv)
  let env = {}
  if get(cmd, 0, '') ==# 'env'
    call remove(cmd, 0)
    while get(cmd, 0, '') =~# '^\w\+='
      let env[matchstr(cmd[0], '^\w\+')] = matchstr(cmd[0], '=\zs.*')
      call remove(cmd, 0)
    endwhile
  endif

  let job = jobstart(cmd, {
        \ 'env': env,
        \ 'on_stdout': function('s:job_cb', [result.out]),
        \ 'on_stderr': function('s:job_cb', [result.err]),
        \ 'on_exit': function('s:job_exit', [result]),
        \ })
  if job <= 0
    throw printf('the %s client could not be started', get(cmd, 0, ''))
  endif
  call jobwait([job])

  " The seed line a chunk never appended to is still there; drop a trailing
  " empty line, whether that seed or a final newline the stream ended with.
  for key in ['out', 'err']
    if empty(result[key][-1])
      call remove(result[key], -1)
    endif
  endfor
  return result
endfunction

" nvim may deliver one stream line as two: a chunk that does not end in a newline
" is continued by the first line of the next chunk. Join the halves, so a row is
" never cut at the field separator. This is the joining db.vim's own job callback
" does.
function! s:job_cb(lines, job, data, event) abort
  let a:lines[-1] .= a:data[0]
  call extend(a:lines, a:data[1:])
endfunction

function! s:job_exit(result, job, status, event) abort
  let a:result.status = a:status
endfunction

" Run one statement through a database's provider and return its rows, one list
" of fields per row. The providers are the only callers: they hand over SQL they
" built themselves, and the argv that runs it is theirs too.
"
" A missing or failing client surfaces as an error rather than an empty answer,
" which is what keeps a silent failure from being drawn as a (0) category; the
" client's stderr, when there is one, rides along in the error.
function! dbui_multidb#admin#query(db, sql) abort
  let prefix = dbui_multidb#admin#provider(a:db)
  if empty(prefix)
    throw 'No administration provider for this database'
  endif

  let argv = call(prefix . 'query_argv', [a:db, a:sql])
  let client = s:client(argv)
  if !empty(client) && !executable(client)
    throw printf('%s is not installed', client)
  endif

  try
    let result = s:run(argv)
  catch
    throw printf('%s could not be run: %s', empty(client) ? 'The client' : client, v:exception)
  endtry

  if result.status
    let detail = empty(result.err) ? '' : ' ' . substitute(join(result.err, ' '), '\s\+', ' ', 'g')
    throw printf('the %s client failed (status %d)%s',
          \ empty(client) ? 'database' : client, result.status, detail)
  endif

  return map(result.out, 'split(v:val, "|")')
endfunction
