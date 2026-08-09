# Changelog

## Unreleased - 2026-08-08

### 修复:watch 之后再改 tabline 选项,want_files 不会跟着变

`want_files` 是随 `watch` 请求一起发过去的——主动推送不回答任何请求,所以没有
后面的请求能再带上一个新答案。可 `MaybeWatch()` 对已经 watch 的目录直接 return,
于是那个答案在 daemon 里被永久冻住,而被 watch 的目录又不再轮询,没有任何东西
会再碰它。两个方向都错:

- 启动时 `g:simpletabline_git_status = 0`,之后再打开——watch 仍然是
  `want_files:false`,每一条推送都带着 `files: {}`,把 `BufEnter`/`BufWritePost`
  刚收集到的逐文件标记又抹掉一次。
- 默认(标记开着)先协商成 `want_files:true`,之后关掉 `g:simpletabline_git_status`
  或 `g:simpleline_tabline`——daemon 还是每次推送都收集、序列化、发送最多 2000 个
  路径,而文档在 `doc/simpleline.txt` 和 README 里是无条件承诺"关掉之后请求不带
  `want_files`,daemon 什么都不收集"的。

现在客户端记住每个 watch 最后发出去的 `want_files`,发现和当前选项不一致就重发
一次 `watch`(daemon 的 `set_want_files()` 本来就认这条路径,会原地改掉并重新
grant,目录不会掉回轮询)。轮询计时器对被 watch 的目录本来直接 return,现在改为
先走一次这个检查——那是这种目录上唯一还会运行的东西,所以选项改了之后最多一个
`g:simpleline_git_interval` 就会生效,不必等某个 autocommand 恰好触发。

- 测试:新增 `tests/vim/git_watch_files.vim`。假 daemon 记录每一条请求,断言首次
  watch 带 `want_files:false`、打开标记后重发一次带 `true`、关掉之后由计时器再
  重发一次带 `false`、答案没变时一条都不发,以及 `g:simpleline_tabline` 这一侧
  同样算数;重发前后 `git_info` 请求数不变,证明目录没有掉回轮询。修改前这个
  文件有五处断言是红的。

### 修复:`tests/vim/git_watch.vim` 里"推送不进缓存"那条断言其实抓不到东西

那条断言是在 withdraw 之后对当前目录注入的,而 withdraw 已经把目录放回 250ms
轮询——`sleep 300m` 期间一条正常的 `git_info` 回复就把错误写进去的缓存项覆盖掉
了,所以把 `OnGitInfo()` 里的 path 关联整个删掉,测试照样是绿的。

- 新增一条断言:在目录**仍然被 watch** 的时候,让 daemon 推一条**邻近路径**的
  事件。那个路径没有人轮询,错误接受的结果会一直留在缓存里,断言直接看
  `:SimpleLineDebug` 的 `git_cache:` 那一行。删掉 path 关联时这条断言必红。
- withdraw 之后那条保留,但改成 300ms 内每 10ms 采样一次,而不是等尘埃落定再看
  一眼。

### 新增:daemon 可以主动上报 Git 变化,不必再按周期轮询

原来的刷新模型是每 2000ms 对当前目录跑一次 `git status`——不管有没有变化,
永远跑。大仓库上一次就是几百毫秒,所以 README 的排错一节只能建议用户把
`g:simpleline_git_interval` 设成 0;可是关掉轮询之后,在终端里 `git commit`
完,分支就再也不会自己更新了。

daemon 现在在握手时多广播一个 `watch` 能力,并且认识两个新请求:

- `{"type":"watch","id":N,"path":P,"want_files":B}` → 回
  `{"type":"watch","id":N,"path":P,"watching":true|false}`。
- `{"type":"unwatch","id":N,"path":P}` → 同样回一个 `watching:false`。

被 watch 的目录上,daemon 递归监听 worktree,把一阵文件事件按 200ms 静默窗口
(1s 硬上限)并成一次,只在状态真的变了的时候重新跑 `git status`,然后推一条
**没有人请求过**的 `git_info` 事件。客户端那边这个目录就完全不再进轮询了;
`BufEnter`/`BufWritePost`/`DirChanged`/`FocusGained` 仍然会主动问一次,所以不
存在"等下一个事件"的空窗。

