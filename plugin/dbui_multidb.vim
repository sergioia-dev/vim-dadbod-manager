if exists('g:loaded_dbui_multidb')
  finish
endif
let g:loaded_dbui_multidb = 1

if !exists('g:dbui_multidb_masters')
  let g:dbui_multidb_masters = []
endif

" Re-query the databases behind the server nodes: with no argument every
" configured server is refreshed, otherwise only the named one, and
" ":DBManagerInfo" prints the effective configuration plus the discovery state of
" every server.
"
" The drawer commands. The drawer is vendored from vim-dadbod-ui, where
" "db_ui#…" is load-bearing (a function name is a path to a file), so they call
" those functions directly. Their bodies repeat vim-dadbod-ui's own commands
" rather than calling ":DBUI", because a command modifier (":botright DBManager")
" is only expanded by <mods> in the command that actually runs.
" vim-dadbod-ui's ":DBUI*" spellings are removed at the end of this file: this
" plugin is the only way in.
command! DBManager call db_ui#open('<mods>')
command! DBManagerToggle call db_ui#toggle()
command! DBManagerClose call db_ui#close()
command! DBManagerAddConnection call db_ui#connections#add()
command! DBManagerFindBuffer call db_ui#find_buffer()
command! DBManagerRenameBuffer call db_ui#rename_buffer()
command! DBManagerLastQueryInfo call db_ui#print_last_query_info()
command! -nargs=? -complete=customlist,dbui_multidb#complete_masters DBManagerRefresh call dbui_multidb#refresh(<f-args>)
command! DBManagerInfo call dbui_multidb#info()

augroup dbui_multidb
  autocmd!
  " The drawer instance is recreated by db_ui#open(), so the patch has to be
  " installed again on every drawer buffer. db_ui#drawer#open() sets the
  " filetype before its first render, and fires User DBUIOpened as a backstop.
  autocmd FileType dbui call dbui_multidb#patch#apply()
  autocmd User DBUIOpened call dbui_multidb#patch#apply()
augroup END

" vim-dadbod-ui's own entry points are hidden. Vim has no notion of a hidden
" command — a command that exists is listed by ":command" and offered by
" completion — so hiding them means not having them. The vendored
" "plugin/db_ui.vim" is sourced before this file (Neovim sorts the files of one
" plugin directory), which is why they can be deleted here, and they are only
" names: nothing in the vendored code calls them, and the functions behind them
" are called directly above. The existence check makes the deletion a no-op if a
" future vim-dadbod-ui renames them instead of aborting this file; the test suite
" pins the result.
" ":DBUIHideNotifications" is deliberately left alone: it is not an entry point, the
" vendored notification module defines it itself when it first draws a notification,
" and it is the only way to dismiss that window. See the README.
for s:cmd in ['DBUI', 'DBUIToggle', 'DBUIClose', 'DBUIAddConnection',
      \ 'DBUIFindBuffer', 'DBUIRenameBuffer', 'DBUILastQueryInfo']
  if exists(':' . s:cmd) == 2
    execute 'delcommand ' . s:cmd
  endif
endfor
unlet! s:cmd

" Upstream's notification module hardcodes the label it paints on every message
" ("[DBUI]"). Vim refuses to let another file redefine db_ui#notifications#*
" (E746: a name containing '#' may only be defined by the matching autoload
" file), so the relabelled module ships next to it and goes first on the
" runtimepath: "autoload/db_ui/notifications.vim" then resolves to the overlay
" copy, which reads the label from g:db_ui_notification_title instead. The
" vendored copy stays byte-identical to upstream — the overlay is generated from
" it by scripts/sync-upstream.sh, which refuses any difference but that one line.
" See the README.
let g:db_ui_notification_title = get(g:, 'db_ui_notification_title', '[DBManager]')
execute 'set runtimepath^=' . fnameescape(expand('<sfile>:p:h:h') . '/notify-overlay')
