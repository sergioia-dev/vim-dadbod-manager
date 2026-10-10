" Backup jobs for the "Backups" section of the drawer.
"
" A backup is a detached job, never something the editor waits for:
"
"   1. dbui_multidb#backup#plan() turns a database entry into a *plan*: the
"      command to run, where its output lands, and what to say about it. It
"      never touches the disk and never starts anything.
"   2. dbui_multidb#backup#start() hands the plan to a detached shell job and
"      reports the outcome as a notification when the job exits.
"   3. dbui_multidb#backup#restore() plans the reverse direction: the same
"      dispatch, with the dump fed back into the database it came from.
"
" The backup files of a connection are the ones this module can list, restore
" and delete: dbui_multidb#backup#list() reads them back out of the backup
" directory, keyed by the same name the planner generates, so the drawer can
" show what a scheme wrote and hand it back to the matching client.
"
" The plan is a plain dict so that everything except the spawn itself is
" testable without a database: the test suite drives the command lines through
" g:dbui_multidb_backup_runner instead of running them.
"
" No password may reach a notification. The commands are built from the
" connection URL exactly like vim-dadbod's own adapters do, so every path that
" could show one goes through dbui_multidb#backup#display().

" Jobs started this session, keyed by their job handle, so a backup is visible
" while it runs (dbui_multidb#backup#running()) and forgotten as soon as it
" exits.
let s:jobs = {}

" Scheme spellings that share a backup command. The raw spelling is kept next
" to the canonical one: messages use it, and the per-scheme configuration keys
" accept either.
let s:aliases = {
      \ 'postgres': 'postgresql',
      \ 'sqlite3': 'sqlite',
      \ 'mssql': 'sqlserver',
      \ 'mongodb+srv': 'mongodb',
      \ 'rediss': 'redis',
      \ }

" The default file extension of each built-in backup.
let s:extensions = {
      \ 'postgresql': '.dump',
      \ 'mysql': '.sql',
      \ 'sqlite': '.sqlite3',
      \ 'sqlserver': '.bak',
      \ 'mongodb': '.archive.gz',
      \ 'duckdb': '.export',
      \ 'clickhouse': '.zip',
      \ 'oracle': '.dmp',
      \ 'redis': '.rdb',
      \ }

" The schemes whose backup files land on this machine. Only these get a
" Backups section: a server side scheme writes on the database host, where this
" editor can neither list, restore nor delete anything.
let s:local_schemes = ['postgresql', 'mysql', 'sqlite', 'mongodb', 'duckdb', 'redis', 'fakedb']

" The schemes whose dump this plugin knows how to feed back into the database.
" A local scheme that is missing here still gets a section: it is listed, and
" restoring it says why it cannot be done from here.
let s:restorable = ['postgresql', 'mysql', 'sqlite', 'mongodb']

" The known extensions, longest first, so that ".archive.gz" is stripped before
" ".gz" and a backup file is always split at its real extension.
function! s:longest_first(x, y) abort
  return len(a:y) - len(a:x)
endfunction

let s:extension_list = sort(map(values(s:extensions), 'tolower(v:val)'), function('s:longest_first'))

function! dbui_multidb#backup#reset() abort
  let s:jobs = {}
  return 1
endfunction

" The plans of the backups this session started and that have not finished.
function! dbui_multidb#backup#running() abort
  return values(s:jobs)
endfunction

" ---------------------------------------------------------------------------
" Entry points
" ---------------------------------------------------------------------------

" Build the plan for a database entry. Returns either
" {ok: 1, ...} (the full plan, documented on dbui_multidb#backup#plan()) or
" {ok: 0, reason: "..."} when the connection does not carry what the command
" needs, or when the scheme has no backup to run here at all, which adds
" {unsupported: 1} so that the caller warns instead of reporting a failure.
" Never throws and never starts anything.
function! dbui_multidb#backup#plan(db) abort
  let cfg = dbui_multidb#config#get()
  let ctx = s:context(a:db, cfg)

  let override = s:lookup(cfg, 'backup_commands', ctx.raw, ctx.scheme)
  if type(override) ==# type('') && !empty(override)
    return s:program_override_plan(ctx, override)
  elseif type(override) ==# type([])
    return s:template_plan(ctx, override)
  endif

  return s:builtin_plan(ctx)
endfunction

