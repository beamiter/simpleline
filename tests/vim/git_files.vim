" Per-file Git status: the daemon reports which repository paths are changed,
" and the tabline turns that into "which of your open buffers is one of them".
" These tests pin the capability gate (an older binary must degrade silently,
" not break), the path resolution, the memo key (a mark is a rendering input,
" and an omitted rendering input is this plugin's recurring defect), and the
" fact that a malformed payload can neither inject format items nor throw.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim/git_files.vim

set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h:h')
execute 'set runtimepath^=' . fnameescape(s:root)
call delete(s:root . '/tests/git-files-errors.log')

" A worktree with three files, two of which the fake daemon calls changed.
let s:repo = resolve(tempname())
call mkdir(s:repo . '/deep', 'p')
for s:name in ['clean.txt', 'dirty.txt', 'deep/nested.txt']
  call writefile(['x'], s:repo . '/' . s:name)
endfor
execute 'cd ' . fnameescape(s:repo)
let s:request_path = substitute(fnamemodify(getcwd(), ':p'), '/$', '', '')

" A fake daemon that echoes back the request id — the supervisor correlates on
" it, so a canned id would leave every reply stale — and that only reports
" paths when the request actually asked for them. That last part is what makes
" the capability gate observable from the outside.
function! s:Payload(id_placeholder, extra) abort
  let l:payload = extend({
        \ 'type': 'git_info',
        \ 'path': s:request_path,
        \ 'branch': 'main',
        \ 'dirty': v:true,
        \ 'added': 0,
        \ 'modified': 1,
        \ 'deleted': 0,
        \ 'conflicts': 0,
        \ 'stash': 0,
        \ 'operation': '',
        \ 'ahead': 0,
        \ 'behind': 0,
        \ 'is_git': v:true,
        \ }, a:extra)
  return substitute(json_encode(l:payload), '^{', '{"id":' . a:id_placeholder . ',', '')
endfunction

function! s:Daemon(capabilities, files) abort
  let l:path = tempname()
  let l:caps = empty(a:capabilities)
        \ ? '' : ',"capabilities":' . json_encode(a:capabilities)
  let l:handshake = '{"type":"version","id":%s,"version":"test-daemon"'
        \ . ',"protocol":2' . l:caps . '}'
  let l:with_files = s:Payload('%s', {
        \ 'repo_root': s:repo,
        \ 'files': a:files,
        \ 'files_truncated': v:false,
        \ })
  let l:without_files = s:Payload('%s', {})
  call writefile([
        \ '#!/bin/sh',
        \ 'while IFS= read -r line; do',
        \ '  id=$(printf ''%s'' "$line" | sed -n ''s/.*"id":\([0-9][0-9]*\).*/\1/p'')',
        \ '  case "$line" in',
        \ '    *''"type":"version"''*) printf ' . shellescape(l:handshake . '\n') . ' "$id" ;;',
        \ '    *''"want_files":true''*) printf ' . shellescape(l:with_files . '\n') . ' "$id" ;;',
        \ '    *''"type":"git_info"''*) printf ' . shellescape(l:without_files . '\n') . ' "$id" ;;',
        \ '  esac',
        \ 'done',
        \ ], l:path, 'b')
  call setfperm(l:path, 'rwx------')
  return l:path
endfunction

let s:caps = {'git-status': v:true}
let s:daemon = s:Daemon(s:caps, {'dirty.txt': 'M', 'deep/nested.txt': 'U'})

let g:simpleline_auto_enable = 0
let g:simpleline_git_enabled = 1
let g:simpleline_git_interval = 0
let g:simpleline_daemon_path = s:daemon
let g:simpleline_nerdfont = 0
let g:simpleline_separator = 'plain'
let g:simpletabline_path_mode = 'rel'
runtime plugin/simpleline.vim

call simpleline#Enable()
execute 'edit ' . fnameescape(s:repo . '/clean.txt')
execute 'edit ' . fnameescape(s:repo . '/dirty.txt')
execute 'edit ' . fnameescape(s:repo . '/deep/nested.txt')
execute 'edit ' . fnameescape(s:repo . '/clean.txt')
call simpleline#RequestGitRefresh()
sleep 400m

" ------------------------------------------------------------- painting ---

let s:line = simpleline#Tabline()
call assert_match('SimpleTablineGitModified#dirty.txt', s:line,
      \ 'a modified buffer is painted with its Git group')
call assert_match('SimpleTablineGitConflict#deep/nested.txt', s:line,
      \ 'an unmerged buffer is painted as a conflict')
call assert_notmatch('SimpleTablineGit\w*#clean.txt', s:line,
      \ 'an unchanged buffer keeps the plain group')
call assert_match('SimpleTablineActive#clean.txt', s:line,
      \ 'the current buffer keeps its own group whatever Git says')

" Health reports the negotiation, so "why is nothing coloured" is answerable.
let s:health = execute('SimpleLineHealth')
call assert_match('git file status: on/negotiated, 2 path(s)', s:health)
call assert_match('root ' . s:repo, s:health)

" ----------------------------------------------------------- memo key ---

