" The per-database "Administrative" section of the drawer.
"
" Every database node gets one, below whatever vim-dadbod-ui drew for it
" (Schemas, Tables, saved queries): a level 1 toggle that expands to the
" administrative actions available for that connection, and today a single level
" 2 leaf, "Backup", whose <CR> starts a backup job (see dbui_multidb#backup).
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
let s:type = 'dbui_multidb_administrative'
let s:backup_type = 'dbui_multidb_backup'

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
" db_ui_icons.expanded.dbui_multidb_administrative wins, then a flat
" db_ui_icons.administrative, then the "tables" icon, which is the same mark
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

  for icon in [get(bucket, s:type, ''), get(icons, 'administrative', ''), get(bucket, 'tables', ''), get(icons, 'tables', '')]
    if type(icon) ==# type('') && !empty(icon)
      return icon
    endif
  endfor

  return ''
endfunction

" The icon of the "Backup" leaf. The leaf reads as a label either way, so an
" unset icon is a sane default and g:db_ui_icons.backup is enough to give it one.
function! dbui_multidb#administrative#backup_icon() abort
  let icons = get(g:, 'db_ui_icons', {})
  if type(icons) !=# type({})
    return ''
  endif
  let icon = get(icons, 'backup', '')
  return type(icon) ==# type('') ? icon : ''
endfunction

" Append the section to a database the drawer just drew. Called by the add_db
" patch, so a:db is the real entry from drawer.dbui.dbs and the returned state
" survives a re-render. Returns 1 when the section was added, 0 when
" g:dbui_multidb_backup_section turned it off, or the database is collapsed.
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

  call a:drawer.add('Administrative', 'toggle', s:type,
        \ dbui_multidb#administrative#icon(state.expanded),
        \ a:db.key_name, 1, {'expanded': state.expanded})
  if !state.expanded
    return 1
  endif

  call a:drawer.add('Backup', 'call_method', s:backup_type,
        \ dbui_multidb#administrative#backup_icon(), a:db.key_name, 2)
  return 1
endfunction

" <CR> on the "Backup" leaf, dispatched by the drawer to the instance method of
" the same name as the item type (see s:drawer.toggle_line()). The item under
" the cursor names the database, which is all the context the job needs.
function! dbui_multidb#administrative#backup() abort dict
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
