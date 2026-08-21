# Simpleline

Simpleline is a responsive statusline and buffer tabline for Vim 9. It keeps rendering in Vim9script and moves Git work to a small asynchronous Rust daemon, so editing never waits for `git status`.

Version 0.4 adds event-driven Git refreshes, per-file tabline state and
declarative statusline sections while retaining the search, diagnostics,
recording and mouse features established in 0.3.

## Features

- Mode-aware statusline with file state, Git, optional LSP/provider text, metadata, and cursor position.
- Search count (`3/14`) while highlighting is active, and a `REC @q` macro-recording indicator.
- Diagnostics segment (`E:n W:n`) with auto-detected providers: coc.nvim, ALE, or vim-lsp.
- simpleremote workspace segment (`ssh:host:project@12ms`), remote `remote://` buffers named relative to the remote root in the statusline and listed in the tabline, and no Git polling for them.
- Responsive layout: narrow windows retain the branch/position and hide detailed metadata/counts.
- Buffer-oriented tabline with relative/abbreviated paths, modified markers, visible jump indexes, overflow indicators, and keyboard picking.
- Mouse support on the tabline: left click switches buffers, middle click deletes unmodified buffers.
- Arrow, rounded, and plain separators; built-in Nerd Font icons with user overrides.
- Asynchronous Git branch, in-progress operation (`REBASE`, `MERGE`, `CHERRY-PICK`, `REVERT`, `BISECT`, or `AM`), ahead/behind, added/modified/deleted counts, plus conflict (`!n`) and stash (`$n`) counts.
- Safe enable/disable/reload lifecycle across all windows.
- `:SimpleLineHealth` diagnostics and headless Vim/Rust regression tests.

## Requirements

- Vim 9.1 with `+vim9script` for the core UI.
- Vim `+job` and `+channel`, Git, and Rust/Cargo 1.88 or newer when Git integration is enabled.
- Vim `+timers` only when `g:simpleline_git_interval` is nonzero.
- Git 2.15 or newer for the stash count; the daemon probes `git --version` once and skips it on older Git.
- A Nerd Font for icons and shaped separators (optional).

Simpleline is Vim9-only. Neovim does not implement Vim9script or Vim's job/channel API, so it is not supported by this plugin.

## Installation

With vim-plug:

```vim
Plug 'beamiter/simpleline', {'do': './install.sh'}
```

Or clone/update the plugin and run:

```sh
./install.sh
```

The POSIX installer can be launched from any working directory on Linux/macOS. It performs a locked release build, atomically installs `lib/simpleline-daemon`, and generates Vim help tags when `vim` is on `PATH` (otherwise it prints the manual command).

On native Windows, build and copy the `.exe` from PowerShell (the runtime searches for it automatically):

```powershell
cargo build --release --locked
New-Item -ItemType Directory -Force lib
Copy-Item target/release/simpleline-daemon.exe lib/simpleline-daemon.exe -Force
vim -Nu NONE -n -i NONE -es -c "helptags doc" -c "qa!"
```

After every source update, rerun the installer/build step. Version 0.2 adds a daemon handshake. Health reports `unknown/0` before the daemon answers (including when Git is disabled or Simpleline has not started); if that state persists after enabling Simpleline and running `:SimpleLineGitRefresh`, rebuild the older/incompatible binary.

For an intentionally Git-free setup, disable the backend before the plugin loads; then building the daemon is optional:

```vim
let g:simpleline_git_enabled = 0
```

If you skip the installer entirely, run `:helptags /path/to/simpleline/doc` once so `:help simpleline` is discoverable.

## Quick start

Simpleline enables itself on `VimEnter`. The historical mappings are retained only when the keys are unused:

- `<leader>bp` or `<leader>bj`: show pick hints and read one key.
- `:BufferJump1` … `:BufferJump9`, `:BufferJump0`: jump to a visible indexed buffer.

For explicit mappings, disable the defaults and map the provided `<Plug>` targets:

```vim
let g:simpleline_enable_default_mappings = 0
nmap <leader>b <Plug>(simpleline-buffer-pick)
nmap <leader>1 <Plug>(simpleline-buffer-jump-1)
```

The picker uses `getcharstr()` and never installs temporary `a`–`z` or `<Esc>` mappings.

## Configuration

