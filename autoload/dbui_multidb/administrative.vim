" The per-database "Backups" section of the drawer.
"
" Every expanded database backed up client-side gets one, below whatever
" vim-dadbod-ui drew for it (Schemas, Tables, saved queries): a level 1 toggle
" that expands into the backup files of that connection (newest first) and a
" final "New backup" leaf whose <CR> starts a job (see dbui_multidb#backup).
"
" Server-side schemes write on the database host, where this editor can neither
" list, restore nor delete anything, so they get no section at all.
"
" Two upstream behaviours carry the section:
"
"   * s:drawer.toggle_line() flips ".expanded" on the dict it finds under the
"     item type on the database entry, so the state has to live in a dict on the
"     entry named exactly like the item type. It also means the section needs no
"     patch of its own: the entry dict lives in drawer.dbui.dbs across renders.
"   * s:drawer.add() takes the level, so the section nests under a database that
"     was already drawn at level 1 (a discovered child of a server node).
"
" The state is seeded even when the section is hidden: a missing key would make
" the toggle a silent no-op instead of an error.
let s:type = 'dbui_multidb_backups'
let s:new_type = 'dbui_multidb_new_backup'
let s:file_type = 'dbui_multidb_backup_file'

" The state of one database's section, seeded on the entry if it is not there.
function! dbui_multidb#administrative#state(db) abort
  if !has_key(a:db, s:type) || type(a:db[s:type]) !=# type({})
    let a:db[s:type] = {'expanded': 0}
  endif
  return a:db[s:type]
endfunction

" The toggle icon.
"
" Icons are read out of g:db_ui_icons rather than through the drawer's
" get_toggle_icon(): that one indexes the icon tables by item type and throws
" E716 for a type vim-dadbod-ui does not know about. A theme that defines
" db_ui_icons.expanded.dbui_multidb_backups wins, then a flat
" db_ui_icons.backups, then the "tables" icon, which is the same mark
" vim-dadbod-ui puts on the section a database's contents hang off.
function! dbui_multidb#administrative#icon(expanded) abort
  let icons = get(g:, 'db_ui_icons', {})
  if type(icons) !=# type({})
    return ''
  endif

  let bucket = get(icons, a:expanded ? 'expanded' : 'collapsed', {})
  if type(bucket) !=# type({})
    let bucket = {}
  endif

  for icon in [get(bucket, s:type, ''), get(icons, 'backups', ''), get(bucket, 'tables', ''), get(icons, 'tables', '')]
    if type(icon) ==# type('') && !empty(icon)
      return icon
    endif
  endfor

  return ''
endfunction

" The icon of the "New backup" leaf: the same mark as vim-dadbod-ui's own "New
" query" action, so the section reads as one more thing a connection offers.
function! dbui_multidb#administrative#new_icon() abort
  let icons = get(g:, 'db_ui_icons', {})
  if type(icons) !=# type({})
    return ''
  endif
  let icon = get(icons, 'new_query', '')
  return type(icon) ==# type('') ? icon : ''
endfunction

" The backup file entry under the cursor, or an empty dict when the cursor is
" somewhere else. The delete_line/rename_line patches use it to know whether the
" line is theirs.
function! dbui_multidb#administrative#backup_item(drawer) abort
  let item = a:drawer.get_current_item()
  if type(item) !=# type({}) || get(item, 'type', '') !=# s:file_type
    return {}
  endif
  return item
endfunction

