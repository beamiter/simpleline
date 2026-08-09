" Event-driven Git updates. A daemon that advertises the 'watch' capability is
" asked to report a directory's changes instead of being asked for them every
" interval, and it answers with unsolicited git_info events carrying id 0.
" These tests pin what makes that safe: the capability gate, the fact that a
" push is correlated by path against directories this client actually asked to
" watch, that a withdrawn watch puts the directory back on the poll, and that a
" daemon which never grants a watch behaves exactly as before.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim/git_watch.vim

set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h:h')
execute 'set runtimepath^=' . fnameescape(s:root)
call delete(s:root . '/tests/git-watch-errors.log')

let s:repo = resolve(tempname())
call mkdir(s:repo, 'p')
call writefile(['x'], s:repo . '/file.txt')
execute 'cd ' . fnameescape(s:repo)
let s:request_path = substitute(fnamemodify(getcwd(), ':p'), '/$', '', '')

" A neighbouring directory this client never asks about: the daemon pushing an
" event for it is the case the path correlation exists to reject, and unlike a
" push for the current directory nothing can ever overwrite the result.
let s:stray_path = s:request_path . '/sub'

function! s:GitAt(id, branch, path) abort
  return '{"type":"git_info","id":' . a:id . ',"path":"' . a:path . '"'
        \ . ',"branch":"' . a:branch . '","dirty":false,"added":0,"modified":0'
        \ . ',"deleted":0,"conflicts":0,"stash":0,"operation":"","ahead":0'
        \ . ',"behind":0,"is_git":true,"files":{},"files_truncated":false'
        \ . ',"repo_root":"' . s:repo . '"}'
endfunction

function! s:Git(id, branch) abort
  return s:GitAt(a:id, a:branch, s:request_path)
endfunction