Set options before Simpleline loads. After changing a visual/runtime option, run `:SimpleLineReload`. The load-time-only `simpleline_auto_enable` and `simpleline_enable_default_mappings` settings require restarting Vim.

### Core and statusline

| Variable | Default | Meaning |
| --- | --- | --- |
| `g:simpleline_auto_enable` | `1` | Enable on `VimEnter`. |
| `g:simpleline_statusline` | `1` | Manage the statusline. |
| `g:simpleline_tabline` | `1` | Manage the buffer tabline. |
| `g:simpleline_separator` | `'arrow'` | `'arrow'`, `'round'`, or `'plain'`. |
| `g:simpleline_nerdfont` | `1` | Use icons/shaped separators; `0` gives a plain fallback. |
| `g:simpleline_compact_width` | `80` | Hide file metadata, Git counts, and ahead/behind below this width; `0` disables compact mode. Measured against `&columns` under `laststatus=3`, otherwise against the window. |
| `g:simpleline_show_filetype` | `1` | Show filetype metadata. |
| `g:simpleline_show_encoding` | `1` | Show file encoding. |
| `g:simpleline_show_fileformat` | `1` | Show Unix/DOS/Mac file format. |
| `g:simpleline_show_position` | `1` | Show line/column; the active line also shows percentage. |
| `g:simpleline_show_lsp` | `1` | Show the compatibility provider described below. |
| `g:simpleline_show_remote` | `1` | Show the simpleremote workspace segment described below; renders nothing without simpleremote or while disconnected. |
| `g:simpleline_show_search` | `1` | Show `current/total` search matches while `v:hlsearch` is on. |
| `g:simpleline_search_maxcount` | `99` | `searchcount()` match limit; exceeding it renders `1/99+`. `0` counts every match. |
| `g:simpleline_search_timeout` | `20` | `searchcount()` budget in ms. A pattern that exceeds it is not retried in that buffer. `0` never gives up. |
| `g:simpleline_show_recording` | `1` | Show `REC @reg` while recording a macro. |
| `g:simpleline_show_diagnostics` | `1` | Show error/warning counts from coc.nvim, ALE, or vim-lsp. |
| `g:simpleline_filename_mode` | `'native'` | Statusline filename: `'native'`, `'tail'`, `'rel'`, `'abbr'`, or `'abs'`. simpleremote `remote://` buffers render relative to the remote root in every mode. |
| `g:simpleline_filetype_icons` | `{}` | Dictionary merged over built-in icons. |
| `g:simpleline_custom_left` | `[]` | User segments before the filename, see below. |
| `g:simpleline_custom_right` | `[]` | User segments on the right, see below. |
| `g:simpleline_sections` | `{}` | Segment layout, `{'left': [...], 'right': [...]}`; empty means the built-in order. See below. |
| `g:simpleline_sections_filetype` | `{}` | Per-kind layouts keyed by `'filetype'` then `'buftype'`. See below. |
| `g:simpleline_debug` | `0` | Emit daemon/client errors through `:messages`. |
| `g:simpleline_enable_default_mappings` | `1` | Add historical mappings only when their keys are unused. |

Example icon override:

```vim
let g:simpleline_filetype_icons = {'python': 'Py', 'text': ''}
```

The statusline is a `%!` expression, so it is rebuilt on every redraw — every cursor movement. The two segments that used to do real work there are memoized: the search count on everything `searchcount()` reads (buffer, `b:changedtick`, `@/`, cursor position, `v:hlsearch`, `'ignorecase'`, `'smartcase'`, and the two budget options), and the diagnostics counts on the buffer, `b:changedtick` and `b:coc_diagnostic_info`, plus the providers' own notifications (`User CocDiagnosticChange`, `ALELintPost`, `ALEJobStarted`, `lsp_diagnostics_updated`) for ALE and vim-lsp, which cost a function call. `:SimpleLineDebug` reports both hit rates. A search pattern that exceeds `g:simpleline_search_timeout` is reported as no count and is not retried in that buffer, so one pathological pattern costs one slow redraw instead of every redraw.

### Git

