set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h:h')
execute 'set runtimepath^=' . fnameescape(s:root)

" A fake daemon that answers the handshake and then returns one fully
" populated git_info payload, including the additive conflicts/stash fields.
let s:daemon = tempname()
let s:handshake = json_encode({
      \ 'type': 'version',
      \ 'id': 0,
      \ 'version': 'test-daemon',
      \ 'protocol': 1,
      \ })
let s:request_path = substitute(fnamemodify(getcwd(), ':p'), '/$', '', '')
let s:payload = json_encode({
      \ 'type': 'git_info',
      \ 'id': 1,
      \ 'path': s:request_path,
      \ 'branch': 'feature/upgrade',
      \ 'dirty': v:true,
      \ 'added': 1,
      \ 'modified': 2,
      \ 'deleted': 3,
      \ 'conflicts': 7,
      \ 'stash': 6,
      \ 'operation': 'REBASE',
      \ 'ahead': 4,
      \ 'behind': 5,
      \ 'is_git': v:true,
      \ })
call writefile([
      \ '#!/bin/sh',
      \ 'while IFS= read -r line; do',
      \ '  case "$line" in',
      \ '    *''"type":"version"''*) printf ''%s\n'' ' . shellescape(s:handshake) . ' ;;',
      \ '    *''"type":"git_info"''*) printf ''%s\n'' ' . shellescape(s:payload) . ' ;;',
      \ '  esac',
      \ 'done',
      \ ], s:daemon, 'b')
call setfperm(s:daemon, 'rwx------')

let g:simpleline_auto_enable = 0
let g:simpleline_git_enabled = 1
let g:simpleline_git_interval = 0
let g:simpleline_daemon_path = s:daemon
let g:simpleline_nerdfont = 0
let g:simpleline_compact_width = 0
runtime plugin/simpleline.vim

call simpleline#Enable()
sleep 300m

let s:statusline = simpleline#ActiveStatusline()
call assert_match('feature/upgrade', s:statusline)
call assert_match('+4', s:statusline)
call assert_match('-5', s:statusline)
call assert_match('\[+1 \~2 -3\]', s:statusline)
call assert_match('!7', s:statusline)
call assert_match('\$6', s:statusline)
call assert_match('REBASE', s:statusline)

" Compact windows keep branch and conflicts but hide counts and stash.
let g:simpleline_compact_width = 999
let s:compact = simpleline#ActiveStatusline()
call assert_match('feature/upgrade', s:compact)
call assert_match('!7', s:compact)
call assert_match('REBASE', s:compact)
call assert_notmatch('\$6', s:compact)
call assert_notmatch('\[+1', s:compact)
let g:simpleline_compact_width = 0

let g:simpleline_git_show_operation = 0
call assert_notmatch('REBASE', simpleline#ActiveStatusline())
let g:simpleline_git_show_operation = 1

let s:health = execute('SimpleLineHealth')
call assert_match('daemon version/protocol: test-daemon/1', s:health)
call assert_match('daemon ready/compatible/waiting: yes/yes/0', s:health)

call simpleline#Stop()
call delete(s:daemon)

if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit 1
endif
qa!
