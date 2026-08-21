set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h:h')
execute 'set runtimepath^=' . fnameescape(s:root)
let g:simpleline_auto_enable = 0
runtime plugin/simpleline.vim

let s:cargo_version = ''
for s:line in readfile(s:root . '/Cargo.toml')
  if s:line =~# '^version\s*='
    let s:cargo_version = matchstr(s:line, '"\zs[^"]\+\ze"')
    break
  endif
endfor
call assert_notequal('', s:cargo_version, 'Cargo.toml declares a package version')
call assert_equal(s:cargo_version, g:simpleline_version,
      \ 'the Vim health version must match the daemon/package version')

if !empty(v:errors)
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit 1
endif
qa!
