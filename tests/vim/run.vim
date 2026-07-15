set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h:h')
execute 'set runtimepath^=' . fnameescape(s:root)

let mapleader = ','
nnoremap <leader>bp :let g:simpleline_user_mapping_ran = 1<CR>
let s:user_bp = maparg('<leader>bp', 'n', 0, 1)

let g:simpleline_auto_enable = 0
let g:simpleline_git_enabled = 0
let g:simpleline_enable_default_mappings = 1
let g:simpleline_nerdfont = 0
runtime plugin/simpleline.vim

call assert_equal(2, exists(':SimpleLine'))
call assert_equal(2, exists(':SimpleLineToggle'))
call assert_equal(2, exists(':SimpleLineHealth'))
call assert_equal(2, exists(':BufferPick'))
call assert_equal(s:user_bp, maparg('<leader>bp', 'n', 0, 1))
call assert_notequal('', maparg('<Plug>(simpleline-buffer-pick)', 'n'))

function! s:WindowStatusline(winid) abort
  let tabwin = win_id2tabwin(a:winid)
  return gettabwinvar(tabwin[0], tabwin[1], '&statusline')
endfunction

function! s:WindowLocalStatusline(winid) abort
  let tabwin = win_id2tabwin(a:winid)
  return gettabwinvar(tabwin[0], tabwin[1], '&l:statusline')
endfunction

" Enable/Disable restores global UI state and every window-local statusline.
silent! only
enew!
let &g:statusline = 'ORIGINAL-GLOBAL'
let &g:tabline = 'ORIGINAL-TABLINE'
set showtabline=1
set laststatus=1
let &l:statusline = 'LOCAL-ONE'
let s:win_one = win_getid()
new
let &l:statusline = 'LOCAL-TWO'
let s:win_two = win_getid()

call simpleline#Enable()
call assert_true(simpleline#IsEnabled())
call assert_match('simpleline#InactiveStatusline', s:WindowStatusline(s:win_one))
call assert_match('simpleline#ActiveStatusline', s:WindowStatusline(s:win_two))
call assert_equal(2, &laststatus)
call simpleline#Enable()
call simpleline#Disable()
call assert_false(simpleline#IsEnabled())
call assert_equal('LOCAL-ONE', s:WindowStatusline(s:win_one))
call assert_equal('LOCAL-TWO', s:WindowStatusline(s:win_two))
call assert_equal('ORIGINAL-GLOBAL', &g:statusline)
call assert_equal('ORIGINAL-TABLINE', &g:tabline)
call assert_equal(1, &showtabline)
call assert_equal(1, &laststatus)
silent! only

" A disabled tabline is never treated as an option owned by Simpleline.
let g:simpleline_tabline = 0
set showtabline=1
call simpleline#Enable()
set showtabline=2
call simpleline#Disable()
call assert_equal(2, &showtabline)
let g:simpleline_tabline = 1

" Empty local options retain inheritance, including windows opened while on.
let &g:statusline = 'INHERITED-GLOBAL'
let &l:statusline = ''
let s:inherited_one = win_getid()
call simpleline#Enable()
new
let s:inherited_two = win_getid()
tabnew
let s:inherited_three = win_getid()
call simpleline#Disable()
call assert_equal('', s:WindowLocalStatusline(s:inherited_one))
call assert_equal('', s:WindowLocalStatusline(s:inherited_two))
call assert_equal('', s:WindowLocalStatusline(s:inherited_three))
call assert_equal('INHERITED-GLOBAL', &g:statusline)
tabclose!
silent! only

" Dynamic provider text and buffer names are escaped as literal text.
enew!
let s:evil_buf = bufnr()
let s:evil_name = 'evil%{setbufvar(' . s:evil_buf . ',''simpleline_injected'',42)}'
execute 'silent file ' . fnameescape(s:evil_name)
let g:simplecc_status = 'busy%{setbufvar(' . s:evil_buf . ',"simpleline_lsp_injected",42)}'
call simpleline#Enable()
let s:tabline = simpleline#Tabline()
let s:statusline = simpleline#ActiveStatusline()
call assert_match('evil%%{setbufvar', s:tabline)
call assert_match('busy%%{setbufvar', s:statusline)
redrawtabline
redrawstatus
call assert_equal(0, getbufvar(s:evil_buf, 'simpleline_injected', 0))
call assert_equal(0, getbufvar(s:evil_buf, 'simpleline_lsp_injected', 0))
let s:control_buf = bufadd("control\nname")
call setbufvar(s:control_buf, '&buflisted', 1)
let s:control_tabline = simpleline#Tabline()
call assert_equal(-1, stridx(s:control_tabline, "\n"))
call assert_match('control\^@name', s:control_tabline)
unlet g:simplecc_status

" Picker consumes one raw key and never creates, replaces, or removes mappings.
nnoremap a :let g:simpleline_a_mapping_ran = 1<CR>
let s:a_mapping = maparg('a', 'n', 0, 1)
call feedkeys("\<Esc>", 't')
call simpleline#BufferPick()
call assert_equal(s:a_mapping, maparg('a', 'n', 0, 1))

" A long current item remains visible, and widening expands hidden buffers.
let g:simpletabline_path_mode = 'tail'
enew!
silent file sl_alpha_long_filename.txt
badd sl_beta_long_filename.txt
badd sl_gamma_current_filename.txt
buffer sl_gamma_current_filename.txt
let s:old_columns = &columns
set columns=20
let s:narrow = simpleline#Tabline()
call assert_match('sl_gamma_current_filename.txt', s:narrow)
set columns=12
call assert_match('sl_gamma_current_filename.txt', simpleline#Tabline())
set columns=200
let s:wide = simpleline#Tabline()
call assert_match('sl_alpha_long_filename.txt', s:wide)
call assert_match('sl_beta_long_filename.txt', s:wide)
call assert_match('sl_gamma_current_filename.txt', s:wide)

let g:simpletabline_show_indexes = 0
call assert_notmatch('SimpleTablineIndex', simpleline#Tabline())
let g:simpletabline_show_indexes = 1

" Separator styles are real glyphs, with an automatic non-Nerd-Font fallback.
let g:simpleline_nerdfont = 1
let g:simpleline_separator = 'round'
call simpleline#Reload()
call assert_match('', simpleline#ActiveStatusline())
let g:simpleline_separator = 'arrow'
call simpleline#Reload()
call assert_match('', simpleline#ActiveStatusline())

" Compact statuslines hide metadata but retain the position segment.
let g:simpleline_compact_width = winwidth(0) + 1
call assert_notmatch('&fileencoding', simpleline#ActiveStatusline())
let g:simpleline_compact_width = max([1, winwidth(0) - 1])
call assert_match('&fileencoding', simpleline#ActiveStatusline())
call assert_match('%l:%c', simpleline#ActiveStatusline())
let g:simpleline_show_position = 0
call assert_notmatch('%l:%c', simpleline#InactiveStatusline())
let g:simpleline_show_position = 1
let &columns = s:old_columns

" User changes made while enabled are not overwritten during teardown.
let &g:tabline = 'USER-CHANGED-WHILE-ENABLED'
call simpleline#Disable()
call assert_equal('USER-CHANGED-WHILE-ENABLED', &g:tabline)
call simpleline#Stop()

if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit 1
endif
qa!
