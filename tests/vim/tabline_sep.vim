" Powerline separators in the tabline are wedges: the glyph is drawn in the
" left item's background over the right item's, so the two colours belong to
" the *pair* of neighbours. Per-file Git marks gave inactive buffers a third
" possible background, which the fixed Fill/Active/Inactive transition groups
" cannot express. These tests read the colours back out of the highlight groups
" the render actually names, so a wedge that does not join its neighbours is a
" red assertion rather than something you have to see to believe.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim/tabline_sep.vim

set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h:h')
execute 'set runtimepath^=' . fnameescape(s:root)
call delete(s:root . '/tests/tabline-sep-errors.log')

let s:repo = resolve(tempname())
call mkdir(s:repo, 'p')
for s:name in ['clean.txt', 'dirty.txt']
  call writefile(['x'], s:repo . '/' . s:name)
endfor
execute 'cd ' . fnameescape(s:repo)
let s:request_path = substitute(fnamemodify(getcwd(), ':p'), '/$', '', '')

" Distinct, recognisable backgrounds: every assertion below is "this wedge is
" cut from that background", so the four must not share a value.
highlight TabLine        guibg=#111111 guifg=#cccccc ctermbg=17 ctermfg=250
highlight TabLineSel     guibg=#222222 guifg=#ffffff ctermbg=18 ctermfg=255
highlight TabLineFill    guibg=#333333 guifg=#cccccc ctermbg=19 ctermfg=250
highlight DiffChange     guibg=#444444 guifg=#ffffff ctermbg=20 ctermfg=255

let s:vfmt = '{"type":"version","id":%s,"version":"test-daemon","protocol":2'
      \ . ',"capabilities":{"git-status":true}}'
let s:gfmt = '{"type":"git_info","id":%s,"path":"' . s:request_path . '"'
      \ . ',"repo_root":"' . s:repo . '"'
      \ . ',"branch":"main","dirty":true,"added":0,"modified":1,"deleted":0'
      \ . ',"conflicts":0,"stash":0,"operation":"","ahead":0,"behind":0'
      \ . ',"is_git":true,"files":{"dirty.txt":"M"},"files_truncated":false}'
let s:daemon = tempname()
call writefile([
      \ '#!/bin/sh',
      \ 'while IFS= read -r line; do',
      \ '  id=$(printf ''%s'' "$line" | sed -n ''s/.*"id":\([0-9][0-9]*\).*/\1/p'')',
      \ '  case "$line" in',
      \ '    *''"type":"version"''*) printf ' . shellescape(s:vfmt . '\n') . ' "$id" ;;',
      \ '    *''"type":"git_info"''*) printf ' . shellescape(s:gfmt . '\n') . ' "$id" ;;',
      \ '  esac',
      \ 'done',
      \ ], s:daemon, 'b')
call setfperm(s:daemon, 'rwx------')

let g:simpleline_auto_enable = 0
let g:simpleline_git_enabled = 1
let g:simpleline_git_interval = 0
let g:simpleline_daemon_path = s:daemon
let g:simpleline_nerdfont = 1
let g:simpleline_separator = 'arrow'
let g:simpletabline_show_indexes = 0
let g:simpletabline_path_mode = 'rel'
runtime plugin/simpleline.vim

call simpleline#Enable()

function! s:Bg(group) abort
  let l:id = synIDtrans(hlID(a:group))
  return [synIDattr(l:id, 'bg#', 'gui'), synIDattr(l:id, 'bg', 'cterm')]
endfunction

" The highlight group named immediately before the item painted with `group`.
" A separator glyph carries no '%', so the run between the two format items is
" exactly the separator text.
function! s:SepBefore(line, group) abort
  let l:m = matchlist(a:line,
        \ '%#\([A-Za-z0-9_]\+\)#[^%]*%\d\+@simpleline#TablineClick@%#'
        \ . a:group . '#')
  return empty(l:m) ? '' : l:m[1]
endfunction

