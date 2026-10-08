" User-facing notifications for vim-dadbod-manager.
"
" Notifications are a side effect, never control flow: a notifier that throws
" (nvim-notify not installed, noecho, a redraw in a weird state) must not abort a
" render, kill a discovery or leave the drawer half patched. Every message goes
" through these wrappers, which degrade to :echomsg.

function! s:notify(kind, message, ...) abort
  try
    return call('db_ui#notifications#' . a:kind, [a:message] + a:000)
  catch /.*/
    echomsg a:message
    return 0
  endtry
endfunction

function! dbui_multidb#notify#error(message) abort
  return s:notify('error', a:message)
endfunction

function! dbui_multidb#notify#warning(message) abort
  return s:notify('warning', a:message)
endfunction

function! dbui_multidb#notify#info(message, ...) abort
  return call('s:notify', ['info', a:message] + a:000)
endfunction