| Variable | Default | Meaning |
| --- | --- | --- |
| `g:simpleline_git_enabled` | `1` | Start/query the Rust daemon and show Git. |
| `g:simpleline_git_interval` | `2000` | Poll interval in ms (minimum 250); `0` is event-only. Directories the daemon is watching are never polled. |
| `g:simpleline_git_watch` | `1` | Let a daemon advertising the `watch` capability report a directory's changes instead of being asked every interval. |
| `g:simpleline_git_show_status` | `1` | Show added/modified/deleted counts. |
| `g:simpleline_git_show_operation` | `1` | Show an in-progress rebase/merge/cherry-pick/revert/bisect/am operation. |
| `g:simpleline_git_provider` | `'auto'` | Branch source: `'auto'` prefers simplegit and falls back to the daemon, `'daemon'` ignores simplegit, `'simplegit'` ignores the daemon. |
| `g:simpleline_show_hunks` | `0` | Show simplegit's added/changed/removed **lines** for the current file in their own segment. |
| `g:simpleline_daemon_path` | `''` | Executable override; otherwise search `runtimepath/lib`. |

Refreshes are also triggered by buffer entry/write, directory changes, focus changes, and by a daemon restart — requests orphaned by a crash, plus the current directory, are re-issued once the replacement has handshaked, so `g:simpleline_git_interval = 0` does not leave the segment showing pre-crash data. The client keeps one in-flight request per directory. The daemon runs one porcelain-v2 Git command per refresh, limits concurrency to four, and times out a query after five seconds. It reads Git's operation sentinel files directly, so operation detection does not add another process. Directory symlinks are resolved before walking for `.git`; if the physical path cannot be resolved, the operation is omitted rather than borrowed from a lexical parent repository. A `git status` that fails inside a repository is reported as an error rather than as "not a repository", so a transient failure (a concurrent `git gc`, a briefly unavailable mount, a `safe.directory` complaint) leaves the last known-good segment in place instead of blanking the branch and the in-progress operation. Unmerged files render as `!n` and stashes as `$n`; both stay out of the added/modified/deleted bracket. Operations and conflicts remain visible in compact windows.

With a `watch`-capable daemon the poll is not the refresh mechanism, it is the fallback. The daemon watches the worktree recursively, coalesces bursts of filesystem events over a 200 ms quiet window (1 s hard deadline), re-runs `git status` only when something changed, and pushes an unsolicited `git_info` event; the client stops polling that directory entirely. Watching is refused — and the directory keeps being polled exactly as before — outside a repository, for a worktree of more than 4096 directories (a recursive watch costs one inotify descriptor per directory, a finite per-user resource), when the platform watcher cannot start, and beyond 16 watched directories, where the oldest is withdrawn and the daemon says so — a withdrawal is the price of a watch that is granted and of nothing else, so a refused watch never costs a directory that is already watched, which matters because a refusal is not retried until the daemon restarts. Pushes are the one exception to id correlation: they carry `id: 0` and are matched by path against the directories this client asked to watch, so an event for anything else is discarded. A push answers no request, so whether the daemon collects the per-file paths travels with the watch itself, and a watched directory sends no further request that could carry a changed answer: the watch is re-sent whenever `g:simpletabline_git_status` or `g:simpleline_tabline` turns the marks on or off, within one `g:simpleline_git_interval` at the latest and without the watch being dropped. `:SimpleLineHealth` reports `git watch: on/negotiated, N dir(s) watched` and whether the current directory is watched or polled.

### Buffer tabline

| Variable | Default | Meaning |
| --- | --- | --- |
| `g:simpletabline_show_modified` | `1` | Append `+` to modified buffers. |
| `g:simpletabline_show_indexes` | `1` | Render visible jump indexes. |
| `g:simpletabline_superscript_index` | `1` | Render indexes as mathematical digits. |
| `g:simpletabline_listed_only` | `1` | Use listed normal buffers; `0` uses loaded normal buffers. |
| `g:simpletabline_path_mode` | `'abbr'` | `'tail'`, `'rel'`, `'abbr'`, or `'abs'`; relative modes use the basename outside the root. simpleremote `remote://` buffers use the remote workspace root. |
| `g:simpletabline_fallback_cwd_root` | `1` | Use cwd when `simpletree` has no root. |
| `g:simpletabline_newbuf_side` | `'right'` | Sort newer buffer numbers right (`'left'` reverses them). |
| `g:simpletabline_clickable` | `1` | Left click switches buffers; middle click deletes unmodified buffers. |
| `g:simpletabline_pick_chars` | home-row-first alphabet | Keys consumed by picker mode. Duplicates are ignored. |
| `g:simpletabline_item_sep` | `' \| '` | Separator for plain mode. |
| `g:simpletabline_key_sep` | two spaces | Gap after indexes in plain mode. |
| `g:simpletabline_ellipsis` | `' … '` | Hidden-buffer marker. |
| `g:simpletabline_git_status` | `1` | Colour buffers by the Git state of their file. |
| `g:simpletabline_git_status_icons` | `{}` | Glyph per state, e.g. `{'M': '●', 'A': '✚', 'D': '✖', 'U': '!'}`. |
| `g:simpletabline_cyan_gui` | `'#00ffff'` | Active tabline accent (GUI/true color). |
| `g:simpletabline_cyan_cterm` | `'14'` | Active tabline terminal accent. |