" Turn a plan into a detached job (or a notification, when the configuration
" asks to only echo the command or to hand the plan to a runner).
function! dbui_multidb#backup#start(db) abort
  return s:run(dbui_multidb#backup#plan(a:db))
endfunction

" Refresh the Backups section of a finished backup's connection in place, so the
" new file shows up without redrawing the whole drawer. Returns 1 when the
" section was rewritten, 0 when the plan carries no connection, the drawer is
" closed, or this database has no section in it.
function! dbui_multidb#backup#refresh_section(plan, ...) abort
  let db = get(a:plan, 'db', {})
  if type(db) !=# type({}) || empty(db)
    return 0
  endif

  try
    let drawer = db_ui#drawer#get()
  catch /.*/
    return 0
  endtry
  if type(drawer) !=# type({}) || !has_key(drawer, 'is_opened') || !drawer.is_opened()
    return 0
  endif

  return dbui_multidb#administrative#replace_section(drawer, db)
endfunction

" Report why a plan cannot run. A scheme that has no command on this machine
" is not a failure: the message says so and nothing was attempted.
function! s:report(plan) abort
  let message = 'vim-dadbod-manager: ' . get(a:plan, 'reason', 'cannot build a backup plan.')
  if get(a:plan, 'unsupported', 0)
    call dbui_multidb#notify#warning(message)
  else
    call dbui_multidb#notify#error(message)
  endif
endfunction

" Run a built plan through the configured runner, the echo mode, or a real
" detached job. Every plan goes through here, so a backup and a restore report
" their outcome the same way.
function! s:run(plan) abort
  if !get(a:plan, 'ok', 0)
    call s:report(a:plan)
    return 0
  endif
  return s:dispatch(a:plan)
endfunction

function! s:dispatch(plan) abort
  let cfg = dbui_multidb#config#get()

  " g:dbui_multidb_backup_runner replaces the job entirely: it receives the plan
  " and is responsible for running (or recording) it. Tests use it so that the
  " suite never spawns a real database client.
  let runner = get(cfg, 'backup_runner', '')
  if s:callable(runner)
    try
      call call(s:funcref(runner), [a:plan])
    catch /.*/
      call dbui_multidb#notify#error('vim-dadbod-manager: backup runner failed: ' . v:exception)
      return 0
    endtry
    return 1
  endif

  if get(cfg, 'backup_echo_command', 0)
    call dbui_multidb#notify#info(s:verb(a:plan) . ' would run: ' . dbui_multidb#backup#display(a:plan))
    return 1
  endif

  return s:spawn(a:plan)
endfunction

" What the notifications call the job: "Backup" or "Restore".
function! s:verb(plan) abort
  return get(a:plan, 'verb', 'Backup')
endfunction

" The command line, with every password redacted.
function! dbui_multidb#backup#display(plan) abort
  let argv = dbui_multidb#backup#redact(copy(get(a:plan, 'argv', [])))
  let secret = s:str(get(a:plan, 'secret', ''))
  if !empty(secret)
    let pattern = '\V' . escape(secret, '\')
    let masked = []
    for arg in argv
      call add(masked, substitute(arg, pattern, '***', 'g'))
    endfor
    let argv = masked
  endif
  let cmd = s:join(argv)
  " A restore pipes the dump in on stdin; it never redirects stdout.
  if !empty(get(a:plan, 'stdin_file', ''))
    let cmd .= ' < ' . fnamemodify(a:plan.stdin_file, ':~')
  endif
  if get(a:plan, 'stdout_target', 0) && !empty(get(a:plan, 'target', ''))
    let cmd .= ' > ' . fnamemodify(a:plan.target, ':~')
  endif
  return cmd
endfunction

" A list with every password-bearing token masked. Purely cosmetic: the result
" is only ever shown, never run.
function! dbui_multidb#backup#redact(argv) abort
  let result = []
  let hide_next = 0
  for arg in a:argv
    let value = s:str(arg)
    if hide_next
      let value = '***'
      let hide_next = 0
    elseif value ==# '--password' || value ==# '--passwd' || value ==# '--pass'
          \ || value ==# '--pwd' || value ==# '--passphrase' || value ==# '-a'
      let hide_next = 1
    endif
    " --password=SECRET and friends
    let value = substitute(value, '\c\(--\(password\|passwd\|pass\|pwd\|passphrase\)=\)[^ ]*', '\1***', '')
    " env SQLCMDPASSWORD=SECRET (and the other environment spellings)
    let value = substitute(value, '\c\(\(SQLCMDPASSWORD\|PGPASSWORD\|MYSQL_PWD\|PGSERVICEFILE\)=\)[^ ]*', '\1***', '')
    " mysql's concatenated -pSECRET (a bare -p is a port flag, left alone)
    let value = substitute(value, '\(^\| \)-p[^ ]\+', '\1-p***', '')
    " password= / passwd= / pwd= inside a URL query
    let value = substitute(value, '\c\([?&;]\)\(password\|passwd\|pwd\)=[^&; ]*', '\1***', '')
    " URL userinfo password: scheme://user:pass@host
    let value = substitute(value, '\(://[^/@:]*\):[^/@]*@', '\1:***@', '')
    call add(result, value)
  endfor
  return result
endfunction

" A name for the backup file, and the database name the command needs.
function! dbui_multidb#backup#dbname(db) abort
  let explicit = s:str(get(a:db, 'db_name', ''))
  if !empty(explicit)
    return explicit
  endif
  let from_url = s:dbname(s:url(a:db), '')
  if !empty(from_url)
    return from_url
  endif
  return s:str(get(a:db, 'name', ''))
endfunction

" ---------------------------------------------------------------------------
" Local backup files
" ---------------------------------------------------------------------------

" The canonical scheme of a connection entry or of a scheme name.
function! s:scheme_of(value) abort
  if type(a:value) ==# type('')
    return s:canonical(a:value)
  endif
  return s:schemes(a:value).scheme
endfunction

" Whether the backup files of this connection are on this machine, i.e.
" whether the drawer can show them at all.
function! dbui_multidb#backup#is_local(db) abort
  return index(s:local_schemes, s:scheme_of(a:db)) >= 0
endfunction

" Whether a dump can be fed back into the database from here.
function! dbui_multidb#backup#restore_supported(db) abort
  return index(s:restorable, s:scheme_of(a:db)) >= 0
endfunction

" The backup files of a connection, newest first. A file belongs to the
" connection when its name starts with the same slug the planner generates,
" which is what keeps two databases' backups apart in one directory.
"
" Each entry is {path, label, prefix, ext, mtime}: label is the file name
" without the connection prefix and without the extension, i.e. the timestamp
" the planner generated.
function! dbui_multidb#backup#list(db) abort
  let dir = s:dirname(dbui_multidb#config#get())
  if !isdirectory(dir)
    return []
  endif

  let prefix = s:slug(dbui_multidb#backup#dbname(a:db)) . '-'
  let pattern = escape(dir, '*?[{') . '/' . escape(prefix, '*?[{') . '*'
  let entries = []
  for path in split(glob(pattern), "\n")
    if !filereadable(path)
      continue
    endif
    let name = fnamemodify(path, ':t')
    " A job's log lives next to its backup under the same name: it is not a
    " backup, so skip it.
    if name =~# '\.log$'
      continue
    endif
    let stem = strpart(name, len(prefix))
    let ext = s:file_extension(stem)
    if !empty(ext)
      let stem = strpart(stem, 0, len(stem) - len(ext))
    endif
    call add(entries, {
          \ 'path': path, 'label': stem, 'prefix': prefix,
          \ 'ext': ext, 'mtime': getftime(path)})
  endfor
  call sort(entries, function('s:by_mtime'))
  return entries
endfunction

" Newest first; the path breaks ties so a listing is always deterministic (two
" backups in one second are ordered by name, which is the timestamp).
function! s:by_mtime(x, y) abort
  if a:x.mtime !=# a:y.mtime
    return a:x.mtime > a:y.mtime ? -1 : 1
  endif
  if a:x.path ==# a:y.path
    return 0
  endif
  return a:x.path <# a:y.path ? 1 : -1
endfunction

" The extension of a backup file name, matched against the known extensions
" longest first. Anything else falls back to the text after the last dot, so a
" file renamed by hand still splits into a name and an extension.
function! s:file_extension(name) abort
  for ext in s:extension_list
    if len(a:name) > len(ext) && tolower(a:name[len(a:name) - len(ext) :]) ==# ext
      return a:name[len(a:name) - len(ext) :]
    endif
  endfor
  let ext = fnamemodify(a:name, ':e')
  return empty(ext) ? '' : '.' . ext
endfunction

" The log a job writes next to its backup (see s:context): the same name with
" ".log" instead of the dump's extension. Restoring a file logs to the same
" place, so a failed restore leaves its log next to the dump it came from.
function! s:log_for(path) abort
  let name = fnamemodify(a:path, ':t')
  let ext = s:file_extension(name)
  if !empty(ext)
    let name = strpart(name, 0, len(name) - len(ext))
  endif
  return fnamemodify(a:path, ':h') . '/' . name . '.log'
endfunction

" Accept either a path or one of the dicts dbui_multidb#backup#list() returns.
function! s:file_path(value) abort
  if type(a:value) ==# type({})
    return s:str(get(a:value, 'path', ''))
  endif
  return s:str(a:value)
endfunction

" Build the plan for restoring one backup file into the database it came from.
" The shape is a backup plan's, with "verb" saying what the notifications call
" the job and "stdin_file" naming a dump a client has to read on stdin.
function! dbui_multidb#backup#restore_plan(db, file) abort
  let file = s:file_path(a:file)
  if empty(file)
    return {'ok': 0, 'reason': 'No backup file to restore here.'}
  endif
  if !filereadable(file)
    return {'ok': 0, 'reason': printf('No readable backup file to restore (got %s).', file)}
  endif

  let ctx = s:context(a:db, dbui_multidb#config#get())
  if !dbui_multidb#backup#restore_supported(a:db)
    return {'ok': 0, 'unsupported': 1, 'reason': printf(
          \ 'Restoring a backup of "%s" from here is not available: use the client of that database (the file is at %s).',
          \ empty(ctx.raw) ? 'this scheme' : ctx.raw, fnamemodify(file, ':~'))}
  endif

  let log = s:log_for(file)
  let common = {'verb': 'Restore', 'file': file, 'target': file, 'log': log, 'writes_target': 0}

  if ctx.scheme ==# 'postgresql'
    " pg_restore reads the same connection URL as psql, so only the program,
    " the destructive options and the input file are added.
    let argv = db#adapter#postgresql#interactive(ctx.url)
    let argv[0] = 'pg_restore'
    return s:plan(ctx, extend(common, {
          \ 'kind': 'client_file',
          \ 'argv': argv[0:1] + s:options(ctx) + ['--no-owner', '--clean', '--if-exists'] + argv[2:] + [file],
          \ 'note': 'pg_restore drops and recreates the objects in the dump; the database itself is kept.'}))
  endif

  if ctx.scheme ==# 'mysql'
    if !s:has_database(ctx.url)
      return {'ok': 0, 'reason': 'No database in this connection to restore into; connect to a specific database first.'}
    endif
    let argv = ctx.raw ==# 'mariadb' ? db#adapter#mariadb#interactive(ctx.url) : db#adapter#mysql#interactive(ctx.url)
    return s:plan(ctx, extend(common, {
          \ 'kind': 'client_stdin',
          \ 'argv': [argv[0]] + s:options(ctx) + argv[1:],
          \ 'stdin_file': file,
          \ 'note': 'The dump is piped into the client on stdin.'}))
  endif

  if ctx.scheme ==# 'sqlite'
    let db_file = db#url#file_path(ctx.url)
    if empty(db_file)
      return {'ok': 0, 'reason': printf('No SQLite database file to restore into (got %s).', empty(ctx.url) ? 'nothing' : ctx.url)}
    endif
    return s:plan(ctx, extend(common, {
          \ 'kind': 'client_file',
          \ 'argv': ['cp', '-f', file, db_file],
          \ 'target': db_file, 'writes_target': 1,
          \ 'note': 'Copies the backup over the SQLite file; close every other connection to it first.'}))
  endif

  if ctx.scheme ==# 'mongodb'
    let gzip = tolower(file) =~# '\.gz$' ? ['--gzip'] : []
    return s:plan(ctx, extend(common, {
          \ 'kind': 'client_file',
          \ 'argv': ['mongorestore', '--uri', ctx.url] + s:options(ctx) + ['--archive=' . file] + gzip + ['--drop'],
          \ 'note': 'mongorestore --drop replaces the collections found in the archive.'}))
  endif

  return {'ok': 0, 'unsupported': 1, 'reason': printf(
        \ 'Restoring a backup of "%s" from here is not available.', empty(ctx.raw) ? 'this scheme' : ctx.raw)}
endfunction

" Restore one backup file into its database, after a confirmation. The plan is
" built first, so an unsupported scheme or a missing file is reported instead of
" turning into a prompt.
function! dbui_multidb#backup#restore(db, file) abort
  let file = s:file_path(a:file)
  let plan = dbui_multidb#backup#restore_plan(a:db, file)
  if !get(plan, 'ok', 0)
    call s:report(plan)
    return 0
  endif
  if !dbui_multidb#backup#confirm(printf('Restore %s into "%s"? This overwrites what the dump contains.',
        \ fnamemodify(file, ':t'), dbui_multidb#backup#dbname(a:db)))
    return 0
  endif
  return s:dispatch(plan)
endfunction

" Delete a backup file and the log next to it, after a confirmation. Only the
" files the section lists are accepted, so a mistyped path cannot remove
" something else.
function! dbui_multidb#backup#delete_file(db, file) abort
  let path = s:file_path(a:file)
  if empty(path) || !filereadable(path)
    call dbui_multidb#notify#error(printf('vim-dadbod-manager: no such backup file: %s.',
          \ empty(path) ? 'nothing' : fnamemodify(path, ':~')))
    return 0
  endif

  let owned = 0
  for entry in dbui_multidb#backup#list(a:db)
    if entry.path ==# path
      let owned = 1
      break
    endif
  endfor
  if !owned
    call dbui_multidb#notify#error(printf('vim-dadbod-manager: %s is not a backup of this connection.',
          \ fnamemodify(path, ':~')))
    return 0
  endif
  if !dbui_multidb#backup#confirm(printf('Delete %s? This also removes its log.', fnamemodify(path, ':t')))
    return 0
  endif

  if delete(path) != 0
    call dbui_multidb#notify#error(printf('vim-dadbod-manager: cannot delete %s.', fnamemodify(path, ':~')))
    return 0
  endif
  let log = s:log_for(path)
  if filereadable(log)
    call delete(log)
  endif
  call dbui_multidb#notify#info('Backup deleted: ' . fnamemodify(path, ':~'))
  return 1
endfunction

" Rename one backup file, keeping its connection prefix and its extension:
" only the label (the timestamp the planner generated) changes, so the listing
" keeps grouping the file under its connection.
function! dbui_multidb#backup#rename_file(file, label, ...) abort
  let path = s:file_path(a:file)
  if empty(path) || !filereadable(path)
    call dbui_multidb#notify#error(printf('vim-dadbod-manager: no such backup file: %s.',
          \ empty(path) ? 'nothing' : fnamemodify(path, ':~')))
    return 0
  endif

  let name = fnamemodify(path, ':t')
  let prefix = a:0 ? s:str(a:1) : s:rename_prefix(name)
  let label = s:label(a:label)
  if empty(label)
    call dbui_multidb#notify#error('vim-dadbod-manager: a backup name is needed.')
    return 0
  endif

  let target = fnamemodify(path, ':h') . '/' . prefix . label . s:file_extension(name)
  if target ==# path
    return 1
  endif
  if filereadable(target) || isdirectory(target)
    call dbui_multidb#notify#error(printf('vim-dadbod-manager: %s already exists.', fnamemodify(target, ':~')))
    return 0
  endif
  if rename(path, target) != 0
    call dbui_multidb#notify#error(printf('vim-dadbod-manager: cannot rename %s.', fnamemodify(path, ':~')))
    return 0
  endif
  call dbui_multidb#notify#info('Backup renamed: ' . fnamemodify(target, ':~'))
  return 1
