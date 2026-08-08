" 'statusline' is a %! expression, so ActiveStatusline() runs on every redraw —
" every cursor movement.  Two of its segments used to do real work there:
" searchcount() re-walked the buffer under a timeout budget, and the
" diagnostics segment re-probed and re-called its provider.  Both are now
" memoized, and these tests pin the two halves of that contract: an unchanged
" state must hit the cache, and every input that changes the rendered value
" must miss it.  A stale count is worse than a slow one.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim/render_cache.vim

set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h:h')
execute 'set runtimepath^=' . fnameescape(s:root)

let g:simpleline_auto_enable = 0
let g:simpleline_git_enabled = 0
let g:simpleline_nerdfont = 0
let g:simpleline_compact_width = 0
runtime plugin/simpleline.vim
call simpleline#Enable()

function! s:SearchMisses() abort
  return simpleline#CacheStats().search_misses
endfunction

function! s:DiagMisses() abort
  return simpleline#CacheStats().diag_misses
endfunction

" ---------------------------------------------------------- search count ---

enew!
call setline(1, ['alpha beta', 'beta gamma beta'])
" 'hlsearch' has to be on: with the option off, searchcount() itself resets
" v:hlsearch, and the segment would vanish after the first render for reasons
" that have nothing to do with the memo.
set hlsearch
let @/ = 'beta'
let v:hlsearch = 1
call cursor(1, 7)

call assert_match('1/3', simpleline#ActiveStatusline(), 'the search count still renders')

" A repeated render in an unchanged state must not call searchcount() again.
let s:misses = s:SearchMisses()
let s:hits = simpleline#CacheStats().search_hits
call simpleline#ActiveStatusline()
call assert_equal(s:misses, s:SearchMisses(), 'an unchanged redraw reuses the memo')
call assert_true(simpleline#CacheStats().search_hits > s:hits, 'the reuse is counted as a hit')

" Every input searchcount() reads has to invalidate: cursor position, ...
call cursor(2, 1)
call assert_match('2/3', simpleline#ActiveStatusline(), 'the count follows the cursor')
call assert_true(s:SearchMisses() > s:misses, 'moving the cursor recomputes')

" ... the pattern, ...
let s:misses = s:SearchMisses()
let @/ = 'gamma'
call cursor(2, 6)
call assert_match('1/1', simpleline#ActiveStatusline(), 'a new pattern recomputes')
call assert_true(s:SearchMisses() > s:misses, 'changing @/ misses the memo')

" ... and the buffer contents.
let @/ = 'beta'
call cursor(1, 7)
call simpleline#ActiveStatusline()
let s:misses = s:SearchMisses()
call setline(3, 'beta beta')
call assert_match('1/5', simpleline#ActiveStatusline(), 'editing the buffer recomputes')
call assert_true(s:SearchMisses() > s:misses, 'a changedtick bump misses the memo')

" 'ignorecase' changes what matches, so it is part of the key too.
call setline(1, ['alpha BETA', 'beta gamma beta'])
call deletebufline('%', 3)
call cursor(2, 1)
set noignorecase
call assert_match('1/2', simpleline#ActiveStatusline(), 'case-sensitive count')
set ignorecase
call assert_match('2/3', simpleline#ActiveStatusline(), "'ignorecase' widens the count")
set noignorecase

" ------------------------------------------------------ search maxcount ---

" The budget options are rendering inputs, so they belong in the memo key too:
" changing one has to take effect on the next redraw, not on the next edit.
let g:simpleline_search_maxcount = 1
call assert_match('1/1+', simpleline#ActiveStatusline(),
      \ 'an exceeded maxcount is reported as <maxcount>+')
unlet g:simpleline_search_maxcount
call assert_match('1/2', simpleline#ActiveStatusline(), 'the default maxcount counts all')

let v:hlsearch = 0
set nohlsearch

" ----------------------------------------------------------- diagnostics ---

enew!
let b:coc_diagnostic_info = {'error': 2, 'warning': 1}
call assert_match('E:2', simpleline#ActiveStatusline(), 'diagnostics still render')

let s:misses = s:DiagMisses()
let s:hits = simpleline#CacheStats().diag_hits
call simpleline#ActiveStatusline()
call assert_equal(s:misses, s:DiagMisses(), 'an unchanged redraw reuses the diagnostics memo')
call assert_true(simpleline#CacheStats().diag_hits > s:hits, 'the reuse is counted as a hit')

" coc.nvim publishes into a buffer variable, which is part of the key, so its
" counts are exact without any notification at all.
let b:coc_diagnostic_info = {'error': 5, 'warning': 0}
call assert_match('E:5', simpleline#ActiveStatusline(),
      \ "the coc buffer variable is part of the diagnostics key")
call assert_true(s:DiagMisses() > s:misses, 'a new provider payload misses the memo')

" ALE and vim-lsp cost a function call, so they are not in the key: their
" documented notifications are what invalidates the memo for them.
call simpleline#ActiveStatusline()
let s:misses = s:DiagMisses()
doautocmd <nomodeline> User ALELintPost
call simpleline#ActiveStatusline()
call assert_true(s:DiagMisses() > s:misses,
      \ 'a provider notification forces a recompute')

" An edit invalidates as well, without any provider event.
let s:misses = s:DiagMisses()
let b:coc_diagnostic_info = {'error': 1, 'warning': 0}
call setline(1, 'edited')
call assert_match('E:1', simpleline#ActiveStatusline(), 'an edit re-reads the provider')
call assert_true(s:DiagMisses() > s:misses, 'a changedtick bump misses the diagnostics memo')

" Switching buffers must not show the previous buffer's counts.
let s:other = bufnr()
enew!
call assert_notmatch('E:1', simpleline#ActiveStatusline(),
      \ 'a buffer without diagnostics renders none')
unlet! b:coc_diagnostic_info

" The cache counters are what makes the win observable in :SimpleLineDebug.
let s:debug = execute('SimpleLineDebug')
call assert_match('search cache:', s:debug)
call assert_match('diagnostics cache:', s:debug)

call simpleline#Disable()

if !empty(v:errors)
  call writefile(v:errors, s:root .. '/tests/render-cache-errors.log')
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit 1
endif
qall!