With `g:simpletabline_git_status`, each buffer is painted by the state of its file in the repository the current buffer belongs to: `SimpleTablineGitModified` (linked to `DiffChange`), `SimpleTablineGitAdded` (`DiffAdd`), `SimpleTablineGitDeleted` (`DiffDelete`) and `SimpleTablineGitConflict` (`Error`). The current buffer keeps `SimpleTablineActive` — which buffer you are in matters more than its Git state — and `g:simpletabline_git_status_icons` adds a glyph when colour alone is not enough. This needs a daemon built from this version, which advertises a `git-status` capability; an older binary is never asked for the data, everything else keeps working, and `:SimpleLineHealth` says `git file status: on/unavailable`. Run `./install.sh` and `:SimpleLineRestart` to get it. Paths are capped at 2000 per repository. The paths are only requested while something can paint them: with `g:simpletabline_git_status` off, or with `g:simpleline_tabline` off so that no tabline is rendered at all, the request carries no `want_files` and the daemon collects nothing. Turning either option on or off later takes effect on a watched directory too, by re-sending the watch.

With a powerline separator (`arrow`/`round`) the wedge between two items is drawn in the left one's background over the right one's, so a marked buffer needs transitions the fixed `SimpleTab*To*` groups cannot express: those pairs get a group synthesized from the two neighbours, named `SimpleTabX<left>To<right>` and rebuilt on `ColorScheme`. Pairs with no Git group in them keep their own named group, so hand-written overrides of `SimpleTabActToInact` and friends still apply.

## Commands

| Command | Action |
| --- | --- |
| `:SimpleLine` | Enable. |
| `:SimpleLineDisable` | Disable and restore prior options. |
| `:SimpleLineToggle` | Toggle enabled state. |
| `:SimpleLineReload` | Re-read configuration and rebuild UI state. |
| `:SimpleLineGitRefresh` | Request an immediate Git refresh. |
| `:SimpleLineHealth` | Show feature, daemon, cache, and last-error diagnostics. |
| `:SimpleLineDebug` | Health output plus the full Git cache. |
| `:BufferPick` | Display hints and consume one key. |
| `:SimpleLineBufferJump {0-9}` | Jump by visible index. |

The legacy `:BufferJump1` … `:BufferJump0` commands remain available.

## Integrations and themes

- If `simpletree#GetRoot()` exists, its root is used for relative tabline paths; otherwise cwd is used when enabled.
- If simplegit is installed it publishes `b:simplegit_status_dict` (`{head, ahead, behind, added, changed, removed}`) and `simplegit#StatusDict()`. Simpleline then takes the branch and ahead/behind from it; its own daemon stays as the fallback and keeps supplying the file counts, conflicts, stash and in-progress operation, which simplegit does not report. An empty head means "not resolved yet" as much as "no repository", so it falls back rather than blanking the segment, and Simpleline redraws on `User SimpleGitUpdate`. Choose the source with `g:simpleline_git_provider`; add simplegit's per-file line counts as their own segment with `g:simpleline_show_hunks`.
- `g:simpleline_git_provider = 'simplegit'` is what actually stops a second daemon running `git status` over the same worktree: the query is not sent and the daemon is never spawned. Its one remaining consumer is the tabline's per-file marks (`g:simpletabline_git_status`), which read the daemon's reply directly — while those are on the query still runs so the marks keep working; turn them off, or turn off `g:simpleline_tabline`, and nothing scans the worktree twice. `:SimpleLineHealth` reports it as `daemon query: on/off`. Under the default `'auto'` the daemon is still queried, because it is the fallback.
- `g:simpleline_filename_mode` leaves Vim's `%f` behavior untouched by default.
  The explicit `rel` and `abbr` modes use SimpleTree's current root when one is
  already available, otherwise the current window's cwd (including `:lcd`);
  files outside that root fall back to their basename. Unnamed and special
  buffers retain Vim's native labels.
