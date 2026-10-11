# vim-dadbod-manager-ui

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
scheme's own default database (see [Server detection](USAGE.md#server-detection)); a connection
pinned to a specific database, and any scheme that cannot list databases (a SQLite
file, a Redis URL), stays a plain connection and behaves exactly as before.

## Install

### lazy.nvim

```lua
{
	"sergioia-dev/vim-dadbod-manager-ui",
	dependencies = { "tpope/vim-dadbod" },
	-- `opts` is passed to vim.g / setup(); see [USAGE.md](USAGE.md).
	-- Server nodes are detected from the connection URL; set
	-- vim.g.dbui_multidb_masters = { "Banco Production" } to control them by hand.
}
```

### vim-plug

```vim
call plug#begin()
Plug 'tpope/vim-dadbod'
Plug 'sergioia-dev/vim-dadbod-manager-ui'
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
    repo = "vim-dadbod-manager-ui";
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

## Usage

The full guide — configuration, server detection, the **Administration** and
**Backups** sections, the `:DBManager*` commands and how the drawer behaves — lives
in [USAGE.md](USAGE.md).

Quick start: open the drawer with `:DBManager` and expand a connection. With
`g:dbui_multidb_masters` empty (the default), a connection whose adapter can list
databases — and whose URL names no specific database — becomes a server node;
expand it to list its databases and to see its per-database sections: **Backups**
everywhere, and an **Administration** section of users and roles — for `postgresql`, `mysql`, `mariadb`, `sqlserver`, `mongodb` and `redis` (see [USAGE.md](USAGE.md)).

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
automatic server detection, the Backups section (create, restore, delete, rename), the
Administration section (the provider gate, the lazy and cached category listing, the
per-provider catalogs and quoting, the read-only leaves, the confirmation that gates the destructive ones, and the query
buffer a leaf fills), the discovery cache and invalidation, the rendered tree (indent,
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
