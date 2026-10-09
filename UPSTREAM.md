# Vendored: vim-dadbod-ui

vim-dadbod-manager patches vim-dadbod-ui's drawer, so it ships the drawer it
patches instead of requiring `tpope/vim-dadbod-ui` to be installed. The vendored
code is upstream's, unmodified (one generated file outside the tree is the only
difference — see [One deviation](#one-deviation)):

- upstream: <https://github.com/tpope/vim-dadbod-ui>
- revision: the first line of [`scripts/vendored-files.sha256`](scripts/vendored-files.sha256)
- license: MIT, © 2020 Kristijan Husak — [`LICENSE.vim-dadbod-ui`](LICENSE.vim-dadbod-ui)

Vendored: the runtime of the plugin — `autoload/db_ui.vim`, `autoload/db_ui/*.vim`,
`plugin/db_ui.vim`, `ftplugin/{dbui,dbout,sql,javascript,mysql,plsql}.vim`,
`syntax/dbui.vim`, `doc/dadbod-ui.txt`, and the license. Upstream's tests,
`.github/`, `README.md`, `.themisrc` and `run.sh` are not vendored.

Everything this plugin adds lives under `autoload/dbui_multidb/` and
`plugin/dbui_multidb.vim` — including the per-database Backups section
(`autoload/dbui_multidb/administrative.vim`, `autoload/dbui_multidb/backup.vim`).
None of it edits the vendored tree, so `scripts/vendored-files.sha256` stays valid
unchanged.

## Why these files and not fewer

`db_ui#drawer#get()` is `autoload/db_ui/drawer.vim`: in Vim the name of a function
*is* the path of the file that defines it, and the same holds for the `g:db_ui_*`
options, the `dbui`/`dbout` filetypes and the `:DBUI*` commands (referenced by help
tags and by user configs). Renaming them is a fork, not a rename — which is why the
internals stay `db_ui*` while the user-facing entry points are `:DBManager*` (and
upstream's `:DBUI*` entry points are deleted in `plugin/dbui_multidb.vim` once the
vendored `plugin/db_ui.vim` has defined them, so only one spelling is offered).
See the README's Commands section.

## One deviation, outside the tree

The vendored files are byte-identical to upstream. This plugin's one behavioural
difference — the notification label — is generated *from* them instead of written
into them: `notify-overlay/autoload/db_ui/notifications.vim` is a copy of the
vendored notification module with one line changed (`s:title` from `'[DBUI]'` to
`get(g:, 'db_ui_notification_title', '[DBUI]')`), put first on the `runtimepath`
so `autoload/db_ui/notifications.vim` resolves to it. It has to be a copy at the
same autoload path: Vim will not let any other script define
`db_ui#notifications#*` (`E746`). `scripts/sync-upstream.sh` regenerates the
overlay and fails unless that line is the only difference.

## Verify

```sh
cd plugins/vim-dadbod-manager
sha256sum -c scripts/vendored-files.sha256
diff autoload/db_ui/notifications.vim \
  notify-overlay/autoload/db_ui/notifications.vim | grep -c '^[<>]'   # 2
```

`doc/tags` is generated with `:helptags doc`, not vendored: it depends on the
editor that built it.

## Re-sync

```sh
nix build --no-link --print-out-paths 'nixpkgs#vimPlugins.vim-dadbod-ui'
./scripts/sync-upstream.sh \
  /nix/store/…-vimplugin-vim-dadbod-ui-<version> <version> <revision>
./test/run.sh
```

The file list lives in the script, so a file upstream adds is vendored on purpose
instead of appearing in the tree unnoticed. A destination file whose hash does not
match the manifest is refused rather than overwritten (`FORCE=1` overrides):
vendored files are never edited in place.

The script also regenerates the notification overlay from the freshly copied
notification module and refuses to continue unless the overlay differs by
exactly the label line, so a re-sync cannot leave a stale overlay behind.

Because the copy is pinned, a nixpkgs bump no longer changes the drawer on its own.
That is deliberate. This plugin wraps drawer methods (`add_db`, `toggle_db`,
`populate`, `render`) and checks them when the patch is applied, so an upstream
change surfaces as `vim-dadbod-manager: cannot patch the drawer …` at the moment a
drawer opens instead of as a broken tree.

## Do not install both

If `tpope/vim-dadbod-ui` is also on the runtimepath, whichever copy loads first
wins, and both define `:DBUI*` (the test suite pins that the drawer Neovim loads is
this copy, and that only `:DBManager*` is left as an entry point). The supported
configuration is this plugin alone.
