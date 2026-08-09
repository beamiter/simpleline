" Declarative section layout. The statusline is a walk over
" g:simpleline_sections, and the first thing these tests pin is that the walk
" changed nothing: the default layout must render the exact string the
" hardcoded builder produced, separators and all. The rest cover what the
" mechanism buys — reordering, dropping, per-filetype layouts, registered
" segments and the escaping rule that keeps a user segment from emitting format
" items.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim/sections.vim

set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h:h')
execute 'set runtimepath^=' . fnameescape(s:root)
call delete(s:root . '/tests/sections-errors.log')

let g:simpleline_auto_enable = 0
" No daemon, no Git segment: this file is about layout, and a repository would
" make the golden string depend on the checkout it runs in.
let g:simpleline_git_enabled = 0
let g:simpleline_nerdfont = 0
runtime plugin/simpleline.vim

call simpleline#Enable()
set columns=200

" ------------------------------------------------- the default layout ---

" Captured from the hardcoded builder before ActiveStatusline() became a walk
" over sections. In -es Vim the mode is COMMAND and no file is loaded.
let s:golden = '%#SimpleLineCommand# COMMAND %#SimpleLineCommandSep#'
      \ . '%#SimpleLineMid# %<%f%( %m%r%)%#SimpleLineMidSep#'
      \ . '%=%#SimpleLineRightSep#%#SimpleLineRight# '
      \ . '%{&filetype ==# "" ? "-" : &filetype} | '
      \ . '%{&fileencoding !=# "" ? &fileencoding : &encoding} | '
      \ . '%{&fileformat} %#SimpleLinePosSep#%#SimpleLinePos# %l:%c %p%% '

let g:simpleline_separator = 'plain'
call simpleline#Reload()
call assert_equal(s:golden, simpleline#ActiveStatusline(),
      \ 'the default section layout renders exactly what the hardcoded builder did')

" The separator glyphs belong to the segments that emit them, so a layout walk
" that dropped one would show up here and nowhere else.
let g:simpleline_nerdfont = 1
let g:simpleline_separator = 'arrow'
call simpleline#Reload()
let s:sep_l = nr2char(0xe0b0)
let s:sep_r = nr2char(0xe0b2)
let s:subsep_r = nr2char(0xe0b3)
let s:golden_arrow = '%#SimpleLineCommand# COMMAND %#SimpleLineCommandSep#' . s:sep_l
      \ . '%#SimpleLineMid# %<%f%( %m%r%)%#SimpleLineMidSep#' . s:sep_l
      \ . '%=%#SimpleLineRightSep#' . s:sep_r . '%#SimpleLineRight# '
      \ . '%{&filetype ==# "" ? "-" : &filetype} ' . s:subsep_r . ' '
      \ . '%{&fileencoding !=# "" ? &fileencoding : &encoding} ' . s:subsep_r . ' '
      \ . '%{&fileformat} %#SimpleLinePosSep#' . s:sep_r . '%#SimpleLinePos# %l:%c %p%% '
call assert_equal(s:golden_arrow, simpleline#ActiveStatusline(),
      \ 'powerline separators survive the walk in both directions')

let g:simpleline_nerdfont = 0
let g:simpleline_separator = 'plain'
call simpleline#Reload()

" ------------------------------------------------------- reordering ---

" What the mechanism exists for: the position block on the left, the mode block
" gone entirely. Neither was expressible before.
let g:simpleline_sections = {'left': ['position', 'filename'], 'right': ['metadata']}
let s:reordered = simpleline#ActiveStatusline()
call assert_equal(0, stridx(s:reordered, '%#SimpleLinePosSep#'),
      \ 'position renders first when it is listed first')
call assert_notmatch('SimpleLineCommand', s:reordered,
      \ 'a segment left out of the layout is not rendered')
call assert_match('%#SimpleLineMid# %<%f', s:reordered)
call assert_match('%=%#SimpleLineRightSep#', s:reordered)

