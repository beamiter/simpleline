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

" User segments render on either side from a function name or a Funcref.
function! CustomSegmentOk() abort
  return 'UPD 3'
endfunction
function! CustomSegmentEmpty() abort
  return ''
endfunction
function! CustomSegmentThrows() abort
  throw 'segment exploded'
endfunction
function! CustomSegmentInjects() abort
  return '%f 50%'
endfunction
function! CustomSegmentNumber() abort
  return 42
endfunction
function! CustomSegmentCounted() abort
  let g:simpleline_custom_calls += 1
  return 'COUNTED'
endfunction

enew!
let g:simpleline_custom_left = [{'fn': 'CustomSegmentOk'}]
let s:line = simpleline#ActiveStatusline()
call assert_match('SimpleLineMid# UPD 3 ', s:line)
call assert_true(stridx(s:line, 'UPD 3') < stridx(s:line, '%<%f'),
      \ 'left custom segments render before the filename')
let g:simpleline_custom_left = []

" Left providers get the same type/exception isolation as right providers,
" and each registered entry is evaluated only once per statusline build.
let g:simpleline_custom_left = [{'fn': 'CustomSegmentThrows'}]
let g:simpleline_custom_right = [{'fn': 'CustomSegmentOk'}]
let s:line = simpleline#ActiveStatusline()
call assert_match('UPD 3', s:line)
call assert_match('%<%f', s:line)
let g:simpleline_custom_left = 'not-a-list'
call assert_match('%<%f', simpleline#ActiveStatusline())
let g:simpleline_custom_calls = 0
let g:simpleline_custom_left = [{'fn': 'CustomSegmentCounted'}]
let g:simpleline_custom_right = []
call assert_match('COUNTED', simpleline#ActiveStatusline())
call assert_equal(1, g:simpleline_custom_calls)
let g:simpleline_custom_left = []

let g:simpleline_custom_right = [{'fn': 'CustomSegmentOk'}]
call assert_match('SimpleLineRight# UPD 3 ', simpleline#ActiveStatusline())
let g:simpleline_custom_right = [
      \ {'fn': 'CustomSegmentOk', 'hl': 'SimpleLineDiagWarn'}]
call assert_match('SimpleLineDiagWarn# UPD 3 ', simpleline#ActiveStatusline())
let g:simpleline_custom_right = [{'fn': function('CustomSegmentOk')}]
call assert_match('UPD 3', simpleline#ActiveStatusline())

" Empty text, a throwing provider, an unknown name, and malformed entries are
" all skipped without breaking the rest of the statusline.
for s:bad in [
      \ [{'fn': 'CustomSegmentEmpty'}],
      \ [{'fn': 'CustomSegmentThrows'}],
      \ [{'fn': 'CustomSegmentNumber'}],
      \ [{'fn': 'NoSuchSegmentProvider'}],
      \ [{'fn': ''}], [{'fn': 42}], ['not-a-dict'], [{}],
      \ 'not-a-list']
  let g:simpleline_custom_right = s:bad
  let s:line = simpleline#ActiveStatusline()
  call assert_match('%<%f', s:line)
  call assert_notmatch('UPD', s:line)
endfor

" Segment text can never inject statusline format items, and an invalid
" highlight name falls back to the default group.
let g:simpleline_custom_right = [
      \ {'fn': 'CustomSegmentInjects', 'hl': 'Bad Group%'}]
call assert_match('SimpleLineRight# %%f 50%% ', simpleline#ActiveStatusline())

" compact:0 drops the segment in narrow windows; the default keeps it.
let g:simpleline_compact_width = 5000
let g:simpleline_custom_right = [{'fn': 'CustomSegmentOk', 'compact': 0}]
call assert_notmatch('UPD 3', simpleline#ActiveStatusline())
let g:simpleline_custom_right = [{'fn': 'CustomSegmentOk'}]
call assert_match('UPD 3', simpleline#ActiveStatusline())
let g:simpleline_compact_width = 80

let s:health = execute('SimpleLineHealth')
call assert_match('custom segments: 1 rendering/1 registered', s:health)
call assert_match('(left/right 0/1)', s:health)
let g:simpleline_custom_right = []

" Both sides coexist and retain their declared order.
let g:simpleline_custom_left = [{'fn': 'CustomSegmentOk'}]
let g:simpleline_custom_right = [{'fn': 'CustomSegmentInjects'}]
let s:line = simpleline#ActiveStatusline()
call assert_true(stridx(s:line, 'UPD 3') < stridx(s:line, '%<%f'))
call assert_true(stridx(s:line, '%%f 50%%') > stridx(s:line, '%='))
let s:health = execute('SimpleLineHealth')
call assert_match('custom segments: 2 rendering/2 registered', s:health)
call assert_match('(left/right 1/1)', s:health)
let g:simpleline_custom_left = []
let g:simpleline_custom_right = []

" Filename display stays native by default, while explicit modes share the
" tabline's root semantics and remain literal statusline text.
let s:old_cwd = getcwd()
let s:path_root = tempname() .. ' status%root'
call mkdir(s:path_root .. '/long-directory/nested', 'p')
execute 'lcd ' .. fnameescape(s:path_root)
execute 'edit ' .. fnameescape(s:path_root .. '/long-directory/nested/name%file.txt')
let g:simpleline_filename_mode = 'native'
call assert_match('%f', simpleline#ActiveStatusline())
let g:simpleline_filename_mode = 'tail'
call assert_match('name%%file.txt', simpleline#ActiveStatusline())
call assert_notmatch('long-directory', simpleline#ActiveStatusline())
let g:simpleline_filename_mode = 'rel'
call assert_match('long-directory/nested/name%%file.txt', simpleline#ActiveStatusline())
call assert_match('long-directory/nested/name%%file.txt', simpleline#InactiveStatusline())
let g:simpleline_filename_mode = 'abbr'
call assert_match('l/n/name%%file.txt', simpleline#ActiveStatusline())
let g:simpleline_filename_mode = 'abs'
call assert_match('/long-directory/nested/name%%file.txt', simpleline#ActiveStatusline())

" A window-local cwd is the relative root; another split must not leak it.
let g:simpleline_filename_mode = 'rel'
let s:path_win = win_getid()
vsplit
let s:other_root = tempname() .. ' other-root'
call mkdir(s:other_root .. '/active', 'p')
execute 'lcd ' .. fnameescape(s:other_root)
execute 'edit ' .. fnameescape(s:other_root .. '/active/current.txt')
call assert_match('active/current.txt', simpleline#ActiveStatusline())
call assert_notmatch('long-directory/nested', simpleline#ActiveStatusline())

" `%!InactiveStatusline()` itself runs in this active window. During a real
" redraw Vim identifies the inactive target with g:statusline_winid; its
" buffer and window-local cwd must drive the explicit filename.
call assert_match('simpleline#InactiveStatusline',
      \ gettabwinvar(1, win_id2tabwin(s:path_win)[1], '&statusline'))
let g:statusline_winid = s:path_win
redrawstatus
let s:inactive_line = simpleline#InactiveStatusline()
call assert_match('long-directory/nested/name%%file.txt', s:inactive_line)
call assert_notmatch('active/current.txt', s:inactive_line)
unlet g:statusline_winid
close!

" Unnamed and special buffers keep Vim's native labels, and malformed runtime
" configuration falls back rather than throwing during a redraw.
enew!
let g:simpleline_filename_mode = 'rel'
call assert_match('\[No Name\]', simpleline#ActiveStatusline())
setlocal buftype=nofile
silent file [SimpleLine Special]
let g:simpleline_filename_mode = 'abs'
call assert_match('%f', simpleline#ActiveStatusline())
let g:simpleline_filename_mode = {}
call assert_match('%f', simpleline#ActiveStatusline())
let g:simpleline_filename_mode = 'native'
execute 'lcd ' .. fnameescape(s:old_cwd)
call delete(s:path_root, 'rf')
call delete(s:other_root, 'rf')

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
