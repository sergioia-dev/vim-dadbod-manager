" Build the dbui entry dict for a discovered database.
"
" The result has exactly the same shape as db_ui#dbui#generate_new_db_entry(),
" so that vim-dadbod-ui's own connect/populate code path works on it unchanged.
" The only additions are the is_child / master_* bookkeeping keys used by this
" plugin, and the :: separated key_name that cannot collide with a real
" connection key ("<name>_<source>").

function! dbui_multidb#entry#build(dbui, master, resolved_url, name) abort
  let name = a:name
  let master_name = a:master.name
  let master_key_name = a:master.key_name

  " Make sure the database directory exists.
  let save_path = a:dbui.save_path
  if !empty(save_path)
    let save_path = printf('%s/%s', save_path, substitute(name, '[\\/:*?"<>|]', '-', 'g'))
    if !isdirectory(save_path)
      call mkdir(save_path, 'p')
    endif
  endif

  " Inherit the buffers that already exist for this database name.
  let buffers = []
  for buffer in a:dbui.old_buffers
    if fnamemodify(buffer, ':t') =~? '^' . name . '[-_]'
      call add(buffers, buffer)
    endif
  endfor

  " Same keys and defaults as generate_new_db_entry(): upstream code touches
  " conn_tried, save_path, table_helpers, schema_support, quote, default_scheme
  " and filetype while connecting, populating and rendering.
  let entry = {
        \ 'url': dbui_multidb#url#with_database(a:resolved_url, name),
        \ 'conn': '',
        \ 'conn_error': '',
        \ 'conn_tried': 0,
        \ 'source': 'master',
        \ 'scheme': '',
        \ 'table_helpers': {},
        \ 'expanded': 0,
        \ 'tables': {'expanded': 0, 'items': {}, 'list': []},
        \ 'schemas': {'expanded': 0, 'items': {}, 'list': []},
        \ 'saved_queries': {'expanded': 0, 'list': []},
        \ 'buffers': {'expanded': 0, 'list': buffers, 'tmp': []},
        \ 'save_path': save_path,
        \ 'db_name': name,
        \ 'name': name,
        \ 'key_name': printf('%s::%s', master_key_name, name),
        \ 'schema_support': 0,
        \ 'quote': 0,
        \ 'default_scheme': '',
        \ 'filetype': '',
        \ 'is_child': 1,
        \ 'master_name': master_name,
        \ 'master_key_name': master_key_name,
        \ }

  call a:dbui.populate_schema_info(entry)

  return entry
endfunction