endfunction

" The "<connection>-" part of a backup file name. The section passes it
" explicitly; a bare path falls back to the text before the timestamp the
" planner generates.
function! s:rename_prefix(name) abort
  let match = matchlist(a:name, '^\(.\{-}-\)backup-\d\{4\}-\d\{2\}-\d\{2\}-\d\{2\}-\d\{2\}-\d\{2\}')
  return empty(match) ? '' : match[1]
endfunction

" A filesystem-safe label for a renamed backup.
function! s:label(name) abort
  let label = substitute(s:str(a:name), '[^A-Za-z0-9._-]', '-', 'g')
  let label = substitute(label, '^-\+', '', '')
  let label = substitute(label, '-\+$', '', '')
  return label[0 : 63]
endfunction

" Ask a destructive question. A wrapper around confirm() rather than a bare
" call, so the suite can answer it without a UI.
function! dbui_multidb#backup#confirm(question) abort
  return confirm(a:question, "&Yes\n&No", 2, 'Warning') == 1
endfunction

" nvim jobstart() on_exit handler (job-id, exit-code, event).
function! dbui_multidb#backup#on_exit(plan, job, code, event) abort
  call s:finish(a:plan, a:code)
endfunction

" Vim job_start() exit_cb handler (job, status).
function! dbui_multidb#backup#vim_exit(plan, job, code) abort
  call s:finish(a:plan, a:code)
