# vim-dadbod-manager

Turn a [vim-dadbod-ui](https://github.com/tpope/vim-dadbod-ui) connection into a
**server → databases → tables** tree, the way DBeaver and DataGrip show a database
server: one node per server, the databases it holds underneath it, and only then the
schemas, tables and queries.

vim-dadbod-ui lists every entry of `g:dbs` flat, so a server such as
`sqlserver://sa@localhost:1433/master` is one connection and the other databases on
that server are simply unreachable. This plugin recognises such a connection as a
**server node** automatically: it asks vim-dadbod's adapter for the databases behind
it (`complete_database`) and splices the result into the drawer as child nodes, without
adding them to `g:dbs`, to the connections file or to `dbui.dbs_list`.

```
▾ Banco Production
  " Databases (4)
  ▸ master
  ▾ app
      + New query
      ▸ Saved queries (0)
      ▸ Tables (128)
  ▸ reporting
  ▸ staging
▸ Banco Local SQLServer
▾ Portfolio PostgreSQL
  ▸ postgres
  ▸ analytics
```

Every child is a fully functional dbui connection: expand it to list its tables, open
a query buffer from it, run it with `:DB`/`<Leader>db`, see it in the statusline. The
URL is rebuilt from the server's, so credentials, ports and query parameters
(`sslmode`, `channel_binding`, `encrypt`, `trustServerCertificate`, …) are inherited.

## Requirements

- Neovim (tested on 0.12.4) or Vim 8.2+
- [vim-dadbod](https://github.com/tpope/vim-dadbod) — provides `db#resolve()`,
  `db#url#parse()`, `db#url#format()` and the adapters used for discovery

The drawer this plugin extends is [vim-dadbod-ui](https://github.com/tpope/vim-dadbod-ui),
and it is vendored in this repository: this plugin is the only one to install. A
separate copy of vim-dadbod-ui must *not* be installed next to it, see
[Vendored code](#vendored-code).

The scheme of a server connection must implement `complete_database` in its
vim-dadbod adapter. As of vim-dadbod 1.4 that is **clickhouse, mariadb, mongodb,
mysql, postgresql, snowflake and sqlserver**. A connection using one of those schemes
is detected as a server automatically when its URL names no database, or names the
scheme's own default database (see [Server detection](#server-detection)); a connection
pinned to a specific database, and any scheme that cannot list databases (a SQLite
file, a Redis URL), stays a plain connection and behaves exactly as before.

## Install

### lazy.nvim

```lua
{
	"sergioia-dev/vim-dadbod-manager",
	dependencies = { "tpope/vim-dadbod" },
	-- `opts` is passed to vim.g / setup(); see Configuration below.
	-- Server nodes are detected from the connection URL; set
	-- vim.g.dbui_multidb_masters = { "Banco Production" } to control them by hand.
}
```

### vim-plug

```vim
call plug#begin()
Plug 'tpope/vim-dadbod'
Plug 'sergioia-dev/vim-dadbod-manager'
call plug#end()

" Optional: name the server connections by hand instead of auto-detecting them.
" let g:dbui_multidb_masters = ['Banco Production', 'Banco Local SQLServer']
```

### No plugin manager

```sh
git clone https://github.com/sergioia-dev/vim-dadbod-manager \
  "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/pack/plugins/start/vim-dadbod-manager"
```

Neovim sources `plugin/` from every `pack/*/start/*` directory at startup, so the
commands and the autocmds exist after a restart.

### Nix

```nix
vim-dadbod-manager = pkgs.vimUtils.buildVimPlugin {
  pname = "vim-dadbod-manager";
  version = "0.1.0";
  src = pkgs.fetchFromGitHub {
    owner = "sergioia-dev";
    repo = "vim-dadbod-manager";
    rev = "<commit>";
    hash = "sha256-...";
  };
  doCheck = false;
};
```

Add the derivation next to `vimPlugins.vim-dadbod` in
`programs.neovim.configure.packages` (or in the `vimPlugins` list of your overlay);
`plugin/dbui_multidb.vim` and the vendored drawer are sourced from the packpath, so
no `require` is needed.

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
| `g:dbui_multidb_backup_section` | `1` | Draw the per-database **Backups** section (lists backups, restores them, and offers a **New backup** action) on expanded client-side databases. `0` hides it. |
| `g:dbui_multidb_backup_dir` | `'~/dbui-backups'` | Where client-side backups are written. `~` and `$VARS` are expanded. |
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

## Backups

An **expanded** client-side database ends with a **Backups** section; expand it to see
the backup files that connection owns (newest first) and a **New backup** action.
`<CR>` on **New backup** starts a backup of that database; `<CR>` on a file restores it
into the database it came from (after a confirmation), `d` deletes it, and `r` renames
it. A backup or restore is a detached job: the editor is never blocked, and a
notification reports when it starts and again when it finishes (or fails, with the log
to read). Passwords never reach a notification: the command is built from the
connection URL, which carries the credentials, and the displayed command is redacted.

```
▾ app
    ▸ Saved queries (0)
    ▸ Tables (128)
    ▾ Backups (1)
        20240101-120000
        + New backup
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

Files are named `<database>-<timestamp>.<ext>` under the destination; an existing file
is never overwritten (a `-1`, `-2`, … suffix is appended instead).

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
| `:DBManagerRefresh` | Drop the cached discoveries and redraw. Every server is queried again on its next expansion. |
| `:DBManagerRefresh <server>` | Same for one server, by connection name or key (tab-completed). A still-expanded server is re-queried immediately. |
| `:DBManagerInfo` | Print the effective configuration, whether the drawer is patched, and the discovery state (`not discovered yet`, the error, or `N database(s): …`) of every server. |

The usual drawer keymaps work unchanged: `o`/`<CR>` in a server node expands it and
runs the discovery, `R` on it re-queries the whole drawer.

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
  `add_db`, `toggle_db`, `populate` and `render` are wrapped on the live instance
  (the originals stay available as `dbui_multidb_orig_*`), and `add` and
  `get_toggle_icon` are left untouched. No vendored file is edited: they are byte
  for byte the files vim-dadbod-ui publishes (see [Vendored code](#vendored-code)).
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
  `dbui_multidb_children`, so a re-render (`BufEnter`, `o`, `R`) never touches the
  network again. The cache is dropped on `render({'dbs': 1})` — i.e. `R`, the
  refresh command, and vim-dadbod-ui's own "Refreshing all databases" — while a
  plain `render()` (moving between windows) leaves the tree and its expansion state
  intact. An expansion that follows a failed discovery retries, because a failure is
  usually a server that was not reachable a minute ago.
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
  [Vendored code](#vendored-code)). Connection URLs are never echoed — a URL
  carries the password.

## Vendored code

The drawer is not a dependency to install: vim-dadbod-ui's runtime is vendored in
this repository, byte for byte as upstream publishes it —
`autoload/db_ui.vim`, `autoload/db_ui/`, `plugin/db_ui.vim`, the `ftplugin/`
files, `syntax/dbui.vim` and `doc/dadbod-ui.txt`. No file among them is edited, so
re-syncing with a newer vim-dadbod-ui is a copy and not a merge — with one
difference, and it is generated rather than edited: the notification label.

Upstream's notification module hardcodes the label it paints on every message
(`let s:title = '[DBUI]'`), and Vim will not let another script redefine
`db_ui#notifications#*` (`E746`: a name containing `#` may only be defined by the
matching autoload file, so a wrapper cannot be installed from here). This plugin
therefore ships `notify-overlay/autoload/db_ui/notifications.vim`: a copy of that
module with the one line changed to `get(g:, 'db_ui_notification_title', '[DBUI]')`,
put first on the `runtimepath` by `plugin/dbui_multidb.vim` so that
`autoload/db_ui/notifications.vim` resolves to the overlay. Every notification is
labelled `[DBManager]` as a result — including the ones the vendored drawer
raises itself — while the vendored file keeps upstream's bytes:
`scripts/sync-upstream.sh` regenerates the overlay and stops if the difference
between the two is anything but that line.

- Upstream: <https://github.com/tpope/vim-dadbod-ui>
- Revision: `07e92e22114cc5b1ba4938d99897d85b58e20475` (`0-unstable-2026-02-11`)
- License: MIT, © 2020 Kristijan Husak — see `LICENSE.vim-dadbod-ui`

`UPSTREAM.md` carries the checksum of every vendored file, and
`scripts/sync-upstream.sh` re-copies them out of a vim-dadbod-ui checkout:

```sh
plugins/vim-dadbod-manager/scripts/sync-upstream.sh /path/to/vim-dadbod-ui
```

The script copies an explicit list of paths, so a file that appears upstream is
never picked up silently; it refuses to overwrite a file that was edited here (the
checksum no longer matches, `FORCE=1` overrides), regenerates
`scripts/vendored-files.sha256` and the help tags, and prints the diff to review.
Two consequences of owning those files: upgrading is manual (a vim-dadbod-ui
release no longer arrives with nixpkgs), and this plugin is self-contained, so
there is no sibling copy to install, keep in sync, or accidentally load twice.

Only the entry points are ours, and only in this plugin's own file: the
`:DBManager*` commands repeat the body of the upstream command they replace
instead of forwarding to it, because a command modifier is swallowed by a
forwarding alias. Upstream's `:DBUI*` entry points are deleted at the end of the
same file, after the vendored `plugin/db_ui.vim` has defined them.
Everything else keeps upstream's names, since they are load-bearing —
`autoload/db_ui/drawer.vim` is what makes `db_ui#drawer#get()` resolve.

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

## Tests

The plugin ships a headless test suite that runs the real drawer (the vendored one),
vim-dadbod, and two adapters in `test/fake_rtp`: `fakedb://` returns a canned
database list and records every call, while `fakebin://` runs a binary that does
not exist so that Neovim raises the genuine `E475` a missing client produces:

```sh
cd plugins/vim-dadbod-manager
./test/run.sh          # NVIM_BIN=/path/to/nvim to use a specific binary
```

The suite covers URL rebuilding per scheme (postgres/mysql/sqlserver/sqlite), the
server detection, the discovery cache and invalidation, the rendered tree (indent,
icons, sections, expansion state), the refresh command, a missing client (the raw
exception never reaches the drawer, the client is named in exactly one warning, a
second server still discovers its databases, re-expanding retries), the
notification fallbacks, the notification label (the module that loads is the
overlay, `[DBManager]` is the default and `g:db_ui_notification_title` overrides
it), and the entry points: every `:DBManager*` command exists,
every `:DBUI*` entry point is gone (`:DBUIHideNotifications` excepted, see above),
a command modifier reaches the drawer (a `:botright DBManager` stacks the windows
while a bare one splits vertically, which no forwarding alias can do), the drawer's
keys are still mapped, and the drawer Neovim loads is the vendored copy rather
than a package next to it. It prints `RESULT: ok (N checks, 0 failures)` and exits
non-zero on the first failure.

## License

MIT — see [LICENSE](LICENSE). The vendored vim-dadbod-ui sources keep their own
MIT license, © 2020 Kristijan Husak — see `LICENSE.vim-dadbod-ui`.
