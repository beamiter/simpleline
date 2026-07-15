set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h:h')
execute 'set runtimepath^=' . fnameescape(s:root)

let g:simpleline_auto_enable = {}
let g:simpleline_enable_default_mappings = []
let g:simpleline_git_enabled = {}
let g:simpleline_separator = {}
let g:simpleline_nerdfont = 'invalid'
let g:simpleline_compact_width = []
let g:simpleline_show_position = {}
let g:simpleline_filetype_icons = []
let g:simpleline_git_interval = {}
let g:simpletabline_item_sep = []
let g:simpletabline_key_sep = {}
let g:simpletabline_newbuf_side = {}
let g:simpletabline_path_mode = 1
let g:simpletabline_pick_chars = []
let g:simpletabline_cyan_gui = []
let g:simpletabline_cyan_cterm = {}

runtime plugin/simpleline.vim
call assert_equal(1, g:simpleline_auto_enable)
call assert_equal(1, g:simpleline_enable_default_mappings)
call assert_equal(1, g:simpleline_git_enabled)

" Keep this smoke test independent of an installed daemon, then exercise the
" actual VimEnter/Toggle/Reload/Stop lifecycle with the normalized settings.
let g:simpleline_git_enabled = 0
doautocmd VimEnter
call assert_true(simpleline#IsEnabled())
enew!
silent file config_type_smoke.txt
call assert_notequal('', simpleline#ActiveStatusline())
call assert_notequal('', simpleline#Tabline())
call simpleline#Toggle()
call assert_false(simpleline#IsEnabled())
call simpleline#Toggle()
call simpleline#Reload()
call assert_true(simpleline#IsEnabled())
call simpleline#Stop()
call simpleline#Stop()
call assert_false(simpleline#IsEnabled())

if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit 1
endif
qa!