" `caps` decides whether watching is advertised, `grant` whether a watch
" request is answered with watching:true. The daemon pushes an unsolicited
" git_info the moment it accepts a watch — that push is the whole feature, and
" it must land without any further request, which the request log proves.
function! s:Daemon(caps, grant, log) abort
  let l:path = tempname()
  let l:handshake = '{"type":"version","id":%s,"version":"test-daemon"'
        \ . ',"protocol":2,"capabilities":' . json_encode(a:caps) . '}'
  let l:ack = '{"type":"watch","id":%s,"path":"' . s:request_path . '"'
        \ . ',"watching":' . (a:grant ? 'true' : 'false') . '}'
  let l:push = s:Git(0, 'pushed')
  let l:refused = '{"type":"watch","id":%s,"path":"' . s:request_path . '"'
        \ . ',"watching":false}'
  let l:granted = a:grant ? (l:ack . '\n' . l:push) : l:refused
  " Two requests no real daemon answers, so that the two things only a daemon
  " can do — withdraw a watch it granted, and push an event for somewhere the
  " client is not watching — are exercised over the real channel instead of by
  " calling an internal function from the test. Once withdrawn, this daemon
  " refuses to watch again: a real one withdraws because it is at capacity, and
  " a daemon that re-granted immediately would hide the client's fallback.
  let l:withdraw = '{"type":"watch","id":0,"path":"' . s:request_path . '"'
        \ . ',"watching":false}'
  let l:marker = tempname()
  call writefile([
        \ '#!/bin/sh',
        \ 'while IFS= read -r line; do',
        \ '  printf ''%s\n'' "$line" >> ' . shellescape(a:log),
        \ '  id=$(printf ''%s'' "$line" | sed -n ''s/.*"id":\([0-9][0-9]*\).*/\1/p'')',
        \ '  case "$line" in',
        \ '    *''"type":"version"''*) printf ' . shellescape(l:handshake . '\n') . ' "$id" ;;',
        \ '    *''"type":"withdraw"''*) : > ' . shellescape(l:marker)
        \   . '; printf ' . shellescape(l:withdraw . '\n') . ' ;;',
        \ '    *''"type":"inject"''*) printf ' . shellescape(s:Git(0, 'injected') . '\n') . ' ;;',
        \ '    *''"type":"stray"''*) printf '
        \   . shellescape(s:GitAt(0, 'injected', s:stray_path) . '\n') . ' ;;',
        \ '    *''"type":"watch"''*)',
        \ '      if [ -f ' . shellescape(l:marker) . ' ]; then',
        \ '        printf ' . shellescape(l:refused . '\n') . ' "$id"',
        \ '      else',
        \ '        printf ' . shellescape(l:granted . '\n') . ' "$id"',
        \ '      fi ;;',
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

" The whole Git cache, keys included — the only view of what an event wrote
" that does not depend on which directory happens to be current.
function! s:Cache() abort
  return matchstr(execute('SimpleLineDebug'), 'git_cache: .*')
endfunction

let g:simpleline_auto_enable = 0
let g:simpleline_git_enabled = 1
let g:simpleline_git_interval = 250
let g:simpleline_nerdfont = 0
let g:simpleline_separator = 'plain'
runtime plugin/simpleline.vim

" ------------------------------------------------------------- watching ---

let s:log = tempname()
call writefile([], s:log)
let g:simpleline_daemon_path = s:Daemon({'git-status': v:true, 'watch': v:true}, 1, s:log)
call simpleline#Enable()
execute 'edit ' . fnameescape(s:repo . '/file.txt')
sleep 500m

call assert_equal(1, len(s:Requests(s:log, 'watch')),
      \ 'a capable daemon is asked to watch the directory, once')
call assert_match('"path":"' . s:request_path . '"', s:Requests(s:log, 'watch')[0])
call assert_match('pushed', simpleline#ActiveStatusline(),
      \ 'an unsolicited push updates the segment with no request behind it')

" The point of the whole feature: a watched directory is not polled. With a
" 250ms interval, a second of silence would otherwise be four more `git status`
" runs over the worktree.
call assert_match('this one watched', execute('SimpleLineHealth'))
call assert_match('git watch: on/negotiated, 1 dir(s) watched', execute('SimpleLineHealth'))
let s:polled = len(s:Requests(s:log, 'git_info'))
sleep 1
call assert_equal(s:polled, len(s:Requests(s:log, 'git_info')),
      \ 'a watched directory is not polled')

" Granting a watch for one directory does not license pushes for another: the
" push carries a path and it is checked against what this client asked to
" watch. The neighbouring path is asserted on rather than the current one
" because nothing ever polls it, so a wrongly accepted event stays in the cache
" to be seen instead of being overwritten by the next legitimate reply.
call simpleline#core#Send({'type': 'stray', 'id': 0})
sleep 300m
call assert_notmatch('injected', s:Cache(),
      \ 'a push for a path this client never watched never reaches the cache')
call assert_notmatch(escape(s:stray_path, '.*[]~\'), s:Cache(),
      \ 'and leaves no cache entry of its own')
call assert_match('pushed', simpleline#ActiveStatusline(),
      \ 'the watched directory keeps the value its own push gave it')

" A withdrawn watch — the daemon keeps a bounded number of them, so a session
" that visits many repositories has the oldest dropped — puts the directory
" back on the poll rather than leaving it silently frozen.
call simpleline#core#Send({'type': 'withdraw', 'id': 0})
sleep 300m
call assert_match('this one polled', execute('SimpleLineHealth'))
call assert_match('git watch: on/negotiated, 0 dir(s) watched', execute('SimpleLineHealth'))
let s:resumed = len(s:Requests(s:log, 'git_info'))
sleep 1
call assert_true(len(s:Requests(s:log, 'git_info')) > s:resumed,
      \ 'a withdrawn watch puts the directory back on the poll')

" And a push for a directory nobody is watching any more is ignored: pushes are
" correlated by path, so accepting one blindly would let any event write the
" cache for anywhere.
let s:before = simpleline#ActiveStatusline()
call simpleline#core#Send({'type': 'inject', 'id': 0})
" Sampled rather than looked at once when the dust settles: this directory is
" back on the 250ms poll, and a reply carrying the real branch would overwrite
" a wrongly accepted push long before a single late assertion could see it —
" which would leave the assertion passing with the correlation deleted.
let s:saw_injected = 0
for s:tick in range(40)
  sleep 10m
  if s:Cache() =~# 'injected'
    let s:saw_injected = 1
    break
  endif
endfor
call assert_equal(0, s:saw_injected,
      \ 'a push for an unwatched path never reaches the cache')
call assert_equal(s:before, simpleline#ActiveStatusline())
call assert_notmatch('injected', simpleline#ActiveStatusline())

call simpleline#Stop()
call delete(g:simpleline_daemon_path)
call delete(s:log)

" ------------------------------------------------------- no capability ---

" An older daemon is never asked to watch, and everything works as before.
let s:log2 = tempname()
call writefile([], s:log2)
let g:simpleline_daemon_path = s:Daemon({'git-status': v:true}, 0, s:log2)
call simpleline#Enable()
call simpleline#RequestGitRefresh()
sleep 400m
call assert_equal([], s:Requests(s:log2, 'watch'),
      \ 'a daemon without the capability is never asked to watch')
call assert_match('main', simpleline#ActiveStatusline(), 'the branch still renders')
call assert_match('git watch: on/unavailable, 0 dir(s) watched', execute('SimpleLineHealth'))
call assert_match('this one polled', execute('SimpleLineHealth'))
let s:polled2 = len(s:Requests(s:log2, 'git_info'))
sleep 1
call assert_true(len(s:Requests(s:log2, 'git_info')) > s:polled2,
      \ 'an unwatched directory keeps being polled')
call simpleline#Stop()
call delete(g:simpleline_daemon_path)
call delete(s:log2)

" ------------------------------------------------------- opted out ---

" The option is checked before the capability, so a user can keep the poll.
let s:log3 = tempname()
call writefile([], s:log3)
let g:simpleline_git_watch = 0
let g:simpleline_daemon_path = s:Daemon({'git-status': v:true, 'watch': v:true}, 1, s:log3)
call simpleline#Enable()
call simpleline#RequestGitRefresh()
sleep 400m
call assert_equal([], s:Requests(s:log3, 'watch'),
      \ 'g:simpleline_git_watch = 0 sends no watch request')
call assert_match('git watch: off/unavailable', execute('SimpleLineHealth'))
call simpleline#Stop()
call delete(g:simpleline_daemon_path)
call delete(s:log3)
let g:simpleline_git_watch = 1

cd /
call delete(s:repo, 'rf')

if !empty(v:errors)
  call writefile(v:errors, s:root . '/tests/git-watch-errors.log')
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit 1
endif
qall!