endfunction

" ---------------------------------------------------------------------------
" The built-in commands
" ---------------------------------------------------------------------------

function! s:builtin_plan(ctx) abort
  let scheme = a:ctx.scheme
  if scheme ==# 'postgresql'
    return s:pg_plan(a:ctx)
  elseif scheme ==# 'mysql'
    return s:mysql_plan(a:ctx)
  elseif scheme ==# 'sqlite'
    return s:sqlite_plan(a:ctx)
  elseif scheme ==# 'sqlserver'
    return s:sqlserver_plan(a:ctx)
  elseif scheme ==# 'mongodb'
    return s:mongo_plan(a:ctx)
  elseif scheme ==# 'duckdb'
    return s:duckdb_plan(a:ctx)
  elseif scheme ==# 'clickhouse'
    return s:clickhouse_plan(a:ctx)
  elseif scheme ==# 'oracle'
    return s:oracle_plan(a:ctx)
  elseif scheme ==# 'redis'
    return s:redis_plan(a:ctx)
  endif

  return {'ok': 0, 'reason': printf(
        \ 'No backup command is configured for the "%s" scheme (see g:dbui_multidb_backup_commands).',
        \ empty(a:ctx.raw) ? 'unknown' : a:ctx.raw)}
endfunction

function! s:pg_plan(ctx) abort
  " pg_dump accepts the same connection URL as psql, so only the program and the
  " dump specific options differ from the adapter's own command.
  let argv = db#adapter#postgresql#interactive(a:ctx.url)
  let argv[0] = 'pg_dump'
  let ext = '.dump'
  let target = s:target(a:ctx.dir, a:ctx.name, ext)
  return s:plan(a:ctx, {
        \ 'kind': 'client_file', 'writes_target': 1, 'ext': ext, 'target': target,
        \ 'argv': argv[0:1] + s:options(a:ctx) + ['--format=custom', '--file', target] + argv[2:],
        \ 'note': 'Custom archive format, restorable with pg_restore.'})
endfunction

