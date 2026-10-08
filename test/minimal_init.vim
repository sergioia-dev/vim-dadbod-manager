" Minimal init for the vim-dadbod-manager test suite.
"
" Only this plugin and the fake adapter runtime are prepended to 'runtimepath'
" together with vim-dadbod, which is installed as a package next to nvim
" (pack/*/start/*); the drawer itself is vendored in this plugin, so it comes
" from 'runtimepath' above. Starting nvim with an explicit -u skips the
" automatic plugin load, so vim-dadbod is added by hand if needed.

set nocompatible
set loadplugins
set shortmess+=aoOtTIcF
set shiftwidth=2
set noswapfile

let s:init = empty($MYVIMRC) ? expand('<sfile>:p') : $MYVIMRC
let s:test_dir = fnamemodify(s:init, ':h')
execute 'set runtimepath^=' . fnameescape(fnamemodify(s:test_dir, ':h'))
execute 'set runtimepath^=' . fnameescape(s:test_dir . '/fake_rtp')

for s:name in ['vim-dadbod']
  for s:dir in globpath(&packpath . ',' . &runtimepath, 'pack/*/start/' . s:name, 0, 1)
    if index(split(&runtimepath, ','), s:dir) < 0
      execute 'set runtimepath^=' . fnameescape(s:dir)
    endif
  endfor
endfor

filetype plugin indent on

" Deterministic, headless friendly drawer behaviour.
let g:db_ui_show_help = 0
let g:db_ui_disable_info_notifications = 1
let g:db_ui_force_echo_notifications = 1
let g:db_ui_use_nvim_notify = 0
let g:db_ui_save_location = tempname()
let g:db_ui_tmp_query_location = tempname()
call mkdir(g:db_ui_save_location, 'p')
call mkdir(g:db_ui_tmp_query_location, 'p')

" Set by the test suite before each discovery.
let g:dbui_multidb_test_dbs = []
let g:dbui_multidb_test_tables = []
let g:dbui_multidb_test_calls = []

" The client binary the fakebin:// adapter runs: it does not exist, so Neovim
" raises the same E475 that a missing sqlcmd/psql/mariadb produces.
let g:dbui_multidb_test_binary = 'vim-dadbod-manager-no-such-binary'