拒绝 watch 是正常结果,拒绝之后那个目录还是走原来的轮询,行为和这个功能不
存在时一模一样。会拒绝的情况:路径不在仓库里;worktree 超过 4096 个目录
(递归 watch 是每个目录一个 inotify 描述符,这是全用户共享的有限资源,一个
monorepo 就能把别人的额度吃光);平台的 watcher 起不来;已经 watch 了 16 个
目录——这时会淘汰最老的那个,并且主动发一条 `watching:false` 告诉客户端它得
自己轮询回去。一次拒绝在 daemon 这条进程的生命周期内不再重试,否则"每个 tick
一个请求"这件本来要消掉的事就换个名字回来了。

- 主动推送是"每个回复都由 id 关联到它的请求"这条规矩唯一的例外:它们的 id
  是 0,改用 **path** 关联——而且只认这个客户端请求过、daemon 也确认过的目录。
  没有这一层,任何一条事件都能写任何一个缓存项,那正是 id 关联本来要防的事;
  把 `TakePending()` 的 id 检查放松掉则会连带把有请求的回复也一起放开。
- daemon 重启之后 watch 全部失效:`ClearPending()` 现在一并清掉 watch 状态,
  否则那些目录会既不被轮询、也不被上报,余下的整个 session 都是冻的。
- 新增 `g:simpleline_git_watch`(默认 1)。选项在能力之前判断,所以在变更通知
  不可靠的挂载点(某些网络盘、容器 bind mount)上可以只关掉 watch 而不必重新
  编译 daemon。
- `:SimpleLineHealth` 新增 `git watch: on/negotiated, N dir(s) watched`,并在
  `Git interval/timer:` 那行标出当前目录是 watched 还是 polled——"为什么不刷新"
  和"为什么一直在跑 git" 这两个问题都得有地方回答。
- 测试:Rust 侧 `a_granted_watch_pushes_an_unsolicited_update` 在真仓库上建一个
  文件,断言 `id:0` 的 `git_info` 会自己送到(含 `want_files` 随 watch 请求一起
  生效);另有拒绝非仓库路径、unwatch 必然应答、`watch` 能力为 false 时如实广播
  三个用例。Vim 侧新增 `tests/vim/git_watch.vim`:能力门(把
  `HasCap('watch')` 换成 `true` 会红)、被 watch 的目录不再轮询、withdraw 之后
  重新回到轮询、以及给一个没在 watch 的路径推事件不会进缓存。

### 修复:被标记的 buffer 两侧的 powerline 楔形颜色对不上

powerline 分隔符是一个楔形:字形用左边那一格的背景色画,底色是右边那一格的
背景色。所以决定它两个颜色的是**相邻的一对**,而不是"当前/非当前"。逐文件
Git 标记出现之后,一个非当前 buffer 也可能带着 DiffChange 的背景,但分隔符
还是只按 `is_cur` 从 TabLine 里取色——默认配置(`nerdfont=1`、
`separator='arrow'`、`simpletabline_git_status=1`)下,每一个有改动的 buffer
左右两侧都会露出一道颜色不接的缺口。

- 分隔符改为按相邻的两个高亮组取色。凡是牵涉到 Git 组的组合,现在按
  `SimpleTabX<左>To<右>`(如 `SimpleTabXFillToGitModified`)即时合成,名字由
  这一对确定性地推出来——渲染结果是被 memo 的,名字如果会变,缓存下来的串就
  会指向没人定义过的颜色。
- 不牵涉 Git 组的组合仍然用原来的 `SimpleTabFillToAct` / `SimpleTabActToInact`
  等具名组:用户手改过它们的颜色,不能被悄悄忽略。
- `:SimpleLineReload` 与 |ColorScheme| 会一起丢掉合成组和 tabline 的 memo——
  合成只发生在渲染时,memo 命中就不会重新推导。
- 新增 `tests/vim/tabline_sep.vim`:把 TabLine / TabLineSel / TabLineFill /
  DiffChange 设成四个可辨认的颜色,然后把渲染串里真正写出来的分隔符组的颜色
  读回来比对。修复前它是红的(楔形取的是 `#111111`,应该是 `#444444`)。


### 修复:关掉 tabline,daemon 照样在收集每个文件的路径

`g:simpleline_tabline = 0` 是文档里的选项:`Enable()` 不碰 `'tabline'`,于是
`simpleline#Tabline()` 永远不会被调用,`TablineGitMarks()` 也就永远不会跑。
但 `WantFileStatus()` 只看 `g:simpletabline_git_status`(默认 1),于是每次刷新
的 `git_info` 请求照样带着 `want_files:true`,daemon 照样把最多 2000 条路径
收集、序列化、发过来——一个没有任何人读的 payload。用会记账的假 daemon 复现:
`g:simpleline_tabline = 0` 时请求里依然是
`{"type":"git_info","want_files":true}`。