" Overriding one side leaves the other at its default rather than blanking it.
let g:simpleline_sections = {'right': ['position']}
let s:one_side = simpleline#ActiveStatusline()
call assert_match('^%#SimpleLineCommand# COMMAND ', s:one_side,
      \ 'the unmentioned side keeps the default layout')
call assert_notmatch('SimpleLineRightSep', s:one_side)

" An empty list is a layout, not a missing one: it clears that side.
let g:simpleline_sections = {'left': [], 'right': []}
call assert_equal('%=', simpleline#ActiveStatusline(),
      \ 'an explicitly empty section renders nothing')

" A malformed value falls back to the default instead of throwing in a redraw.
let g:simpleline_sections = 'nonsense'
call assert_equal(s:golden, simpleline#ActiveStatusline(),
      \ 'a non-dict g:simpleline_sections is ignored')

" An unknown name is skipped and the rest of the layout still renders.
let g:simpleline_sections = {'left': ['mode', 'flename'], 'right': ['position']}
let s:typo = simpleline#ActiveStatusline()
call assert_match('^%#SimpleLineCommand# COMMAND ', s:typo)
call assert_notmatch('%<%f', s:typo)
call assert_match('%#SimpleLinePos# %l:%c', s:typo)
call assert_match('unknown: flename', execute('SimpleLineHealth'),
      \ 'health names the segment that resolved to nothing')

unlet g:simpleline_sections

" ------------------------------------------------ registered segments ---

function! g:Ticket() abort
  return 'PROJ-7 100%'
endfunction

call simpleline#RegisterSegment('ticket', {'fn': 'Ticket', 'hl': 'Search'})
let g:simpleline_sections = {'left': ['ticket'], 'right': []}
call assert_equal('%#Search# PROJ-7 100%%%=', simpleline#ActiveStatusline(),
      \ 'a registered segment is escaped: its %% cannot become a format item')

" Built-ins are a closed set. Letting a registration shadow `filename` would
" hand a user's return value the raw treatment those segments get, which is the
" one thing this design must not allow.
call simpleline#RegisterSegment('filename', {'fn': 'Ticket'})
let g:simpleline_sections = {'left': ['filename'], 'right': []}
call assert_match('%<%f', simpleline#ActiveStatusline(),
      \ 'a built-in segment cannot be redefined by a registration')

call assert_equal(-1, index(simpleline#SegmentNames(), 'nope'))
call assert_notequal(-1, index(simpleline#SegmentNames(), 'ticket'))
call assert_notequal(-1, index(simpleline#SegmentNames(), 'diagnostics'))

" An inline dict needs no registration at all — the same shape the custom
" segment lists have always taken.
let g:simpleline_sections = {'left': [{'fn': 'Ticket', 'hl': 'Title'}], 'right': []}
call assert_equal('%#Title# PROJ-7 100%%%=', simpleline#ActiveStatusline())

unlet g:simpleline_sections

" ------------------------------------------------ per-filetype layout ---

new
setlocal filetype=qf
setlocal buftype=nofile
let g:simpleline_sections_filetype = {'qf': {'left': ['mode'], 'right': []}}
call assert_equal('%#SimpleLineCommand# COMMAND %#SimpleLineCommandSep#%=',
      \ simpleline#ActiveStatusline(),
      \ 'a filetype layout replaces the default for that buffer')

" buftype is consulted when the filetype does not match, so every scratch
" buffer can share one layout without naming each filetype.
let g:simpleline_sections_filetype = {'nofile': {'left': [], 'right': ['position']}}
call assert_equal('%=%#SimpleLinePosSep#%#SimpleLinePos# %l:%c %p%% ',
      \ simpleline#ActiveStatusline(),
      \ 'buftype is the fallback key')

let g:simpleline_sections_filetype = {}
call assert_equal(s:golden, simpleline#ActiveStatusline(),
      \ 'with no matching kind the default layout is used')
bwipeout!

call simpleline#Disable()

if !empty(v:errors)
  call writefile(v:errors, s:root . '/tests/sections-errors.log')
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit 1
endif
qall!
