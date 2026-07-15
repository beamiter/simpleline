set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h:h')
execute 'set runtimepath^=' . fnameescape(s:root)

let s:daemon = tempname()
let s:handshake = json_encode({
      \ 'type': 'version',
      \ 'id': 0,
      \ 'version': 'test-daemon',
      \ 'protocol': 1,
      \ })
let s:request_path = substitute(fnamemodify(getcwd(), ':p'), '/$', '', '')
let s:malformed = json_encode({
      \ 'type': 'git_info',
      \ 'id': 1,
      \ 'path': s:request_path,
      \ 'branch': {},
      \ 'dirty': v:false,
      \ 'added': 0,
      \ 'modified': 0,
      \ 'deleted': 0,
      \ 'ahead': {},
      \ 'behind': 0,
      \ 'is_git': v:true,
      \ })
call writefile([
      \ '#!/bin/sh',
      \ 'while IFS= read -r line; do',
      \ '  case "$line" in',
      \ '    *''"type":"version"''*) printf ''%s\n'' ' . shellescape(s:handshake) . ' ;;',
      \ '    *''"type":"git_info"''*) printf ''%s\n'' ' . shellescape(s:malformed) . ' ;;',
      \ '  esac',
      \ 'done',
      \ ], s:daemon, 'b')
call setfperm(s:daemon, 'rwx------')

let g:simpleline_auto_enable = 0
let g:simpleline_git_enabled = 1
let g:simpleline_git_interval = 0
let g:simpleline_daemon_path = s:daemon
runtime plugin/simpleline.vim

call simpleline#Enable()
sleep 300m
let s:health = execute('SimpleLineHealth')
call assert_match('ignored malformed git response', s:health)
let s:render_error = ''
try
  call simpleline#ActiveStatusline()
catch
  let s:render_error = v:exception
endtry
call assert_equal('', s:render_error)
call simpleline#Stop()
call delete(s:daemon)

if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit 1
endif
qa!