- 逐文件标记只有 tabline 一个消费者,所以 tabline 关着就不再请求路径。
  statusline 的 Git 段不受影响,分支照常查。
- `:SimpleLineHealth` 的 `git file status:` 第一段现在同时看这两个开关:
  前半句回答"有没有人会画标记",后半句回答"daemon 能不能给"。
- `tests/vim/git_files.vim` 新增一节:假 daemon 把收到的每一行请求写进日志,
  断言 tabline 关着时请求里没有 `want_files`、重新打开后又有。

### 测试:"能力协商"那一节其实不会红

那一节声称证明了"没有 `git-status` 能力的 daemon 从不会被要求路径",但它的假
daemon 是用空文件表构造的:`want_files` 分支回的是 `"files":{}`,和根本不带
路径的分支在效果上一模一样。把 `RequestGitDir()` 里的 `if WantFileStatus()`
整个删掉,全套测试依然全绿——实测如此。

现在这个 daemon 带着和有能力的那个一样的文件表(被问到就真的会答),并且把
收到的每一行请求记进日志,于是这个门是在它真正所在的地方——线上的请求——被
断言的。有能力的那条路径补上对称的断言:一个永远不开的门和一个永远不关的门
一样坏。


### 修复:`git_provider = 'simplegit'` 依然在跑第二遍 `git status`

这个选项的卖点就是"没有理由让两个 daemon 对同一个 worktree 各跑一遍
`git status`",文档也写着"完全忽略自己的 daemon"。但忽略的只是**回复**:
`GitStr()` 在读 payload 之前就把 `info` 清空了,而 `RequestGitDir()` 从来没
看过 provider,于是 daemon 照样被拉起来、照样每个 interval 发一次 `git_info`、
daemon 那边照样跑一遍 `git status --porcelain=v2 --branch --show-stash`,
结果整个丢掉。用一个会记账的假 daemon 复现:provider 为 `'simplegit'`、
interval 250ms,1.5s 内发了 7 次请求,每次都带 `want_files:true`;
`:SimpleLineHealth` 还说 "daemon running: yes"。选项想省掉的开销一分没省。

- `'simplegit'` 现在真的不发这个请求:没人要答案就不问,daemon 连起都不起。
- 唯一的例外是 tabline 的逐文件标记(`g:simpletabline_git_status`)——它直接
  读 daemon 的回复,是这个 provider 下仅剩的消费者,所以它开着的时候查询照旧,
  标记不会因为换了 provider 就没了。关掉它(或关掉 `g:simpleline_tabline`),
  worktree 就一次都不会被扫。
- `:SimpleLineHealth` 的 provider 行新增 `daemon query: on/off`,好回答
  "为什么 daemon 没在跑"。
- 文档、README 都改成说实话:`'auto'` 下 daemon 仍然要查(它是 fallback),
  真正省掉第二遍扫描的是 `'simplegit'`。
- 新增 `tests/vim/git_provider.vim`:假 daemon 每收到一次 `git_info` 就往日志
  追加一行,所以"worktree 到底被扫了没有"是数出来的事实而不是从渲染串推的。

### 性能:statusline 的每帧开销

`'statusline'` 是 `%!` 表达式,每次重绘都重建一遍——也就是每次光标移动。里面
有两段在做真活:

- 搜索计数每帧都调 `searchcount({maxcount: 99, timeout: 20})`。这是每个按键
  20ms 的预算,哪怕光标和模式一个都没动。现在按 "buffer + `b:changedtick` +
  `@/` + 光标位置 + `v:hlsearch` + `'ignorecase'` + `'smartcase'` + 两个新选项"
  做备忘,状态没变就是一次字符串比较。备忘键每次从头重建:漏掉一个输入应该
  表现为键不匹配,而不是悄悄复用旧值——计数陈旧比计数慢更糟。
- 诊断段每帧都要做一遍 `exists()` 探测加一次 provider 调用。现在按
  "buffer + `b:changedtick` + `b:coc_diagnostic_info` + provider tick" 做备忘。
  coc.nvim 把结果写在 buffer 变量里,读一次字典比调一次函数便宜得多,所以它
  的精确输入直接进键;ALE 与 vim-lsp 要调函数,只能靠它们自己的通知失效。

