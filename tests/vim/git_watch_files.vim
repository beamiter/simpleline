" want_files travels with a `watch` request, and a granted watch is the one
" place where the client stops sending requests: a push answers nothing, so
" whatever the watch was granted with is what the daemon keeps doing until it
" is told otherwise.  These tests pin that the client tells it — that turning
" the tabline marks on or off after a watch was granted re-sends the watch with
" the new answer, that the poll timer does so for a directory no autocommand
" touches, and that an unchanged answer re-sends nothing.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim/git_watch_files.vim

set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h:h')
execute 'set runtimepath^=' . fnameescape(s:root)
call delete(s:root . '/tests/git-watch-files-errors.log')

let s:repo = resolve(tempname())
call mkdir(s:repo, 'p')
call writefile(['x'], s:repo . '/file.txt')
execute 'cd ' . fnameescape(s:repo)
let s:request_path = substitute(fnamemodify(getcwd(), ':p'), '/$', '', '')

function! s:Git(id, branch) abort
  return '{"type":"git_info","id":' . a:id . ',"path":"' . s:request_path . '"'
        \ . ',"branch":"' . a:branch . '","dirty":false,"added":0,"modified":0'
        \ . ',"deleted":0,"conflicts":0,"stash":0,"operation":"","ahead":0'
        \ . ',"behind":0,"is_git":true,"files":{},"files_truncated":false'
        \ . ',"repo_root":"' . s:repo . '"}'
endfunction

" A daemon that grants every watch and logs every request line, so the test can
" read back exactly what want_files each watch carried.  Every grant is
" followed by the unsolicited push a real one sends, which is what keeps the
" directory off the poll across a renegotiation.
function! s:Daemon(log) abort
  let l:path = tempname()
  let l:handshake = '{"type":"version","id":%s,"version":"test-daemon"'
        \ . ',"protocol":2,"capabilities":'
        \ . json_encode({'git-status': v:true, 'watch': v:true}) . '}'
  let l:ack = '{"type":"watch","id":%s,"path":"' . s:request_path . '"'
        \ . ',"watching":true}'
  call writefile([
        \ '#!/bin/sh',
        \ 'while IFS= read -r line; do',
        \ '  printf ''%s\n'' "$line" >> ' . shellescape(a:log),
        \ '  id=$(printf ''%s'' "$line" | sed -n ''s/.*"id":\([0-9][0-9]*\).*/\1/p'')',
        \ '  case "$line" in',
        \ '    *''"type":"version"''*) printf ' . shellescape(l:handshake . '\n') . ' "$id" ;;',
        \ '    *''"type":"watch"''*) printf '
        \   . shellescape(l:ack . '\n' . s:Git(0, 'pushed') . '\n') . ' "$id" ;;',
        \ '    *''"type":"git_info"''*) printf ' . shellescape(s:Git('%s', 'main') . '\n') . ' "$id" ;;',
        \ '  esac',
        \ 'done',
        \ ], l:path, 'b')
  call setfperm(l:path, 'rwx------')
  return l:path
endfunction

function! s:Requests(log, type) abort
  return filter(readfile(a:log), 'v:val =~# ''"type":"' . a:type . '"''')
endfunction

let g:simpleline_auto_enable = 0
let g:simpleline_git_enabled = 1
let g:simpleline_git_interval = 250
let g:simpleline_nerdfont = 0
let g:simpleline_separator = 'plain'
let g:simpleline_tabline = 1
" Nothing paints a mark yet, so the watch must be negotiated without paths.
let g:simpletabline_git_status = 0
runtime plugin/simpleline.vim

let s:log = tempname()
call writefile([], s:log)
let g:simpleline_daemon_path = s:Daemon(s:log)
call simpleline#Enable()
execute 'edit ' . fnameescape(s:repo . '/file.txt')
sleep 600m

let s:watches = s:Requests(s:log, 'watch')
call assert_equal(1, len(s:watches), 'the directory is watched once')
call assert_match('"want_files":false', s:watches[0],
      \ 'with the marks off the watch asks the daemon to collect nothing')
call assert_match('"path":"' . s:request_path . '"', s:watches[0])
call assert_match('git file status: off/unavailable', execute('SimpleLineHealth'))
call assert_match('git watch: on/negotiated, 1 dir(s) watched', execute('SimpleLineHealth'))

" ------------------------------------------------- marks turned back on ---

" A watched directory sends no more git_info requests, so a watch granted with
" want_files:false would go on pushing `files: {}` forever — wiping the marks a
" BufEnter refresh collects — unless the watch itself is re-sent.
let g:simpletabline_git_status = 1
call simpleline#RequestGitRefresh()
sleep 600m
let s:watches = s:Requests(s:log, 'watch')
call assert_equal(2, len(s:watches),
      \ 'turning the marks on renegotiates the watch')
call assert_match('"want_files":true', s:watches[1],
      \ 'the renegotiated watch asks for the paths')
call assert_match('git file status: on/negotiated', execute('SimpleLineHealth'))
call assert_match('git watch: on/negotiated, 1 dir(s) watched', execute('SimpleLineHealth'),
      \ 'renegotiating keeps the watch rather than dropping back to the poll')

" ------------------------------------------------------ marks off again ---

" No autocommand and no request fires here: the poll timer is the only thing
" left that runs for a watched directory, so it is what has to notice.
let s:polled = len(s:Requests(s:log, 'git_info'))
let g:simpletabline_git_status = 0
sleep 800m
let s:watches = s:Requests(s:log, 'watch')
call assert_equal(3, len(s:watches),
      \ 'the timer renegotiates a watch nothing else would touch')
call assert_match('"want_files":false', s:watches[2],
      \ 'turning the marks off stops the daemon collecting paths')
call assert_equal(s:polled, len(s:Requests(s:log, 'git_info')),
      \ 'renegotiating a watch does not put the directory back on the poll')

" An unchanged answer is not re-sent: this runs on every tick.
sleep 800m
call assert_equal(3, len(s:Requests(s:log, 'watch')),
      \ 'an unchanged want_files sends no watch request')

" ------------------------------------------------------- the tabline off ---

" g:simpleline_tabline off means no tabline is rendered at all, so the marks
" option alone cannot make anything paint one.
let g:simpleline_tabline = 0
let g:simpletabline_git_status = 1
sleep 800m
call assert_equal(3, len(s:Requests(s:log, 'watch')),
      \ 'with no tabline rendered the marks option renegotiates nothing')
call assert_match('git file status: off/unavailable', execute('SimpleLineHealth'))

let g:simpleline_tabline = 1
sleep 800m
let s:watches = s:Requests(s:log, 'watch')
call assert_equal(4, len(s:watches),
      \ 'a tabline that renders again renegotiates the watch')
call assert_match('"want_files":true', s:watches[3])

call simpleline#Stop()
call delete(g:simpleline_daemon_path)
call delete(s:log)

cd /
call delete(s:repo, 'rf')

if !empty(v:errors)
  call writefile(v:errors, s:root . '/tests/git-watch-files-errors.log')
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit 1
endif
qall!
