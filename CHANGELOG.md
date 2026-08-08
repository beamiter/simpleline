# Changelog

## Unreleased - 2026-08-08

### CI:MSRV 钉住的版本与声明的版本对不上

- `dtolnay/rust-toolchain` 一直钉在 1.85.0,而 `Cargo.toml` 声明的是
  `rust-version = "1.88"`。cargo 把"工具链比声明的更旧"当硬错误,所以每次
  push,MSRV 作业都在编译第一个 crate 之前就失败——CI 红了整整一个版本周期,
  红到没人再看。现在钉 1.88.0。
- 新增一步:从 `Cargo.toml` 里抽出 `rust-version`,与实际 `rustc --version`
  比对,不一致就报错。action 引用必须是字面量,所以这里只能"派生断言",不能
  "派生取值";但至少两者再分叉时会当场说清楚,而不是丢一屏 trait 解析错误。
- CI 不再手抄 Makefile 的子集:`make defcompile` 与 `make vim-core` 两步删掉了,
  它们本来就在 `make check` 里。门禁范围以 Makefile 为唯一事实来源,否则以后
  往 `check` 里加的目标会在 CI 里被静默跳过。

## Unreleased - 2026-08-05

### 全套统一

- `.simplecore/` 回来了。10 个仓库里的 supervisor(`autoload/<plugin>/core.vim`
  与三个测试文件)本来就是一套 vendored bundle,但源头目录早已丢失,而每个
  Makefile 都还在引用 `../.simplecore/vendor.sh`。现在 bundle 有了源头,而且
  每个仓库带一份 `.simplecore.manifest` 记录各文件的 sha256,`make core-verify`
  会校验它,`check` 依赖它——手改 vendored 文件会在改它的那个仓库里直接失败,
  不需要 `.simplecore/` 在场。
- 安装器抽成共享的 `install-common.sh`,各仓库的 `install.sh` 只剩配置。
  由此补齐的能力:构建前检查 cargo/rustc 与 MSRV(此前 3 个仓库缺,用户看到的
  是一屏 trait 解析错误);原子替换(此前 2 个仓库是就地覆写,Vim 还开着旧 daemon
  时会 ETXTBSY);Windows 的 `.exe` 后缀;安装前用 `--self-test` 验证刚构建的
  二进制;以及生成 helptags。
- `make check` 现在是每个仓库统一的完整门禁。simplemarkdown 与 simpleminimap
  此前叫 `make test`,旧名字保留为别名。
- daemon 的命令行统一为 `--version` / `--help` / `--self-test`。

### 工具链

- `rust-version` 统一到 1.88(此前 1.85 与 1.88 各半)。实测:1.88 能构建全部
  10 个仓库,1.85 只能构建 5 个。
- `cargo update`:全部为补丁级更新。

  注意:这次更新让 `ignore` 从 0.4.27 升到 0.4.30+,而后者用了 let-chains。
  simplefinder 与 simpletree 此前声明的 1.85 在更新前是真实可用的,更新后不再成立
  ——这是这次依赖刷新付出的代价,不是发现了旧的错误声明。
- MSRV 提到 1.88 后,clippy 的 `collapsible_if` 开始建议用 let-chains 合并
  (该 lint 受 MSRV 门控)。已按建议合并,语义不变。

### 本插件

- 新增 `g:simpleline_filename_mode`:状态栏文件名可选 `native`、`tail`、
  `rel`、`abbr`、`abs`。默认 `native` 保持旧行为；相对模式尊重 SimpleTree
  当前 root 或 window-local cwd，所有显式路径都经过 statusline 转义，且不会
  触发 Git 刷新或额外执行自定义 provider。

- `--version`/`--help`/`--self-test`:此前 daemon 完全忽略命令行参数。
  `--self-test` 用内存管道把一条真实请求走完 parse → dispatch → reply。
- Git 段现在显示进行中的 `REBASE` / `MERGE` / `CHERRY-PICK` / `REVERT` /
  `BISECT` / `AM`,紧凑窗口也不会隐藏;检测直接读取 gitdir 的状态文件,不会给
  每次刷新再加一个 Git 进程。`g:simpleline_git_show_operation` 可关闭。
- operation 探测会先解析实际工作目录 symlink,与 `git status` 的 current-dir 语义一致;
  不会再错读 symlink 词法父目录中另一个仓库的 merge/rebase 状态。物理路径无法
  解析时宁可省略 operation,也不回退到可能无关的词法父仓库。

### 新增:用户自定义段位

- 新增 `g:simpleline_custom_left`,把自定义 provider 放在 Git/诊断之后、文件名
  之前；它与原有 `g:simpleline_custom_right` 共用安全转义、异常隔离、compact
  规则和配置格式。health 现在同时报告总数及 left/right 注册分布。
- `g:simpleline_custom_right`:在 LSP/provider 段位与文件元信息之间插入用户段位。
  每项是 `{'fn': 函数名或 Funcref, 'hl': 高亮组, 'compact': 0/1}`,`fn` 无参数、
  返回字符串,返回空串即隐藏。
- 与其他动态段位一样转义,provider 无法注入 statusline 格式项;provider 抛异常
  时跳过该段位并走 `g:simpleline_debug`,不会破坏整条 statusline。
- 函数不存在时静默跳过,因此可以在 provider 插件加载之前就注册段位。
- `:SimpleLineHealth` 增加一行:已注册段位数与当前实际渲染的段位数。

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
