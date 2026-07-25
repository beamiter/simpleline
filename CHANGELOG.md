# Changelog

## 0.3.0 - 2026-07-25

### Upgrade notes

- Rerun `./install.sh` (or rebuild/copy the Windows `.exe`) after updating. The protocol stays at 1; the new daemon adds optional `conflicts` and `stash` fields that an older Vim side simply ignores, and an older daemon keeps working without them.
- Stash counts need Git 2.15 or newer (`--show-stash`). The daemon probes `git --version` once and silently skips the flag on older Git.
- Unmerged files are now reported as conflicts (`!N`) instead of being folded into the modified count.

- Add a search-count segment (`current/total` via `searchcount()`) while search highlighting is active; `g:simpleline_show_search` disables it.
- Add a macro-recording indicator (`REC @q`); `g:simpleline_show_recording` disables it.
- Add a diagnostics segment with auto-detected providers — coc.nvim, ALE, then vim-lsp — showing `E:n`/`W:n`; `g:simpleline_show_diagnostics` disables it.
- Add mouse support to the tabline: left click switches to a buffer, middle click deletes an unmodified buffer; `g:simpletabline_clickable` disables it.
- Show Git stash (`$N`) and conflict (`!N`) counts in the Git segment; conflicts stay visible in compact windows.
- `:SimpleLineHealth` now reports daemon compatibility and the detected diagnostics provider.
- Fix an inconsistent fallback default for `g:simpletabline_pick_chars`.

## 0.2.0 - 2026-07-15

### Upgrade notes

- Rerun `./install.sh` (or rebuild/copy the Windows `.exe`) after updating. Health now reports daemon handshake/version state; persistent `unknown/0` after enable/refresh points to a legacy or unavailable daemon.
- Shaped separators and file icons are now real Nerd Font glyphs. Set `g:simpleline_nerdfont = 0` for an ASCII-safe display.
- Windows narrower than 80 columns hide file metadata and detailed Git counts by default; set `g:simpleline_compact_width = 0` to keep every segment.

- Prevent statusline/tabline format injection from filenames, Git refs, and provider text.
- Replace mapping-based buffer picking with a safe `getcharstr()` picker.
- Correlate Git responses by request ID and deduplicate in-flight directory requests.
- Ignore inherited Git repository-location overrides so cached directories cannot resolve to another repository.
- Reduce each refresh from four Git processes to one porcelain-v2 query.
- Add daemon timeouts, bounded concurrency, validated requests, and graceful EOF draining.
- Restore global and per-window UI options when disabling Simpleline.
- Add responsive statusline sections and correct tabline viewport expansion.
- Add working Powerline separators, filetype icons, health/reload/toggle commands, tests, and documentation.