" And the one after it: the wedge that follows the item's own %X terminator.
function! s:SepAfter(line, group) abort
  let l:m = matchlist(a:line,
        \ '%#' . a:group . '#[^%]*\%(%[^#X][^%]*\)\{-}%X%#\([A-Za-z0-9_]\+\)#')
  return empty(l:m) ? '' : l:m[1]
endfunction

" ------------------------------------------------------- without Git marks ---

" Nothing here is Git-marked yet, so the pre-existing transition groups must
" still be the ones named: a user who redefined SimpleTabFillToInact by hand
" keeps their colours.
execute 'edit ' . fnameescape(s:repo . '/dirty.txt')
execute 'edit ' . fnameescape(s:repo . '/clean.txt')
let s:plain = simpleline#Tabline()
call assert_equal('SimpleTabFillToInact', s:SepBefore(s:plain, 'SimpleTablineInactive'),
      \ 'the leading wedge of an unmarked buffer keeps its named group')
call assert_equal('SimpleTabActToFill', s:SepAfter(s:plain, 'SimpleTablineActive'),
      \ 'the trailing wedge of the current buffer keeps its named group')

" ---------------------------------------------------------- with Git marks ---

call simpleline#RequestGitRefresh()
sleep 400m
let s:line = simpleline#Tabline()
call assert_match('SimpleTablineGitModified# dirty.txt', s:line,
      \ 'the modified buffer is painted with its Git group')

let s:before = s:SepBefore(s:line, 'SimpleTablineGitModified')
let s:after = s:SepAfter(s:line, 'SimpleTablineGitModified')
call assert_notequal('', s:before, 'the marked item has a leading wedge')
call assert_notequal('', s:after, 'the marked item has a trailing wedge')

" A wedge joins two backgrounds: its own background is the item it points into,
" its foreground the item it comes from. Before the fix both wedges were cut
" from TabLine, leaving a notch on either side of every marked buffer.
let s:mark_bg = s:Bg('SimpleTablineGitModified')
call assert_equal('#444444', s:mark_bg[0], 'the test fixture is wired to DiffChange')

let s:before_id = synIDtrans(hlID(s:before))
call assert_equal(s:mark_bg[0], synIDattr(s:before_id, 'bg#', 'gui'),
      \ 'the wedge before a marked buffer is filled with its background')
call assert_equal(s:mark_bg[1], synIDattr(s:before_id, 'bg', 'cterm'),
      \ 'and in cterm too')
call assert_equal(s:Bg('SimpleTablineFill')[0], synIDattr(s:before_id, 'fg#', 'gui'),
      \ 'and cut from the background on its left, here the fill')

let s:after_id = synIDtrans(hlID(s:after))
call assert_equal(s:mark_bg[0], synIDattr(s:after_id, 'fg#', 'gui'),
      \ 'the wedge after a marked buffer is cut from its background')
call assert_equal(s:mark_bg[1], synIDattr(s:after_id, 'fg', 'cterm'),
      \ 'and in cterm too')
call assert_equal(s:Bg('SimpleTablineActive')[0], synIDattr(s:after_id, 'bg#', 'gui'),
      \ 'and filled with the background on its right, here the current buffer')

" ------------------------------------------------------------ colorscheme ---

" The derived groups are only rebuilt while rendering, so a colorscheme change
" has to drop the memo as well as the derivation, or the bar keeps the previous
" scheme's colours until some unrelated input changes.
highlight DiffChange guibg=#556655 guifg=#ffffff ctermbg=28 ctermfg=255
call simpleline#ResetHighlights()
let s:recoloured = simpleline#Tabline()
let s:before2 = s:SepBefore(s:recoloured, 'SimpleTablineGitModified')
call assert_notequal('', s:before2, 'the marked item still has a leading wedge')
call assert_equal('#556655', synIDattr(synIDtrans(hlID(s:before2)), 'bg#', 'gui'),
      \ 'a colorscheme change re-derives the wedge')

call simpleline#Stop()
call delete(s:daemon)
cd /
call delete(s:repo, 'rf')

if !empty(v:errors)
  call writefile(v:errors, s:root . '/tests/tabline-sep-errors.log')
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit 1
endif
qall!
