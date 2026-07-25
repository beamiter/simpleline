set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h:h')
execute 'set runtimepath^=' . fnameescape(s:root)

let g:simpleline_auto_enable = 0
let g:simpleline_git_enabled = 0
let g:simpleline_nerdfont = 0
runtime plugin/simpleline.vim
call simpleline#Enable()

" Diagnostics segment reads a coc.nvim-compatible buffer variable.
enew!
let b:coc_diagnostic_info = {'error': 2, 'warning': 1, 'information': 0, 'hint': 0}
let s:statusline = simpleline#ActiveStatusline()
call assert_match('E:2', s:statusline)
call assert_match('W:1', s:statusline)
let s:health = execute('SimpleLineHealth')
call assert_match('diagnostics provider: coc', s:health)

" Zero counts render nothing, and the segment can be disabled entirely.
let b:coc_diagnostic_info = {'error': 0, 'warning': 0}
call assert_notmatch('E:0', simpleline#ActiveStatusline())
let b:coc_diagnostic_info = {'error': 3, 'warning': 0}
let g:simpleline_show_diagnostics = 0
call assert_notmatch('E:3', simpleline#ActiveStatusline())
let g:simpleline_show_diagnostics = 1
unlet b:coc_diagnostic_info

" Malformed provider counts are ignored instead of rendered.
let b:coc_diagnostic_info = {'error': 'many', 'warning': -2}
call assert_notmatch('SimpleLineDiag', simpleline#ActiveStatusline())
unlet b:coc_diagnostic_info

" Search count appears only while search highlighting is active.
enew!
call setline(1, ['alpha beta', 'beta gamma beta'])
let @/ = 'beta'
let v:hlsearch = 1
call cursor(1, 7)
let s:statusline = simpleline#ActiveStatusline()
call assert_match('1/3', s:statusline)
let v:hlsearch = 0
call assert_notmatch('1/3', simpleline#ActiveStatusline())
let v:hlsearch = 1
let g:simpleline_show_search = 0
call assert_notmatch('1/3', simpleline#ActiveStatusline())
let g:simpleline_show_search = 1
let v:hlsearch = 0

" Macro recording indicator follows reg_recording().
call assert_notmatch('REC @', simpleline#ActiveStatusline())
normal! qz
call assert_match('REC @z', simpleline#ActiveStatusline())
let g:simpleline_show_recording = 0
call assert_notmatch('REC @z', simpleline#ActiveStatusline())
let g:simpleline_show_recording = 1
normal! q
call assert_notmatch('REC @', simpleline#ActiveStatusline())

" Tabline items are wrapped in click labels bound to their buffer number.
enew!
silent file click_current.txt
badd click_target_a.txt
badd click_target_b.txt
let s:tabline = simpleline#Tabline()
call assert_match('@simpleline#TablineClick@', s:tabline)
call assert_match('%X', s:tabline)
let g:simpletabline_clickable = 0
call assert_notmatch('TablineClick', simpleline#Tabline())
let g:simpletabline_clickable = 1

" Left click switches to the clicked buffer.
let s:target = bufnr('click_target_a.txt')
call simpleline#TablineClick(s:target, 1, 'l', '')
call assert_equal(s:target, bufnr('%'))

" Middle click deletes an unmodified buffer.
let s:other = bufnr('click_target_b.txt')
call simpleline#TablineClick(s:other, 1, 'm', '')
call assert_equal(0, buflisted(s:other))

" Middle click refuses to drop unsaved changes.
call setbufvar(s:target, '&modified', 1)
call simpleline#TablineClick(s:target, 1, 'm', '')
call assert_equal(1, bufexists(s:target))
call setbufvar(s:target, '&modified', 0)

" Clicks on vanished buffers are ignored without errors.
let s:click_error = ''
try
  call simpleline#TablineClick(9999, 1, 'l', '')
catch
  let s:click_error = v:exception
endtry
call assert_equal('', s:click_error)

call simpleline#Stop()

if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit 1
endif
qa!
