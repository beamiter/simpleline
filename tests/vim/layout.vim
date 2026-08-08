set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h:h')
execute 'set runtimepath^=' . fnameescape(s:root)
let g:simpleline_auto_enable = 0
let g:simpleline_git_enabled = 0
let g:simpleline_nerdfont = 0
let g:simpleline_separator = 'plain'
let g:simpletabline_path_mode = 'tail'
runtime plugin/simpleline.vim

for name in split('abcdefghijklmnopqrstu', '\zs')
  execute 'badd ' . name
endfor
buffer u
set columns=50
let s:formatted = simpleline#Tabline()
let s:plain = substitute(s:formatted, '%#[^#]*#', '', 'g')
let s:plain = substitute(s:plain, '%\d*@[^@]*@', '', 'g')
let s:plain = substitute(s:plain, '%X', '', 'g')
let s:plain = substitute(s:plain, '%=', '', 'g')
let s:plain = substitute(s:plain, '%%', '%', 'g')
call assert_true(strdisplaywidth(s:plain) <= &columns,
      \ 'tabline width ' . strdisplaywidth(s:plain) . ' exceeds ' . &columns)
call assert_match('u', s:plain)

set columns=12
let s:tiny = simpleline#Tabline()
call assert_match('u', s:tiny)

" Under 'laststatus' = 3 Vim draws a single statusline across the whole screen,
" so the compact threshold has to be measured against &columns.  Measuring the
" current window instead hid half the segments on a wide global statusline as
" soon as the user split it.
set columns=160
let g:simpleline_compact_width = 80
only
vsplit
vsplit
call assert_true(winwidth(0) < g:simpleline_compact_width,
      \ 'the split windows are narrower than the compact threshold')

set laststatus=2
call assert_notmatch('&filetype', simpleline#ActiveStatusline(),
      \ 'a narrow window still hides metadata')

set laststatus=3
call assert_match('&filetype', simpleline#ActiveStatusline(),
      \ 'a global statusline is as wide as the screen, not as the window')

set laststatus=2
only
unlet g:simpleline_compact_width

if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit 1
endif
qa!
