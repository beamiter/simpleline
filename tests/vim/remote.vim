" simpleremote integration. simpleremote's virtual mode opens remote files as
" buffers named remote:///abs/path with 'buftype' acwrite and b:vimrc_remote,
" publishes the workspace in g:simpleremote_workspace and its state in
" g:simpleremote_status, and never redraws itself. These tests pin what
" Simpleline makes of that: the `remote` segment and its highlight, the
" filename segment shortened against the remote root, remote buffers listed
" and named in the tabline, and the Git daemon left alone for a buffer nothing
" local can run `git status` in — plus the slowed, unwatched poll over an
" sshfs projection. simpleremote itself is never on the runtimepath here; its
" surface is stubbed exactly as documented, so the plugin has to keep working
" (and keep the golden layouts) without it.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim/remote.vim

set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h:h')
execute 'set runtimepath^=' . fnameescape(s:root)
call delete(s:root . '/tests/remote-errors.log')

let g:simpleline_auto_enable = 0
let g:simpleline_git_enabled = 0
let g:simpleline_nerdfont = 0
let g:simpleline_separator = 'plain'
let g:simpleline_compact_width = 0
runtime plugin/simpleline.vim

call assert_equal(1, g:simpleline_show_remote, 'the remote segment is on by default')
call assert_notequal(-1, index(simpleline#SegmentNames(), 'remote'),
      \ "'remote' is a built-in segment name")

call simpleline#Enable()
set columns=200

let s:mode_chunk = '%#SimpleLineCommand# COMMAND %#SimpleLineCommandSep#'

" ------------------------------------------------ segment: absent/present ---

" Without simpleremote — no status global, no accessor — the segment is empty
" and the default layout is untouched (tests/vim/sections.vim pins the exact
" golden; this only pins the part that matters here).
call assert_notmatch('SimpleLineRemote', simpleline#ActiveStatusline(),
      \ 'no remote segment without simpleremote')

" simpleremote's documented surface: the status string and the accessor.
let g:simpleremote_status = 'ssh:h'
function! g:SimpleRemoteStatusline() abort
  return 'ssh:h:proj@12ms'
endfunction

let s:line = simpleline#ActiveStatusline()
call assert_equal(0, stridx(s:line, s:mode_chunk . '%#SimpleLineRemote# ssh:h:proj@12ms '),
      \ 'the remote segment renders right after the mode block: ' . s:line)
call assert_notequal(-1, index(hlget()->map({_, v -> v.name}), 'SimpleLineRemote'),
      \ 'the SimpleLineRemote highlight group is defined')

" While connecting the accessor already names the workspace, but the status
" says what is really going on.
let g:simpleremote_status = 'connecting ssh:h'
call assert_match('%#SimpleLineRemote# connecting ssh:h:proj@12ms ',
      \ simpleline#ActiveStatusline(), 'connecting is shown while the handshake runs')

" An accessor that returns nothing yet leaves the status to speak, without a
" doubled prefix.
function! g:SimpleRemoteStatusline() abort
  return ''
endfunction
call assert_match('%#SimpleLineRemote# connecting ssh:h ', simpleline#ActiveStatusline(),
      \ 'the status string is the fallback text')

" A throwing accessor is a skipped accessor, never a broken statusline.
function! g:SimpleRemoteStatusline() abort
  throw 'boom'
endfunction
let g:simpleremote_status = 'ssh:h'
call assert_match('%#SimpleLineRemote# ssh:h ', simpleline#ActiveStatusline(),
      \ 'a throwing accessor falls back to the status')

" The text is escaped like every other dynamic segment.
function! g:SimpleRemoteStatusline() abort
  return 'ssh:h:100%'
endfunction
call assert_match('%#SimpleLineRemote# ssh:h:100%% ', simpleline#ActiveStatusline(),
      \ 'a percent in the workspace name cannot become a format item')

function! g:SimpleRemoteStatusline() abort
  return 'ssh:h:proj@12ms'
endfunction

" Disconnected, or turned off, is nothing at all.
let g:simpleremote_status = 'disconnected'
call assert_notmatch('SimpleLineRemote', simpleline#ActiveStatusline(),
      \ 'no remote segment while disconnected')
let g:simpleremote_status = 'ssh:h'
let g:simpleline_show_remote = 0
call assert_notmatch('SimpleLineRemote', simpleline#ActiveStatusline(),
      \ 'g:simpleline_show_remote = 0 hides the segment')
let g:simpleline_show_remote = 1

" A narrow window drops the latency suffix the way it drops ahead/behind.
let g:simpleline_compact_width = winwidth(0) + 1
call assert_match('%#SimpleLineRemote# ssh:h:proj ', simpleline#ActiveStatusline(),
      \ 'compact windows drop the @NNms suffix')
let g:simpleline_compact_width = 0

" The segment is a layout entry like any other: it can be moved or dropped.
let g:simpleline_sections = {'left': ['remote', 'mode'], 'right': []}
call assert_equal('%#SimpleLineRemote# ssh:h:proj@12ms ' . s:mode_chunk . '%=',
      \ simpleline#ActiveStatusline(), 'the remote segment can be laid out')
unlet g:simpleline_sections

" ---------------------------------------------------- redraw on events ---

" simpleremote's Emit() sets g:simpleremote_event and fires the User event;
" nothing else redraws, so Simpleline listens. The autocommand must exist and
" must survive being fired with nothing but the payload set.
call assert_true(exists('#SimpleLineAutoUpdate#User'),
      \ 'the update group has User autocommands')
let g:simpleremote_event = {'event': 'SimpleRemoteConnected', 'status': 'ssh:h',
      \ 'time': localtime(), 'snapshot': {}}
for s:ev in ['SimpleRemoteConnecting', 'SimpleRemoteConnected',
      \ 'SimpleRemoteWorkspaceChanged', 'SimpleRemoteRuntimeReady',
      \ 'SimpleRemoteTreeRootChanged', 'SimpleRemoteDisconnected']
  let g:simpleremote_event.event = s:ev
  try
    execute 'doautocmd <nomodeline> User ' . s:ev
  catch
    call assert_report('User ' . s:ev . ' threw: ' . v:exception)
  endtry
endfor

" ---------------------------------------------------- filename segment ---

let g:simpleremote_workspace = {'id': 1, 'kind': 'ssh', 'target': 'h',
      \ 'root': '/a', 'tree_root': '/a', 'local_root': '', 'mode': 'virtual',
      \ 'uri': 'remote:///a'}

" A virtual buffer exactly as simpleremote's BufReadCmd leaves it. There is no
" BufReadCmd here, so Vim creates an empty buffer with that name.
function! s:OpenRemote(path) abort
  execute 'edit remote://' . a:path
  setlocal buftype=acwrite noswapfile
  let b:vimrc_remote = {'path': a:path, 'uri': 'remote://' . a:path, 'generation': 1}
  return bufnr()
endfunction

let s:deep = s:OpenRemote('/a/b/deep/c.txt')

" %f would print the whole URI; every mode shortens against the remote root.
let g:simpleline_filename_mode = 'native'
let s:line = simpleline#ActiveStatusline()
call assert_match('%#SimpleLineMid# %<b/deep/c.txt%( %m%r%)', s:line,
      \ 'native mode renders the path relative to the remote root: ' . s:line)
call assert_notmatch('remote://', s:line, 'the URI scheme never shows')
call assert_notmatch('%<%f', s:line, 'no %f for a remote buffer')
call assert_match('%<b/deep/c.txt%( %m%r%)', simpleline#InactiveStatusline(),
      \ 'the inactive line uses the same name')

let g:simpleline_filename_mode = 'rel'
call assert_match('%<b/deep/c.txt%( %m%r%)', simpleline#ActiveStatusline(), 'rel')
let g:simpleline_filename_mode = 'abbr'
call assert_match('%<b/d/c.txt%( %m%r%)', simpleline#ActiveStatusline(), 'abbr')
let g:simpleline_filename_mode = 'tail'
call assert_match('%<c.txt%( %m%r%)', simpleline#ActiveStatusline(), 'tail')
let g:simpleline_filename_mode = 'abs'
call assert_match('%</a/b/deep/c.txt%( %m%r%)', simpleline#ActiveStatusline(), 'abs')

" The tree's view root wins over the workspace root, as it does for SimpleTree.
let g:simpleline_filename_mode = 'rel'
let g:simpleremote_workspace.tree_root = '/a/b'
call assert_match('%<deep/c.txt%( %m%r%)', simpleline#ActiveStatusline(),
      \ 'tree_root is the root when the tree is detached')
let g:simpleremote_workspace.tree_root = '/a'

" Outside the root, and with no workspace at all, the whole remote path shows:
" the tail alone would hide which of two same-named files this is.
let s:outside = s:OpenRemote('/elsewhere/c.txt')
call assert_match('%</elsewhere/c.txt%( %m%r%)', simpleline#ActiveStatusline(),
      \ 'outside the root the full remote path is shown')
execute 'buffer ' . s:deep
unlet g:simpleremote_workspace
call assert_match('%</a/b/deep/c.txt%( %m%r%)', simpleline#ActiveStatusline(),
      \ 'without a workspace the full remote path is shown')
let g:simpleremote_workspace = {'id': 1, 'kind': 'ssh', 'target': 'h',
      \ 'root': '/a', 'tree_root': '/a', 'local_root': '', 'mode': 'virtual',
      \ 'uri': 'remote:///a'}

" A buffer named remote:// whose fill has not completed yet (no b:vimrc_remote,
" no buftype) is already a remote path, not a local file called remote:///...
enew!
silent file remote:///a/pending.txt
call assert_match('%<pending.txt%( %m%r%)', simpleline#ActiveStatusline(),
      \ 'a remote:// name is shortened before the fill completes')
bwipeout!

" The percent-escape applies to remote names too.
let s:evil = s:OpenRemote('/a/50%.txt')
call assert_match('%<50%%.txt%( %m%r%)', simpleline#ActiveStatusline(),
      \ 'a remote name is escaped')
execute 'bwipeout! ' . s:evil

" A local acwrite buffer without b:vimrc_remote is not remote and keeps %f.
new
setlocal buftype=acwrite
call assert_match('%<%f%( %m%r%)', simpleline#ActiveStatusline(),
      \ 'an ordinary acwrite buffer keeps Vim''s %f')
bwipeout!
let g:simpleline_filename_mode = 'native'
execute 'bwipeout! ' . s:outside

" -------------------------------------------------------------- tabline ---

let g:simpletabline_path_mode = 'rel'
call simpleline#InvalidateTabline()
let s:tab = simpleline#Tabline()
call assert_match('b/deep/c.txt', s:tab,
      \ 'a remote virtual buffer is listed and named against the remote root: ' . s:tab)
call assert_notmatch('remote://', s:tab, 'the URI scheme never shows in the tabline')

" A second one, to see both and the current one distinguished.
let s:other = s:OpenRemote('/a/other.txt')
let s:tab = simpleline#Tabline()
call assert_match('b/deep/c.txt', s:tab)
call assert_match('SimpleTablineActive#.*other.txt', s:tab, 'the current remote buffer is active')

" Only *filled* virtual buffers get in: an acwrite buffer without b:vimrc_remote
" is still excluded, exactly as before.
new
setlocal buftype=acwrite
silent file scratchy
call assert_notmatch('scratchy', simpleline#Tabline(),
      \ 'an ordinary acwrite buffer stays out of the tabline')
bwipeout!
execute 'buffer ' . s:other

" The remote root is a memo input: a remote tree re-root or a workspace switch
" must re-render the labels, through the event or through the key alone.
let s:before = simpleline#Tabline()
let g:simpleremote_workspace.tree_root = '/a/b'
let g:simpleremote_event = {'event': 'SimpleRemoteTreeRootChanged', 'status': 'ssh:h',
      \ 'time': localtime(), 'root': '/a/b', 'workspace': '/a', 'mode': 'virtual'}
doautocmd <nomodeline> User SimpleRemoteTreeRootChanged
let s:after = simpleline#Tabline()
call assert_notequal(s:before, s:after, 'a tree re-root re-renders the tabline')
call assert_match('deep/c.txt', s:after, 'labels follow the new root')
call assert_notmatch('b/deep/c.txt', s:after)
let g:simpleremote_workspace.tree_root = '/a'
call assert_equal(s:before, simpleline#Tabline(),
      \ 'the remote root is in the memo key, so restoring it restores the render without an event')

" Disconnected: g:simpleremote_workspace is unlet before the event fires. The
" buffers stay (they are still buffers) but fall back to their tail.
unlet g:simpleremote_workspace
let g:simpleremote_status = 'disconnected'
let g:simpleremote_event = {'event': 'SimpleRemoteDisconnected', 'status': 'disconnected',
      \ 'time': localtime(), 'reason': 'disconnect'}
doautocmd <nomodeline> User SimpleRemoteDisconnected
let s:gone = simpleline#Tabline()
call assert_match('c.txt', s:gone, 'remote buffers stay listed after a disconnect')
call assert_notmatch('deep/c.txt', s:gone, 'without a root the label is the tail')

" tail/abs modes on remote buffers.
let g:simpleremote_workspace = {'id': 2, 'kind': 'ssh', 'target': 'h',
      \ 'root': '/a', 'tree_root': '/a', 'local_root': '', 'mode': 'virtual',
      \ 'uri': 'remote:///a'}
let g:simpleremote_status = 'ssh:h'
let g:simpletabline_path_mode = 'tail'
call assert_match('SimpleTablineActive#.*other.txt', simpleline#Tabline())
call assert_notmatch('a/other.txt', simpleline#Tabline(), 'tail shows no directory')
let g:simpletabline_path_mode = 'abs'
call assert_match('/a/other.txt', simpleline#Tabline(), 'abs shows the remote path')
call assert_notmatch('remote://', simpleline#Tabline())
let g:simpletabline_path_mode = 'abbr'
call assert_match('b/d/c.txt', simpleline#Tabline(), 'abbr shortens the remote directories')
unlet g:simpletabline_path_mode

" ----------------------------------------------------------- health ---

let s:health = execute('SimpleLineHealth')
call assert_match('remote workspace: ssh:h (mode virtual, segment on, this buffer remote)',
      \ s:health, 'health reports what the remote segment sees: ' . s:health)
call assert_match('this one remote, not queried', s:health,
      \ 'health says the Git poll is off for a remote buffer')

execute 'bwipeout! ' . s:other
execute 'bwipeout! ' . s:deep
call simpleline#Disable()

" ------------------------------------------------ git: no poll over remote ---

" A fake daemon that logs every git_info and watch request, answers git_info
" for whatever path was asked, and refuses every watch — so a directory it is
" asked about keeps being polled, which is what makes "was it asked" and "how
" often" observable from the outside.
let s:log = tempname()
let s:daemon = tempname()
let s:version = '{"type":"version","id":%s,"version":"test-daemon","protocol":2'
      \ . ',"capabilities":{"git-status":true,"watch":true}}'
let s:git = '{"type":"git_info","id":%s,"path":"%s"'
      \ . ',"branch":"daemonbranch","dirty":false,"added":0,"modified":0'
      \ . ',"deleted":0,"conflicts":0,"stash":0,"operation":"","ahead":0'
      \ . ',"behind":0,"is_git":true,"files":{},"files_truncated":false'
      \ . ',"repo_root":"%s"}'
let s:refused = '{"type":"watch","id":%s,"path":"%s","watching":false}'
call writefile([
      \ '#!/bin/sh',
      \ 'while IFS= read -r line; do',
      \ '  id=$(printf ''%s'' "$line" | sed -n ''s/.*"id":\([0-9][0-9]*\).*/\1/p'')',
      \ '  path=$(printf ''%s'' "$line" | sed -n ''s/.*"path":"\([^"]*\)".*/\1/p'')',
      \ '  case "$line" in',
      \ '    *''"type":"version"''*) printf ' . shellescape(s:version . '\n') . ' "$id" ;;',
      \ '    *''"type":"git_info"''*)',
      \ '      echo "scanned $path" >> ' . shellescape(s:log),
      \ '      printf ' . shellescape(s:git . '\n') . ' "$id" "$path" "$path" ;;',
      \ '    *''"type":"watch"''*)',
      \ '      echo "watch $path" >> ' . shellescape(s:log),
      \ '      printf ' . shellescape(s:refused . '\n') . ' "$id" "$path" ;;',
      \ '  esac',
      \ 'done',
      \ ], s:daemon, 'b')
call setfperm(s:daemon, 'rwx------')

function! s:LogLines(prefix) abort
  return filereadable(s:log)
        \ ? len(filter(readfile(s:log), {_, v -> v =~# '^' . a:prefix . ' '})) : 0
endfunction

let g:simpleline_git_enabled = 1
" 250 ms is the floor the timer clamps to, so a poll that should not happen
" has several chances to happen inside the sleeps below.
let g:simpleline_git_interval = 250
let g:simpleline_daemon_path = s:daemon

" A remote virtual buffer is current: nothing local to ask about, so nothing
" is asked and the daemon is not even spawned on its account.
let g:simpleremote_workspace = {'id': 3, 'kind': 'ssh', 'target': 'h',
      \ 'root': '/a', 'tree_root': '/a', 'local_root': '', 'mode': 'virtual',
      \ 'uri': 'remote:///a'}
let s:remote_buf = s:OpenRemote('/a/b/c.txt')
call delete(s:log)
call simpleline#Enable()
call simpleline#RequestGitRefresh()
sleep 800m
call assert_equal(0, s:LogLines('scanned'),
      \ 'no git_info is ever sent for a remote virtual buffer')
call assert_false(simpleline#core#IsRunning(),
      \ 'the daemon is not spawned for a remote virtual buffer')
call assert_notmatch('SimpleLineGit', simpleline#ActiveStatusline(),
      \ 'and the Git segment is simply absent')

" The Git segment of a remote buffer is whatever simplegit publishes for it.
let b:simplegit_status_dict = {'head': 'remotebranch', 'ahead': 1, 'behind': 0,
      \ 'added': 0, 'changed': 0, 'removed': 0}
call assert_match('%#SimpleLineGit# remotebranch +1 ', simpleline#ActiveStatusline(),
      \ 'simplegit''s dictionary still drives the Git segment for a remote buffer')
unlet b:simplegit_status_dict

" A local file next to it is queried as always: the poll is off for the
" buffer, not for the session.
let s:repo = resolve(tempname())
call mkdir(s:repo . '/mount/src', 'p')
call writefile(['x'], s:repo . '/mount/src/file.txt')
call mkdir(s:repo . '/plain', 'p')
call writefile(['x'], s:repo . '/plain/file.txt')
execute 'edit ' . fnameescape(s:repo . '/plain/file.txt')
call simpleline#RequestGitRefresh()
sleep 800m
call assert_true(s:LogLines('scanned') > 0, 'a local buffer is still queried')
call assert_true(simpleline#core#IsRunning(), 'and the daemon runs for it')
call simpleline#Stop()
call simpleline#Disable()

" ------------------------------------------- git: sshfs projection ---

" Over an sshfs projection the worktree is a FUSE mount: the daemon must not be
" asked to watch it (inotify never reports remote-side edits, and a granted
" watch would silence the poll for good), and the poll runs at the 10 s floor
" instead of every interval — every `git status` there is a network round trip
" per file. Buffer entry and an explicit refresh still ask at once.
let g:simpleremote_workspace = {'id': 4, 'kind': 'ssh', 'target': 'h',
      \ 'root': '/srv/proj', 'tree_root': '/srv/proj',
      \ 'local_root': s:repo . '/mount', 'mode': 'sshfs',
      \ 'uri': 'remote:///srv/proj'}
call delete(s:log)
execute 'edit ' . fnameescape(s:repo . '/mount/src/file.txt')
call simpleline#Enable()
sleep 900m
let s:first_scans = s:LogLines('scanned')
call assert_true(s:first_scans >= 1, 'the sshfs directory is queried on entry')
call assert_equal(0, s:LogLines('watch'), 'the sshfs mount is never watched')
sleep 900m
call assert_equal(s:first_scans, s:LogLines('scanned'),
      \ 'the timer does not poll an sshfs projection every interval')
call assert_match('this one polled every 10000ms, sshfs', execute('SimpleLineHealth'),
      \ 'health explains the slow poll')
call simpleline#RequestGitRefresh()
sleep 500m
call assert_true(s:LogLines('scanned') > s:first_scans,
      \ 'an explicit refresh still asks at once')
call assert_equal(0, s:LogLines('watch'), 'still no watch after the refresh')

" The floor follows a longer g:simpleline_git_interval; a shorter one is not
" honoured over the mount.
call simpleline#Stop()
call simpleline#Disable()

" The same layout under a mode that is not sshfs (docker-bind is a local bind
" mount and gets inotify events like any local directory): watched — here
" refused — and polled at the ordinary interval.
let g:simpleremote_workspace.mode = 'docker-bind'
call delete(s:log)
call simpleline#Enable()
sleep 900m
call assert_true(s:LogLines('watch') > 0, 'a docker-bind projection is asked to be watched')
let s:before_scans = s:LogLines('scanned')
sleep 900m
call assert_true(s:LogLines('scanned') > s:before_scans,
      \ 'a refused watch on a non-sshfs projection keeps the ordinary poll')
call simpleline#Stop()
call simpleline#Disable()

unlet g:simpleremote_workspace
cd /
call delete(s:daemon)
call delete(s:log)
call delete(s:repo, 'rf')

if !empty(v:errors)
  call writefile(v:errors, s:root . '/tests/remote-errors.log')
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit 1
endif
qall!
