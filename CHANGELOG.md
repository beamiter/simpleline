# Changelog

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
