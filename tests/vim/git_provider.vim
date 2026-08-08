" g:simpleline_git_provider = 'simplegit' is sold as "ignore the daemon
" entirely": simplegit already keeps a daemon on this worktree, and there is no
" reason for a second one to run `git status --porcelain=v2` over the same
" files.  GitStr() does drop the reply, but dropping a reply is not the same as
" not asking — the daemon was still spawned and still polled, so the entire
" cost the option exists to remove was still paid, every interval, forever.
"
" These tests pin the request itself, not the render: the fake daemon appends a
" line to a log for every git_info it is asked, so "was the worktree scanned"
" is observable from the outside.  They also pin the one case where the query
" must survive — the tabline's per-file marks are the only remaining consumer
" of the daemon's answer under this provider, so turning the provider on must
" not silently blank them.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim/git_provider.vim

set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h:h')
execute 'set runtimepath^=' . fnameescape(s:root)
call delete(s:root . '/tests/git-provider-errors.log')

let s:repo = resolve(tempname())
call mkdir(s:repo, 'p')
call writefile(['x'], s:repo . '/dirty.txt')
call writefile(['x'], s:repo . '/clean.txt')
execute 'cd ' . fnameescape(s:repo)
let s:request_path = substitute(fnamemodify(getcwd(), ':p'), '/$', '', '')

" One log line per git_info request, so a query that should never have been
" sent is a counted fact rather than an inference from the rendered string.
let s:log = tempname()
let s:daemon = tempname()
let s:version = '{"type":"version","id":%s,"version":"test-daemon","protocol":2'
      \ . ',"capabilities":{"git-status":true}}'
let s:git = '{"type":"git_info","id":%s,"path":"' . s:request_path . '"'
      \ . ',"repo_root":"' . s:repo . '"'
      \ . ',"branch":"daemonbranch","dirty":true,"added":0,"modified":1'
      \ . ',"deleted":0,"conflicts":0,"stash":0,"operation":"","ahead":0'
      \ . ',"behind":0,"is_git":true,"files":{"dirty.txt":"M"}'
      \ . ',"files_truncated":false}'
call writefile([
      \ '#!/bin/sh',
      \ 'while IFS= read -r line; do',
      \ '  id=$(printf ''%s'' "$line" | sed -n ''s/.*"id":\([0-9][0-9]*\).*/\1/p'')',
      \ '  case "$line" in',
      \ '    *''"type":"version"''*) printf ' . shellescape(s:version . '\n') . ' "$id" ;;',
      \ '    *''"type":"git_info"''*)',
      \ '      echo scanned >> ' . shellescape(s:log),
      \ '      printf ' . shellescape(s:git . '\n') . ' "$id" ;;',
      \ '  esac',
      \ 'done',
      \ ], s:daemon, 'b')
call setfperm(s:daemon, 'rwx------')

function! s:Scans() abort
  return filereadable(s:log) ? len(readfile(s:log)) : 0
endfunction

function! s:ResetLog() abort
  call delete(s:log)
endfunction

let g:simpleline_auto_enable = 0
let g:simpleline_git_enabled = 1
" 250ms is the floor the timer clamps to, so a poll that should not happen has
" several chances to happen inside the sleeps below.
let g:simpleline_git_interval = 250
let g:simpleline_daemon_path = s:daemon
let g:simpleline_nerdfont = 0
let g:simpleline_compact_width = 0
let g:simpleline_separator = 'plain'
let g:simpletabline_path_mode = 'rel'
runtime plugin/simpleline.vim

execute 'edit ' . fnameescape(s:repo . '/dirty.txt')
" simplegit's documented consumer contract; this is what makes it the provider.
let b:simplegit_status_dict = {'head': 'sgbranch', 'ahead': 2, 'behind': 1,
      \ 'added': 0, 'changed': 0, 'removed': 0}

" ------------------------------------------- provider with nothing to feed ---

let g:simpleline_git_provider = 'simplegit'
let g:simpletabline_git_status = 0
call s:ResetLog()
call simpleline#Enable()
call simpleline#RequestGitRefresh()
sleep 900m

call assert_equal(0, s:Scans(),
      \ "provider 'simplegit' must not have the worktree scanned at all")
call assert_false(simpleline#core#IsRunning(),
      \ 'a daemon whose every answer is discarded is never even spawned')
call assert_match('daemon query: off', execute('SimpleLineHealth'),
      \ 'health explains why the daemon is idle')

" The segment still renders — from simplegit, which is the whole point.
let s:line = simpleline#ActiveStatusline()
call assert_match('sgbranch', s:line, 'the branch still comes from simplegit')
call assert_notmatch('daemonbranch', s:line)
call assert_match('+2', s:line, 'and so does ahead/behind')
call simpleline#Stop()

" --------------------------------------------- the marks keep it alive ---

" The tabline's per-file marks read the daemon's reply directly, so with them
" on the query still has a consumer and must still be sent.
let g:simpletabline_git_status = 1
call s:ResetLog()
call simpleline#Enable()
" Marked buffers are the ones that are *not* current — the current one always
" keeps SimpleTablineActive — so clean.txt is the one on screen, and it needs
" simplegit's dictionary of its own for the statusline half of this check.
execute 'edit ' . fnameescape(s:repo . '/clean.txt')
let b:simplegit_status_dict = {'head': 'sgbranch', 'ahead': 2, 'behind': 1,
      \ 'added': 0, 'changed': 0, 'removed': 0}
call simpleline#RequestGitRefresh()
sleep 900m

call assert_true(s:Scans() > 0,
      \ 'the per-file marks are a consumer, so the query survives')
call assert_match('daemon query: on', execute('SimpleLineHealth'))
call assert_match('SimpleTablineGitModified#dirty.txt', simpleline#Tabline(),
      \ 'and the marks are still painted under this provider')
" The statusline is still simplegit's alone: the daemon's branch and its file
" counts must not leak back in through the reply the tabline needed.
let s:line = simpleline#ActiveStatusline()
call assert_match('sgbranch', s:line)
call assert_notmatch('daemonbranch', s:line)
" '[~]' rather than '~', which is the previous substitute string in a pattern.
call assert_notmatch('[~]1', s:line, "the daemon's file counts stay discarded")
call simpleline#Stop()

" ------------------------------------------------- every other provider ---

" 'auto' and 'daemon' are unaffected, with or without the marks.
for s:provider in ['auto', 'daemon']
  let g:simpleline_git_provider = s:provider
  let g:simpletabline_git_status = 0
  call s:ResetLog()
  call simpleline#Enable()
  call simpleline#RequestGitRefresh()
  sleep 600m
  call assert_true(s:Scans() > 0, "provider '" . s:provider . "' still queries")
  call assert_match('daemon query: on', execute('SimpleLineHealth'))
  call simpleline#Stop()
endfor

" 'daemon' ignores simplegit, so its branch is the daemon's even though
" b:simplegit_status_dict is right there.
let g:simpleline_git_provider = 'daemon'
call s:ResetLog()
call simpleline#Enable()
execute 'buffer ' . bufnr(s:repo . '/dirty.txt')
call simpleline#RequestGitRefresh()
sleep 600m
call assert_match('daemonbranch', simpleline#ActiveStatusline())
call simpleline#Stop()

cd /
call delete(s:daemon)
call delete(s:log)
call delete(s:repo, 'rf')

if !empty(v:errors)
  call writefile(v:errors, s:root . '/tests/git-provider-errors.log')
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit 1
endif
qall!
