" Schema viewer for vim-dadbod-manager.
"
" sqlv (the sql-mer-tui package) draws a database's entity-relationship diagram
" in a terminal. This module adds a "Schema viewer" leaf as the first child of a
" database's Schemas section -- or of its Tables section for a database without
" schema support, such as sqlite or a single-database mysql -- and opens sqlv for
" that database in a centered floating terminal when the leaf is pressed.
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

  call s:open(argv)
  return 1
endfunction

" Open argv in a centered floating terminal. In Neovim a rounded float holds a
" termopen() buffer and a buffer-local TermClose autocmd returns to the drawer
" once the command exits. In Vim the terminal goes into a popup; 'term_finish'
" closes it with the job.
function! s:open(argv) abort
  let columns = &columns
  let lines = &lines
  let width = max([20, columns * 9 / 10])
  let height = max([5, lines * 8 / 10])

  if has('nvim')
    let buf = nvim_create_buf(v:false, v:true)
    let win = nvim_open_win(buf, v:true, {
          \ 'relative': 'editor',
          \ 'row': (lines - height) / 2,
          \ 'col': (columns - width) / 2,
          \ 'width': width,
          \ 'height': height,
          \ 'border': 'rounded',
          \ 'style': 'minimal',
          \ })
    call termopen(a:argv)
    call nvim_create_autocmd('TermClose', {
          \ 'buffer': buf,
          \ 'once': v:true,
          \ 'callback': { -> s:nvim_close(win, buf) },
          \ })
    startinsert
    return
  endif

  if exists('*term_start') && exists('*popup_create')
    let buf = term_start(a:argv, {'curwin': v:true, 'hidden': v:true, 'term_finish': 'close'})
    call popup_create(buf, {
          \ 'line': (lines - height) / 2,
          \ 'col': (columns - width) / 2,
          \ 'minwidth': width,
          \ 'minheight': height,
          \ 'mapping': 0,
          \ 'border': [],
          \ 'padding': [],
          \ })
    return
  endif

  call dbui_multidb#notify#error('vim-dadbod-manager: the schema viewer needs Neovim or a Vim with terminal support.')
endfunction

" TermClose callback: close the float and drop the terminal buffer.
function! s:nvim_close(win, buf) abort
  if nvim_win_is_valid(a:win)
    call nvim_win_close(a:win, v:true)
  endif
  if bufexists(a:buf)
    execute 'silent! bwipeout!' a:buf
  endif
endfunction