" A mark is a rendering input: it has to be in the memo key, or a file going
" dirty would never repaint.
call assert_equal(s:line, simpleline#Tabline(), 'an unchanged state renders identically')
let g:simpletabline_git_status = 0
let s:without = simpleline#Tabline()
call assert_notequal(s:line, s:without, 'disabling the paint must re-render')
call assert_notmatch('SimpleTablineGitModified', s:without)
call assert_match('git file status: off/unavailable', execute('SimpleLineHealth'))
let g:simpletabline_git_status = 1
call assert_equal(s:line, simpleline#Tabline(), 're-enabling restores the render')

" ------------------------------------------------------------- glyphs ---

let g:simpletabline_git_status_icons = {'M': 'M!', 'U': 'U!'}
let s:with_icons = simpleline#Tabline()
call assert_notequal(s:line, s:with_icons, 'an icon change must re-render')
call assert_match('dirty.txt M!', s:with_icons)
call assert_match('nested.txt U!', s:with_icons)
call assert_notmatch('clean.txt \w!', s:with_icons)

" Glyphs are dynamic text like any other, so they cannot inject format items.
let g:simpletabline_git_status_icons = {'M': '%f 50%'}
call assert_match('dirty.txt %%f 50%%', simpleline#Tabline())
let g:simpletabline_git_status_icons = {}

call simpleline#Stop()
call delete(s:daemon)

" ------------------------------------------------- capability degradation ---

" A daemon that does not advertise 'git-status' is never asked for paths, and
" everything else has to keep working exactly as before.
let s:old = s:Daemon({}, {})
let g:simpleline_daemon_path = s:old
call simpleline#Enable()
execute 'buffer ' . bufnr(s:repo . '/dirty.txt')
call simpleline#RequestGitRefresh()
sleep 400m
let s:degraded = simpleline#Tabline()
call assert_notmatch('SimpleTablineGit', s:degraded, 'no capability, no paint')
call assert_match('dirty.txt', s:degraded, 'the tabline still renders')
call assert_match('main', simpleline#ActiveStatusline(), 'the branch still renders')
call assert_match('git file status: on/unavailable', execute('SimpleLineHealth'))
call simpleline#Stop()
call delete(s:old)

" ------------------------------------------------- two repositories at once ---

" Marks answer for the repository the *current* buffer belongs to. Moving to a
" buffer in another one changes which cache entry answers without changing any
" payload, so a mark resolved against the previous root must not survive.
" Two files over there, because the current buffer decides which repository
" answers and always keeps SimpleTablineActive — it can never be the buffer
" whose mark is under test.
let s:other = resolve(tempname())
call mkdir(s:other, 'p')
call writefile(['x'], s:other . '/elsewhere.txt')
call writefile(['x'], s:other . '/current.txt')

" This daemon echoes the requested directory back as both path and repo_root,
" and reports the same two names for either repository — so which of them can
" actually be resolved is entirely a question of the root.
let s:two = tempname()
let s:vfmt = '{"type":"version","id":%s,"version":"test-daemon","protocol":2'
      \ . ',"capabilities":{"git-status":true}}'
let s:gfmt = '{"type":"git_info","id":%s,"path":"%s","repo_root":"%s"'
      \ . ',"branch":"main","dirty":true,"added":0,"modified":2,"deleted":0'
      \ . ',"conflicts":0,"stash":0,"operation":"","ahead":0,"behind":0'
      \ . ',"is_git":true,"files":{"dirty.txt":"M","elsewhere.txt":"M"}'
      \ . ',"files_truncated":false}'
call writefile([
      \ '#!/bin/sh',
      \ 'while IFS= read -r line; do',
      \ '  id=$(printf ''%s'' "$line" | sed -n ''s/.*"id":\([0-9][0-9]*\).*/\1/p'')',
      \ '  p=$(printf ''%s'' "$line" | sed -n ''s/.*"path":"\([^"]*\)".*/\1/p'')',
      \ '  case "$line" in',
      \ '    *''"type":"version"''*) printf ' . shellescape(s:vfmt . '\n') . ' "$id" ;;',
      \ '    *''"type":"git_info"''*) printf ' . shellescape(s:gfmt . '\n') . ' "$id" "$p" "$p" ;;',
      \ '  esac',
      \ 'done',
      \ ], s:two, 'b')
call setfperm(s:two, 'rwx------')

let g:simpleline_daemon_path = s:two
call simpleline#Enable()
execute 'edit ' . fnameescape(s:other . '/elsewhere.txt')
execute 'edit ' . fnameescape(s:other . '/current.txt')
execute 'edit ' . fnameescape(s:repo . '/clean.txt')
sleep 400m
let s:in_repo = simpleline#Tabline()
call assert_match('SimpleTablineGitModified#dirty.txt', s:in_repo,
      \ 'the file inside the current repository is marked')
call assert_notmatch('SimpleTablineGitModified#[^#]*elsewhere.txt', s:in_repo,
      \ 'a file outside it is not, despite sharing the name in the payload')

execute 'buffer ' . bufnr(s:other . '/current.txt')
sleep 400m
let s:in_other = simpleline#Tabline()
call assert_match('SimpleTablineGitModified#[^#]*elsewhere.txt', s:in_other,
      \ 'the other repository answers once its buffer is current')
call assert_notmatch('SimpleTablineGitModified#dirty.txt', s:in_other,
      \ 'a mark resolved against the previous root does not survive the move')

call simpleline#Stop()
call delete(s:two)
call delete(s:other, 'rf')

" ------------------------------------------------------ malformed payload ---

" A non-string mark must be rejected by validation, leaving the previous cache
" entry untouched rather than half-updating it.
let s:bad = s:Daemon(s:caps, {'dirty.txt': 42})
let g:simpleline_daemon_path = s:bad
call simpleline#Enable()
call simpleline#RequestGitRefresh()
sleep 400m
let s:render_error = ''
try
  call simpleline#Tabline()
  call simpleline#ActiveStatusline()
catch
  let s:render_error = v:exception
endtry
call assert_equal('', s:render_error, 'a malformed payload never reaches the renderer')
call assert_match('ignored malformed git response', execute('SimpleLineHealth'))
call simpleline#Stop()
call delete(s:bad)

cd /
call delete(s:repo, 'rf')

if !empty(v:errors)
  call writefile(v:errors, s:root . '/tests/git-files-errors.log')
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit 1
endif
qall!
