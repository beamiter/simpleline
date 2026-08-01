# Changelog

## Unreleased - 2026-08-01

### 构建与 CI 修复

- 修复 `doc/simpleline.txt` 中重复的 help tag(`:SimpleLineHealth`)。`helptags` 会因此报错,而 `install.sh` 在 `set -e` 下会随之失败——上一次提交把 CI 弄挂了,就是这个原因。
- 新增 CI 的 MSRV 作业。

### 性能:tabline

`tabline` 每次重绘都会被求值(等于每次光标移动),而它过去每次都要把所有 buffer
的标签宽度量一遍:

| 已列出 buffer 数 | 优化前 | 优化后 |
|---|---|---|
| 20 | 0.38 ms | 0.07 ms |
| 60 | 1.03 ms | 0.17 ms |
| 120 | 2.02 ms | 0.34 ms |

- 渲染结果按 "宽度 + 当前 buffer + 各 buffer 的编号/修改标记/文件名 + 渲染根 +
  影响渲染的配置项" 做备忘;状态没变就直接返回上次的字符串。
- 修复:`RefreshTabRenderRoot()` 过去每次渲染都无条件清空显示名缓存,那份缓存
  从来没有机会被命中过。现在只在渲染根真的变了才清。
- 显示名缓存改为按 "buffer 号 + 文件名" 作键,`:file` / `:saveas` 改名后不会再
  显示旧标签;条目数超过 4096 时整体重置,避免长会话无限增长。
- 新增 `simpleline#InvalidateTabline()`,并由 `FileType` / `BufFilePost`
  自动命令调用——图标取自 `&filetype`,它不在备忘键里。
- 新增 `tests/vim/tabline_memo.vim`:逐项验证切换 buffer、修改标记、增删 buffer、
  改宽度、改名、改文件类型、改配置都会重新渲染。

### 修复

- daemon 崩溃后 git 段会永久停更,只能重启 Vim;现在会自动退避重启并重新握手。

### 变更

- `:SimpleLineHealth` 增加崩溃/重启计数与熔断状态。

### 可靠性:统一 daemon 监督层 (simplecore)

- 进程生命周期改由 vendored `simplecore` 监督层接管(`autoload/simpleline/core.vim`,
  从 `.simplecore/` 同步,请勿直接编辑)。九个插件共用同一份实现:
  - 存活判定一律走 `job_status()`。`job_start()` 即使 exec 失败也会返回 job
    对象,所以 `job != null` 并不能说明进程还活着。
  - 代际守卫:被替换掉的旧 daemon 的 `exit_cb` 迟到时,不会再清掉接替它的新
    进程的状态。
  - 停止栅栏:显式停止后仍在管道里的事件会被丢弃,不会把刚拆掉的状态又写回去。
  - 指数退避自动重启;同一时间窗内反复崩溃则熔断,只报错一次而不是无限重启。
    手动 `:SimpleLineRestart` 会重新合闸。
  - 请求按 id 关联并支持超时,卡死的 daemon 不会让回调永远悬着。
- 新增 `:SimpleLineHealth`、`:SimpleLineRestart`、`:SimpleLineLog`,全套插件命名一致。

### 测试

- 新增 `tests/vim_core.vim`:监督层回归套件(存活判定、代际守卫、停止栅栏、
  退避重启、崩溃熔断、请求超时、协议握手、raw/json 两种编解码),由
  `tests/fake_daemon.py` 驱动——一个可以按需应答/静默/乱码/崩溃/忽略 SIGTERM
  的假 daemon。
- 新增 `make defcompile`:强制编译所有 Vim9 `def`。Vim9 惰性编译会把冷分支里的
  语法/类型错误一直藏到用户真正踩中为止。
- `make check` 现在包含以上两项。

## 0.4.0 - 2026-07-25

- Migrated to Rust edition 2024; minimum supported Rust is now 1.85.
- Refreshed the dependency lockfile. No behavior or protocol changes
  (protocol stays at 1). Rerun `./install.sh` after updating.

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