function! s:mysql_plan(ctx) abort
  if !s:has_database(a:ctx.url)
    return {'ok': 0, 'reason': 'No database in this connection to back up; connect to a specific database first.'}
  endif
  let bin = a:ctx.raw ==# 'mariadb' ? 'mariadb-dump' : 'mysqldump'
  let argv = a:ctx.raw ==# 'mariadb' ? db#adapter#mariadb#interactive(a:ctx.url) : db#adapter#mysql#interactive(a:ctx.url)
  let dbname = argv[-1]
  let conn = argv[1:-2]
  let ext = '.sql'
  let target = s:target(a:ctx.dir, a:ctx.name, ext)
  return s:plan(a:ctx, {
        \ 'kind': 'client_file', 'writes_target': 1, 'ext': ext, 'target': target,
        \ 'argv': [bin] + s:options(a:ctx) + conn
        \   + ['--single-transaction', '--routines', '--events', '--triggers', '--result-file=' . target, dbname],
        \ 'note': 'Writes the dump through --result-file, so nothing is routed through a shell.'})
endfunction

function! s:sqlite_plan(ctx) abort
  let file = db#url#file_path(a:ctx.url)
  if empty(file) || !filereadable(file)
    return {'ok': 0, 'reason': printf('No readable SQLite database file to back up (got %s).', empty(file) ? a:ctx.url : file)}
  endif
  let ext = '.sqlite3'
  let target = s:target(a:ctx.dir, a:ctx.name, ext)
  " VACUUM INTO makes the copy without the sqlite3 shell's dot commands, so the
  " target needs no shell quoting of its own and the copy is compacted at the
  " same time (SQLite 3.27+).
  let sql = printf("VACUUM INTO '%s'", s:sql_escape(target))
  let argv = db#adapter#sqlite#command(a:ctx.url)
  return s:plan(a:ctx, {
        \ 'kind': 'client_file', 'writes_target': 1, 'ext': ext, 'target': target,
        \ 'argv': [argv[0]] + s:options(a:ctx) + argv[1:] + [sql],
        \ 'note': 'A VACUUM INTO copy: consistent, compacted, and free of the source''s free pages.'})
endfunction

function! s:sqlserver_plan(ctx) abort
  if !s:has_database(a:ctx.url)
    return {'ok': 0, 'reason': 'No database in this connection to back up; connect to a specific database first.'}
  endif
  let base = s:server_dir(a:ctx)
  if empty(base)
    " SQL Server keeps its backups on its own disk: the only command that can
    " write one is BACKUP DATABASE, which the server itself runs, and there is
    " no client side dump tool for it. Say that instead of pretending a backup
    " ran here; the two keys named in the message are the ways out.
    return {'ok': 0, 'unsupported': 1, 'reason': printf(
          \ 'Backups are not available for "%s": SQL Server writes .bak files on the server host and has no client side dump tool. Set g:dbui_multidb_backup_server_dirs.%s to a directory on the server, or g:dbui_multidb_backup_commands.%s for a client side export.',
          \ a:ctx.raw, a:ctx.raw, a:ctx.raw)}
  endif
  let ext = '.bak'
  let target = s:server_target(base, a:ctx.name, ext)
  let db = s:dbname(a:ctx.url, a:ctx.dbname)
  let argv = db#adapter#sqlserver#interactive(a:ctx.url)
  let pstart = s:program_at('sqlserver', argv)[0]
  let argv = argv[0 : pstart] + s:options(a:ctx) + argv[pstart + 1 :]
  let sql = printf("BACKUP DATABASE [%s] TO DISK = N'%s' WITH COPY_ONLY, INIT, COMPRESSION, STATS = 25",
        \ s:tsql_ident(db), s:tsql_str(target))
  return s:plan(a:ctx, {
        \ 'kind': 'server_file', 'writes_target': 1, 'local': 0, 'ext': ext, 'target': target,
        \ 'argv': argv + ['-b', '-Q', sql],
        \ 'note': 'Runs BACKUP DATABASE on the server; the path is on the SQL Server host.'})
endfunction

function! s:mongo_plan(ctx) abort
  let ext = '.archive.gz'
  let target = s:target(a:ctx.dir, a:ctx.name, ext)
  return s:plan(a:ctx, {
        \ 'kind': 'client_file', 'writes_target': 1, 'ext': ext, 'target': target,
        \ 'argv': ['mongodump'] + s:options(a:ctx) + ['--uri', a:ctx.url, '--archive=' . target, '--gzip'],
        \ 'note': 'A single gzipped archive; a URL without a database dumps every database.'})
endfunction

function! s:duckdb_plan(ctx) abort
  let file = db#url#file_path(a:ctx.url)
  if empty(file) || !filereadable(file)
    return {'ok': 0, 'reason': printf('No readable DuckDB database file to back up (got %s).', empty(file) ? a:ctx.url : file)}
  endif
  let ext = '.export'
  let target = s:target(a:ctx.dir, a:ctx.name, ext)
  let sql = printf("EXPORT DATABASE '%s' (FORMAT PARQUET)", s:sql_escape(target))
  let argv = db#adapter#duckdb#command(a:ctx.url)
  return s:plan(a:ctx, {
        \ 'kind': 'client_file', 'writes_target': 1, 'ext': ext, 'target': target,
        \ 'argv': [argv[0]] + s:options(a:ctx) + argv[1:] + [sql],
        \ 'note': 'EXPORT DATABASE writes a directory of Parquet files.'})
endfunction

function! s:clickhouse_plan(ctx) abort
  let disk = s:server_dir(a:ctx)
  if empty(disk)
    return {'ok': 0, 'reason': printf(
          \ 'Backups for "%s" are written by the ClickHouse server; set g:dbui_multidb_backup_server_dirs.%s to the disk name (the default disk is "backups").',
          \ a:ctx.raw, a:ctx.raw)}
  endif
  let ext = '.zip'
  let file = a:ctx.name . ext
  let db = s:dbname(a:ctx.url, a:ctx.dbname)
  if empty(db)
    let db = 'default'
  endif
  let argv = db#adapter#clickhouse#interactive(a:ctx.url)
  let pstart = s:program_at('clickhouse', argv)[0]
  let argv = argv[0 : pstart] + s:options(a:ctx) + argv[pstart + 1 :]
  let sql = printf("BACKUP DATABASE `%s` TO Disk('%s', '%s')", s:ch_ident(db), s:sql_escape(disk), s:sql_escape(file))
  return s:plan(a:ctx, {
        \ 'kind': 'server_file', 'writes_target': 1, 'local': 0, 'ext': ext,
        \ 'target': disk . '/' . file,
        \ 'argv': argv + ['--query', sql],
        \ 'note': 'Runs BACKUP DATABASE on the ClickHouse server; the file lands on the configured disk.'})
