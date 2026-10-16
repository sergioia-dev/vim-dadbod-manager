" Schema viewer for vim-dadbod-manager.
"
" sqlv (the sql-mer-tui package) draws a database's entity-relationship diagram
" in a terminal. This module adds a "Schema viewer" leaf as the first child of a
" database's Schemas section -- or of its Tables section for a database without
" schema support, such as sqlite or a single-database mysql -- and opens sqlv for
" that database in the window a query buffer would use when the leaf is pressed.
"
" sqlv is an optional dependency. The leaf is added either way; <CR> reports an
" error instead of opening an empty window when the command is not installed.
"
" The connection URL is handed to the command as a list element of
" termopen()/term_start(), never through a shell, so a password inside the URL is
" not parsed, expanded or echoed by anything.

let s:type = 'dbui_multidb_schema_viewer'

" The icon for the Schema viewer leaf. g:db_ui_icons.schema_viewer wins, then
" the Tables icon, then the New query icon. get_toggle_icon() is deliberately
" not used: it looks the type up in g:db_ui_icons.expanded/collapsed, where a
" Funcref may live (E716), and this item is a leaf, not a toggle.
function! dbui_multidb#schema_viewer#icon() abort
  let icons = get(g:, 'db_ui_icons', {})
  if type(icons) !=# type({})
    return ''
  endif
  for name in ['schema_viewer', 'tables', 'new_query']
    let icon = get(icons, name, '')
    if type(icon) ==# type('') && !empty(icon)
      return icon
    endif
  endfor
  return ''
endfunction