- 新增 `g:simpleline_search_maxcount`(默认 99,0 为不限)与
  `g:simpleline_search_timeout`(默认 20ms,0 为不设超时)。超出 maxcount 时
  显示 `1/99+` 而不是把 `maxcount + 1` 当成真实总数。
- 一次超时之后,该 buffer 上的该模式不再重试:一个病态模式退化一次,而不是
  每帧退化一次。换模式或换 buffer 会重新获得机会。
- 诊断结果是异步到达的,不会动 `b:changedtick`,所以新增监听三个 provider 的
  公开通知:`User CocDiagnosticChange`、`ALELintPost`、`ALEJobStarted`、
  `lsp_diagnostics_updated`。
- `:SimpleLineDebug` 报告两个缓存的命中率——tabline 备忘当初也是这样自证的。
- 新增 `tests/vim/render_cache.vim`:逐项验证"状态没变必须命中"与"每个输入
  变化必须未命中且值正确"。

### 修复:一次失败的 `git status` 会抹掉整个 Git 段

`if !output.status.success() { return Ok(GitStatus::default()) }` 分不清
"这儿不是仓库"和"这一次调用失败了"。并发的 `git gc` 在重写 ref、挂载点短暂
不可用、`safe.directory` 抱怨、子进程被 OOM killer 干掉——都落在这个分支里,
于是 `is_git: false` 被写进缓存,分支、operation、冲突指示一起消失,直到下一次
成功刷新为止。rebase 中途正好是最需要看到 operation 的时候。

现在只有"确实不在任何仓库里"才报空状态,其余情况回一个 error 事件;客户端的
`OnDaemonError()` 本来就不会动缓存,于是保留住已知good的数据。stderr 只取第一
行非空内容并截到 200 字符。判定被拆成纯函数 `interpret_status_failure()` 以便
单测——这台机器上 `/tmp/.git` 恰好存在,依赖真实目录游走的测试是不可靠的。

### 修复:daemon 崩溃重启后 Git 段永久不再更新

supervisor 会退避重启并重新握手,但"重发 Git 请求"是本插件自己的事。
`OnDaemonExit()` 把 `s_daemon_waiting_dirs` 清空,于是重启后
`FlushDaemonWaiters()` 在一个空字典上跑一遍,什么都不发。配合
`g:simpleline_git_interval = 0`(文档推荐的、用来避免在大仓库上轮询的模式),
重启是唯一还会触发刷新的事件,于是一个人开着一个窗口编辑一个文件,就会一直
看到崩溃之前的分支。

现在崩溃时在途的目录会重新排队,再加上当前目录;只在"确实要重启"且插件仍启用、
Git 仍开启时才排队,显式停止不会留下任何东西。新增
`tests/vim/daemon_restart.vim`:假 daemon 第一次应答完就自杀,第二次用另一个
分支名应答,断言在没有任何 BufEnter / 手动刷新 / 定时器的情况下分支会更新。

### 新增:tabline 按每个文件的 Git 状态上色

以前只知道"仓库里有 3 个文件改了",不知道"改的是不是我开着的这几个 buffer
里的哪一个"。而 daemon 其实一直在解析 porcelain-v2 的每一条路径记录,解析完
就把路径扔掉,只留计数。

- daemon:`GitStatus` 增加 `files`(仓库相对路径 → `M`/`A`/`D`/`U`)、
  `files_truncated` 与 `repo_root`。ordinary/rename/unmerged/untracked 四种
  记录的路径偏移量各不相同,按字段个数定位,不按空白切分——路径里可以有空格,
  切错了就是给错误的 buffer 上色,比不上色更糟。rename 取的是改名后的名字。
- 路径上限 2000 条,超出后置 `files_truncated`;200k 个脏文件不该把一次刷新
  变成几 MB 的 JSON 行。计数本身仍然覆盖整棵树,只有映射被截断。
- `git` 调用加 `-c core.quotePath=false`:否则非 ASCII 路径会被 git 转义成
  `"sub/b \321\201.txt"`,匹配 buffer 名前还得做一遍 C-unquote。中文文件名
  不是边角情况。仍然被引号包起来的路径(含控制字符)直接丢弃。
- `repo_root` 取的是持有 `.git` 标记的那个目录,普通仓库和 linked worktree
  都对;`git_dir` 在 linked worktree 里指向主仓库内部,不能当根用。
- 协议升到 2,并在握手回复里宣告 `capabilities: {"git-status": true}`。
  supervisor 的 `HasCap()` 机制本来就 vendored 在那儿没人用,现在用上了。
  客户端同时接受协议 1 和 2:二进制由 `install.sh` 重建,而 Vim 文件由插件
  管理器更新,只更新一边的人应该降级,而不是直接坏掉。