endfunction

function! s:oracle_plan(ctx) abort
  let directory = s:server_dir(a:ctx)
  if empty(directory)
    return {'ok': 0, 'reason': printf(
          \ 'Backups for "%s" are written by the Oracle server (expdp); set g:dbui_multidb_backup_server_dirs.%s to an Oracle DIRECTORY object name (default: DATA_PUMP_DIR).',
          \ a:ctx.raw, a:ctx.raw)}
  endif
  let ext = '.dmp'
  let file = a:ctx.name . ext
  let logfile = a:ctx.name . '.log'
  let base = db#adapter#oracle#interactive(a:ctx.url)
  let userid = len(base) > 2 ? base[2] : 'system/oracle@localhost'
  return s:plan(a:ctx, {
        \ 'kind': 'server_file', 'writes_target': 1, 'local': 0, 'ext': ext,
        \ 'target': directory . '/' . file,
        \ 'argv': ['expdp'] + s:options(a:ctx)
        \   + [userid, 'DIRECTORY=' . directory, 'DUMPFILE=' . file, 'LOGFILE=' . logfile, 'FULL=Y'],
        \ 'note': 'Runs expdp on the Oracle server; FULL=Y needs the DATAPUMP_EXP_FULL_DATABASE role.'})
endfunction

function! s:redis_plan(ctx) abort
  let argv = db#adapter#redis#interactive(a:ctx.url)
  let ext = '.rdb'
  let target = s:target(a:ctx.dir, a:ctx.name, ext)
  return s:plan(a:ctx, {
        \ 'kind': 'client_file', 'writes_target': 1, 'ext': ext, 'target': target,
        \ 'argv': [argv[0]] + s:options(a:ctx) + argv[1:] + ['--rdb', target],
        \ 'note': 'redis-cli --rdb: a point-in-time dump over the wire; standalone servers only.'})
endfunction

" ---------------------------------------------------------------------------
" Overrides
" ---------------------------------------------------------------------------

" A string override replaces the program of a built-in command (the built-in
" arguments stay), so it must name a scheme the plugin knows how to run.
function! s:program_override_plan(ctx, program) abort
  let plan = s:builtin_plan(a:ctx)
  if !get(plan, 'ok', 0)
    return plan
  endif
  let plan.argv = s:replace_program(a:ctx.scheme, plan.argv, a:program)
  return plan
endfunction

" A list override is a complete argv template with {placeholder} substitution.
" If the template mentions {output} or {file}, the command is assumed to create
" the target itself; otherwise its stdout is redirected into the target.
function! s:template_plan(ctx, template) abort
  let ext = s:str(get(s:extensions, a:ctx.scheme, '.bak'))
  let target = s:target(a:ctx.dir, a:ctx.name, ext)
  let values = s:values(a:ctx, ext, target)
  let argv = []
  let mentions_output = 0
  for arg in a:template
    let str = s:str(arg)
    if str =~# '{output}\|{file}'
      let mentions_output = 1
    endif
    call add(argv, s:fill(str, values))
  endfor
  return s:plan(a:ctx, {
        \ 'kind': 'custom', 'ext': ext, 'target': target, 'argv': argv,
        \ 'writes_target': mentions_output, 'stdout_target': !mentions_output,
        \ 'note': 'Custom command from g:dbui_multidb_backup_commands.'})
endfunction

" ---------------------------------------------------------------------------
" The detached runner
" ---------------------------------------------------------------------------

function! s:spawn(plan) abort
  if !empty(a:plan.dir) && !isdirectory(a:plan.dir)
    try
      call mkdir(a:plan.dir, 'p')
    catch /.*/
      call dbui_multidb#notify#error(printf('vim-dadbod-manager: cannot create %s: %s', a:plan.dir, v:exception))
      return 0
    endtry
  endif

  let cmd = ['sh', '-c', s:command(a:plan)]

  try
    if has('nvim')
      let job = jobstart(cmd, {'detach': 1, 'on_exit': function('dbui_multidb#backup#on_exit', [a:plan])})
      if job <= 0
        throw printf('jobstart() returned %d', job)
      endif
      let s:jobs[job] = a:plan
    else
      let job = job_start(cmd, {'stoponexit': '', 'exit_cb': function('dbui_multidb#backup#vim_exit', [a:plan])})
      let info = job_info(job)
      let s:jobs[string(get(info, 'process', 0))] = a:plan
    endif
  catch /.*/
    call dbui_multidb#notify#error(printf('vim-dadbod-manager: cannot start the %s: %s', tolower(s:verb(a:plan)), v:exception))
    return 0
  endtry

  call dbui_multidb#notify#info(printf('%s started: %s%s', s:verb(a:plan), s:target_label(a:plan), s:remote_hint(a:plan)))
  return 1
endfunction

" The sh -c string: the command with its input on stdin when it has one, stdout
" routed to the target (for commands that dump to stdout) or /dev/null, and
" stderr always to the log.
function! s:command(plan) abort
  let out = get(a:plan, 'stdout_target', 0) && !empty(a:plan.target)
        \ ? s:sh_quote(a:plan.target) : s:devnull()
  let stdin = empty(get(a:plan, 'stdin_file', ''))
        \ ? '' : ' < ' . s:sh_quote(a:plan.stdin_file)
  return printf('%s%s > %s 2> %s', s:join(a:plan.argv), stdin, out, s:sh_quote(a:plan.log))
endfunction

