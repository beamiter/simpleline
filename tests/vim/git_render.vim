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

" ------------------------------------------------------ simplegit hand-off ---

" simplegit publishes {head, ahead, behind, added, changed, removed} per
" buffer.  Where it is installed, the branch and ahead/behind come from it
" instead of from a second `git status` over the same worktree — but the file
" counts, conflicts, stash and operation stay with the daemon, because
" simplegit's counts are *lines in this file* and mean something else.
let b:simplegit_status_dict = {
      \ 'head': 'from-simplegit',
      \ 'ahead': 8,
      \ 'behind': 9,
      \ 'added': 12,
      \ 'changed': 3,
      \ 'removed': 1,
      \ }
let s:handed_off = simpleline#ActiveStatusline()
call assert_match('from-simplegit', s:handed_off)
call assert_notmatch('feature/upgrade', s:handed_off)
call assert_match('+8', s:handed_off)
call assert_match('-9', s:handed_off)
call assert_notmatch('+4', s:handed_off)
call assert_match('\[+1 \~2 -3\]', s:handed_off)
call assert_match('!7', s:handed_off)
call assert_match('REBASE', s:handed_off)
call assert_match('Git provider: auto', execute('SimpleLineHealth'))

" The per-file line counts are opt-in and render in their own group.
call assert_notmatch('SimpleLineHunks', s:handed_off)
let g:simpleline_show_hunks = 1
call assert_match('SimpleLineHunks# +12 \~3 -1 ', simpleline#ActiveStatusline())
let g:simpleline_show_hunks = 0

" An empty head means "not resolved yet" as much as "no repository", so it is
" no evidence: the daemon answers instead.
let b:simplegit_status_dict = {'head': '', 'ahead': 0, 'behind': 0}
call assert_match('feature/upgrade', simpleline#ActiveStatusline())

" A malformed payload can never inject format items or throw.
let b:simplegit_status_dict = {'head': 'evil%{setbufvar(1, "x", 1)}', 'ahead': 'many'}
let s:hostile = simpleline#ActiveStatusline()
call assert_match('evil%%{setbufvar', s:hostile)
call assert_notmatch('+many', s:hostile)

" The hand-off is refusable in both directions.
let b:simplegit_status_dict = {'head': 'from-simplegit', 'ahead': 8, 'behind': 9}
let g:simpleline_git_provider = 'daemon'
call assert_match('feature/upgrade', simpleline#ActiveStatusline())
call assert_notmatch('from-simplegit', simpleline#ActiveStatusline())
let g:simpleline_git_provider = 'simplegit'
let s:only_simplegit = simpleline#ActiveStatusline()
call assert_match('from-simplegit', s:only_simplegit)
call assert_notmatch('\[+1 \~2 -3\]', s:only_simplegit)
call assert_notmatch('REBASE', s:only_simplegit)
let g:simpleline_git_provider = 'auto'
unlet b:simplegit_status_dict

" With no buffer variable, the autoload accessor is the fallback source. It has
" to be a real autoload script: exists('*simplegit#StatusDict') is what decides
" whether the hand-off is available at all.
let s:fake_rtp = tempname()
call mkdir(s:fake_rtp .. '/autoload', 'p')
call writefile([
      \ 'function! simplegit#StatusDict(...) abort',
      \ "  return {'head': 'from-accessor', 'ahead': 0, 'behind': 0,",
      \ "        \\ 'added': 0, 'changed': 0, 'removed': 0}",
      \ 'endfunction',
      \ ], s:fake_rtp .. '/autoload/simplegit.vim')
execute 'set runtimepath^=' . fnameescape(s:fake_rtp)
" exists() deliberately does not source autoload scripts, so the accessor is
" only detectable once simplegit has actually run — which is exactly when it
" has something to report.  Calling it once here reproduces that state.
call simplegit#StatusDict()
call assert_match('from-accessor', simpleline#ActiveStatusline())
call assert_match('simplegit available', execute('SimpleLineHealth'))
call delete(s:fake_rtp, 'rf')

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