- If `g:simplecc_status` is a non-empty string, it appears as the LSP/provider segment. Its contents are rendered as literal text.
- simpleremote (SSH/Docker workspaces) is feature-detected at redraw time; nothing here needs it to be installed, and every hook renders nothing without it:
  - The built-in `remote` segment, second in the default left layout after the mode, shows the workspace `g:SimpleRemoteStatusline()` names — `ssh:host:project@12ms` once the runtime probe has run — in the `SimpleLineRemote` group; `connecting ssh:host:project` while the handshake runs; nothing while disconnected or with `g:simpleline_show_remote = 0`. Compact windows drop the `@NNms` suffix. Simpleline redraws on `User SimpleRemoteConnecting/Connected/WorkspaceChanged/RuntimeReady/TreeRootChanged/Disconnected`, so a transition shows at once. Move or drop it through `g:simpleline_sections`.
  - In virtual mode a remote file is a buffer named `remote:///abs/path` with `'buftype'` `acwrite` and `b:vimrc_remote`. The filename segment shows its remote path relative to the workspace root (`g:simpleremote_workspace.tree_root`, or `root`) in every `g:simpleline_filename_mode`, `'native'` included — `%f` would print the whole URI; a path outside the root, or a session's remote buffer before the reconnect, shows the whole remote path. The tabline lists such buffers (an ordinary `acwrite` buffer is still left out) and labels them against the same root under `g:simpletabline_path_mode`; a workspace switch or a remote tree re-root relabels at once, and after a disconnect they stay listed under their basename.
  - The Git daemon is not asked about a remote virtual buffer — `remote:///...` is not a directory anything local can run `git status` in — so no request and no poll happens while one is current, and the daemon is not spawned on its account. The Git segment then shows what simplegit publishes for the buffer in `b:simplegit_status_dict`, if anything.
  - Over an sshfs projection (`mode` `'sshfs'`, files under `local_root`) the mount is never asked to be watched — a FUSE mount delivers no inotify events for remote-side edits, so a granted watch would silence the poll for good — and the timer polls a directory on it at most every 10 s (or every `g:simpleline_git_interval` when that is longer). Buffer entry, write, focus and `:SimpleLineGitRefresh` still ask at once. A watch granted before the workspace appeared — the mountpoint is a stable path simpleremote reuses, so a buffer under it can be opened while nothing is connected — is given back with an `unwatch` as soon as the mount is known, instead of leaving the segment frozen; that withdrawal is not recorded as a refusal, so the directory is watched again once it is no longer a projection.
  - `:SimpleLineHealth` prints `remote workspace: ssh:host (mode virtual, segment on, this buffer remote)` and says `remote, not queried` / `polled every 10000ms, sshfs` on the Git interval line.
- `g:simpleline_custom_left` adds user segments after Git/diagnostics and before
  the filename; `g:simpleline_custom_right` places them between the LSP/provider
  segment and file metadata. Both use the same entry format:

  ```vim
  let g:simpleline_custom_left = [
        \ {'fn': 'MyProjectStatus', 'hl': 'SimpleLineGit'},
        \ ]
  let g:simpleline_custom_right = [
        \ {'fn': 'MyVimrcStatus', 'hl': 'SimpleLineDiagWarn'},
        \ ]
  ```

  `fn` is a function name or Funcref taking no argument and returning a string; an empty return hides the segment, and an unknown function name is skipped silently so a segment can be registered before its provider loads. `hl` defaults to `SimpleLineMid` on the left and `SimpleLineRight` on the right; `compact` (default `1`) controls whether the segment survives in compact windows. The text is escaped like every other dynamic segment, and a provider that throws is skipped instead of breaking the statusline. Providers run on every redraw, so they should read a cached variable rather than shell out.
