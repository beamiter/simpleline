" The rendered tabline is memoized because 'tabline' is re-evaluated on every
" redraw.  These tests pin down the invalidation: anything that changes what
" the user should see has to change the memo key (or fire the autocommand that
" clears it), or the tabline silently goes stale.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim/tabline_memo.vim

set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
call delete(s:root .. '/tests/tabline-memo-errors.log')

let g:simpleline_auto_enable = 0
let g:simpleline_git_enabled = 0
let g:simpleline_daemon_path = '/nonexistent/simpleline-daemon'
runtime plugin/simpleline.vim
call simpleline#Enable()

let s:dir = tempname()
call mkdir(s:dir, 'p')

function! s:Open(name) abort
  execute 'edit ' .. fnameescape(s:dir .. '/' .. a:name)
  return bufnr()
endfunction

" ------------------------------------------------------------- stability ---

let s:a = s:Open('alpha.txt')
let s:b = s:Open('beta.txt')

" A repeated call with nothing changed must return an identical string — that
" is the whole point of the memo.
let s:first = simpleline#Tabline()
call assert_equal(s:first, simpleline#Tabline(), 'a stable state renders identically')
call assert_true(s:first =~# 'beta', 'the current buffer appears in the tabline')

" ------------------------------------------------------- current buffer ---

execute 'buffer ' .. s:a
let s:on_a = simpleline#Tabline()
call assert_notequal(s:first, s:on_a, 'switching buffers must re-render')
execute 'buffer ' .. s:b
call assert_equal(s:first, simpleline#Tabline(), 'switching back reproduces the earlier render')

" ------------------------------------------------------- modified flag ---

setlocal modifiable
call setline(1, 'dirty')
call assert_notequal(s:first, simpleline#Tabline(), 'a modified buffer must re-render')
call assert_true(simpleline#Tabline() =~# '+', 'the modified marker is shown')
setlocal nomodified
call assert_equal(s:first, simpleline#Tabline(), 'clearing modified restores the render')

" ----------------------------------------------------------- buffer list ---

let s:c = s:Open('gamma.txt')
let s:with_c = simpleline#Tabline()
call assert_true(s:with_c =~# 'gamma', 'a new buffer appears')
execute 'bwipeout ' .. s:c
call assert_false(simpleline#Tabline() =~# 'gamma', 'a wiped buffer disappears')

" ------------------------------------------------------------------ width ---

" Enough buffers that a narrow tabline genuinely has to drop some of them —
" with only two short names nothing truncates and the string is legitimately
" identical at any width.
let s:filler = []
for s:i in range(15)
  call add(s:filler, s:Open(printf('width_filler_%02d.txt', s:i)))
endfor
execute 'buffer ' .. s:b

let s:cols = &columns
set columns=200
let s:wide = simpleline#Tabline()
set columns=40
let s:narrow = simpleline#Tabline()
call assert_notequal(s:wide, s:narrow, 'a width change must re-render')
call assert_true(strlen(s:narrow) < strlen(s:wide), 'the narrow tabline shows fewer buffers')
set columns=200
call assert_equal(s:wide, simpleline#Tabline(), 'restoring the width restores the render')
let &columns = s:cols

for s:fb in s:filler
  execute 'bwipeout ' .. s:fb
endfor
execute 'buffer ' .. s:b

" ------------------------------------------------------------------ rename ---

" The display-name cache now survives across redraws, so a rename has to miss
" it rather than keep showing the old label.
execute 'buffer ' .. s:a
execute 'file ' .. fnameescape(s:dir .. '/renamed.txt')
call assert_true(simpleline#Tabline() =~# 'renamed', 'a renamed buffer shows its new name')
call assert_false(simpleline#Tabline() =~# 'alpha', 'the old name is gone')

" ---------------------------------------------------------------- filetype ---

" The icon comes from &filetype, which is not in the memo key; a FileType
" autocommand is what keeps this honest.
if get(g:, 'simpleline_nerdfont', 1)
  execute 'buffer ' .. s:b
  setfiletype text
  let s:as_text = simpleline#Tabline()
  setfiletype python
  call assert_notequal(s:as_text, simpleline#Tabline(),
        \ 'a filetype change must re-render (icon)')
endif

" ------------------------------------------------------------ config change ---

" The option only has a visible effect on a buffer that is actually modified,
" so dirty one first.
setlocal modifiable
call setline(1, 'dirty again')
let s:before = simpleline#Tabline()
call assert_true(s:before =~# '+', 'the modified marker is shown to begin with')
let g:simpletabline_show_modified = 0
call assert_notequal(s:before, simpleline#Tabline(),
      \ 'a rendering option change must re-render')
call assert_false(simpleline#Tabline() =~# '+', 'the marker is gone once disabled')
unlet g:simpletabline_show_modified
setlocal nomodified

" ------------------------------------------------- explicit invalidation ---

let s:stable = simpleline#Tabline()
call simpleline#InvalidateTabline()
call assert_equal(s:stable, simpleline#Tabline(),
      \ 'an explicit invalidation rebuilds the same string when nothing changed')

call simpleline#Disable()
call delete(s:dir, 'rf')

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/tabline-memo-errors.log')
  for s:e in v:errors
    echomsg s:e
  endfor
  cquit
endif
qall!