" Append the section to a database the drawer just drew. Called by the add_db
" patch, so a:db is the real entry from drawer.dbui.dbs and the returned state
" survives a re-render. Returns 1 when the section was added, 0 when the
" configuration or the scheme turns it off, or the database is collapsed.
function! dbui_multidb#administrative#append(drawer, db) abort
  let state = dbui_multidb#administrative#state(a:db)
  if empty(get(dbui_multidb#config#get(), 'backup_section', 1))
    return 0
  endif
  " The section belongs to an expanded database only: a collapsed node keeps
  " the exact shape vim-dadbod-ui draws for it.
  if !get(a:db, 'expanded', 0)
    return 0
  endif
  " Server-side schemes write on the database host; there is nothing to list.
  if !dbui_multidb#backup#is_local(a:db)
    return 0
  endif

  let entries = dbui_multidb#backup#list(a:db)
  call a:drawer.add(printf('Backups (%d)', len(entries)), 'toggle', s:type,
        \ dbui_multidb#administrative#icon(state.expanded),
        \ a:db.key_name, 1, {'expanded': state.expanded})
  if !state.expanded
    return 1
  endif

  call a:drawer.add('New backup', 'call_method', s:new_type,
        \ dbui_multidb#administrative#new_icon(), a:db.key_name, 2)
  for entry in entries
    call a:drawer.add(entry.label, 'call_method', s:file_type, '',
          \ a:db.key_name, 2, {
          \   'dbui_backup_file': entry.path,
          \   'dbui_backup_prefix': entry.prefix,
          \   'dbui_backup_label': entry.label})
  endfor
  return 1
endfunction

" <CR> on the "New backup" leaf, dispatched by the drawer to the instance method
" of the same name as the item type (see s:drawer.toggle_line()). The item under
" the cursor names the database, which is all the context the job needs.
function! dbui_multidb#administrative#new_backup() abort dict
  let item = self.get_current_item()
  if type(item) !=# type({})
    return 0
  endif

  let db = get(self.dbui.dbs, get(item, 'dbui_db_key_name', ''), {})
  if type(db) !=# type({}) || empty(db)
    call dbui_multidb#notify#error('vim-dadbod-manager: no database to back up here.')
    return 0
  endif

  return dbui_multidb#backup#start(db)
endfunction

" <CR> on a backup file entry: restore it into the database it came from.
function! dbui_multidb#administrative#backup_file() abort dict
  let item = dbui_multidb#administrative#backup_item(self)
  if empty(item)
    return 0
  endif

  let db = get(self.dbui.dbs, get(item, 'dbui_db_key_name', ''), {})
  if type(db) !=# type({}) || empty(db)
    call dbui_multidb#notify#error('vim-dadbod-manager: no database to restore into here.')
    return 0
  endif

  return dbui_multidb#backup#restore(db, get(item, 'dbui_backup_file', ''))
endfunction

" d on a backup file entry: delete the file (and the log next to it) after a
" confirmation.
function! dbui_multidb#administrative#delete_file(drawer, item) abort
  let db = get(a:drawer.dbui.dbs, get(a:item, 'dbui_db_key_name', ''), {})
  if type(db) !=# type({}) || empty(db)
    call dbui_multidb#notify#error('vim-dadbod-manager: no database for this backup file.')
    return 0
  endif
  if !dbui_multidb#backup#delete_file(db, get(a:item, 'dbui_backup_file', ''))
    return 0
  endif
  call a:drawer.render()
  return 1
endfunction

" r on a backup file entry: rename the file, keeping its prefix and extension.
function! dbui_multidb#administrative#rename_file(drawer, item) abort
  let db = get(a:drawer.dbui.dbs, get(a:item, 'dbui_db_key_name', ''), {})
  if type(db) !=# type({}) || empty(db)
    call dbui_multidb#notify#error('vim-dadbod-manager: no database for this backup file.')
    return 0
  endif

  let label = get(a:item, 'dbui_backup_label', '')
  try
    let new_label = db_ui#utils#input('Backup name: ', label)
  catch /.*/
    call dbui_multidb#notify#error(v:exception)
    return 0
  endtry
  if empty(new_label) || new_label ==# label
    return 0
  endif

  if !dbui_multidb#backup#rename_file(get(a:item, 'dbui_backup_file', ''), new_label, get(a:item, 'dbui_backup_prefix', ''))
    return 0
  endif
  call a:drawer.render()
  return 1
endfunction
