" The supervisor restarts a crashed daemon and re-handshakes, but re-issuing
" the Git request is this plugin's job.  With g:simpleline_git_interval = 0 —
" the documented way to avoid polling a large repository — a restart is the
" only thing that will ever prompt a refresh, so a request that is not re-sent
" leaves the segment showing pre-crash data forever.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim/daemon_restart.vim

set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h:h')
execute 'set runtimepath^=' . fnameescape(s:root)
call delete(s:root . '/tests/daemon-restart-errors.log')

let s:request_path = substitute(fnamemodify(getcwd(), ':p'), '/$', '', '')
let s:state = tempname()
let s:daemon = tempname()

" Answers with a branch named after its own run number, and kills itself after
" the first Git answer.  The second run is therefore distinguishable from the
" first by the rendered branch alone.
let s:version = '{"type":"version","id":%s,"version":"test-daemon","protocol":2}'
let s:git = '{"type":"git_info","id":%s,"path":"' . s:request_path . '"'
      \ . ',"branch":"run%s","dirty":false,"added":0,"modified":0,"deleted":0'
      \ . ',"conflicts":0,"stash":0,"operation":"","ahead":0,"behind":0'
      \ . ',"is_git":true}'
call writefile([
      \ '#!/bin/sh',
      \ 'n=$(cat ' . shellescape(s:state) . ' 2>/dev/null || echo 0)',
      \ 'n=$((n+1))',
      \ 'echo "$n" > ' . shellescape(s:state),
      \ 'while IFS= read -r line; do',
      \ '  id=$(printf ''%s'' "$line" | sed -n ''s/.*"id":\([0-9][0-9]*\).*/\1/p'')',
      \ '  case "$line" in',
      \ '    *''"type":"version"''*) printf ' . shellescape(s:version . '\n') . ' "$id" ;;',
      \ '    *''"type":"git_info"''*)',
      \ '      printf ' . shellescape(s:git . '\n') . ' "$id" "$n"',
      \ '      if [ "$n" -eq 1 ]; then exit 1; fi',
      \ '      ;;',
      \ '  esac',
      \ 'done',
      \ ], s:daemon, 'b')
call setfperm(s:daemon, 'rwx------')

let g:simpleline_auto_enable = 0
let g:simpleline_git_enabled = 1
" Event-only: no timer may rescue the segment behind the fix's back.
let g:simpleline_git_interval = 0
let g:simpleline_daemon_path = s:daemon
let g:simpleline_nerdfont = 0
let g:simpleline_compact_width = 0
runtime plugin/simpleline.vim

call simpleline#Enable()
sleep 400m
" Which run answered first is a race with the 100ms restart backoff; that a
" branch is rendered at all is not.
call assert_match('run\d', simpleline#ActiveStatusline(), 'the first daemon answers')

" No BufEnter, no :SimpleLineGitRefresh, no timer — only the restart.
sleep 2

call assert_match('run2', simpleline#ActiveStatusline(),
      \ 'the restarted daemon is asked again instead of leaving stale data')
call assert_notmatch('run1', simpleline#ActiveStatusline())

let s:health = execute('SimpleLineHealth')
call assert_match('daemon crashes/restarts: 1/1', s:health)
call assert_match('daemon ready/compatible/waiting: yes/yes/0', s:health)

call simpleline#Stop()
call delete(s:daemon)
call delete(s:state)

if !empty(v:errors)
  call writefile(v:errors, s:root . '/tests/daemon-restart-errors.log')
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit 1
endif
qall!
