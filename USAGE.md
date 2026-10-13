# Using vim-dadbod-manager

The day-to-day guide: configuration, how a connection is recognised as a server
node, the **Administration** and **Backups** sections, the commands and how the
drawer behaves. Install
and the vendored-code notes live in [README.md](README.md).

## Configuration

All options live in `g:dbui_multidb_*`, are read lazily on every use (so they can be
set at any point after startup) and can also be passed to `dbui_multidb#setup()` from
Lua or Vimscript:

```lua
-- From Lua, set the variables or call the API directly (this plugin is plain
-- Vimscript, there is no Lua wrapper to require).
vim.g.dbui_multidb_masters = { 'Banco Production' }
vim.g.dbui_multidb_exclude = { 'test$' }
vim.fn['dbui_multidb#setup']({ masters = { 'Banco Production' } })
```

```vim
" From Vimscript, in a ftplugin or after startup:
let g:dbui_multidb_masters = ['Banco Production', 'Banco Local SQLServer']
let g:dbui_multidb_exclude = ['_test$', '_staging$']
```

| Option | Default | Meaning |
| --- | --- | --- |
| `g:dbui_multidb_masters` | `[]` | Names of the `g:dbs` connections to render as server nodes. Empty (the default) means **auto-detect**; a non-empty list is explicit mode and turns auto-detection off (see [Server detection](#server-detection)). A list, or a comma separated string (`'Banco, Rama Dev'`) — the string form is handy from a `ftplugin`. |
| `g:dbui_multidb_exclude` | `[]` | Regexes; a discovered database whose name matches any of them is hidden (case insensitive: `'test$'`, `'^information_schema$'`). |
| `g:dbui_multidb_sort` | `1` | Sort the discovered databases case-insensitively. `0` keeps the adapter order. |
| `g:dbui_multidb_cache` | `1` | Discover once per server and reuse the result on later expansions. `0` re-queries on every expansion. |
| `g:dbui_multidb_notify` | `1` | Show an info notification while a discovery is running. Failures are always notified: they are the reason the server node came back empty. |
| `g:dbui_multidb_server_icons` | `{}` | Override the toggle icon of server nodes: `{'server_expanded': '▼', 'server_collapsed': '▶'}`. Unset keys fall back to `g:db_ui_icons`. |
| `g:dbui_multidb_admin_section` | `1` | Draw the per-database **Administration** section (the provider's users and roles, with the destructive actions behind a confirmation) on expanded databases. `0` hides it. |
| `g:dbui_multidb_backup_section` | `1` | Draw the per-database **Backups** section (lists backups, restores them, and offers a **New backup** action) on expanded client-side databases. `0` hides it. |
| `g:dbui_multidb_backup_dir` | `'~/dbui-backups'` | Where client-side backups are written, one folder per database. `~` and `$VARS` are expanded. |
| `g:dbui_multidb_backup_commands` | `{}` | Override a backup command by scheme (see [Backups](#backups)). |
| `g:dbui_multidb_backup_options` | `{}` | Extra flags inserted into a built-in command, by scheme. |
| `g:dbui_multidb_backup_server_dirs` | `{}` | Destination **on the server** for the server-side schemes (`sqlserver`, `clickhouse`, `oracle`), which have no Backups section and only back up through the planner API; see [Backups](#backups). |
| `g:dbui_multidb_backup_runner` | `''` | A function name that receives the backup plan and replaces the spawn entirely. |
| `g:dbui_multidb_backup_echo_command` | `0` | `1` shows the redacted command as a notification instead of running it. |

### Server detection

With `g:dbui_multidb_masters` empty (the default) a connection becomes a server when
**both** hold:

1. its resolved URL scheme advertises `complete_database` in vim-dadbod (clickhouse,
   mariadb, mongodb, mysql, postgresql, snowflake, sqlserver), and
2. its URL names no database, or names the scheme's own default database:

| Scheme | Default database |
| --- | --- |
| `sqlserver` | `master` |
| `postgresql` | `postgres` |
| `clickhouse` | `default` |

A scheme that implements `complete_database` but is not in the table (`mysql`,
`mariadb`, `mongodb`, `snowflake`) is still detected, but only when its URL names no
database at all: `mysql://root@localhost/` is a server while
`mysql://root@localhost/app` is a plain connection. Database names are compared
case-insensitively, so `sqlserver://sa@host/master` and `SQLServer://sa@host/MASTER`
are equivalent.

Set `g:dbui_multidb_masters` to a non-empty list to opt out: the list is then the
whole truth, auto-detection is off, and a connection is a server only when its name
is in the list. That is the escape hatch for a scheme or a naming convention the
heuristic gets wrong.

`g:dbui_multidb_masters` is initialised to `[]` at load time, so `:DBManagerInfo`
never sees an undefined variable; every other option is only read through its default.

The notification label is the one option that is not named `dbui_multidb_*`: it
belongs to the shadowed upstream module rather than to this plugin.
`g:db_ui_notification_title` (default `[DBManager]`) is read when that module
loads, so set it in your configuration; changed later, it needs
`:runtime autoload/db_ui/notifications.vim` to take effect.

## Connection URLs

Every connection in `g:dbs` is a URL of the form:

    scheme://[user[:password]@]host[:port][/database][?param=value[&param=value]]

The schemes this plugin works with, the exact URL shape each expects, and the query
parameters each adapter understands:

| Scheme | URL format | Common parameters | Notes |
| --- | --- | --- | --- |
| `postgresql` (`postgres`) | `postgresql://user:password@host:5432/database` | `sslmode`, `channel_binding`, `connect_timeout`, `application_name`, `hostaddr`, `sslrootcert`, `sslcert`, `sslkey` | `sslmode` accepts `disable`, `allow`, `prefer`, `require`, `verify-ca`, `verify-full`. `channel_binding` accepts `disable`, `prefer`, `require`. `ssl=true` is translated to `sslmode=require`. The `postgres` spelling also works; `postgres` is the default database for server detection. |
| `mysql` / `mariadb` | `mysql://user:password@host:3306/database` | `socket`, `ssl-mode`, `default-character-set`, `connect-timeout`, `protocol`, `login-path` | `ssl-mode` accepts `disabled`, `preferred`, `required`, `verify_ca`, `verify_identity`. Use `mariadb://` for MariaDB. Omit `/database` to detect the server. |
| `sqlite` | `sqlite:/absolute/path/file.db` | — | A file path, no host or user. |
| `mongodb` | `mongodb://user:password@host:27017/database` | `tls`, `ssl`, `authSource`, `replicaSet`, `readPreference`, `w`, `journal` | `tls=true` or `ssl=true` enables TLS. `authSource=admin` specifies the authentication database. `mongodb+srv://` also works for Atlas. |
| `sqlserver` | `sqlserver://user:password@host:1433/database` | `encrypt`, `trustServerCertificate`, `authentication`, `integratedSecurity` | Both `?param=value&param=value` and `;param=value;param=value` query strings are accepted. `encrypt` accepts `optional`, `mandatory`, `strict`. `trustServerCertificate=true` bypasses certificate validation. `master` is the default database for server detection. |
| `duckdb` | `duckdb:/path/file.duckdb` | — | A file path. The adapter can also detect and open SQLite files. |
| `clickhouse` | `clickhouse://user:password@host:8123/database` | `secure`, `multiline`, `multiquery`, `time`, `stacktrace`, `skip_verify` | Boolean parameters (`secure`, `multiline`, `multiquery`, `time`, `stacktrace`) are passed as flags when true. `secure` maps to `--secure` and is required for ClickHouse Cloud. `default` is the default database for server detection. |
| `oracle` | `oracle://user:password@host:1521/service` | — | The path is the service name. The adapter uses sqlplus and builds the connection string `username/password@host:port/service`. |
| `redis` | `redis://user:password@host:6379/0` | `password`, `database` | The path is the database index (0-based). `rediss://` enables TLS. The authentication password can also be given as `?password=secret&database=3`. |
| `snowflake` | `snowflake://user:password@account/database/schema` | `warehouse`, `role`, `authenticator` | The account goes in the host position. `authenticator=externalbrowser` enables browser-based SSO. |

### Examples

Real connection URLs, with the password redacted (`<password>` — fill in your own,
URL-encoded if it contains special characters):

| Name | URL |
| --- | --- |
| Database Production | `sqlserver://admindevsql:<password>@20.62.126.199:1433/master` |
| Database Production2 Dev | `mariadb://admin:<password>@localhost:33006` |
| Database Production QA | `mariadb://admin:<password>@localhost:33007` |
|  Local SQLServer | `sqlserver://localhost:1433;database=master;user=sa;password=<password>;encrypt=optional;trustServerCertificate=true` |
|  Local MySQL | `mariadb://root:<password>@localhost:3306/?ssl=0` |
| Portfolio  | `postgresql://neondb_owner:<password>@ep-patient-shape-ac8dli88-pooler.sa-east-1.aws.neon.tech/?sslmode=require&channel_binding=require` |
| postgres | `postgresql://postgres:postgres@localhost:5432/postgres` |


### SQL Server semicolon syntax

The SQL Server adapter accepts a JDBC/ODBC-style connection string after the
scheme, in addition to the standard URL query syntax. Use `;` instead of `&`
between parameters:

    sqlserver://localhost:1433;database=master;user=sa;password=<password>;encrypt=optional;trustServerCertificate=true

Both forms are canonicalised to the same internal representation, so you can mix
and match if needed:

    sqlserver://sa@localhost:1433/master?encrypt=optional&trustServerCertificate=true
    sqlserver://sa@localhost:1433;database=master;encrypt=optional;trustServerCertificate=true

### URL-encoding credentials

Users and passwords that contain special characters must be **percent-encoded**
(`%XX`) in the URL. vim-dadbod decodes them when it parses the URL and this plugin
re-encodes them when it rebuilds a child connection, so a character that collides
with the URL syntax (`@`, `:`, `/`, `#`, `?`, `&`, ...) has to be escaped or it breaks
the connection instead of reaching the server:

| Character | Encoding |
| --- | --- |
| `@` | `%40` |
| `:` | `%3A` |
| `/` | `%2F` |
| `#` | `%23` |
| `?` | `%3F` |
| `&` | `%26` |
| `=` | `%3D` |
| space | `%20` |
| `%` | `%25` |

For example, the password `p@ss:w/rd` becomes `p%40ss%3Aw%2Frd` and the user
`alice@example.com` becomes `alice%40example.com`:

    postgresql://alice%40example.com:p%40ss%3Aw%2Frd@db.example.com/app

### Default database per scheme

The default database matters for server detection: a connection whose URL names no
database, or names the scheme's own default, is rendered as a server node rather
than a plain connection. The schemes above that participate in auto-detection use:

| Scheme | Default database |
| --- | --- |
| `sqlserver` | `master` |
| `postgresql` | `postgres` |
| `clickhouse` | `default` |
| `mysql`, `mariadb`, `mongodb`, `snowflake` | (none — only an absent database triggers detection) |

A connection pinned to a specific database stays a plain connection, exactly as
before. Set `g:dbui_multidb_masters` to a non-empty list to turn detection off
entirely (see [Server detection](#server-detection)).

## Administration

An **expanded** database whose scheme has an administration provider gets an
**Administration** section between **Tables** and **Backups**. Expand it to see the
categories the provider serves, then expand a category to list what it holds. The
registry ships six providers:

- `postgresql` — **Users** (the roles that can log in) and **Roles** (every role).
- `mysql` — **Users** (the accounts that can log in) and **Roles** (accounts created as roles).
- `mariadb` — **Users** (the accounts that can log in) and **Roles** (the rows `is_role` marks), with the locked flag read from `mysql.global_priv`.
- `sqlserver` — **Logins** and **Server roles**, the names the server itself uses.
- `mongodb` — **Users** only, read from the database the connection authenticates against (`?authSource=`, else the URL's database, else `admin`).
- `redis` — **Users** only (the ACL users).

A scheme with no provider — every other scheme — draws no section at all.

```
▾ app
    ▸ Saved queries (0)
    ▸ Tables (128)
    ▾ Administration
        ▾ Users (3)
            ▾ alice (active)
                List
                Attributes
                Identity
                Roles
                Grants
                Effective access
                Dependencies
                Activity
                ────────────────────────
                Lock
                Reset password
                Drop
            ▸ root (superuser)
            ▸ old (expired)
        ▸ Roles (7)
    ▾ Backups (1)
        + New backup
```

The section, the categories and the entities are containers; expand them freely.
Nothing is queried until a category is expanded, and a listing is fetched once and
reused on every later collapse and expand, so drawing — or re-drawing — the tree
costs nothing. The category shows its count once it is loaded. The status in
parentheses is the server's own word for the entity, per provider: `postgresql`
says `superuser`, `active`, `expired` or `group`; `mysql` and `mariadb` say `active`, `locked` or
`expired` for an account and `role` for a role; `sqlserver` says `active`, `group`
or `disabled` for a login and `fixed` or `user-defined` for a server role;
`mongodb` shows the role summary (or `no roles`); `redis` says `on` or `off`.

`<CR>` on a read-only leaf — **List**, **Attributes**, … **Activity** — opens a query
buffer named after the database, the entity and the action, pre-filled with the
statement and **not executed**: it is an ordinary query buffer, run it the way you
run any other.

The **Lock**, **Reset password** and **Drop** leaves sit below a rule and are
**destructive**. `<CR>` on one asks for confirmation first (`Drop alice in database
alpha?`), and only an accepted answer opens the statement — a cancelled one opens
nothing and leaves the connection as it was. As with a read-only leaf the plugin
does not run it itself; with `g:db_ui_auto_execute_table_helpers` set, the confirmed
statement is executed as soon as the buffer opens.

The section reuses the `tables` toggle icon, and its leaves render without an icon.
A role whose name contains `->` (or is empty) is not supported, because the entity
name is carried inside the drawer item's path. Names are quoted where they are
identifiers (`DROP ROLE "a""b"`) and bound as literals where they are values
(`o'brien`), never spliced into the statement as raw SQL.

A provider is a registry entry plus one autoload file: `dbui_multidb#admin#register()`
maps a scheme to a function prefix, and the file behind it answers `supports(db)`
(which categories it serves — a string instead of a number renames the category,
which is how `sqlserver` shows **Logins** and **Server roles**), `list_users(db)` /
`list_roles(db)` (the category listing) and one builder per leaf (`user_drop(db,
name)` and friends, returning the statement; an empty or missing builder hides
that leaf, which is how `mongodb` omits Lock and `mysql` omits Effective access).
The postgresql provider reads `pg_roles`; the others read their server's own
catalogs (`mysql.user` and `role_edges`; MariaDB's `is_role`, `roles_mapping` and
`global_priv`; `sys.server_principals`; `db.getUsers()`; `ACL LIST`).

## Backups

An **expanded** client-side database ends with a **Backups** section; expand it to see
the backup files that connection owns (newest first) and a **New backup** action.
`<CR>` on **New backup** starts a backup of that database; `<CR>` on a file restores it
into the database it came from and `d` deletes it — both ask for confirmation first — and `r` renames
it. A backup or restore is a detached job: the editor is never blocked, and a
notification reports when it starts and again when it finishes (or fails, with the log
to read). When a local backup finishes, only that database's **Backups** section is
rewritten in place — the new file appears and the count grows — so the rest of the
tree, the cursor and the view are left as they were. When a restore finishes, that
one database is re-queried and only its subtree is rewritten, so the restored
contents replace the old ones in place. A server-side dump changes no local listing
and leaves the drawer alone. Passwords never reach a
notification: the command is built from the connection URL, which carries the
credentials, and the displayed command is redacted.

```
▾ app
    ▸ Saved queries (0)
    ▸ Tables (128)
    ▾ Backups (1)
        + New backup
        backup-2024-01-01-12-00-00
```

The Backups section reuses the `tables` toggle icon, and the **New backup** leaf uses
`g:db_ui_icons.new_query` (the same mark as the connection's "New query" action).
Backup files render without an icon.

The command for each scheme, and where the dump lands:

| Scheme | Command | Destination |
| --- | --- | --- |
| `postgresql` | `pg_dump --format=custom` | local (`g:dbui_multidb_backup_dir`) |
| `mysql` / `mariadb` | `mysqldump` / `mariadb-dump --result-file` | local |
| `sqlite` | `sqlite3 … "VACUUM INTO …"` (SQLite 3.27+) | local |
| `mongodb` | `mongodump --archive --gzip` | local |
| `duckdb` | `duckdb … "EXPORT DATABASE … (FORMAT PARQUET)"` | local (a directory) |
| `redis` | `redis-cli --rdb` | local |
| `sqlserver` | no section; `sqlcmd -Q "BACKUP DATABASE …"` through the planner only, with `…_server_dirs.sqlserver` | server (or nowhere) |
| `clickhouse` | `clickhouse-client -q "BACKUP DATABASE … TO Disk(…)"` | **server** (`…_server_dirs.clickhouse` = disk name) |
| `oracle` | `expdp` | **server** (`…_server_dirs.oracle` = Oracle `DIRECTORY` object) |

Each database gets its own folder under the destination — `<database>` is the slug the
plugin builds from the connection's database name — and the files in it are named
`backup-YYYY-MM-DD-HH-MM-SS.<ext>`, which is also the listed label. The folder is what
makes a file a backup of that connection: a file renamed by hand keeps its place in the
section, and another database's folder is never listed. A flat `<database>-backup-…`
name written by an older version is still recognised, with the leading `<database>-`
left out of the label. An existing file is never overwritten (a `-1`, `-2`, … suffix is
appended instead).

The section appears only for client-side schemes — `postgresql`, `mysql`/`mariadb`,
`sqlite`, `mongodb`, `duckdb`, `redis` — whose dumps land on this machine, where the
drawer can list them. Restoring a file from the drawer is supported for `postgresql`,
`mysql`, `sqlite` and `mongodb`; for the others the file is listed, but `<CR>` explains
that it has to be restored with that database's own client.

**Server-side schemes have no Backups section.** `sqlcmd`, `clickhouse-client` and
`expdp` write on the database server, not on your machine, so there is nothing here to
list, restore or delete: the drawer draws no section for `sqlserver`, `clickhouse` and
`oracle`. Their commands in the table above still plan through the plugin's planner API
(`dbui_multidb#backup#plan()`), which refuses to run them until you tell the planner
where the server should write via `g:dbui_multidb_backup_server_dirs`:

```vim
let g:dbui_multidb_backup_server_dirs = {
      \ 'sqlserver': '/var/opt/mssql/backup',
      \ 'clickhouse': 'backups',        " a ClickHouse disk name, not a path
      \ 'oracle': 'DATA_PUMP_DIR',      " an Oracle DIRECTORY object, not a path
      \ }
```

Without that key the planner reports the backup as **not available** rather than
pretending one ran.

### Overriding the command

- `g:dbui_multidb_backup_commands` replaces a command, keyed by scheme (the raw
  spelling `mariadb` or the canonical `mysql` both work). A **string** replaces only
  the program: `{'postgresql': 'pg_dump16'}`. A **list** is a complete argv template
  with placeholders `{url} {db} {host} {port} {user} {password} {output} {file}
  {dir} {name} {timestamp} {ext} {log} {scheme} {disk} {directory}`; if it mentions
  `{output}`/`{file}` the command is assumed to create the file, otherwise its stdout
  is redirected there.
- `g:dbui_multidb_backup_options` inserts extra flags into a built-in command, keyed
  by scheme: `{'postgresql': '--no-owner --verbose'}` (a string) or a list.
- `g:dbui_multidb_backup_runner` (a function name) receives the plan dict and
  replaces the spawn entirely — the command is never run. Use it to route backups
  through your own machinery.
- `g:dbui_multidb_backup_echo_command` (`1`) shows the redacted command instead of
  running it.

Backups are POSIX-only: they run through `sh -c`, so the database client must be in
the `$PATH` of the shell Neovim was started from.

## Commands

The drawer's own entry points are only available under this plugin's name: the
`:DBUI*` spellings are removed while this plugin loads, because the drawer is
vendored here and two names for one command only invite drift. The right column
is what each command is called upstream, for anyone who had it in a keymap:

| `:DBManager*` | upstream spelling (removed) | Description |
| --- | --- | --- |
| `:DBManager` | `:DBUI` | Open the drawer, or focus it when it is already open. Command modifiers are passed through: `:vertical DBManager`, `:botright DBManager`. |
| `:DBManagerToggle` | `:DBUIToggle` | Open the drawer, or close it when it is open. |
| `:DBManagerClose` | `:DBUIClose` | Close the drawer. |
| `:DBManagerAddConnection` | `:DBUIAddConnection` | Add a connection to `g:dbs` and to the connections file. |
| `:DBManagerFindBuffer` | `:DBUIFindBuffer` | Jump to the connection of the current buffer. |
| `:DBManagerRenameBuffer` | `:DBUIRenameBuffer` | Rename the connection of the current buffer. |
| `:DBManagerLastQueryInfo` | `:DBUILastQueryInfo` | Show the connection of the last executed query. |

This plugin's own commands:

| Command | Description |
| --- | --- |
| `:DBManagerRefresh` | Drop the cached discoveries and re-render. Every server is queried again on its next expansion. |
| `:DBManagerRefresh <server>` | Same for one server, by connection name or key (tab-completed). A still-expanded server is re-queried immediately. |
| `:DBManagerInfo` | Print the effective configuration, whether the drawer is patched, and the discovery state (`not discovered yet`, the error, or `N database(s): …`) of every server. |

The usual drawer keymaps work unchanged: `o`/`<CR>` in a server node expands it and
runs the discovery. `R` re-queries the whole drawer wherever the cursor is: every
expanded server's database list is re-discovered, not only the tables of the node
under the cursor.

One `:DBUI*` name survives, and it is not an entry point: the vendored notification
module defines `:DBUIHideNotifications` itself, from an autoload file, the first time
a notification is shown. It is upstream's documented way to dismiss the
notification window (help tag `*DBUIHideNotifications*`) and there is no
`:DBManager*` command that could stand in for it, so it is left exactly as upstream
writes it. `:h db_ui` therefore still describes that command, and the removed entry
points; the help file is vendored text and is kept byte-identical.

## Behavior

- **The drawer is extended, not forked.** vim-dadbod-ui's drawer is a dict whose
  methods are Funcrefs, so `db_ui#drawer#get()` is patched from the outside:
  `add_db`, `toggle_db`, `populate`, `render` and `redraw` are wrapped on the live
  (the originals stay available as `dbui_multidb_orig_*`), and `add` and
  `get_toggle_icon` are left untouched. No vendored file is edited: they are byte
  for byte the files vim-dadbod-ui publishes (see [Vendored code](README.md#vendored-code)).
  The patch is installed from `FileType dbui` and `User DBUIOpened`, is idempotent,
  and re-applies itself whenever `db_ui#open()` builds a fresh drawer. If a future
  vim-dadbod-ui loses one of those methods the patch reports it and disables itself
  instead of breaking the drawer.
- **Server nodes are containers.** They are never connected, never queried and never
  get a `db#connect()` call, so an expanded server cannot pop a password prompt for
  the *server* connection; only the database you expand connects.
- **Servers are detected from the URL, not named.** With `g:dbui_multidb_masters`
  empty (the default) a connection is a server when its adapter can list databases
  and its URL names no database — or names the scheme's own default. Putting a name
  in `g:dbui_multidb_masters` switches to explicit mode and turns detection off for
  every connection. Detection never connects: it reads the URL, and
  `dbui_multidb#discoverable()` never throws while the drawer is rendered.
- **Children live only in `drawer.dbui.dbs`.** They are not appended to
  `dbui.dbs_list`, which is what `populate_dbs()` rebuilds from `g:dbs`, dotenv files
  and the connections file. Nothing this plugin discovers can therefore leak into
  `g:dbs`, be written back to disk, or survive as a stale entry after a redraw.
- **Discovery is synchronous and cached** in the master's own dict under
  `dbui_multidb_children`, so a plain re-render (`BufEnter`, moving between windows)
  never touches the network again and leaves the tree and its expansion state intact.
  The cache is dropped by `R` — through the `redraw` patch, from any cursor position
  — by `:DBManagerRefresh`, and by vim-dadbod-ui's own "Refreshing all databases"
  (`render({'dbs': 1})`); the next render then re-queries every expanded server. An
  expansion that follows a failed discovery retries, because a failure is usually a
  server that was not reachable a minute ago.
- **Hierarchy.** A child is added as `key_name = '<master key>::<database>'` with
  `source = 'master'`, `is_child = 1` and `master_key_name` pointing at its server.
  Its dict carries the same keys as a normal entry (a child is built by the same code
  path that vim-dadbod-ui uses when it could not be discovered to begin with), and it
  is rendered through upstream's `add_db`, indented one level, so schemas, tables and
  saved queries keep working one level further down.
- **Saved queries** go to `<g:db_ui_save_location>/<master>/<database>` when a save
  location is configured, keeping the queries of two databases on the same server
  apart.
- **Refresh is lazy.** `:DBManagerRefresh` does not open connections: it forgets
  what it knew and lets the next expansion re-query, which keeps the command usable
  from a keymap that must not block on a slow server.
- **A failure is notified, not painted.** When a discovery fails the drawer keeps
  its tree: the server node carries vim-dadbod-ui's own `connection_error` icon
  (`✕`, the same mark a failed connection gets) and no error line is inserted,
  because the drawer is not where a diagnosis belongs. The reason is delivered as
  one warning notification per attempt — `vim-dadbod-manager: Banco Production:
  sqlcmd is not installed` — and the same message shows up under that server in
  `:DBManagerInfo`. Other servers are untouched: one unreachable server, or one
  client that is not installed in the shell Neovim was started from, never stops
  the others from being discovered.
- **An empty answer means the connection failed.** vim-dadbod's `db#systemlist()`
  returns `[]` when a client exits non-zero instead of throwing, so an adapter that
  reports nothing did not connect. An empty list is therefore treated like any
  other failure: the server node is marked and the notification says the client
  returned no databases. `" No databases found` is reserved for the one case where
  the client answered and every name was filtered away by
  `g:dbui_multidb_exclude`.
- **The connection's own database is always listed.** The database named in the
  server URL (`sqlserver://…/master`, `postgresql://…/postgres`,
  `clickhouse://…/default`) is, by construction, a real database on that server,
  so it is added to the discovered list when an adapter's query omits it (a
  `sqlcmd` query that misses `master`, for instance). The adapter's own spelling
  wins and the name is never duplicated.
- **Errors are translated.** vim-dadbod reports a missing client as
  `Vim(let):E475: Invalid value for argument cmd: 'sqlcmd' is not executable`,
  which is an implementation detail rather than a diagnosis. That exception
  becomes `sqlcmd is not installed`, and the `Vim(<command>):` prefix is stripped
  from every other exception before it is shown. The binary is taken from the
  message itself, so it is correct even when the adapter runs its client through
  `env` (sqlserver does that to pass `SQLCMDPASSWORD`).
- **Notifications never break the drawer.** Every message goes through
  `dbui_multidb#notify#*`, which falls back to `:echomsg` when a notifier throws
  (nvim-notify misconfigured, `noecho` in a redraw, …), and it is labelled
  `[DBManager]` rather than upstream's `[DBUI]` (see
  [Vendored code](README.md#vendored-code)). Connection URLs are never echoed — a URL
  carries the password.

## Limitations

- Discovery asks the adapter to *complete* a database name. That is the only
  server-side listing vim-dadbod exposes, so it is used as the list of databases;
  adapters that implement it as "the current database plus the schemas of a
  PostgreSQL connection" will show what the adapter returns.
- Only one level of hierarchy is added. A database that itself needs to be
  split further (a MongoDB cluster → databases is already that level) is drawn by
  vim-dadbod-ui's normal code, schemas included where the adapter supports them.
- The tree is rebuilt from the configuration on every redraw; expansion state is
  remembered per database, but a server that disappears from `g:dbs` takes its
  children with it (still-referenced children are kept alive if an open query buffer
  points at them, so a statusline never sees a dangling key).
- The **Administration** section reports what the connection can see: its catalog
  queries run with that connection's own rights, so a role you may not inspect is
  simply not listed, and a statement the section opens succeeds or fails with them.
- The **Administration** section is scheme-scoped, and a server node draws the same
  section under every discovered database child: `mysql` accounts, `sqlserver` logins
  and `postgresql` roles are server- or cluster-wide, while `mongodb` users are scoped
  to the authentication database and `redis` users are the server's ACL.
- `mysql` and `mariadb` share an account model but not the catalogs behind it:
  MySQL 8 keeps roles in `mysql.user` with no flag (the provider infers them), while
  MariaDB marks them with `is_role` and stores role grants in `roles_mapping`; each
  scheme has its own provider reading the right catalog.
