" Test suite for vim-dadbod-manager.
"
" Plain Vimscript on purpose: the plugin is pure Vimscript, so the suite only
" needs a headless nvim with vim-dadbod installed; the drawer is vendored in this
" test/run.sh, which reports the "RESULT: ok|failed" line printed at the end.

" A globpath check rather than exists('*db#resolve'): autoload functions do not
" exist until their script has been sourced once.
if empty(globpath(&runtimepath, 'autoload/db.vim')) || empty(globpath(&runtimepath, 'autoload/db_ui.vim'))
  echo 'vim-dadbod must be on the runtimepath and the vendored drawer must load; run test/run.sh'
  cquit 1
endif

let s:failures = []
let s:checks = 0
" <sfile> is the script path only at script level; inside a function it expands to
" the function name, so the plugin root is resolved once, here.
let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')

function! s:ok(cond, msg) abort
  let s:checks += 1
  if !a:cond
    call add(s:failures, a:msg)
  endif
endfunction

function! s:eq(actual, expected, msg) abort
  call s:ok(a:actual ==# a:expected,
        \ printf('%s (expected %s, got %s)', a:msg, string(a:expected), string(a:actual)))
endfunction

function! s:index_of(lines, pattern) abort
  for i in range(0, len(a:lines) - 1)
    if a:lines[i] =~# a:pattern
      return i
    endif
  endfor
  return -1
endfunction

" The test runner for backups: it records a plan instead of spawning anything.
" It is a global function because g:dbui_multidb_backup_runner is read as a
" function name (a Funcref cannot live in a lowercase-named global, E704).
function! DbuiMultidbTestRecordBackup(plan) abort
  call add(g:dbui_multidb_test_backup_plans, a:plan)
endfunction