" The command line for a database: [command, url]. The command comes from
" g:dbui_multidb_schema_viewer_command; the url is db.url resolved through
" vim-dadbod, with the raw value as a fallback, so environment variables in a
" connection string are honoured.
function! dbui_multidb#schema_viewer#argv(db) abort
  let command = get(dbui_multidb#config#get(), 'schema_viewer_command', 'sqlv')
  if type(command) !=# type('') || empty(command)
    let command = 'sqlv'
  endif

  let url = ''
  if type(a:db) ==# type({})
    let raw = get(a:db, 'url', '')
    if type(raw) ==# type('')
      let url = dbui_multidb#url#resolve(raw)
      if empty(url)
        let url = raw
      endif
    endif
  endif

  return [command, url]
endfunction

" Append the Schema viewer leaf when the database is expanded and its Schemas
" (or Tables) section is expanded. It is inserted as the first child of that
" section, directly under the toggle and above the schema/table list. Returns 1
" when the leaf was added.
function! dbui_multidb#schema_viewer#append(drawer, db) abort
  if empty(get(dbui_multidb#config#get(), 'schema_viewer_section', 1))
    return 0
  endif
  if !get(a:db, 'expanded', 0)
    return 0
  endif

  " schema_support decides which section the database renders: databases with
  " schemas draw a "Schemas" section, the others draw a "Tables" section.
  let parent_type = get(a:db, 'schema_support', 0) ? 'schemas' : 'tables'
  let index = -1
  let i = 0
  while i < len(a:drawer.content)
    let item = a:drawer.content[i]
    " The exact match keeps "schemas->items->name" and "tables->items->name"
    " (the schema and table toggles) out of the search.
    if get(item, 'type', '') ==# parent_type && get(item, 'dbui_db_key_name', '') ==# a:db.key_name
      let index = i
      break
    endif
    let i += 1
  endwhile

  if index < 0 || !get(a:drawer.content[index], 'expanded', 0)
    return 0
  endif

  call insert(a:drawer.content, {
        \ 'label': 'Schema viewer',
        \ 'action': 'call_method',
        \ 'type': s:type,
        \ 'icon': dbui_multidb#schema_viewer#icon(),
        \ 'dbui_db_key_name': a:db.key_name,
        \ 'level': 2,
        \ }, index + 1)
  return 1
endfunction

" <CR> on the Schema viewer leaf. The leaf's type is the method name, so
" vim-dadbod-ui's call_method dispatch reaches this function with the drawer as
" self. Returns 1 when a terminal was opened.
function! dbui_multidb#schema_viewer#open() abort dict
  let item = self.get_current_item()
  if type(item) !=# type({}) || get(item, 'type', '') !=# s:type
    return 0
  endif

  let db = get(self.dbui.dbs, get(item, 'dbui_db_key_name', ''), {})
  if type(db) !=# type({}) || empty(db)
    return 0
  endif

  let argv = dbui_multidb#schema_viewer#argv(db)
  if !executable(argv[0])
    call dbui_multidb#notify#error(printf(
          \ 'vim-dadbod-manager: %s is not installed (the schema viewer needs the sql-mer-tui package).',
          \ argv[0]))
    return 0
  endif

  call s:open(argv, self)
  return 1
endfunction

" Move to the window that a query buffer would open in -- db_ui/query.vim's
" focus_window() -- so the viewer uses the same window as "New query" instead
" of adding a split of its own. Returns 1 when a split had to be created because
" no query or editable window was available.
function! s:focus_query_window(drawer) abort
  if type(get(a:drawer, 'get_query', 0)) !=# v:t_func
    belowright new
    return 1
  endif

  let win = win_getid()
  let windows = winnr('$')
  call a:drawer.get_query().focus_window()
  return winnr('$') > windows && win_getid() !=# win ? 1 : 0
endfunction

" Open argv in the window a query buffer would use, so the viewer behaves like
" the buffer that "New query" opens rather than a terminal split of its own: a
" terminal buffer fills that window and a buffer-local TermClose autocmd drops
" the buffer once the command exits, closing the window as well when the viewer
" had to create it. In Vim 'term_finish': 'close' gives the same behaviour: the
" terminal window closes itself when the job finishes.
function! s:open(argv, drawer) abort
  if has('nvim')
    " The drawer is the current window until s:focus_query_window() moves
    " focus away, so record it and the cursor line now: quitting the viewer
    " should return the user to the leaf they left, not to the query window
    " the viewer took over.
    let drawer_win = win_getid()
    let drawer_line = line('.')
    let own_split = s:focus_query_window(a:drawer)
    let win = win_getid()
    " Remember the buffer to put back when the terminal goes away.
    let prev = winbufnr(win)
    let buf = nvim_create_buf(v:false, v:true)
    call nvim_win_set_buf(win, buf)
    let b:dbui_multidb_schema_viewer_win = win
    let b:dbui_multidb_schema_viewer_split = own_split
    let b:dbui_multidb_schema_viewer_prev = prev
    " Where the drawer was when the viewer opened, so focus and the cursor can
    " go back to that leaf when the command exits.
    let b:dbui_multidb_schema_viewer_drawer_win = drawer_win
    let b:dbui_multidb_schema_viewer_drawer_line = drawer_line
    call termopen(a:argv)
    " A buffer-local autocmd so the terminal buffer disappears as soon as the
    " command exits; it dies with the buffer. The buffer number is passed in from
    " <abuf> because a buffer-local autocmd cannot carry a closure here:
    " nvim_create_autocmd() rejects a Funcref or lambda callback with E5555
    " ("Invalid 'callback': expected Lua function or Vim function name, got nil")
    " on Neovim 0.12.
    autocmd TermClose <buffer> ++once call dbui_multidb#schema_viewer#term_close(str2nr(expand('<abuf>')))
    startinsert
    return
  endif

  if exists('*term_start')
    call term_start(a:argv, {'term_finish': 'close'})
    return
  endif

  call dbui_multidb#notify#error('vim-dadbod-manager: the schema viewer needs Neovim or a Vim with terminal support.')
endfunction

" TermClose callback: drop the viewer's terminal buffer, so quitting the command
" (or the command failing) leaves the drawer as it was. The window goes away only
" when the viewer created it; otherwise the buffer the window showed before the
" viewer took it over comes back, so a query window is never lost. The buffer
" comes from the autocmd (see s:open), and the window facts travel in buffer-local
" variables because a buffer-local autocmd cannot capture them. Finally focus and
" the cursor go back to the drawer leaf the viewer was opened from.
function! dbui_multidb#schema_viewer#term_close(...) abort
  let buf = a:0 > 0 ? a:1 : 0
  if buf <= 0 || !bufexists(buf)
    let buf = bufnr('%')
  endif
  let win = getbufvar(buf, 'dbui_multidb_schema_viewer_win', 0)
  let own_split = getbufvar(buf, 'dbui_multidb_schema_viewer_split', 0)
  let prev = getbufvar(buf, 'dbui_multidb_schema_viewer_prev', 0)
  let drawer_win = getbufvar(buf, 'dbui_multidb_schema_viewer_drawer_win', 0)
  let drawer_line = getbufvar(buf, 'dbui_multidb_schema_viewer_drawer_line', 0)
  if has('nvim') && win > 0 && nvim_win_is_valid(win)
    if own_split
      call nvim_win_close(win, v:true)
    elseif prev > 0 && nvim_buf_is_valid(prev)
      call nvim_win_set_buf(win, prev)
    endif
  endif
  if bufexists(buf)
    execute 'silent! bwipeout!' buf
  endif
  " Return to the drawer leaf the viewer was opened from. This comes after the
  " close/restore above: closing the viewer window moves focus around, and the
  " drawer should be the window that ends up focused.
  if has('nvim') && drawer_win > 0 && nvim_win_is_valid(drawer_win)
    call win_gotoid(drawer_win)
    if drawer_line > 0
      call cursor(drawer_line, 1)
    endif
  endif
endfunction