- The statusline is a walk over a section layout, so segment order — and which segments appear at all — is configuration rather than code:

  ```vim
  let g:simpleline_sections = {
        \ 'left':  ['mode', 'git', 'filename'],
        \ 'right': ['metadata', 'position'],
        \ }
  ```

  `left` is packed against the left edge and `right` against the right; the `%=` between them is the only thing the walk itself contributes. The built-in names, in default order, are `mode`, `remote`, `recording`, `git`, `hunks`, `diagnostics`, `custom_left`, `filename` on the left and `search`, `lsp`, `custom_right`, `metadata`, `position` on the right — `custom_left`/`custom_right` render the two lists above in place, so both mechanisms compose. A side that is not mentioned keeps its default, an explicit empty list clears that side, and a malformed value falls back to the default rather than breaking a redraw. An unknown name is skipped and `:SimpleLineHealth` lists it under `segments unknown`.

  An entry may also be a `{'fn': ..., 'hl': ...}` dictionary inline, needing no registration. `simpleline#RegisterSegment('ticket', {'fn': 'MyTicket', 'hl': 'SimpleLineGit'})` gives one a name a layout can use; `simpleline#SegmentNames()` lists everything available. A registration cannot take a built-in name: built-ins emit Vim format items on purpose, while a registered segment's text is always escaped.

  `g:simpleline_sections_filetype` overrides the layout per buffer, keyed by `'filetype'` first and `'buftype'` second so one entry covers every scratch buffer:

  ```vim
  let g:simpleline_sections_filetype = {
        \ 'qf':     {'left': ['mode'], 'right': ['position']},
        \ 'nofile': {'left': [], 'right': ['position']},
        \ }
  ```
- All `SimpleLine*` status groups use `:highlight default`, so a colorscheme or vimrc can define them first. Tabline colors derive from `TabLine`, `TabLineSel`, and `TabLineFill`; the pick hint has its own default red group.

## Troubleshooting

- No Git segment: run `:SimpleLineHealth`, then `./install.sh`. Confirm that `git` is on `$PATH`.
- Boxes instead of icons: install a Nerd Font or set `g:simpleline_nerdfont = 0`.
- Too much polling: check `git watch:` in `:SimpleLineHealth` — watched directories are not polled. `on/unavailable` means the daemon predates the capability: run `./install.sh`, then `:SimpleLineRestart`. Otherwise set `g:simpleline_git_interval = 0`; buffer/focus/write events still refresh.
- Changes arrive late on a network or container mount: set `g:simpleline_git_watch = 0` to keep polling everywhere.
- A custom statusline should coexist: set `g:simpleline_statusline = 0` or toggle Simpleline. Disable restores values owned before enable and leaves user changes made while active alone.
- No visible statusline: Simpleline raises `laststatus` to 2 when necessary and restores it on disable; check the value in `:SimpleLineHealth`.
- No remote segment: `:SimpleLineHealth` prints `remote workspace:` — `simpleremote absent` means the plugin is not loaded, `disconnected` that nothing is connected; the segment also needs `g:simpleline_show_remote` (default `1`) and a layout that lists `remote`.
- More daemon detail: set `g:simpleline_debug = 1`, reload, and inspect `:messages`.

## Development

Run the complete local gate:

```sh
make check
```

This runs Rust formatting, Clippy with warnings denied, all Rust tests, and the headless Vim suite. Individual targets are `make rust-test` and `make vim-test`.

The daemon protocol is newline-delimited JSON. Vim first sends `{"type":"version","id":N}` and expects `{"type":"version","id":N,"version":"…","protocol":2,"capabilities":{…}}`. It then sends `{"type":"git_info","id":N,"path":"…"}` and receives a `git_info` event carrying the same `id` and path, or an `error` event. Request IDs are the source of truth for asynchronous cache placement. Paths are limited to 4096 UTF-8 bytes; an encoded request line is limited to 25,600 bytes.

Protocol 1 has additive `git_info` fields: `conflicts` (unmerged entries), `stash` (stash count), and `operation` (an in-progress repository operation). Either side may be older: Vim treats missing fields as zero/empty, and unknown fields are ignored.

Protocol 2 adds the `git-status` capability and three more additive `git_info` fields: `repo_root` (absolute worktree root), `files` (repository-relative path → `M`/`A`/`D`/`U`, capped at 2000 entries) and `files_truncated`. The map is only produced when the request carries `"want_files":true`, which Vim sends only after the capability is negotiated, so an older daemon is never asked and an older Vim never asks. Both protocol versions are accepted by the client, because the binary is rebuilt by `install.sh` while the Vim files arrive with the plugin manager: updating one and not the other must degrade, not break.
