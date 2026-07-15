# Simpleline

Simpleline is a responsive statusline and buffer tabline for Vim 9. It keeps rendering in Vim9script and moves Git work to a small asynchronous Rust daemon, so editing never waits for `git status`.

Version 0.2 focuses on safety and lifecycle correctness: dynamic text is escaped, buffer picking does not touch user mappings, Git replies cannot cross repositories, and disabling the plugin restores the UI state that existed before it was enabled.

## Features

- Mode-aware statusline with file state, Git, optional LSP/provider text, metadata, and cursor position.
- Responsive layout: narrow windows retain the branch/position and hide detailed metadata/counts.
- Buffer-oriented tabline with relative/abbreviated paths, modified markers, visible jump indexes, overflow indicators, and keyboard picking.
- Arrow, rounded, and plain separators; built-in Nerd Font icons with user overrides.
- Asynchronous Git branch, ahead/behind, and added/modified/deleted counts.
- Safe enable/disable/reload lifecycle across all windows.
- `:SimpleLineHealth` diagnostics and headless Vim/Rust regression tests.

## Requirements

- Vim 9.1 with `+vim9script` for the core UI.
- Vim `+job` and `+channel`, Git, and Rust/Cargo 1.78 or newer when Git integration is enabled.
- Vim `+timers` only when `g:simpleline_git_interval` is nonzero.
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
| `g:simpleline_compact_width` | `80` | Hide file metadata, Git counts, and ahead/behind below this width; `0` disables compact mode. |
| `g:simpleline_show_filetype` | `1` | Show filetype metadata. |
| `g:simpleline_show_encoding` | `1` | Show file encoding. |
| `g:simpleline_show_fileformat` | `1` | Show Unix/DOS/Mac file format. |
| `g:simpleline_show_position` | `1` | Show line/column; the active line also shows percentage. |
| `g:simpleline_show_lsp` | `1` | Show the compatibility provider described below. |
| `g:simpleline_filetype_icons` | `{}` | Dictionary merged over built-in icons. |
| `g:simpleline_debug` | `0` | Emit daemon/client errors through `:messages`. |
| `g:simpleline_enable_default_mappings` | `1` | Add historical mappings only when their keys are unused. |

Example icon override:

```vim
let g:simpleline_filetype_icons = {'python': 'Py', 'text': ''}
```

### Git

| Variable | Default | Meaning |
| --- | --- | --- |
| `g:simpleline_git_enabled` | `1` | Start/query the Rust daemon and show Git. |
| `g:simpleline_git_interval` | `2000` | Poll interval in ms (minimum 250); `0` is event-only. |
| `g:simpleline_git_show_status` | `1` | Show added/modified/deleted counts. |
| `g:simpleline_daemon_path` | `''` | Executable override; otherwise search `runtimepath/lib`. |

Refreshes are also triggered by buffer entry/write, directory changes, and focus changes. The client keeps one in-flight request per directory. The daemon runs one porcelain-v2 Git command per refresh, limits concurrency to four, and times out a query after five seconds.

### Buffer tabline

| Variable | Default | Meaning |
| --- | --- | --- |
| `g:simpletabline_show_modified` | `1` | Append `+` to modified buffers. |
| `g:simpletabline_show_indexes` | `1` | Render visible jump indexes. |
| `g:simpletabline_superscript_index` | `1` | Render indexes as mathematical digits. |
| `g:simpletabline_listed_only` | `1` | Use listed normal buffers; `0` uses loaded normal buffers. |
| `g:simpletabline_path_mode` | `'abbr'` | `'tail'`, `'rel'`, `'abbr'`, or `'abs'`; relative modes use the basename outside the root. |
| `g:simpletabline_fallback_cwd_root` | `1` | Use cwd when `simpletree` has no root. |
| `g:simpletabline_newbuf_side` | `'right'` | Sort newer buffer numbers right (`'left'` reverses them). |
| `g:simpletabline_pick_chars` | home-row-first alphabet | Keys consumed by picker mode. Duplicates are ignored. |
| `g:simpletabline_item_sep` | `' \| '` | Separator for plain mode. |
| `g:simpletabline_key_sep` | two spaces | Gap after indexes in plain mode. |
| `g:simpletabline_ellipsis` | `' … '` | Hidden-buffer marker. |
| `g:simpletabline_cyan_gui` | `'#00ffff'` | Active tabline accent (GUI/true color). |
| `g:simpletabline_cyan_cterm` | `'14'` | Active tabline terminal accent. |

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
- If `g:simplecc_status` is a non-empty string, it appears as the LSP/provider segment. Its contents are rendered as literal text.
- All `SimpleLine*` status groups use `:highlight default`, so a colorscheme or vimrc can define them first. Tabline colors derive from `TabLine`, `TabLineSel`, and `TabLineFill`; the pick hint has its own default red group.

## Troubleshooting

- No Git segment: run `:SimpleLineHealth`, then `./install.sh`. Confirm that `git` is on `$PATH`.
- Boxes instead of icons: install a Nerd Font or set `g:simpleline_nerdfont = 0`.
- Too much polling: set `g:simpleline_git_interval = 0`; buffer/focus/write events still refresh.
- A custom statusline should coexist: set `g:simpleline_statusline = 0` or toggle Simpleline. Disable restores values owned before enable and leaves user changes made while active alone.
- No visible statusline: Simpleline raises `laststatus` to 2 when necessary and restores it on disable; check the value in `:SimpleLineHealth`.
- More daemon detail: set `g:simpleline_debug = 1`, reload, and inspect `:messages`.

## Development

Run the complete local gate:

```sh
make check
```

This runs Rust formatting, Clippy with warnings denied, all Rust tests, and the headless Vim suite. Individual targets are `make rust-test` and `make vim-test`.

The daemon protocol is newline-delimited JSON. Vim first sends `{"type":"version","id":0}` and expects `{"type":"version","id":0,"version":"…","protocol":1}`. It then sends `{"type":"git_info","id":N,"path":"…"}` and receives a `git_info` event carrying the same `id` and path, or an `error` event. Request IDs are the source of truth for asynchronous cache placement. Paths are limited to 4096 UTF-8 bytes; an encoded request line is limited to 25,600 bytes.