" Back to a pristine state: no drawer, no connections, no configuration.
function! s:reset() abort
  call db_ui#reset_state()
  silent! %bwipeout!
  let g:dbs = {}
  for key in keys(dbui_multidb#config#defaults())
    execute 'unlet! g:dbui_multidb_' . key
  endfor
  let g:dbui_multidb_test_dbs = []
  let g:dbui_multidb_test_tables = []
  let g:dbui_multidb_test_calls = []
  " Backups are never spawned: the directory is a tempdir and the runner records
  " every plan instead of running it.
  let g:dbui_multidb_backup_dir = tempname()
  let g:dbui_multidb_backup_runner = 'DbuiMultidbTestRecordBackup'
  let g:dbui_multidb_test_backup_plans = []
  call dbui_multidb#backup#reset()
endfunction
" Notifications are collected instead of displayed so a test can assert on what
" the user is told. This replaces upstream notifiers; s:end_capture() puts them
" back (the suite runs s:test_notify last for the same reason).
let s:notifications = []
function! s:begin_capture(...) abort
  let s:notifications = []
  function! db_ui#notifications#warning(msg, ...) abort
    call add(s:notifications, {'kind': 'warning', 'message': a:msg})
  endfunction
  function! db_ui#notifications#error(msg, ...) abort
    call add(s:notifications, {'kind': 'error', 'message': a:msg})
  endfunction
  " info notifications are off by default (g:db_ui_disable_info_notifications
  " is set in minimal_init), so capturing them is opt-in: the backup tests need
  " the "Backup started/finished" messages.
  if get(a:, 1, 0)
    function! db_ui#notifications#info(msg, ...) abort
      call add(s:notifications, {'kind': 'info', 'message': a:msg})
    endfunction
  endif
endfunction

function! s:end_capture() abort
  runtime autoload/db_ui/notifications.vim
endfunction

function! s:notified() abort
  return map(copy(s:notifications), 'v:val.message')
endfunction

" ":messages" keeps everything echoed so far, so its newest non-empty line is the
" whole assertion: the notification label is what the user reads.
function! s:last_message() abort
  let lines = filter(split(execute('messages'), "\n"), '!empty(v:val)')
  return lines[-1]
endfunction

" The file that last defined the notifier, i.e. which copy of the module is in
" charge: 'verbose function' prints "Last set from <path> line <n>".
function! s:notifier_source() abort
  " Load the module first: 'function <name>' on an undefined name raises E123,
  " and autoload only happens on the first call.
  runtime autoload/db_ui/notifications.vim
  return matchstr(execute('verbose function db_ui#notifications#warning'),
        \ '\S\+notifications\.vim')
endfunction

function! s:test_config() abort
  call s:reset()

  let cfg = dbui_multidb#config#get()
  call s:eq(cfg.masters, [], 'masters defaults to an empty list')
  call s:eq(cfg.exclude, [], 'exclude defaults to an empty list')
  call s:eq(cfg.sort, 1, 'sort is on by default')
  call s:eq(cfg.cache, 1, 'cache is on by default')
  call s:eq(cfg.notify, 1, 'notify is on by default')

  call dbui_multidb#setup({'masters': 'Server One, Server Two', 'sort': 0})
  call s:eq(dbui_multidb#masters(), ['Server One', 'Server Two'],
        \ 'a comma separated masters value is split and trimmed')
  call s:eq(dbui_multidb#config#get().sort, 0, 'setup overrides a default')

  call dbui_multidb#setup({'masters': ['Server One'], 'exclude': '^mysql$, ^information_schema$, '})
  call s:eq(dbui_multidb#config#get().exclude, ['^mysql$', '^information_schema$'],
        \ 'exclude accepts a comma separated string and drops empty entries')
endfunction

function! s:test_is_master() abort
  call s:reset()
  call dbui_multidb#setup({'masters': ['Rama Local MySQL']})

  call s:ok(dbui_multidb#is_master({'name': 'rama local mysql', 'key_name': 'Rama Local MySQL_g:dbs'}),
        \ 'server matching is case insensitive')
  call s:ok(!dbui_multidb#is_master({'name': 'Rama Local MySQL', 'is_child': 1}),
        \ 'discovered databases are never servers')
  call s:ok(!dbui_multidb#is_master({'name': 'Banco Production'}), 'unlisted connections are not servers')
  call s:ok(!dbui_multidb#is_master({}), 'an empty connection is not a server')
  call s:ok(!dbui_multidb#is_master('Banco Production'), 'a non dict argument is not a server')
endfunction

function! s:test_url() abort
  call s:reset()

  let pg = 'postgresql://user:pw@pg.example.com/master?channel_binding=require&sslmode=require'
  let child = dbui_multidb#url#with_database(pg, 'neondb')
  let parsed = db#url#parse(child)
  call s:eq(parsed.path, '/neondb', 'postgresql: the database is replaced')
  call s:eq(get(parsed.params, 'sslmode', ''), 'require', 'postgresql: sslmode survives')
  call s:eq(get(parsed.params, 'channel_binding', ''), 'require', 'postgresql: channel_binding survives')
  call s:ok(child !~# 'master', 'postgresql: the master database name is gone')

  let mysql = 'mysql://root@127.0.0.1:3306/'
  call s:eq(db#url#parse(dbui_multidb#url#with_database(mysql, 'alpha')).path, '/alpha',
        \ 'mysql: the database is added to the path')

  let ado = 'sqlserver://sa:dummy@localhost:1433;database=master;user=sa;password=dummy;encrypt=optional'
  let child = dbui_multidb#url#with_database(db#resolve(ado), 'mydb')
  let parsed = db#url#parse(child)
  call s:eq(parsed.path, '/mydb', 'sqlserver: the database is replaced')
  call s:eq(get(parsed.params, 'encrypt', ''), 'optional', 'sqlserver: connection options survive')

  call s:eq(db#url#parse(dbui_multidb#url#with_database('sqlite:/var/lib/app.db', 'other.db')).opaque,
        \ '/var/lib/other.db', 'sqlite: an absolute path keeps its directory')
  call s:eq(db#url#parse(dbui_multidb#url#with_database('sqlite:relative/app.db', 'other.db')).opaque,
        \ 'relative/other.db', 'sqlite: a relative path keeps its directory')

  call s:eq(db#url#parse(dbui_multidb#url#with_database('snowflake://acct', 'mydb')).path, '/mydb',
        \ 'snowflake: a host only URL gains a path')
  call s:eq(db#url#parse(dbui_multidb#url#with_database('postgresql://u@h/master', 'my db')).path, '/my db',
        \ 'a database name with a space is usable')

  call s:eq(dbui_multidb#url#scheme('mongodb+srv://u@h/master'), 'mongodb+srv', 'the scheme is extracted')
  call s:eq(dbui_multidb#url#resolve('nosuchdb://u@h'), '', 'an unresolvable URL resolves to an empty string')
endfunction

function! s:test_discovery() abort
  call s:reset()
  call dbui_multidb#setup({'masters': ['Server']})

  let g:dbui_multidb_test_dbs = ['zeta', 'Alpha', 'alpha', '', 'beta']
  let result = dbui_multidb#discover#names('fakedb://u@h/master', 'Server')
  call s:eq(result.error, '', 'discovery succeeds')
  call s:eq(result.names, ['Alpha', 'beta', 'zeta'],
        \ 'discovery drops empties, dedupes case insensitively and sorts')
  call s:eq(len(g:dbui_multidb_test_calls), 1, 'discovery asks the adapter exactly once')

  call dbui_multidb#setup({'sort': 0})
  call s:eq(dbui_multidb#discover#names('fakedb://u@h/master').names, ['zeta', 'Alpha', 'beta'],
        \ 'sorting can be turned off')

  call dbui_multidb#setup({'exclude': ['^mysql$', 'schema$']})
  let g:dbui_multidb_test_dbs = ['mysql', 'information_schema', 'app', 'public']
  call s:eq(dbui_multidb#discover#names('fakedb://u@h/master').names, ['app', 'public'],
        \ 'exclude patterns are regular expressions')

  let result = dbui_multidb#discover#names('sqlite:/var/lib/app.db')
  call s:eq(result.names, [], 'an unsupported scheme returns no names')
  call s:ok(result.error =~# 'does not support', 'an unsupported scheme explains itself')

  let result = dbui_multidb#discover#names('nosuchdb://u@h')
  call s:ok(!empty(result.error), 'an unknown scheme reports an error instead of throwing')

  let result = dbui_multidb#discover#names('')
  call s:ok(!empty(result.error), 'an empty URL reports an error instead of throwing')
endfunction

function! s:test_drawer() abort
  call s:reset()
  let g:dbs = {'Server': 'fakedb://u@h/master', 'Plain': 'sqlite:/var/lib/plain.db'}
  let g:dbui_multidb_test_dbs = ['beta', 'alpha', '']
  let g:dbui_multidb_test_tables = ['orders', 'users']
  call dbui_multidb#setup({'masters': ['Server']})

  DBManager
  call s:eq(&filetype, 'dbui', 'the drawer buffer has the dbui filetype')

  let drawer = db_ui#drawer#get()
  call s:ok(dbui_multidb#patch#is_patched(drawer), 'the drawer instance is patched')

  let collapsed = g:db_ui_icons.collapsed.db
  let expanded = g:db_ui_icons.expanded.db

  let lines = getline(1, '$')
  call s:eq(len(lines), 2, 'a collapsed tree has one line per connection')
  let server = s:index_of(lines, 'Server$')
  call s:eq(lines[server], collapsed . ' Server', 'a server node is drawn like a connection')
  call s:ok(s:index_of(lines, 'Plain$') > -1, 'connections that are not servers are untouched')

  " Expand the server node exactly like <Plug>(DBUI_SelectLine) does.
  call cursor(server + 1, 1)
  call drawer.toggle_line('')
  let lines = getline(1, '$')
  let server = s:index_of(lines, 'Server$')
  call s:eq(lines[server], expanded . ' Server', 'an expanded server node shows the expanded icon')
  call s:eq(lines[server + 1], '  " Databases (2)', 'an expanded server node announces its databases')
  call s:eq(lines[server + 2], '  ' . collapsed . ' alpha', 'databases are drawn one level down, sorted')
  call s:eq(lines[server + 3], '  ' . collapsed . ' beta', 'every discovered database is drawn')

  let dbs = drawer.dbui.dbs
  call s:ok(has_key(dbs, 'Server_g:dbs::alpha'), 'a database is keyed by its server and name')
  call s:eq(dbs['Server_g:dbs::alpha'].url, 'fakedb://u@h/alpha', 'a database URL points at its own database')
  call s:eq(dbs['Server_g:dbs::alpha'].master_key_name, 'Server_g:dbs', 'a database knows its server')
  call s:eq(dbs['Server_g:dbs::alpha'].source, 'master', 'a database is sourced from its server')
  call s:eq(dbs['Server_g:dbs::alpha'].db_name, 'alpha', 'a database reports its own name')
  call s:eq(len(drawer.dbui.dbs_list), 2, 'databases are not added to dbs_list')
  call s:eq(len(g:dbui_multidb_test_calls), 1, 'expanding a server discovers its databases once')
  let base = len(getline(1, '$'))

  " Re-rendering must neither rediscover nor collapse the tree.
  call drawer.render()
  call s:eq(len(g:dbui_multidb_test_calls), 1, 'a plain re-render reuses the cached discovery')
  call s:eq(len(getline(1, '$')), base, 'a plain re-render keeps the tree expanded')

  " Files and sections of a database render one level further down.
  call cursor(s:index_of(lines, 'alpha$') + 1, 1)
  call drawer.toggle_line('')
  let lines = getline(1, '$')
  " An expanded database is connected, which vim-dadbod-ui decorates.
  call s:eq(lines[server + 2],
        \ '  ' . expanded . ' alpha ' . g:db_ui_icons.connection_ok,
        \ 'a database can be expanded too')
  call s:eq(lines[server + 3], '    ' . g:db_ui_icons.new_query . ' New query',
        \ 'a database renders its sections one more level down')
  call s:ok(s:index_of(lines, 'Saved queries (0)$') > -1, 'a database renders its saved queries')
  call s:ok(s:index_of(lines, 'Tables (2)$') > -1, 'a database renders its tables')
  call s:eq(drawer.dbui.dbs['Server_g:dbs::alpha'].expanded, 1, 'a database keeps its expansion state')
  call s:eq(lines[server + 6], '    ' . g:db_ui_icons.collapsed.tables . ' Administrative',
        \ 'a database appends its Administrative section after its tables')

  call cursor(s:index_of(lines, 'alpha$') + 1, 1)
  call drawer.toggle_line('')
  let lines = getline(1, '$')
  call s:eq(len(lines), base, 'collapsing a database removes its sections')

  " R on a server node refreshes it, both through the mapping and the command.
  call cursor(server + 1, 1)
  call drawer.redraw()
  call s:eq(len(g:dbui_multidb_test_calls), 2, 'R on a server node rediscovers')
  call s:eq(len(getline(1, '$')), base, 'the tree is rebuilt after R')

  call s:eq(dbui_multidb#refresh('NoSuchServer'), 0, 'refreshing an unknown server reports failure')
  call s:eq(len(g:dbui_multidb_test_calls), 2, 'a failed refresh does not query the adapter')
  call s:eq(dbui_multidb#refresh('Server'), 1, 'refreshing a server by name succeeds')
  call s:eq(len(g:dbui_multidb_test_calls), 3, 'refreshing a server rediscovers')
  call s:eq(len(getline(1, '$')), base, 'the tree is rebuilt after a refresh')

  let info = dbui_multidb#info()
  call s:ok(s:index_of(info, 'Server: 2 database(s): alpha, beta') > -1, 'info reports the databases')
  call s:ok(s:index_of(info, 'patch:.*installed') > -1, 'info reports the patch state')
endfunction

function! s:test_discovery_error() abort
  call s:reset()
  let g:dbs = {'Local': 'sqlite:/var/lib/plain.db'}
  call dbui_multidb#setup({'masters': ['Local']})

  call s:begin_capture()
  DBManager
  let drawer = db_ui#drawer#get()
  call cursor(s:index_of(getline(1, '$'), 'Local$') + 1, 1)
  call drawer.toggle_line('')
  let lines = getline(1, '$')
  call s:eq(lines[s:index_of(lines, 'Local')],
        \ g:db_ui_icons.expanded.db . ' Local ' . g:db_ui_icons.connection_error,
        \ 'a scheme that cannot be discovered is marked as a failed server')
  call s:ok(s:index_of(lines, 'does not support database discovery') < 0,
        \ 'the reason is not painted into the drawer')
  call s:ok(s:index_of(lines, 'No databases found') < 0, 'no empty database list is drawn after an error')
  call s:eq(len(s:notifications), 1, 'a discovery failure is reported once')
  call s:eq(s:notifications[0].kind, 'warning', 'a discovery failure is a warning, not an error')
  call s:ok(s:notifications[0].message =~# 'Local: "sqlite" does not support database discovery',
        \ 'the notification names the server and the reason')
  call s:eq(len(g:dbui_multidb_test_calls), 0, 'the adapter is never asked for an unsupported scheme')
  call s:end_capture()
endfunction

" A server whose client is not installed must never paint Neovim's exception
" into the drawer. The user gets one notification naming the client to install,
" the node carries the connection_error icon, and every other driver keeps
" working.
function! s:test_missing_client() abort
  call s:reset()
  let g:dbs = {'Banco Production': 'fakebin://u@h/master', 'Server': 'fakedb://u@h/master'}
  let g:dbui_multidb_test_dbs = ['alpha']
  call dbui_multidb#setup({'masters': ['Banco Production', 'Server']})

  let collapsed = g:db_ui_icons.collapsed.db
  let expanded = g:db_ui_icons.expanded.db
  let failed = g:db_ui_icons.connection_error

  call s:begin_capture()
  DBManager
  let drawer = db_ui#drawer#get()

  let lines = getline(1, '$')
  let broken = s:index_of(lines, 'Banco Production$')
  call s:ok(broken > -1, 'a server with a missing client is still listed')
  call s:eq(len(s:notifications), 0, 'a collapsed server is not discovered, so nothing is reported')

  call cursor(broken + 1, 1)
  call drawer.toggle_line('')
  let lines = getline(1, '$')
  let broken = s:index_of(lines, 'Banco Production')
  call s:eq(lines[broken], expanded . ' Banco Production ' . failed,
        \ 'a server whose discovery failed is marked like a failed connection')
  call s:eq(lines[broken + 1], collapsed . ' Server',
        \ 'a failed discovery adds no line to the drawer')
  call s:ok(s:index_of(lines, 'E475') < 0, 'the raw E475 never reaches the drawer')
  call s:ok(s:index_of(lines, 'is not installed') < 0, 'the drawer holds no error text at all')
  call s:ok(s:index_of(lines, 'Vim(') < 0, 'no Vim exception is painted anywhere')

  call s:eq(len(s:notifications), 1, 'a failed discovery notifies exactly once')
  call s:eq(s:notifications[0].kind, 'warning', 'a failed discovery warns instead of erroring')
  call s:ok(s:notifications[0].message =~# 'Banco Production', 'the notification names the server')
  call s:ok(s:notifications[0].message =~# 'vim-dadbod-manager-no-such-binary is not installed',
        \ 'the notification names the client the user has to install')

  " Showing a notification is what defines vim-dadbod-ui's own dismissal command:
  " it is the one ":DBUI*" name that is not an entry point and is not removed.
  call s:eq(exists(':DBUIHideNotifications'), 2,
        \ 'the notification can still be dismissed with :DBUIHideNotifications')

  " The other drivers are unaffected: the next server discovers and draws normally.
  call cursor(s:index_of(lines, 'Server$') + 1, 1)
  call drawer.toggle_line('')
  let lines = getline(1, '$')
  let server = s:index_of(lines, 'Server$')
  call s:eq(lines[server], expanded . ' Server', 'a server with a working client still expands')
  call s:eq(lines[server + 1], '  " Databases (1)', 'a working server is not affected by a failed one')
  call s:eq(lines[server + 2], '  ' . collapsed . ' alpha', 'a working server still draws its databases')
  call s:eq(lines[broken], expanded . ' Banco Production ' . failed,
        \ 'the failed server keeps its mark while the tree is rebuilt')
  call s:eq(len(s:notifications), 1, 'a successful discovery adds no notification')
  call s:eq(len(g:dbui_multidb_test_calls), 2, 'each server is discovered once')

  " A plain re-render neither rediscovers nor repeats the notification.
  call drawer.render()
  call s:eq(len(g:dbui_multidb_test_calls), 2, 'a plain re-render reuses the failed discovery')
  call s:eq(len(s:notifications), 1, 'a plain re-render does not notify again')

  " Collapsing and expanding the failed server again retries it.
  call cursor(s:index_of(getline(1, '$'), 'Banco Production') + 1, 1)
  call drawer.toggle_line('')
  call s:eq(len(g:dbui_multidb_test_calls), 2, 'collapsing a failed server does not rediscover')
  call s:eq(len(s:notifications), 1, 'collapsing a failed server does not notify')
  call drawer.toggle_line('')
  let lines = getline(1, '$')
  call s:eq(len(g:dbui_multidb_test_calls), 3, 'expanding a failed server retries the discovery')
  call s:eq(len(s:notifications), 2, 'the retry notifies again')
  call s:eq(lines[s:index_of(lines, 'Banco Production')], expanded . ' Banco Production ' . failed,
        \ 'the retry keeps the node marked')

  " :DBManagerInfo reports the same message, without the exception.
  let info = dbui_multidb#info()
  call s:ok(s:index_of(info, 'Banco Production: error: vim-dadbod-manager-no-such-binary is not installed') > -1,
        \ 'info reports the missing client in plain language')
  call s:ok(s:index_of(info, 'E475') < 0, 'info holds no raw exception')

  call s:end_capture()
endfunction

" The Administrative section and its Backup leaf are part of the drawer, wired
" to the backup planner through the call_method dispatch.
function! s:test_backup_section() abort
  call s:reset()
  let g:dbs = {'Server': 'fakedb://u@h/master', 'Plain': 'sqlite:/var/lib/plain.db'}
  let g:dbui_multidb_test_dbs = ['alpha']
  let g:dbui_multidb_test_tables = ['orders']
  call dbui_multidb#setup({'masters': ['Server']})

  call s:begin_capture()
  DBManager
  let drawer = db_ui#drawer#get()

  " A collapsed tree shows no Administrative section at all.
  let lines = getline(1, '$')
  call s:ok(s:index_of(lines, 'Administrative$') < 0,
        \ 'a collapsed database shows no Administrative section')

  " Expand Server, then alpha, then alpha's Administrative section.
  call cursor(s:index_of(lines, 'Server$') + 1, 1)
  call drawer.toggle_line('')
  let lines = getline(1, '$')
  call cursor(s:index_of(lines, 'alpha$') + 1, 1)
  call drawer.toggle_line('')
  let lines = getline(1, '$')
  let admin = s:index_of(lines, '^    \S* Administrative$')
  call s:ok(admin > -1, 'an expanded database appends its Administrative section')
  call cursor(admin + 1, 1)
  call drawer.toggle_line('')
  let lines = getline(1, '$')
  let backup = s:index_of(lines, '^      Backup$')
  call s:ok(backup > -1, 'expanding Administrative reveals the Backup action')
  call s:eq(lines[backup], '      Backup', 'the Backup action nests under Administrative')

  " <CR> on Backup reaches the planner: fakedb has no backup command, so the
  " user gets an explanation and the runner is never handed a plan.
  call cursor(backup + 1, 1)
  call drawer.toggle_line('')
  call s:eq(len(g:dbui_multidb_test_backup_plans), 0, 'a failed plan never reaches the runner')
  call s:eq(len(s:notifications), 1, 'the failed plan reports exactly once')
  call s:eq(s:notifications[0].kind, 'error', 'a failed plan is an error')
  call s:ok(s:notifications[0].message =~# 'fakedb', 'the error names the scheme')

  call s:end_capture()
endfunction

" The command lines: every built-in scheme, the override forms, redaction, and
" the safe-by-default behaviour of the server-side schemes.
function! s:test_backup_plan() abort
  call s:reset()

  " postgresql
  let pg = {'url': 'postgresql://user:s3cr3tpw@db.example.com:5432/app', 'name': 'app'}
  let plan = dbui_multidb#backup#plan(pg)
  call s:eq(plan.ok, 1, 'postgresql plans successfully')
  call s:eq(plan.scheme, 'postgresql', 'postgresql is canonical')
  call s:eq(plan.argv[0], 'pg_dump', 'postgresql uses pg_dump')
  call s:ok(index(plan.argv, '--file') >= 0, 'postgresql writes a file')
  call s:ok(dbui_multidb#backup#display(plan) !~# 's3cr3tpw', 'the display redacts the password')

  " mysql: the database name stays last
  let plan = dbui_multidb#backup#plan({'url': 'mysql://root:s3cr3tpw@127.0.0.1:3306/app', 'name': 'app'})
  call s:eq(plan.ok, 1, 'mysql plans successfully')
  call s:ok(plan.argv[0] =~# 'dump$', 'mysql uses a *dump binary')
  call s:eq(plan.argv[-1], 'app', 'mysql keeps the database name last')
  call s:ok(index(plan.argv, '--result-file=' . plan.target) >= 0, 'mysql writes through --result-file')
  call s:ok(dbui_multidb#backup#display(plan) !~# 's3cr3tpw', 'mysql display redacts the password')

  " mysql without a database
  let plan = dbui_multidb#backup#plan({'url': 'mysql://root@127.0.0.1:3306/', 'name': 'app'})
  call s:eq(plan.ok, 0, 'mysql without a database refuses to plan')
  call s:ok(plan.reason =~# 'database', 'the reason mentions the missing database')

  " sqlite (a real readable file, created on the fly)
  let dir = tempname()
  call mkdir(dir, 'p')
  let f = dir . '/app.db'
  call writefile([], f)
  let plan = dbui_multidb#backup#plan({'url': 'sqlite:' . f, 'name': 'app'})
  call s:eq(plan.ok, 1, 'sqlite plans successfully')
  call s:ok(join(plan.argv, ' ') =~# 'VACUUM INTO', 'sqlite uses VACUUM INTO')

  " sqlite without a readable file
  let plan = dbui_multidb#backup#plan({'url': 'sqlite:/nonexistent/nowhere.db', 'name': 'app'})
  call s:eq(plan.ok, 0, 'sqlite without a file refuses to plan')

  " sqlserver: server-side, so the directory is required
  let ss = {'url': 'sqlserver://sa:s3cr3tpw@localhost:1433/app', 'name': 'app'}
  let plan = dbui_multidb#backup#plan(ss)
  call s:eq(plan.ok, 0, 'sqlserver refuses to plan without a server directory')
  call s:ok(plan.reason =~# 'backup_server_dirs', 'sqlserver explains the missing directory')
  let g:dbui_multidb_backup_server_dirs = {'sqlserver': '/var/opt/mssql/backup'}
  let plan = dbui_multidb#backup#plan(ss)
  call s:eq(plan.ok, 1, 'sqlserver plans once the directory is set')
  call s:ok(join(plan.argv, ' ') =~# 'BACKUP DATABASE \[app\]', 'sqlserver backs up the right database')
  call s:ok(dbui_multidb#backup#display(plan) !~# 's3cr3tpw', 'sqlserver display redacts the password')

  " mongodb
  let plan = dbui_multidb#backup#plan({'url': 'mongodb://user:s3cr3tpw@db.example.com/app', 'name': 'app'})
  call s:eq(plan.ok, 1, 'mongodb plans successfully')
  call s:eq(plan.argv[0], 'mongodump', 'mongodb uses mongodump')
  call s:ok(index(plan.argv, '--gzip') >= 0, 'mongodb gzips the archive')

  " duckdb (a real readable file)
  let dir = tempname()
  call mkdir(dir, 'p')
  let f = dir . '/app.duckdb'
  call writefile([], f)
  let plan = dbui_multidb#backup#plan({'url': 'duckdb:' . f, 'name': 'app'})
  call s:eq(plan.ok, 1, 'duckdb plans successfully')
  call s:ok(join(plan.argv, ' ') =~# 'EXPORT DATABASE', 'duckdb uses EXPORT DATABASE')

  " clickhouse: server-side, so the disk is required
  let ch = {'url': 'clickhouse://user:s3cr3tpw@db.example.com/app', 'name': 'app'}
  let plan = dbui_multidb#backup#plan(ch)
  call s:eq(plan.ok, 0, 'clickhouse refuses to plan without a disk')
  let g:dbui_multidb_backup_server_dirs = {'clickhouse': 'backups'}
  let plan = dbui_multidb#backup#plan(ch)
  call s:eq(plan.ok, 1, 'clickhouse plans once the disk is set')
  call s:ok(join(plan.argv, ' ') =~# 'BACKUP DATABASE `app`', 'clickhouse backs up the right database')

  " oracle: server-side, so the DIRECTORY object is required
  let oa = {'url': 'oracle://system:s3cr3tpw@db.example.com:1521/app', 'name': 'app'}
  let plan = dbui_multidb#backup#plan(oa)
  call s:eq(plan.ok, 0, 'oracle refuses to plan without a DIRECTORY')
  let g:dbui_multidb_backup_server_dirs = {'oracle': 'DATA_PUMP_DIR'}
  let plan = dbui_multidb#backup#plan(oa)
  call s:eq(plan.ok, 1, 'oracle plans once the DIRECTORY is set')
  call s:eq(plan.argv[0], 'expdp', 'oracle uses expdp')
  call s:ok(index(plan.argv, 'FULL=Y') >= 0, 'oracle exports the full database')

  " redis
  let plan = dbui_multidb#backup#plan({'url': 'redis://user:s3cr3tpw@db.example.com:6379/0', 'name': 'app'})
  call s:eq(plan.ok, 1, 'redis plans successfully')
  call s:eq(plan.argv[0], 'redis-cli', 'redis uses redis-cli')
  call s:ok(index(plan.argv, '--rdb') >= 0, 'redis fetches an RDB dump')

  " redaction: every password-bearing form is masked
  let redacted = dbui_multidb#backup#redact([
        \ '--password=hunter2', '-psecret', '--pass', 'hunter2', '-a', 'hunter2',
        \ 'env', 'SQLCMDPASSWORD=abc', 'mongodb://u:hunter2@h/db?password=xyz'])
  let joined = join(redacted, ' ')
  call s:ok(joined !~# 'hunter2', 'redaction masks --password=, -p, --pass, -a and URL passwords')
  call s:ok(joined !~# 'abc', 'redaction masks SQLCMDPASSWORD=')
  call s:ok(joined !~# 'xyz', 'redaction masks a password= query parameter')

  " a scheme the plugin does not know how to back up
  let plan = dbui_multidb#backup#plan({'url': 'bigquery://proj', 'name': 'proj'})
  call s:eq(plan.ok, 0, 'an unsupported scheme refuses to plan')
  call s:ok(plan.reason =~# 'bigquery', 'the unsupported scheme is named')

  " string override: replace only the program
  let g:dbui_multidb_backup_commands = {'postgresql': 'my-pg-dump'}
  let plan = dbui_multidb#backup#plan(pg)
  call s:eq(plan.argv[0], 'my-pg-dump', 'a string override replaces the program')

  " list override: a full argv template, stdout redirected when no {output}
  let g:dbui_multidb_backup_commands = {'postgresql': ['echo', 'hello {name}']}
  let plan = dbui_multidb#backup#plan(pg)
  call s:eq(plan.kind, 'custom', 'a list override yields a custom command')
  call s:eq(plan.writes_target, 0, 'a template without {output} does not write the target')
  call s:eq(plan.stdout_target, 1, 'a template without {output} redirects stdout')
  call s:eq(plan.argv[0], 'echo', 'the template argv is preserved')

  " a template with {output} writes the target itself
  let g:dbui_multidb_backup_commands = {'postgresql': ['cp', '{url}', '{output}']}
  let plan = dbui_multidb#backup#plan(pg)
  call s:eq(plan.writes_target, 1, 'a template with {output} writes the target')

  " target collisions: a backup never overwrites an earlier file
  let g:dbui_multidb_backup_commands = {}
  let dir = tempname()
  call mkdir(dir, 'p')
  let g:dbui_multidb_backup_dir = dir
  let first = dbui_multidb#backup#plan(pg)
  call writefile(['x'], first.target)
  let second = dbui_multidb#backup#plan(pg)
  call s:ok(second.target !=# first.target, 'a second backup does not overwrite the first')
  call s:ok(!filereadable(second.target), 'the second backup picks a free path')

  " backup_echo_command: show, do not run, and do not leak
  unlet g:dbui_multidb_backup_runner
  let g:dbui_multidb_backup_echo_command = 1
  call s:begin_capture(1)
  call dbui_multidb#backup#start(pg)
  call s:eq(len(g:dbui_multidb_test_backup_plans), 0, 'echo mode never reaches the runner')
  call s:ok(len(s:notifications) == 1 && s:notifications[0].kind ==# 'info', 'echo mode informs instead of spawning')
  call s:ok(s:notifications[0].message =~# 'Backup would run', 'echo mode says what would run')
  call s:ok(s:notifications[0].message !~# 's3cr3tpw', 'echo mode does not leak the password')
  call s:end_capture()
endfunction

" Back to a single window with the drawer closed: the layout probes below read
" winlayout(), which only means something when the suite left no windows behind.
function! s:only_window() abort
  if &filetype ==# 'dbui'
    silent! DBManagerClose
  endif
  silent! only!
endfunction

" The ":DBManager*" entry points are the only names for the vendored drawer's
" commands: vim-dadbod-ui's own ":DBUI*" spellings are removed while this plugin
" loads, so the two sets must not coexist. The layout probes are the interesting
" part: they fail if a command forwards to another command instead of repeating
" upstream's body, because a command modifier would then be swallowed by the
" forward instead of reaching <mods>.
function! s:test_dbmanager_commands() abort
  for name in ['DBManager', 'DBManagerToggle', 'DBManagerClose',
        \ 'DBManagerAddConnection', 'DBManagerFindBuffer',
        \ 'DBManagerRenameBuffer', 'DBManagerLastQueryInfo',
        \ 'DBManagerRefresh', 'DBManagerInfo']
    call s:ok(exists(':' . name), ':' . name . ' is defined')
  endfor
  " The vendored drawer's own spellings are gone: only one name per command
  " should ever be offered by ":command", by completion and by "exists()". The one
  " exception is ":DBUIHideNotifications": the vendored notification module defines
  " it itself from an autoload file the first time a notification is shown, it is
  " the documented way to dismiss the notification window, and it has no
  " ":DBManager*" twin to name it after.
  let dbui_commands = getcompletion('DBUI', 'command')
  call s:ok(dbui_commands ==# [] || dbui_commands ==# ['DBUIHideNotifications'],
        \ 'only the vendored notification helper keeps a ":DBUI" name: '
        \ . string(dbui_commands))
  for name in ['DBUI', 'DBUIToggle', 'DBUIClose', 'DBUIAddConnection',
        \ 'DBUIFindBuffer', 'DBUIRenameBuffer', 'DBUILastQueryInfo',
        \ 'DBUIMultiDBRefresh', 'DBUIMultiDBInfo']
    " "exists()" is 2 for a defined command, 1 when the name only starts one.
    call s:ok(exists(':' . name) != 2, ':' . name . ' is removed')
  endfor

  " :command {name} prints the flags as columns, so the argument and the
  " completion of the source command have to be matched as columns too.
  let refresh = execute('command DBManagerRefresh')
  call s:ok(refresh =~# 'DBManagerRefresh\s\+?\s',
        \ ':DBManagerRefresh takes the optional server name')
  call s:ok(stridx(refresh, 'customlist') > -1
        \ && stridx(refresh, 'call dbui_multidb#refresh(<f-args>)') > -1,
        \ ':DBManagerRefresh completes server names and calls the same function')
  call s:ok(stridx(execute('command DBManagerInfo'), 'call dbui_multidb#info()') > -1,
        \ ':DBManagerInfo calls dbui_multidb#info()')
  call s:ok(stridx(execute('command DBManager'), "call db_ui#open('<mods>')") > -1,
        \ ':DBManager carries <mods>, so a command modifier is not swallowed')

  " The drawer that answers is the vendored copy, not a package next to nvim:
  " both can be on runtimepath, the first match is the one autoload resolves to.
  let drawer = globpath(&runtimepath, 'autoload/db_ui/drawer.vim', 0, 1)
  call s:ok(!empty(drawer) && strpart(fnamemodify(drawer[0], ':p'), 0, len(s:root)) ==# s:root,
        \ 'the loaded drawer is the vendored one: ' . string(drawer))

  " winlayout() names the axis, not the split: 'row' means the windows sit next
  " to each other (a vertical split) and 'col' means they are stacked.
  call s:reset()
  call s:only_window()
  " Unprefixed on purpose: ":silent" is a command modifier as well, and the
  " drawer would then take the explicitly split path below.
  DBManager
  call s:eq(&filetype, 'dbui', ':DBManager opens the drawer')
  call s:eq(winlayout()[0], 'row', 'the drawer opens as a vertical split by default')
  " Only the ex-commands were hidden: the drawer keeps the buffer-local mappings
  " that ftplugin/dbui.vim installs for its own keys.
  call s:ok(stridx(execute('nmap'), '<Plug>(DBUI_SelectLine)') > -1,
        \ 'the drawer keeps its buffer-local mappings')

  call s:only_window()
  silent botright DBManager
  call s:eq(&filetype, 'dbui', ':botright DBManager opens the drawer')
  call s:eq(winlayout()[0], 'col', 'a command modifier reaches the drawer, not the alias')

  call s:only_window()
  call s:reset()
endfunction

" The label is this plugin's, not upstream's: the module that defines
" db_ui#notifications#* is the overlay copy, and upstream's own call sites — which
" pass no title — get the configured label. The vendored file itself is untouched.
function! s:test_notification_title() abort
  call s:ok(stridx(&runtimepath, s:root . '/notify-overlay') >= 0,
        \ 'the overlay shipped with this plugin is on the runtimepath')
  call s:ok(s:notifier_source() =~# 'notify-overlay/autoload/db_ui/notifications\.vim$',
        \ 'the notification module in charge is an overlay copy')
  call s:eq(get(g:, 'db_ui_notification_title', 'unset'), '[DBManager]',
        \ 'the notification label defaults to [DBManager]')

  call s:reset()
  call db_ui#notifications#warning('title probe')
  call s:eq(s:last_message(), '[DBManager] title probe',
        \ 'a notification raised by upstream code is labelled [DBManager]')

  " A configured label wins, and the module reads it when it loads.
  let g:db_ui_notification_title = '[Whatever]'
  runtime autoload/db_ui/notifications.vim
  call db_ui#notifications#warning('override probe')
  call s:eq(s:last_message(), '[Whatever] override probe',
        \ 'g:db_ui_notification_title overrides the label')
  let g:db_ui_notification_title = '[DBManager]'
  runtime autoload/db_ui/notifications.vim
endfunction

" must not escape into a refresh or into a render. Runs last because it
" temporarily replaces an upstream function.
function! s:test_notify() abort
  function! db_ui#notifications#warning(msg, ...) abort
    throw 'notifier exploded'
  endfunction
  call s:eq(dbui_multidb#refresh('NoSuchServer'), 0,
        \ 'a throwing notifier does not break a failed refresh')
  call s:ok(type(dbui_multidb#notify#error('boom')) ==# type(0),
        \ 'a notification wrapper always reports success')
  runtime autoload/db_ui/notifications.vim
  call s:ok(exists('*db_ui#notifications#warning'), 'the upstream notifier is restored')
endfunction

let s:tests = [
      \ function('s:test_config'),
      \ function('s:test_is_master'),
      \ function('s:test_url'),
      \ function('s:test_discovery'),
      \ function('s:test_drawer'),
      \ function('s:test_discovery_error'),
      \ function('s:test_missing_client'),
      \ function('s:test_backup_section'),
      \ function('s:test_backup_plan'),
      \ function('s:test_dbmanager_commands'),
      \ function('s:test_notification_title'),
      \ function('s:test_notify'),
      \ ]

for s:Test in s:tests
  try
    call s:Test()
  catch /.*/
    call s:ok(0, printf('%s threw: %s', string(s:Test), v:exception))
    " A test that threw may not have restored the captured notifiers.
    call s:end_capture()
  endtry
endfor

for s:failure in s:failures
  echo 'FAILED: ' . s:failure
endfor
echo printf('RESULT: %s (%d checks, %d failures)', empty(s:failures) ? 'ok' : 'failed', s:checks, len(s:failures))

if empty(s:failures)
  qall!
endif
cquit 1