function! s:finish(plan, code) abort
  call filter(s:jobs, 'v:val isnot# a:plan')
  let label = s:target_label(a:plan) . s:remote_hint(a:plan)
  if a:code == 0
    call dbui_multidb#notify#info(s:verb(a:plan) . ' finished: ' . label)
    " The listing of a finished backup changed: refresh just that section
    " instead of redrawing the whole drawer. Deferred out of the job callback
    " with a zero-delay timer. A restore or a server-side dump changes no
    " local listing, so only a local backup schedules the refresh.
    if get(a:plan, 'local', 1) && get(a:plan, 'verb', 'Backup') ==# 'Backup'
      call timer_start(0, function('dbui_multidb#backup#refresh_section', [a:plan]))
    endif
  else
    call dbui_multidb#notify#warning(printf(
          \ '%s failed (exit %d): %s. See %s.',
          \ s:verb(a:plan), a:code, label, fnamemodify(a:plan.log, ':~')))
  endif
endfunction

" ---------------------------------------------------------------------------
" Helpers
" ---------------------------------------------------------------------------

function! s:str(value) abort
  return type(a:value) ==# type('') ? a:value : ''
endfunction

function! s:url(db) abort
  let url = s:str(get(a:db, 'url', ''))
  if empty(url)
    return ''
  endif
  let resolved = dbui_multidb#url#resolve(url)
  return empty(resolved) ? url : resolved
endfunction

function! s:parse(url) abort
  if empty(a:url)
    return {}
  endif
  try
    return db#url#parse(a:url)
  catch /.*/
    return {}
  endtry
endfunction

function! s:canonical(scheme) abort
  let scheme = tolower(s:str(a:scheme))
  if scheme =~# '^mysql\d*$' || scheme =~# '^mariadb\d*$'
    return 'mysql'
  endif
  return get(s:aliases, scheme, scheme)
endfunction

" The scheme of a connection, and its canonical name. db.scheme is only filled
" in once vim-dadbod-ui has connected the database, so the URL is the fallback.
function! s:schemes(db) abort
  let raw = tolower(s:str(get(a:db, 'scheme', '')))
  if empty(raw)
    let raw = tolower(s:str(get(s:parse(s:url(a:db)), 'scheme', '')))
  endif
  return {'raw': raw, 'scheme': s:canonical(raw)}
endfunction

function! s:context(db, cfg) abort
  let url = s:url(a:db)
  let schemes = s:schemes(a:db)
  let dir = s:dirname(a:cfg)
  let dbname = dbui_multidb#backup#dbname(a:db)
  let timestamp = 'backup-' . strftime('%Y-%m-%d-%H-%M-%S')
  let name = printf('%s-%s', s:slug(dbname), timestamp)
  let parsed = s:parse(url)
  return {
        \ 'cfg': a:cfg, 'url': url, 'parsed': parsed, 'db': a:db,
        \ 'raw': schemes.raw, 'scheme': schemes.scheme,
        \ 'dbname': dbname, 'dir': dir, 'timestamp': timestamp,
        \ 'name': name, 'log': dir . '/' . name . '.log',
        \ 'secret': s:secret(parsed)}
endfunction

" The shared part of every plan; branches only fill in what differs.
function! s:plan(ctx, overrides) abort
  let plan = {
        \ 'ok': 1,
        \ 'db': a:ctx.db,
        \ 'kind': 'client_file',
        \ 'scheme': a:ctx.scheme,
        \ 'raw_scheme': a:ctx.raw,
        \ 'argv': [],
        \ 'target': '',
        \ 'dir': a:ctx.dir,
        \ 'name': a:ctx.name,
        \ 'timestamp': a:ctx.timestamp,
        \ 'ext': '',
        \ 'log': a:ctx.log,
        \ 'note': '',
        \ 'writes_target': 1,
        \ 'stdout_target': 0,
        \ 'local': 1,
        \ 'verb': 'Backup',
        \ 'stdin_file': '',
        \ 'secret': a:ctx.secret,
        \ }
  call extend(plan, a:overrides)
  return plan
endfunction

function! s:dirname(cfg) abort
  let dir = s:str(get(a:cfg, 'backup_dir', ''))
  if empty(dir)
    let dir = '~/dbui-backups'
  endif
  let dir = simplify(expand(dir))
  if len(dir) > 1
    let dir = substitute(dir, '/\+$', '', '')
  endif
  return empty(dir) ? 'dbui-backups' : dir
endfunction

" The database name out of a parsed URL, falling back to a caller supplied name.
function! s:dbname(url, fallback) abort
  let parsed = s:parse(a:url)
  if get(parsed, 'path', '') !~# '^/\=$'
    let name = s:last_segment(substitute(parsed.path, '^/', '', ''))
    if !empty(name)
      return name
    endif
  endif
  if has_key(parsed, 'opaque')
    let name = s:last_segment(substitute(parsed.opaque, '[?#].*', '', ''))
    if !empty(name)
      return name
    endif
  endif
  return a:fallback
endfunction

function! s:last_segment(str) abort
  let parts = split(a:str, '/')
  return empty(parts) ? '' : parts[-1]
endfunction

function! s:has_database(url) abort
  let parsed = s:parse(a:url)
  if get(parsed, 'path', '') !~# '^/\=$'
    return 1
  endif
  if has_key(parsed, 'opaque')
    return s:last_segment(substitute(parsed.opaque, '[?#].*', '', '')) !=# ''
  endif
  return 0
endfunction

" A filesystem-safe stem from a database name. The timestamp makes the file
" unique, so a collision between two names only changes readability.
function! s:slug(name) abort
  let slug = tolower(substitute(a:name, '[^A-Za-z0-9_-]', '-', 'g'))
  let slug = substitute(slug, '-\+', '-', 'g')
  let slug = substitute(slug, '^-\|-$', '', 'g')
  if empty(slug)
    let slug = 'database'
  endif
  return slug[0 : 63]
endfunction

" A free path under dir: timestamps make collisions unlikely, but a backup must
" never silently overwrite an earlier one.
function! s:target(dir, name, ext) abort
  let candidate = a:dir . '/' . a:name . a:ext
  let counter = 0
  while filereadable(candidate) || isdirectory(candidate)
    let counter += 1
    let candidate = printf('%s/%s-%d%s', a:dir, a:name, counter, a:ext)
  endwhile
  return candidate
endfunction