- `files` 只在请求里带 `want_files: true` 时才收集和序列化,而这个标志只在
  能力协商成功后才发——旧 daemon 从来不会被问,新客户端也不会白付线上开销。
- Vim:新增 `g:simpletabline_git_status`(默认 1)与
  `g:simpletabline_git_status_icons`(默认 `{}`),以及四个高亮组
  `SimpleTablineGitModified/GitAdded/GitDeleted/GitConflict`,分别 link 到
  `DiffChange`/`DiffAdd`/`DiffDelete`/`Error`。当前 buffer 保持
  `SimpleTablineActive`:你在哪个 buffer 比它的 Git 状态更重要。
- 标记进了 tabline 备忘键,图标也进了——它们是渲染输入,漏掉渲染输入正是这个
  插件反复犯的那类错。每个 buffer 的标记按 "仓库根 + buffer + 文件名" 缓存,
  只在 Git 数据真的变了才丢弃;根必须进键,因为切到另一个仓库的 buffer 会换
  一条缓存记录来作答,而这个过程不改动任何 payload。经过 symlink 打开的文件
  会退一步用 `resolve()` 再匹配。
- `:SimpleLineHealth` 增加一行:开关状态、能力是否协商成功、路径条数、是否
  截断、仓库根。"为什么没上色"是这个功能唯一的支持负担。

### 新增:接住 simplegit 的 statusline API

simplegit 现在发布 `b:simplegit_status_dict`(`{head, ahead, behind, added,
changed, removed}`)和 `simplegit#StatusDict()`。装了它的话,没有理由让两个
daemon 对同一个 worktree 各跑一遍 `git status`:

- 分支与 ahead/behind 改从 simplegit 拿;自己的 daemon 仍然是 fallback,
  并且继续负责文件计数、冲突、stash 和进行中的 operation——这些 simplegit
  不报。`head` 为空既可能是"不在仓库里"也可能是"还没解析出来",不构成证据,
  所以此时回落到 daemon,而不是把段位清空。
- 新增 `g:simpleline_git_provider`:`'auto'`(默认,优先 simplegit)、
  `'daemon'`(完全忽略 simplegit)、`'simplegit'`(完全忽略自己的 daemon)。
- 新增 `g:simpleline_show_hunks`(默认 0):把 simplegit 的"当前文件相对 index
  的增/改/删**行数**"渲染成独立段位 `SimpleLineHunks`。默认关闭是因为它长得
  跟 Git 段的 `[+n ~n -n]` 很像,而后者数的是 worktree 里的**文件数**——把
  一个当成另一个渲染会悄悄改变段位的含义,所以两者分开。
- 监听 `User SimpleGitUpdate` 重绘,交接过来的分支不用等下一次轮询。
- `:SimpleLineHealth` 报告 provider 选择、simplegit 是否可用、以及当前 buffer
  实际用的是哪一边。

### 修复:两个"改了也没用"的渲染选项

- `g:simpletabline_path_mode` 与 `g:simpleline_filetype_icons` 不在 tabline 的
  备忘键里,`Reload()` 也不清备忘,所以这两个选项在运行时根本改不动——连文档
  写的"改完视觉选项跑一次 `:SimpleLineReload`"都不管用。现在两者都进了备忘键;
  另外显示名缓存只按 "buffer 号 + 文件名" 作键,所以路径模式变化时也一并清掉,
  否则备忘重算了、名字还是旧模式下缩短的那个。
- `Enable()` 会重新推导分隔符与高亮,现在顺手作废 tabline 备忘,旧渲染不会
  跨过一次 `:SimpleLineReload` 活下来。
- `tests/vim/tabline_memo.vim` 补上这两项——这正是当初漏掉它们的那个测试缺口。

### 修复:`laststatus=3` 下的 compact 判定

`IsCompact()` 量的是 `winwidth(0)`,但 `laststatus=3` 时 Vim 只画一条横跨整个
屏幕的 statusline。160 列终端上两次 `:vsplit`,窗口宽约 53,于是文件类型、
编码、换行格式、`[+n ~n -n]`、ahead/behind 和 stash 全被藏起来,而实际上还空着
100 列。现在 `laststatus == 3` 时按 `&columns` 量。`Enable()` 只在 `laststatus`
低于 2 时才抬高它,所以用户设的 3 会保留下来,这个状态是能走到的。

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
