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
let s:plain = substitute(s:plain, '%=', '', 'g')
let s:plain = substitute(s:plain, '%%', '%', 'g')
call assert_true(strdisplaywidth(s:plain) <= &columns,
      \ 'tabline width ' . strdisplaywidth(s:plain) . ' exceeds ' . &columns)
call assert_match('u', s:plain)

set columns=12
let s:tiny = simpleline#Tabline()
call assert_match('u', s:tiny)

if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit 1
endif
qa!