" The password to mask out of any display, from the URL (userinfo, then a
" password= / passwd= / pwd= parameter).
function! s:secret(parsed) abort
  let password = s:str(get(a:parsed, 'password', ''))
  if !empty(password)
    return password
  endif
  let params = get(a:parsed, 'params', {})
  if type(params) !=# type({})
    return ''
  endif
  for key in ['password', 'passwd', 'pwd']
    let password = s:str(get(params, key, ''))
    if !empty(password)
      return password
    endif
  endfor
  return ''
endfunction

" g:dbui_multidb_backup_options[<scheme>] adds arguments to a built-in command.
function! s:options(ctx) abort
  let value = s:lookup(a:ctx.cfg, 'backup_options', a:ctx.raw, a:ctx.scheme)
  if type(value) ==# type([])
    return map(copy(value), 's:str(v:val)')
  elseif type(value) ==# type('') && !empty(value)
    return split(value, '\s\+')
  endif
  return []
endfunction

" g:dbui_multidb_backup_server_dirs[<scheme>]: where a server-side command
" writes. Required for the schemes whose tool writes on the database server.
function! s:server_dir(ctx) abort
  let dirs = get(a:ctx.cfg, 'backup_server_dirs', {})
  if type(dirs) !=# type({})
    return ''
  endif
  let dir = get(dirs, a:ctx.raw, get(dirs, a:ctx.scheme, ''))
  return s:str(dir)
endfunction

" A server-side path under the configured directory. No local collision check:
" the path lives on another machine, and the timestamp already makes it unique.
function! s:server_target(base, name, ext) abort
  return substitute(a:base, '/\+$', '', '') . '/' . a:name . a:ext
endfunction

" Look a scheme up in one of the per-scheme configuration dicts, trying the raw
" spelling first and the canonical one second. Returns 0 when absent.
function! s:lookup(cfg, key, raw, scheme) abort
  let table = get(a:cfg, a:key, {})
  if type(table) !=# type({})
    return 0
  endif
  if has_key(table, a:raw)
    return table[a:raw]
  endif
  if a:scheme !=# a:raw && has_key(table, a:scheme)
    return table[a:scheme]
  endif
  return 0
endfunction

" The start and length of the program prefix inside a built-in argv, so that a
" string override can replace it. Most commands are a single leading binary;
" clickhouse is one or two tokens and sqlserver carries an "env VAR=" prefix.
function! s:program_at(scheme, argv) abort
  if a:scheme ==# 'clickhouse'
    return [0, s:leading(a:argv)]
  endif
  if a:scheme ==# 'sqlserver'
    let i = index(a:argv, 'sqlcmd')
    return i < 0 ? [0, 1] : [i, 1]
  endif
  return [0, 1]
endfunction

function! s:leading(argv) abort
  let i = 0
  while i < len(a:argv) && a:argv[i] !~# '^-'
    let i += 1
  endwhile
  return i > 0 ? i : 1
endfunction

function! s:replace_program(scheme, argv, program) abort
  let [start, length] = s:program_at(a:scheme, a:argv)
  let head = start > 0 ? a:argv[0 : start - 1] : []
  return head + split(a:program, '\s\+') + a:argv[start + length :]
endfunction

function! s:values(ctx, ext, target) abort
  return {
        \ 'output': a:target, 'file': a:target,
        \ 'dir': a:ctx.dir, 'name': a:ctx.name, 'log': a:ctx.log,
        \ 'timestamp': a:ctx.timestamp, 'ext': a:ext,
        \ 'db': a:ctx.dbname, 'database': a:ctx.dbname,
        \ 'scheme': a:ctx.raw, 'url': a:ctx.url,
        \ 'host': s:str(get(a:ctx.parsed, 'host', '')),
        \ 'port': s:str(get(a:ctx.parsed, 'port', '')),
        \ 'user': s:str(get(a:ctx.parsed, 'user', '')),
        \ 'password': s:str(get(a:ctx.parsed, 'password', '')),
        \ 'disk': a:ctx.scheme ==# 'clickhouse' ? 'backups' : '',
        \ 'directory': a:ctx.scheme ==# 'oracle' ? 'DATA_PUMP_DIR' : '',
        \ }
endfunction

function! s:fill(str, values) abort
  return substitute(a:str, '{\(\w\+\)}', '\=get(a:values, submatch(1), "{" . submatch(1) . "}")', 'g')
endfunction

function! s:callable(value) abort
  if type(a:value) ==# type(function('tr'))
    return 1
  endif
  return type(a:value) ==# type('') && !empty(a:value) && exists('*' . a:value)
endfunction

function! s:funcref(value) abort
  if type(a:value) ==# type(function('tr'))
    return a:value
  endif
  return function(a:value)
endfunction

" POSIX single-quote quoting, with the standard '\'' escape for embedded
" quotes. The string is only ever given to sh -c, so there is no dependency on
" 'shell' or shellescape().
function! s:sh_quote(str) abort
  return "'" . substitute(a:str, "'", "'\\''", 'g') . "'"
endfunction

" Join argv into one sh -c command, quoting only the tokens that need it so the
" echo_command display stays readable.
function! s:join(argv) abort
  let parts = []
  for arg in a:argv
    if arg =~# '^[A-Za-z0-9_/:.@%+=,-]\+$'
      call add(parts, arg)
    else
      call add(parts, s:sh_quote(arg))
    endif
  endfor
  return join(parts, ' ')
endfunction

function! s:devnull() abort
  return has('win32') ? 'NUL' : '/dev/null'
endfunction

function! s:target_label(plan) abort
  let target = a:plan.target
  if empty(target)
    return a:plan.name
  endif
  return a:plan.local ? fnamemodify(target, ':~') : target
endfunction

function! s:remote_hint(plan) abort
  return a:plan.local ? '' : ' (on the database server)'
endfunction

function! s:sql_escape(str) abort
  return substitute(a:str, "'", "''", 'g')
endfunction

function! s:tsql_ident(str) abort
  return substitute(a:str, ']', ']]', 'g')
endfunction

function! s:tsql_str(str) abort
  return substitute(a:str, "'", "''", 'g')
endfunction

function! s:ch_ident(str) abort
  return substitute(a:str, '`', '``', 'g')
endfunction
