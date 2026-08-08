vim9script

# =============================================================
# Simpleline — lightweight statusline & tabline (Vim9 + Rust)
# =============================================================

# ----------- State -----------
# Protocol 1 is the original git_info event; protocol 2 adds the optional
# per-path `files` map, `files_truncated` and `repo_root`, all additive.  Both
# are accepted, because the daemon binary is rebuilt by ./install.sh while the
# Vim files arrive with the plugin manager — a user who updates one and not the
# other must keep a working Git segment, not lose it.
const SUPPORTED_PROTOCOLS: list<number> = [1, 2]

var s_enabled: bool = false
var s_next_id: number = 0
var s_git_timer: number = 0
var s_last_error: string = ''
var s_daemon_version: string = ''
var s_daemon_protocol: number = 0
var s_daemon_ready: bool = false
var s_daemon_incompatible: bool = false
var s_daemon_waiting_dirs: dict<bool> = {}

# Git info cache (per-directory)
var s_git_cache: dict<dict<any>> = {}
# Correlate asynchronous replies and keep at most one request per directory.
var s_git_pending: dict<string> = {}
var s_git_inflight: dict<number> = {}
var s_git_refresh_again: dict<bool> = {}

# UI state owned by the user, restored exactly when Simpleline is disabled.
var s_saved_global_statusline: string = ''
var s_saved_global_tabline: string = ''
var s_saved_showtabline: number = 1
var s_saved_laststatus: number = 1
var s_saved_window_statuslines: dict<string> = {}
var s_capturing_existing_windows: bool = false
var s_owns_statusline: bool = false
var s_owns_tabline: bool = false
var s_changed_laststatus: bool = false

# ----------- Nerd Font icon map -----------
var s_ft_icons: dict<string> = {
  vim: '', lua: '', python: '', ruby: '',
  go: '', rust: '', javascript: '', typescript: '',
  javascriptreact: '', typescriptreact: '',
  c: '', cpp: '', java: '', kotlin: '',
  sh: '', bash: '', zsh: '',
  html: '', css: '', scss: '',
  json: '', yaml: '', toml: '',
  markdown: '', text: '',
  haskell: '', julia: '',
  dart: '', swift: '', r: '󰟔',
  sql: '', docker: '', dockerfile: '',
  gitcommit: '', gitrebase: '',
  help: '󰋖', man: '󰋖',
  fugitive: '',
}

# ----------- Separator glyphs -----------
var s_sep_l: string = ''
var s_sep_r: string = ''
var s_subsep_l: string = ''
var s_subsep_r: string = ''

def SetupSeparators()
  var style = SeparatorStyle()
  if !ConfBool('simpleline_nerdfont', true) || style ==# 'plain'
    s_sep_l = ''
    s_sep_r = ''
    s_subsep_l = '|'
    s_subsep_r = '|'
  elseif style ==# 'round'
    s_sep_l = ''
    s_sep_r = ''
    s_subsep_l = ''
    s_subsep_r = ''
  else
    # arrow (powerline)
    s_sep_l = ''
    s_sep_r = ''
    s_subsep_l = ''
    s_subsep_r = ''
  endif
enddef

def ConfBool(name: string, default_val: bool): bool
  var value = get(g:, name, default_val)
  if type(value) == v:t_bool
    return value
  endif
  if type(value) == v:t_number
    return value != 0
  endif
  return default_val
enddef

def ConfNumber(name: string, default_val: number): number
  var value = get(g:, name, default_val)
  return type(value) == v:t_number ? value : default_val
enddef

def SeparatorStyle(): string
  var value = get(g:, 'simpleline_separator', 'arrow')
  if type(value) != v:t_string || index(['arrow', 'round', 'plain'], value) < 0
    return 'arrow'
  endif
  return value
enddef

# Text inserted into a statusline/tabline format must never be interpreted as
# another format item. strtrans() makes control bytes visible and doubling '%'
# is Vim's literal-percent escape.
def VisibleText(text: any): string
  var value = type(text) == v:t_string ? text : string(text)
  return strtrans(value)
enddef

def RenderEscape(text: any): string
  return substitute(VisibleText(text), '%', '%%', 'g')
enddef

def DebugLog(message: string)
  s_last_error = message
  if ConfBool('simpleline_debug', false)
    echomsg '[SimpleLine] ' .. message
  endif
enddef

def IsCompact(): bool
  var threshold = ConfNumber('simpleline_compact_width', 80)
  if threshold <= 0
    return false
  endif
  # 'laststatus' = 3 draws one statusline across the whole screen, so the width
  # of whichever window happens to be current says nothing about the space this
  # line has.  Measuring the window there hid metadata, Git counts and
  # ahead/behind on a 160-column global statusline as soon as it was split.
  var width = &laststatus == 3 ? &columns : winwidth(0)
  return width < threshold
enddef

# ----------- Mode display -----------
def ModeKind(): string
  var m = mode(1)
  if m =~# '^i'
    return 'insert'
  elseif m =~# '^R'
    return 'replace'
  elseif m ==# 'v' || m ==# 'V' || m ==# "\<C-V>"
    return 'visual'
  elseif m ==# 's' || m ==# 'S' || m ==# "\<C-S>"
    return 'select'
  elseif m =~# '^c' || m =~# '^r' || m ==# '!'
    return 'command'
  elseif m =~# '^t'
    return 'terminal'
  endif
  return 'normal'
enddef

# kind -> [label, body highlight, separator highlight]
var s_mode_specs: dict<list<string>> = {
  normal:   ['NORMAL',   'SimpleLineNormal',   'SimpleLineNormalSep'],
  insert:   ['INSERT',   'SimpleLineInsert',   'SimpleLineInsertSep'],
  replace:  ['REPLACE',  'SimpleLineReplace',  'SimpleLineReplaceSep'],
  visual:   ['VISUAL',   'SimpleLineVisual',   'SimpleLineVisualSep'],
  select:   ['SELECT',   'SimpleLineVisual',   'SimpleLineVisualSep'],
  command:  ['COMMAND',  'SimpleLineCommand',  'SimpleLineCommandSep'],
  terminal: ['TERMINAL', 'SimpleLineTerminal', 'SimpleLineTerminalSep'],
}

def ModeSpec(): list<string>
  return get(s_mode_specs, ModeKind(), s_mode_specs.normal)
enddef

# ----------- Filetype icon -----------
def FtIcon(): string
  if !ConfBool('simpleline_nerdfont', true)
    return ''
  endif
  var ft = &filetype
  var custom = get(g:, 'simpleline_filetype_icons', {})
  if type(custom) == v:t_dict && has_key(custom, ft) && type(custom[ft]) == v:t_string
    return custom[ft] ==# '' ? '' : custom[ft] .. ' '
  endif
  if has_key(s_ft_icons, ft)
    return s_ft_icons[ft] .. ' '
  endif
  return ''
enddef

def BufFtIcon(bn: number): string
  if !ConfBool('simpleline_nerdfont', true)
    return ''
  endif
  var ft = getbufvar(bn, '&filetype')
  if type(ft) != v:t_string || ft ==# ''
    return ''
  endif
  var custom = get(g:, 'simpleline_filetype_icons', {})
  if type(custom) == v:t_dict && has_key(custom, ft) && type(custom[ft]) == v:t_string
    return custom[ft] ==# '' ? '' : custom[ft] .. ' '
  endif
  if has_key(s_ft_icons, ft)
    return s_ft_icons[ft] .. ' '
  endif
  return ''
enddef

# ----------- Git info -----------
def CurrentGitDir(): string
  var dir = expand('%:p:h')
  if dir ==# ''
    dir = getcwd()
  endif
  var normalized = simplify(fnamemodify(dir, ':p'))
  if normalized !=# '/' && normalized !~? '^[A-Za-z]:[\\/]$'
    normalized = substitute(normalized, '[\\/]\+$', '', '')
  endif
  return normalized
enddef

# ----------- simplegit hand-off -----------
# simplegit publishes a per-buffer {head, ahead, behind, added, changed,
# removed} dictionary — b:simplegit_status_dict, plus simplegit#StatusDict()
# for the same data — kept fresh by its own daemon from the hunks that drive
# its sign column.  Where it is installed there is no reason for two daemons to
# run `git status` over the same worktree, so the repository facts come from it
# and Simpleline's own query stays as the fallback for everyone else.
#
# Only the repository-level facts are taken.  simplegit's added/changed/removed
# are *line* counts for one buffer against the index; Simpleline's [+n ~n -n]
# are *file* counts for the whole worktree.  Rendering one as the other would
# silently change what the segment means, so the file counts keep coming from
# the daemon and the line counts get their own opt-in segment.
def GitProvider(): string
  var value = get(g:, 'simpleline_git_provider', 'auto')
  if type(value) != v:t_string || index(['auto', 'daemon', 'simplegit'], value) < 0
    return 'auto'
  endif
  return value
enddef

def NonNegative(entry: dict<any>, name: string): number
  var value = get(entry, name, 0)
  return type(value) == v:t_number && value > 0 ? value : 0
enddef

# {} when simplegit is absent, silent, or has nothing to say about this buffer.
def SimpleGitStatus(): dict<any>
  if GitProvider() ==# 'daemon'
    return {}
  endif
  # The buffer variable is simplegit's documented consumer contract and costs
  # one lookup; the accessor is the fallback for a buffer it has not published
  # yet.  Neither dispatches nor blocks, so both are safe inside a redraw.
  # exists() does not source an autoload script, so the accessor becomes
  # visible only once simplegit has run — which is also the only time it has
  # anything to report, and until then the buffer variable is absent too.
  var dict: any = getbufvar(bufnr('%'), 'simplegit_status_dict', {})
  if type(dict) != v:t_dict || empty(dict)
    if !exists('*simplegit#StatusDict')
      return {}
    endif
    try
      dict = simplegit#StatusDict()
    catch
      DebugLog('simplegit#StatusDict() threw: ' .. v:exception)
      return {}
    endtry
    if type(dict) != v:t_dict
      return {}
    endif
  endif
  var head = get(dict, 'head', '')
  if type(head) != v:t_string || head ==# ''
    # simplegit reports '' both for "no repository" and for "not resolved
    # yet", so an empty head is no evidence at all: fall back to the daemon.
    return {}
  endif
  return {
    branch: head,
    ahead: NonNegative(dict, 'ahead'),
    behind: NonNegative(dict, 'behind'),
    added: NonNegative(dict, 'added'),
    changed: NonNegative(dict, 'changed'),
    removed: NonNegative(dict, 'removed'),
  }
enddef

# `+12 ~3 -1` for the current file: added/changed/removed *lines* against the
# index, which is the one thing simplegit knows and the daemon does not.
def HunkStr(): string
  if !ConfBool('simpleline_show_hunks', false) || IsCompact()
    return ''
  endif
  var sg = SimpleGitStatus()
  if empty(sg)
    return ''
  endif
  var parts: list<string> = []
  for [key, marker] in [['added', '+'], ['changed', '~'], ['removed', '-']]
    if sg[key] > 0
      parts->add(marker .. sg[key])
    endif
  endfor
  return join(parts, ' ')
enddef

def GitStr(): string
  if !ConfBool('simpleline_git_enabled', true)
    return ''
  endif
  var dir = CurrentGitDir()
  var info = get(s_git_cache, dir, {})
  var has_daemon_info = !empty(info) && get(info, 'is_git', false)
  if GitProvider() ==# 'simplegit'
    info = {}
    has_daemon_info = false
  endif
  var sg = SimpleGitStatus()
  # Branch and ahead/behind describe the repository, so whichever source knows
  # the branch answers for both.  Everything after them still comes from the
  # daemon: it is the only side that counts files, conflicts and stashes.
  var branch = empty(sg)
        \ ? (has_daemon_info ? get(info, 'branch', '') : '')
        \ : sg.branch
  if branch ==# ''
    return ''
  endif
  var parts: list<string> = []
  var icon = ConfBool('simpleline_nerdfont', true) ? ' ' : ''
  parts->add(icon .. RenderEscape(branch))
  var operation = get(info, 'operation', '')
  if ConfBool('simpleline_git_show_operation', true)
        \ && type(operation) == v:t_string && operation !=# ''
    # Keep repository operations visible in compact windows: losing sight of
    # an in-progress rebase or merge is much costlier than one short segment.
    parts->add(RenderEscape(operation))
  endif
  var counter = empty(sg) ? info : sg
  var ahead = IsCompact() ? 0 : get(counter, 'ahead', 0)
  var behind = IsCompact() ? 0 : get(counter, 'behind', 0)
  if ahead > 0
    parts->add('+' .. ahead)
  endif
  if behind > 0
    parts->add('-' .. behind)
  endif
  var show_status = !IsCompact() && ConfBool('simpleline_git_show_status', true)
  var added = show_status ? get(info, 'added', 0) : 0
  var modified = show_status ? get(info, 'modified', 0) : 0
  var deleted = show_status ? get(info, 'deleted', 0) : 0
  var stats: list<string> = []
  if added > 0
    stats->add('+' .. added)
  endif
  if modified > 0
    stats->add('~' .. modified)
  endif
  if deleted > 0
    stats->add('-' .. deleted)
  endif
  if len(stats) > 0
    parts->add('[' .. join(stats, ' ') .. ']')
  endif
  # Conflicts are always worth attention; stash count follows the detailed
  # metadata and disappears in compact windows.
  var conflicts = get(info, 'conflicts', 0)
  if conflicts > 0
    parts->add('!' .. conflicts)
  endif
  var stash = IsCompact() ? 0 : get(info, 'stash', 0)
  if stash > 0
    parts->add('$' .. stash)
  endif
  return join(parts, ' ')
enddef

# ----------- User segments -----------
# g:simpleline_custom_left / g:simpleline_custom_right =
#   [{fn: 'MyStatus', hl: 'SimpleLineRight', compact: true}]
# `fn` is a function name or Funcref taking no argument and returning a
# string; an empty return hides the segment.  The text is escaped like every
# other dynamic segment, so a provider can never inject format items, and a
# provider that throws is skipped instead of breaking the statusline.
def DictBool(entry: dict<any>, name: string, default_val: bool): bool
  var value = get(entry, name, default_val)
  if type(value) == v:t_bool
    return value
  endif
  if type(value) == v:t_number
    return value != 0
  endif
  return default_val
enddef

def CustomSegments(config_name: string, default_hl: string): list<dict<string>>
  var entries = get(g:, config_name, [])
  if type(entries) != v:t_list
    DebugLog(config_name .. ' must be a list')
    return []
  endif

  var compact = IsCompact()
  var rendered: list<dict<string>> = []
  for entry in entries
    if type(entry) != v:t_dict
      DebugLog('custom segment must be a dict')
      continue
    endif
    if compact && !DictBool(entry, 'compact', true)
      continue
    endif

    var fn = get(entry, 'fn', '')
    var Target: any = fn
    if type(fn) == v:t_string
      # A bare name resolves script-locally inside this Vim9 script, while
      # user providers live in the global namespace.
      if fn !=# '' && !exists('*' .. fn) && exists('*g:' .. fn)
        Target = 'g:' .. fn
      elseif fn ==# '' || !exists('*' .. fn)
        # A provider whose plugin is not loaded is silently absent, not an
        # error.
        continue
      endif
    elseif type(fn) == v:t_func
      # function('Name') stores only the bare name, which has the same
      # script-local resolution problem once it is called from here.
      var fn_name = get(fn, 'name', '')
      if fn_name =~# '^\a\w*$'
            \ && !exists('*' .. fn_name)
            \ && exists('*g:' .. fn_name)
        var fn_args = get(fn, 'args', [])
        var fn_dict = get(fn, 'dict', {})
        Target = empty(fn_dict)
              \ ? function('g:' .. fn_name, fn_args)
              \ : function('g:' .. fn_name, fn_args, fn_dict)
      endif
    else
      DebugLog('custom segment fn must be a function name or Funcref')
      continue
    endif

    var text: any
    try
      text = call(Target, [])
    catch
      DebugLog('custom segment failed: ' .. v:exception)
      continue
    endtry
    if type(text) != v:t_string || text ==# ''
      continue
    endif

    var hl = get(entry, 'hl', default_hl)
    if type(hl) != v:t_string || hl !~# '^\w\+$'
      hl = default_hl
    endif
    rendered->add({hl: hl, text: RenderEscape(text)})
  endfor
  return rendered
enddef

# Resolve the window whose statusline Vim is evaluating. A top-level `%!`
# expression runs in the current window, even when it is building an inactive
# window's line; Vim exposes that real target through g:statusline_winid.
def StatusTarget(): dict<any>
  var configured = get(g:, 'statusline_winid', win_getid())
  var winid = type(configured) == v:t_number ? configured : win_getid()
  var tabwin = win_id2tabwin(winid)
  if len(tabwin) < 2 || tabwin[0] == 0 || tabwin[1] == 0
    winid = win_getid()
    tabwin = win_id2tabwin(winid)
  endif

  var windows = getwininfo(winid)
  var bn = empty(windows) ? bufnr() : get(windows[0], 'bufnr', bufnr())
  var buffers = getbufinfo(bn)
  var name = empty(buffers) ? bufname(bn) : get(buffers[0], 'name', '')
  var cwd = getcwd()
  try
    cwd = getcwd(tabwin[1], tabwin[0])
  catch
    # A window can disappear between statusline invalidation and redraw. The
    # current cwd is a safe last-resort display root for that single frame.
  endtry
  return {bufnr: bn, name: name, cwd: cwd}
enddef

# Return the statusline filename item. `native` deliberately stays as Vim's
# own %f item for full backward compatibility. Explicit path modes are literal
# text and therefore pass through RenderEscape(); unnamed and special buffers
# keep Vim's useful built-in labels instead of becoming filesystem paths.
def StatusFilename(): string
  var configured = get(g:, 'simpleline_filename_mode', 'native')
  var mode = type(configured) == v:t_string ? configured : 'native'
  if index(['native', 'tail', 'rel', 'abbr', 'abs'], mode) < 0
    mode = 'native'
  endif
  if mode ==# 'native'
    return '%f'
  endif
  var target = StatusTarget()
  if getbufvar(target.bufnr, '&buftype') !=# ''
    return '%f'
  endif
  var name = target.name
  if name ==# ''
    return '[No Name]'
  endif
  if mode ==# 'tail'
    return RenderEscape(fnamemodify(name, ':t'))
  endif
  # getbufinfo().name is already absolute for named file buffers. Keeping that
  # value avoids resolving a relative name against the active window's cwd.
  var absolute = name
  if mode ==# 'abs'
    return RenderEscape(absolute)
  endif

  # GetRoot() is a pure accessor over SimpleTree's already-known state; this
  # path never queries Git or evaluates a user status provider. Without an
  # open tree, the target window's cwd intentionally observes its local :lcd.
  var root = TreeRoot()
  if root ==# ''
    root = target.cwd
  endif
  var relative = root ==# '' ? '' : RelToRoot(absolute, root)
  if relative ==# ''
    return RenderEscape(fnamemodify(name, ':t'))
  endif
  return RenderEscape(mode ==# 'rel' ? relative : AbbrevRelPath(relative))
enddef

# ----------- Extra statusline segments -----------
def RecordingStr(): string
  if !ConfBool('simpleline_show_recording', true) || !exists('*reg_recording')
    return ''
  endif
  var reg = reg_recording()
  return reg ==# '' ? '' : 'REC @' .. reg
enddef

# ----------- Search count -----------
# 'statusline' is a %! expression, so this runs on every redraw — that is, on
# every cursor movement.  searchcount() re-walks the buffer, and its timeout
# was being spent per keystroke even when nothing it reads had moved.  The memo
# is keyed on the complete input set, and rebuilt from scratch on every call:
# a stale count is worse than a slow one, so a forgotten input must show up as
# a wrong key, never as a silently reused value.
var s_search_key: string = ''
var s_search_value: string = ''
var s_search_hits: number = 0
var s_search_misses: number = 0
# A pattern that blows the timeout once will blow it again on the next frame,
# which is how one pathological search makes the whole editor feel broken.
# Remember the (buffer, pattern) pairs that timed out and stop asking; a new
# pattern or a new buffer gets a fresh chance.
var s_search_slow: dict<bool> = {}

def SearchStr(): string
  if !ConfBool('simpleline_show_search', true) || !v:hlsearch
        \ || !exists('*searchcount')
    return ''
  endif
  var bufnum = bufnr('%')
  var pattern = @/
  var maxcount = ConfNumber('simpleline_search_maxcount', 99)
  var timeout = ConfNumber('simpleline_search_timeout', 20)
  var key = join([
    string(bufnum),
    pattern,
    string(line('.')),
    string(col('.')),
    string(getbufvar(bufnum, 'changedtick', 0)),
    string(v:hlsearch),
    string(&ignorecase),
    string(&smartcase),
    string(maxcount),
    string(timeout),
  ], "\x01")
  if key ==# s_search_key
    s_search_hits += 1
    return s_search_value
  endif
  s_search_misses += 1
  s_search_key = key
  s_search_value = ''

  var slow_key = bufnum .. "\x01" .. pattern
  if has_key(s_search_slow, slow_key)
    return ''
  endif

  var result: dict<any>
  try
    result = searchcount({maxcount: maxcount, timeout: timeout})
  catch
    return ''
  endtry
  var incomplete = get(result, 'incomplete', 0)
  if incomplete == 1
    # Timed out: the count is unusable anyway, so stop paying for it.
    if len(s_search_slow) >= 64
      s_search_slow = {}
    endif
    s_search_slow[slow_key] = true
    DebugLog('searchcount() timed out after ' .. timeout
          \ .. 'ms; the count is disabled for this pattern')
    return ''
  endif
  var total = get(result, 'total', 0)
  if type(total) != v:t_number || total <= 0
    return ''
  endif
  var current = get(result, 'current', 0)
  # An exceeded maxcount reports total as maxcount + 1; say so rather than
  # pretending the inflated number is a count.
  var total_txt = incomplete == 2 && maxcount > 0
        \ ? maxcount .. '+' : string(total)
  s_search_value = current .. '/' .. total_txt
  return s_search_value
enddef

# ----------- Diagnostics -----------
def DiagCount(value: any): number
  return type(value) == v:t_number && value > 0 ? value : 0
enddef

# Diagnostics from the first detected provider: coc.nvim, ALE, then vim-lsp.
# The provider that answered is returned with its counts so that the memo and
# :SimpleLineHealth can never disagree about who is being asked.
def DiagnosticProbe(): dict<any>
  var coc = getbufvar(bufnr('%'), 'coc_diagnostic_info', {})
  if type(coc) == v:t_dict && !empty(coc)
    return {provider: 'coc', counts: {
      error: DiagCount(get(coc, 'error', 0)),
      warning: DiagCount(get(coc, 'warning', 0)),
    }}
  endif
  if exists('*ale#statusline#Count')
    try
      var counts = ale#statusline#Count(bufnr('%'))
      return {provider: 'ale', counts: {
        error: DiagCount(get(counts, 'error', 0)) + DiagCount(get(counts, 'style_error', 0)),
        warning: DiagCount(get(counts, 'warning', 0)) + DiagCount(get(counts, 'style_warning', 0)),
      }}
    catch
    endtry
  endif
  if exists('*lsp#get_buffer_diagnostics_counts')
    try
      var counts = lsp#get_buffer_diagnostics_counts()
      return {provider: 'vim-lsp', counts: {
        error: DiagCount(get(counts, 'error', 0)),
        warning: DiagCount(get(counts, 'warning', 0)),
      }}
    catch
    endtry
  endif
  return {provider: 'none', counts: {error: 0, warning: 0}}
enddef

# The probe above ran on every redraw: an exists() sweep plus a provider call
# per cursor movement.  Its result only changes when the buffer changes or when
# the provider says so, so memoize on exactly that.
var s_diag_provider: string = 'none'
var s_diag_tick: number = 0
var s_diag_key: string = ''
var s_diag_value: dict<number> = {error: 0, warning: 0}
var s_diag_hits: number = 0
var s_diag_misses: number = 0

def DiagnosticCounts(): dict<number>
  var bufnum = bufnr('%')
  # coc.nvim publishes into a buffer variable rather than through a function,
  # so its exact input is one dictionary lookup — cheap enough to keep in the
  # key, which makes the memo exact for the most common provider.  ALE and
  # vim-lsp cost a function call, so they invalidate through their events.
  var key = printf('%d:%d:%d:%s', bufnum,
        \ getbufvar(bufnum, 'changedtick', 0), s_diag_tick,
        \ string(getbufvar(bufnum, 'coc_diagnostic_info', {})))
  if key ==# s_diag_key
    s_diag_hits += 1
    return s_diag_value
  endif
  s_diag_misses += 1
  s_diag_key = key
  var probe = DiagnosticProbe()
  s_diag_provider = probe.provider
  s_diag_value = probe.counts
  return s_diag_value
enddef

def DiagProviderName(): string
  return DiagnosticProbe().provider
enddef

# Providers publish results asynchronously, without touching b:changedtick, so
# nothing else in the memo key moves when new diagnostics arrive.  Their
# documented notifications are wired to this in the SimpleLineAutoUpdate group.
export def RefreshDiagnostics()
  s_diag_tick += 1
  # Providers call this from their own autocommands, which can fire in states
  # where a redraw is refused; the invalidation above is the part that matters.
  try
    redrawstatus
  catch
  endtry
enddef

def ResetRenderCaches()
  s_search_key = ''
  s_search_value = ''
  s_search_slow = {}
  s_search_hits = 0
  s_search_misses = 0
  s_diag_key = ''
  s_diag_value = {error: 0, warning: 0}
  s_diag_provider = 'none'
  s_diag_hits = 0
  s_diag_misses = 0
enddef

# Hit counts for the two per-redraw memos, so the win is observable rather
# than asserted; :SimpleLineDebug renders them.
export def CacheStats(): dict<number>
  return {
    search_hits: s_search_hits,
    search_misses: s_search_misses,
    diag_hits: s_diag_hits,
    diag_misses: s_diag_misses,
  }
enddef

# ----------- Highlight groups -----------
def SetupHighlights()
  # Mode colors
  highlight default SimpleLineNormal    guibg=#61afef guifg=#282c34 gui=bold ctermfg=235 ctermbg=75 cterm=bold
  highlight default SimpleLineInsert    guibg=#98c379 guifg=#282c34 gui=bold ctermfg=235 ctermbg=114 cterm=bold
  highlight default SimpleLineVisual    guibg=#c678dd guifg=#282c34 gui=bold ctermfg=235 ctermbg=176 cterm=bold
  highlight default SimpleLineReplace   guibg=#e06c75 guifg=#282c34 gui=bold ctermfg=235 ctermbg=168 cterm=bold
  highlight default SimpleLineCommand   guibg=#e5c07b guifg=#282c34 gui=bold ctermfg=235 ctermbg=180 cterm=bold
  highlight default SimpleLineTerminal  guibg=#56b6c2 guifg=#282c34 gui=bold ctermfg=235 ctermbg=73 cterm=bold

  # Separator (mode -> mid): fg = mode bg, bg = mid bg
  highlight default SimpleLineNormalSep   guifg=#61afef guibg=#3e4452 ctermfg=75 ctermbg=238
  highlight default SimpleLineInsertSep   guifg=#98c379 guibg=#3e4452 ctermfg=114 ctermbg=238
  highlight default SimpleLineVisualSep   guifg=#c678dd guibg=#3e4452 ctermfg=176 ctermbg=238
  highlight default SimpleLineReplaceSep  guifg=#e06c75 guibg=#3e4452 ctermfg=168 ctermbg=238
  highlight default SimpleLineCommandSep  guifg=#e5c07b guibg=#3e4452 ctermfg=180 ctermbg=238
  highlight default SimpleLineTerminalSep guifg=#56b6c2 guibg=#3e4452 ctermfg=73 ctermbg=238

  # Middle section
  highlight default SimpleLineMid       guibg=#3e4452 guifg=#abb2bf ctermfg=145 ctermbg=238
  highlight default SimpleLineMidSep    guifg=#3e4452 guibg=#282c34 ctermfg=238 ctermbg=235

  # Right section (file info)
  highlight default SimpleLineRight     guibg=#3e4452 guifg=#abb2bf ctermfg=145 ctermbg=238
  highlight default SimpleLineRightSep  guifg=#3e4452 guibg=#282c34 ctermfg=238 ctermbg=235

  # Position section
  highlight default SimpleLinePos       guibg=#61afef guifg=#282c34 gui=bold ctermfg=235 ctermbg=75 cterm=bold
  highlight default SimpleLinePosSep    guifg=#61afef guibg=#3e4452 ctermfg=75 ctermbg=238

  # Git
  highlight default SimpleLineGit       guibg=#3e4452 guifg=#e5c07b ctermfg=180 ctermbg=238

  # Per-file hunk counts from simplegit (added/changed/removed lines)
  highlight default SimpleLineHunks     guibg=#3e4452 guifg=#98c379 ctermfg=114 ctermbg=238

  # LSP (simplecc)
  highlight default SimpleLineLSP       guibg=#3e4452 guifg=#56b6c2 ctermfg=73 ctermbg=238

  # Macro recording indicator
  highlight default SimpleLineRec       guibg=#e06c75 guifg=#282c34 gui=bold ctermfg=235 ctermbg=168 cterm=bold

  # Diagnostics
  highlight default SimpleLineDiagError guibg=#3e4452 guifg=#e06c75 ctermfg=168 ctermbg=238
  highlight default SimpleLineDiagWarn  guibg=#3e4452 guifg=#e5c07b ctermfg=180 ctermbg=238

  # Search count
  highlight default SimpleLineSearch    guibg=#3e4452 guifg=#98c379 ctermfg=114 ctermbg=238

  # Inactive
  highlight default SimpleLineInactive  guibg=#282c34 guifg=#5c6370 ctermfg=241 ctermbg=235

  # Tabline (uses default links, actual colors set by SimpleTablineApplyHL)
enddef

# =============================================================
# Statusline builder
# =============================================================
export def ActiveStatusline(): string
  var s = ''
  var compact = IsCompact()

  # Mode
  var mode_spec = ModeSpec()
  s ..= '%#' .. mode_spec[1] .. '# ' .. mode_spec[0] .. ' '
  s ..= '%#' .. mode_spec[2] .. '#' .. s_sep_l

  # Macro recording indicator
  var recording = RecordingStr()
  if recording !=# ''
    s ..= '%#SimpleLineRec# ' .. RenderEscape(recording) .. ' '
  endif

  # Git info
  var git = GitStr()
  if git !=# ''
    s ..= '%#SimpleLineGit# ' .. git .. ' '
  endif

  # Per-file hunk counts, when simplegit is there to provide them.  They sit in
  # their own group next to the repository segment precisely because they count
  # something else: lines in this file, not files in the worktree.
  var hunks = HunkStr()
  if hunks !=# ''
    s ..= '%#SimpleLineHunks# ' .. hunks .. ' '
  endif

  # Diagnostics (coc.nvim / ALE / vim-lsp)
  if ConfBool('simpleline_show_diagnostics', true)
    var diag = DiagnosticCounts()
    if diag.error > 0
      s ..= '%#SimpleLineDiagError# E:' .. diag.error .. ' '
    endif
    if diag.warning > 0
      s ..= '%#SimpleLineDiagWarn# W:' .. diag.warning .. ' '
    endif
  endif

  # User-provided left segments sit beside Git/diagnostics, before the
  # filename truncation point.  This makes project/task state visible without
  # competing with file metadata and position on the right.
  for segment in CustomSegments('simpleline_custom_left', 'SimpleLineMid')
    s ..= '%#' .. segment.hl .. '# ' .. segment.text .. ' '
  endfor

  # Middle: filename. %< marks the truncation point so a long path is shortened
  # here instead of Vim eating the mode/git segments from the left.
  s ..= '%#SimpleLineMid#'
  s ..= ' ' .. RenderEscape(FtIcon()) .. '%<' .. StatusFilename()
  s ..= '%( %m%r%)'

  # Separator to background
  s ..= '%#SimpleLineMidSep#' .. s_sep_l

  # Right align
  s ..= '%='

  # Search count while highlighting is active
  var search = SearchStr()
  if search !=# ''
    s ..= '%#SimpleLineSearch# ' .. search .. ' '
  endif

  # LSP status (simplecc compatibility provider)
  var lsp = get(g:, 'simplecc_status', '')
  if ConfBool('simpleline_show_lsp', true) && type(lsp) == v:t_string && lsp !=# ''
    s ..= '%#SimpleLineLSP# ' .. RenderEscape(lsp) .. ' '
  endif

  # User-provided segments
  for segment in CustomSegments('simpleline_custom_right', 'SimpleLineRight')
    s ..= '%#' .. segment.hl .. '# ' .. segment.text .. ' '
  endfor

  # Right metadata progressively disappears in compact windows.
  var metadata: list<string> = []
  if !compact && ConfBool('simpleline_show_filetype', true)
    metadata->add('%{&filetype ==# "" ? "-" : &filetype}')
  endif
  if !compact && ConfBool('simpleline_show_encoding', true)
    metadata->add('%{&fileencoding !=# "" ? &fileencoding : &encoding}')
  endif
  if !compact && ConfBool('simpleline_show_fileformat', true)
    metadata->add('%{&fileformat}')
  endif
  if !empty(metadata)
    s ..= '%#SimpleLineRightSep#' .. s_sep_r
    s ..= '%#SimpleLineRight# ' .. join(metadata, ' ' .. s_subsep_r .. ' ') .. ' '
  endif

  # Position
  if ConfBool('simpleline_show_position', true)
    s ..= '%#SimpleLinePosSep#' .. s_sep_r
    s ..= '%#SimpleLinePos# %l:%c %p%% '
  endif

  return s
enddef

export def InactiveStatusline(): string
  var value = '%#SimpleLineInactive# %<' .. StatusFilename() .. '%( %m%r%) %='
  if ConfBool('simpleline_show_position', true)
    value ..= ' %l:%c '
  endif
  return value
enddef

# =============================================================
# Tabline (merged from simpletabline)
# =============================================================

# ----------- Tabline state -----------
var s_pick_mode: bool = false
var s_pick_chars: list<string> = []
var s_char_to_bufnr: dict<number> = {}
var s_idx_to_buf: dict<number> = {}
var s_buf_to_idx: dict<number> = {}
var s_tab_render_root: string = ''
var s_tab_name_mode: string = ''
var s_tab_name_cache: dict<string> = {}

# ----------- Per-file Git status -----------
# The daemon reports which paths in the worktree are changed; this turns that
# into "which of the open buffers is one of them".  Resolving a buffer path
# against the repository root costs a path normalization, so the answer is
# cached and thrown away only when the Git payload actually moves — the
# tabline is rebuilt on every redraw, and this feeds its memo key.
var s_git_tick: number = 0
var s_git_mark_tick: number = -1
var s_git_mark_cache: dict<string> = {}
var s_git_mark_groups: dict<string> = {
  M: 'SimpleTablineGitModified',
  A: 'SimpleTablineGitAdded',
  D: 'SimpleTablineGitDeleted',
  U: 'SimpleTablineGitConflict',
}

# ----------- Tabline helpers -----------
def TabConfBool(name: string, default_val: bool): bool
  return ConfBool(name, default_val)
enddef

def TabConfString(name: string, default_val: string): string
  var value = get(g:, name, default_val)
  return type(value) == v:t_string ? value : default_val
enddef

def SupDigit(s: string): string
  if s ==# ''
    return ''
  endif
  var m: dict<string> = {
    '0': '𝟎', '1': '𝟏', '2': '𝟐', '3': '𝟑', '4': '𝟒',
    '5': '𝟓', '6': '𝟔', '7': '𝟕', '8': '𝟖', '9': '𝟗'
  }
  var out = ''
  for ch in split(s, '\zs')
    out ..= get(m, ch, ch)
  endfor
  return out
enddef

def TreeRoot(): string
  var r = ''
  if exists('*simpletree#GetRoot')
    try
      r = simpletree#GetRoot()
    catch
    endtry
  endif
  return type(r) == v:t_string ? r : ''
enddef

def RefreshTabRenderRoot()
  var root = TreeRoot()
  if root ==# '' && ConfBool('simpletabline_fallback_cwd_root', true)
    root = getcwd()
  endif
  # Only drop the cached display names when something they were computed from
  # actually moved.  Clearing unconditionally made the cache dead weight —
  # 'tabline' is re-evaluated on every redraw, so every entry was thrown away
  # and recomputed before it could ever be reused.  The path mode belongs here
  # too: the cache is keyed on buffer and file name only, so without this a
  # mode change kept returning labels shortened under the previous mode.
  var mode = TabConfString('simpletabline_path_mode', 'abbr')
  if root !=# s_tab_render_root || mode !=# s_tab_name_mode
    s_tab_render_root = root
    s_tab_name_mode = mode
    s_tab_name_cache = {}
  endif
enddef

def IsWin(): bool
  return has('win32') || has('win64') || has('win95') || has('win32unix')
enddef

def NormPath(p: string): string
  var ap = fnamemodify(p, ':p')
  ap = simplify(substitute(ap, '\\', '/', 'g'))
  var q = substitute(ap, '/\+$', '', '')
  if q ==# ''
    return '/'
  endif
  if q =~? '^[A-Za-z]:$'
    return q .. '/'
  endif
  return q
enddef

def RelToRoot(abs: string, root: string): string
  if abs ==# '' || root ==# ''
    return ''
  endif
  var A = NormPath(abs)
  var R = NormPath(root)
  var aCmp = IsWin() ? tolower(A) : A
  var rCmp = IsWin() ? tolower(R) : R
  if aCmp ==# rCmp
    return fnamemodify(A, ':t')
  endif
  var rprefix = (R ==# '/' || R =~? '^[A-Za-z]:/$') ? R : (R .. '/')
  var rprefixCmp = IsWin() ? tolower(rprefix) : rprefix
  if stridx(aCmp, rprefixCmp) == 0
    return strpart(A, strlen(rprefix))
  endif
  return ''
enddef

def AbbrevRelPath(rel: string): string
  if rel ==# ''
    return rel
  endif
  if exists('*pathshorten')
    try
      return pathshorten(rel)
    catch
    endtry
  endif
  var parts = split(rel, '/')
  if len(parts) <= 1
    return rel
  endif
  var out: list<string> = []
  var i = 0
  while i < len(parts) - 1
    var seg = parts[i]
    if seg ==# '' || seg ==# '.'
      out->add(seg)
    else
      out->add(strcharpart(seg, 0, 1))
    endif
    i += 1
  endwhile
  out->add(parts[-1])
  return join(out, '/')
enddef

def ResolveGitMark(name: string, root: string, files: dict<any>): string
  var rel = RelToRoot(name, root)
  if rel ==# ''
    # The daemon canonicalizes the worktree root, so a buffer opened through a
    # symlinked path only lines up after resolve().  That is a syscall, so it
    # is the fallback rather than the rule.
    rel = RelToRoot(resolve(fnamemodify(name, ':p')), root)
  endif
  if rel ==# ''
    return ''
  endif
  var mark = get(files, rel, '')
  return type(mark) == v:t_string && has_key(s_git_mark_groups, mark) ? mark : ''
enddef

# bufnr (as a string) -> 'M' / 'A' / 'D' / 'U', for the repository the current
# buffer belongs to.  Buffers in another repository simply carry no mark.
def TablineGitMarks(all: list<dict<any>>): dict<string>
  if !TabConfBool('simpletabline_git_status', true) || empty(s_git_cache)
    # Nothing has ever answered, so skip the path work entirely — this runs on
    # every redraw, including for everyone who keeps Git turned off.
    return {}
  endif
  var info = get(s_git_cache, CurrentGitDir(), {})
  var files = get(info, 'files', {})
  var root = get(info, 'repo_root', '')
  if type(files) != v:t_dict || empty(files) || root ==# ''
    return {}
  endif
  if s_git_mark_tick != s_git_tick
    s_git_mark_cache = {}
    s_git_mark_tick = s_git_tick
  endif
  var marks: dict<string> = {}
  for b in all
    var name = get(b, 'name', '')
    if name ==# ''
      continue
    endif
    # The root is part of the key, not just the tick: moving to a buffer in
    # another repository changes which cache entry answers without changing
    # any payload, and a mark resolved against the previous root would
    # otherwise survive the move.
    var key = root .. "\x01" .. b.bufnr .. "\x01" .. name
    var mark: string
    if has_key(s_git_mark_cache, key)
      mark = s_git_mark_cache[key]
    else
      mark = ResolveGitMark(name, root, files)
      if len(s_git_mark_cache) > 512
        s_git_mark_cache = {}
      endif
      s_git_mark_cache[key] = mark
    endif
    if mark !=# ''
      marks[string(b.bufnr)] = mark
    endif
  endfor
  return marks
enddef

# Rendered form of the glyph, escaped and spaced exactly as TabLabelText()
# measures it — the two must agree or the width budget drifts.
def GitIconPart(bufnum: number, marks: dict<string>): string
  var icon = GitMarkIcon(get(marks, string(bufnum), ''))
  return icon ==# '' ? '' : ' ' .. RenderEscape(icon)
enddef

def GitMarkIcon(mark: string): string
  if mark ==# ''
    return ''
  endif
  var icons = get(g:, 'simpletabline_git_status_icons', {})
  if type(icons) != v:t_dict
    return ''
  endif
  var icon = get(icons, mark, '')
  return type(icon) == v:t_string ? icon : ''
enddef

# The current buffer keeps its own highlight: which buffer you are in matters
# more than its Git state, and that state is still shown by the icon.
def TabItemGroup(bufnum: number, is_cur: bool, marks: dict<string>): string
  if is_cur
    return 'SimpleTablineActive'
  endif
  var group = get(s_git_mark_groups, get(marks, string(bufnum), ''), '')
  return group ==# '' ? 'SimpleTablineInactive' : group
enddef

def IsEligibleBuffer(bn: number): bool
  if bn <= 0 || bufexists(bn) == 0
    return false
  endif
  var bt = getbufvar(bn, '&buftype')
  if type(bt) != v:t_string || bt !=# ''
    return false
  endif
  var use_listed = TabConfBool('simpletabline_listed_only', true)
  var bl = getbufvar(bn, '&buflisted')
  var is_listed = (type(bl) == v:t_bool) ? bl : (bl != 0)
  return use_listed ? is_listed : true
enddef

def ListedNormalBuffers(): list<dict<any>>
  var use_listed = TabConfBool('simpletabline_listed_only', true)
  var bis = use_listed ? getbufinfo({'buflisted': 1}) : getbufinfo({'bufloaded': 1})
  var res: list<dict<any>> = []
  for b in bis
    var bt = getbufvar(b.bufnr, '&buftype')
    if type(bt) == v:t_string && bt ==# ''
      res->add(b)
    endif
  endfor
  var side = TabConfString('simpletabline_newbuf_side', 'right')
  if side ==# 'left'
    sort(res, (a, b) => b.bufnr - a.bufnr)
  else
    sort(res, (a, b) => a.bufnr - b.bufnr)
  endif
  return res
enddef

def RawBufDisplayName(b: dict<any>): string
  var n = bufname(b.bufnr)
  if n ==# ''
    return '[No Name]'
  endif
  var bmode = TabConfString('simpletabline_path_mode', 'abbr')
  if bmode ==# 'tail'
    return fnamemodify(n, ':t')
  endif
  var abs = fnamemodify(n, ':p')
  if bmode ==# 'abs'
    return abs
  endif
  var root = s_tab_render_root
  var rel = (root !=# '') ? RelToRoot(abs, root) : ''
  if rel ==# ''
    return fnamemodify(n, ':t')
  endif
  if bmode ==# 'rel'
    return rel
  elseif bmode ==# 'abbr'
    return AbbrevRelPath(rel)
  else
    return AbbrevRelPath(rel)
  endif
enddef

def BufDisplayName(b: dict<any>): string
  # Keyed on the file name as well as the buffer number: now that entries
  # survive across redraws, a buffer renamed with :file or :saveas has to miss
  # rather than keep showing its old label.
  var key = b.bufnr .. "\x01" .. get(b, 'name', '')
  if has_key(s_tab_name_cache, key)
    return s_tab_name_cache[key]
  endif
  var name = RawBufDisplayName(b)
  if len(s_tab_name_cache) > 4096
    # Entries for wiped buffers are never removed individually; bound the
    # dictionary instead of letting a long session grow it without limit.
    s_tab_name_cache = {}
  endif
  s_tab_name_cache[key] = name
  return name
enddef

def TabLabelText(
    b: dict<any>,
    key: string,
    pick_mode: bool = false,
    marks: dict<string> = {}
): string
  var name = VisibleText(BufDisplayName(b))
  var powerline = SeparatorStyle() !=# 'plain'
        \ && ConfBool('simpleline_nerdfont', true)
  var sep_key = powerline ? ' '
        \ : (pick_mode ? '' : VisibleText(TabConfString('simpletabline_key_sep', '')))
  var show_mod = TabConfBool('simpletabline_show_modified', true)
  var mod_mark = (show_mod && get(b, 'changed', 0) == 1) ? ' +' : ''
  var key_txt = key
  if key_txt !=# '' && !pick_mode && TabConfBool('simpletabline_superscript_index', true)
    key_txt = SupDigit(key_txt)
  endif
  var icon = powerline ? VisibleText(BufFtIcon(b.bufnr)) : ''
  var padding = powerline ? '  ' : ''
  # The Git glyph is part of the label, so the width budget accounts for it.
  var git_icon = VisibleText(GitMarkIcon(get(marks, string(b.bufnr), '')))
  var base = padding .. (key_txt !=# '' ? key_txt .. sep_key : '')
        \ .. icon .. name .. mod_mark .. (git_icon ==# '' ? '' : ' ' .. git_icon)
  return base
enddef

def AssignDigitsForVisible(visible: list<number>)
  s_idx_to_buf = {}
  s_buf_to_idx = {}
  var digits: list<number> = []
  for d in range(1, 9)
    digits->add(d)
  endfor
  digits->add(0)
  var i = 0
  var j = 0
  while i < len(visible) && j < len(digits)
    var bn = visible[i]
    if IsEligibleBuffer(bn)
      var dg = digits[j]
      s_idx_to_buf[dg] = bn
      s_buf_to_idx[bn] = dg
      j += 1
    endif
    i += 1
  endwhile
enddef

def ComputeVisible(
    all: list<dict<any>>,
    buf_keys: dict<string>,
    pick_mode: bool = false,
    index_capacity: number = 0,
    marks: dict<string> = {}
): list<number>
  var cols = max([&columns, 1])
  var powerline = SeparatorStyle() !=# 'plain'
        \ && ConfBool('simpleline_nerdfont', true)
  var sep_w = powerline
        \ ? max([1, strdisplaywidth(s_sep_l), strdisplaywidth(s_subsep_l)])
        \ : strdisplaywidth(VisibleText(TabConfString('simpletabline_item_sep', ' | ')))
  var ellipsis_w = strdisplaywidth(VisibleText(TabConfString('simpletabline_ellipsis', ' … ')))

  var curbn = bufnr('%')
  var cur_idx = -1
  for i in range(len(all))
    if all[i].bufnr == curbn
      cur_idx = i
      break
    endif
  endfor
  if cur_idx < 0
    cur_idx = 0
  endif

  var widths: list<number> = []
  var indexed_widths: list<number> = []
  var i = 0
  while i < len(all)
    var key = get(buf_keys, string(all[i].bufnr), '')
    var txt = TabLabelText(all[i], key, pick_mode, marks)
    var w = strdisplaywidth(txt)
    widths->add(w)
    indexed_widths->add(strdisplaywidth(TabLabelText(all[i], '8', false, marks)))
    i += 1
  endwhile

  def DisplayWidth(indices: list<number>): number
    var used = powerline ? strdisplaywidth(s_sep_l) * 2 : 0
    var k = 0
    while k < len(indices)
      used += index_capacity > k ? indexed_widths[indices[k]] : widths[indices[k]]
      if k > 0
        used += sep_w
      endif
      k += 1
    endwhile
    if !empty(indices) && indices[0] > 0
      used += ellipsis_w
    endif
    if !empty(indices) && indices[-1] < len(all) - 1
      used += ellipsis_w
    endif
    return used
  enddef

  var all_idx = range(len(all))
  if DisplayWidth(all_idx) <= cols
    return mapnew(all_idx, (_, idx) => all[idx].bufnr)
  endif

  # Expand around the current buffer. It is never removed: a single long item
  # is left for Vim to truncate rather than producing an empty tabline.
  var visible_idx: list<number> = [cur_idx]
  var left = cur_idx - 1
  var right = cur_idx + 1

  while true
    var added = false
    if right < len(all)
      var with_right = copy(visible_idx)->add(right)
      if DisplayWidth(with_right) <= cols
        visible_idx = with_right
        right += 1
        added = true
      endif
    endif
    if left >= 0
      var with_left = copy(visible_idx)->insert(left, 0)
      if DisplayWidth(with_left) <= cols
        visible_idx = with_left
        left -= 1
        added = true
      endif
    endif
    if !added
      break
    endif
  endwhile

  var visible: list<number> = []
  for j in range(len(visible_idx))
    visible->add(all[visible_idx[j]].bufnr)
  endfor
  return visible
enddef

# ----------- Pick mode tabline -----------
def TablinePickMode(): string
  RefreshTabRenderRoot()
  var all = ListedNormalBuffers()
  if len(all) == 0
    return ''
  endif

  var pick_keys: dict<string> = {}
  var widest_pick = ''
  var widest_pick_width = 0
  for ch in s_pick_chars
    var width = strdisplaywidth(VisibleText(ch))
    if width > widest_pick_width
      widest_pick = ch
      widest_pick_width = width
    endif
  endfor
  for binfo in all
    # Budget every candidate with the widest possible hint. This is monotonic
    # and prevents late-list buffers or mixed-width keys from overflowing.
    pick_keys[string(binfo.bufnr)] = widest_pick
  endfor
  var marks = TablineGitMarks(all)
  var visible = ComputeVisible(all, pick_keys, true, 0, marks)

  var bynr: dict<dict<any>> = {}
  for binfo in all
    bynr[string(binfo.bufnr)] = binfo
  endfor

  var sep = RenderEscape(TabConfString('simpletabline_item_sep', ' | '))
  var ellipsis = RenderEscape(TabConfString('simpletabline_ellipsis', ' … '))
  var left_omitted = (len(visible) > 0 && visible[0] != all[0].bufnr)
  var right_omitted = (len(visible) > 0 && visible[-1] != all[-1].bufnr)

  var s = ''
  var curbn = bufnr('%')

  var style = SeparatorStyle()
  var use_powerline = (style !=# 'plain') && ConfBool('simpleline_nerdfont', true)

  s_char_to_bufnr = {}
  var char_idx = 0

  if use_powerline
    # Powerline-style pick mode
    if left_omitted
      s ..= '%#SimpleTablineFill#' .. ellipsis
    endif

    var is_first = true
    var prev_is_active = false

    for vbn in visible
      var k = string(vbn)
      if !has_key(bynr, k)
        continue
      endif
      var b = bynr[k]
      var is_cur = (b.bufnr == curbn)

      # Powerline separator
      if is_first
        if is_cur
          s ..= '%#SimpleTabFillToAct#' .. s_sep_l
        else
          s ..= '%#SimpleTabFillToInact#' .. s_sep_l
        endif
      else
        if prev_is_active && !is_cur
          s ..= '%#SimpleTabActToInact#' .. s_sep_l
        elseif !prev_is_active && is_cur
          s ..= '%#SimpleTabInactToAct#' .. s_sep_l
        elseif prev_is_active && is_cur
          s ..= '%#SimpleTabActToInact#' .. s_sep_l
        else
          s ..= '%#SimpleTabInactSep#' .. s_subsep_l
        endif
      endif

      var hint_char = ''
      if char_idx < len(s_pick_chars)
        hint_char = s_pick_chars[char_idx]
        s_char_to_bufnr[hint_char] = b.bufnr
        char_idx += 1
      endif

      var icon = RenderEscape(BufFtIcon(b.bufnr))
      var name = RenderEscape(BufDisplayName(b))
      var show_mod = TabConfBool('simpletabline_show_modified', true)
      var mod_mark = (show_mod && get(b, 'changed', 0) == 1) ? ' +' : ''
      var git_icon = GitIconPart(b.bufnr, marks)
      var grp_item = '%#' .. TabItemGroup(b.bufnr, is_cur, marks) .. '#'

      if hint_char !=# '' && len(name) > 0
        s ..= grp_item .. ' %#SimpleTablinePickHint#' .. RenderEscape(hint_char) .. grp_item .. ' ' .. icon .. name .. mod_mark .. git_icon .. ' '
      else
        s ..= grp_item .. ' ' .. icon .. name .. mod_mark .. git_icon .. ' '
      endif

      is_first = false
      prev_is_active = is_cur
    endfor

    # Right separator
    if !is_first
      if prev_is_active
        s ..= '%#SimpleTabActToFill#' .. s_sep_l
      else
        s ..= '%#SimpleTabInactToFill#' .. s_sep_l
      endif
    endif

    if right_omitted
      s ..= '%#SimpleTablineFill#' .. ellipsis
    endif
  else
    # Plain-style pick mode (fallback)
    var first = true
    var prev_is_cur = false

    if left_omitted
      s ..= '%#SimpleTablineInactive#' .. ellipsis
    endif

    for vbn in visible
      var k = string(vbn)
      if !has_key(bynr, k)
        continue
      endif
      var b = bynr[k]
      var is_cur = (b.bufnr == curbn)

      if !first
        var use_cur_sep = (prev_is_cur || is_cur)
        if use_cur_sep
          s ..= '%#SimpleTablineSepCurrent#' .. sep .. '%#None#'
        else
          s ..= '%#SimpleTablineSep#' .. sep .. '%#None#'
        endif
      endif

      var hint_char = ''
      if char_idx < len(s_pick_chars)
        hint_char = s_pick_chars[char_idx]
        s_char_to_bufnr[hint_char] = b.bufnr
        char_idx += 1
      endif

      var name = RenderEscape(BufDisplayName(b))
      var show_mod = TabConfBool('simpletabline_show_modified', true)
      var mod_mark = (show_mod && get(b, 'changed', 0) == 1) ? ' +' : ''
      var git_icon = GitIconPart(b.bufnr, marks)

      var grp_item = '%#' .. TabItemGroup(b.bufnr, is_cur, marks) .. '#'
      var name_part = ''

      if hint_char !=# '' && len(name) > 0
        name_part = '%#SimpleTablinePickHint#' .. RenderEscape(hint_char) .. '%#None#'
              \ .. grp_item .. name .. mod_mark .. git_icon .. '%#None#'
      else
        name_part = grp_item .. name .. mod_mark .. git_icon .. '%#None#'
      endif

      s ..= name_part
      first = false
      prev_is_cur = is_cur
    endfor

    if right_omitted
      s ..= '%#SimpleTablineInactive#' .. ellipsis .. '%#None#'
    endif
  endif

  s ..= '%=%#SimpleTablineFill#'
  return s
enddef

# ----------- Mouse support -----------
# %N@simpleline#TablineClick@ labels; Vim calls this on tabline clicks with the
# buffer number as minwid. Left click switches, middle click deletes.
export def TablineClick(minwid: number, clicks: number, button: string, mods: string)
  if !bufexists(minwid)
    return
  endif
  if button ==# 'm'
    var modified = getbufvar(minwid, '&modified')
    if type(modified) != v:t_string && modified
      echo '[SimpleLine] buffer ' .. minwid .. ' has unsaved changes'
      return
    endif
    try
      execute 'bdelete ' .. minwid
    catch
      DebugLog('failed to delete buffer ' .. minwid .. ': ' .. v:exception)
    endtry
  elseif button ==# 'l'
    try
      execute 'buffer ' .. minwid
    catch
      DebugLog('failed to switch to buffer ' .. minwid .. ': ' .. v:exception)
    endtry
  endif
enddef

# ----------- Main tabline -----------
# Rendered-tabline memo.  Vim re-evaluates 'tabline' on every redraw, so this
# function runs on every cursor move, but its output only changes when the
# buffer list, the current buffer, a modified flag, a buffer name, the window
# width or the render root changes.  Recomputing unconditionally meant
# measuring every buffer's label twice per redraw (ComputeVisible), which
# reached ~2ms with 120 buffers open — visible lag while scrolling.
var s_tabline_cache: string = ''
var s_tabline_key: string = ''

def TablineMemoKey(all: list<dict<any>>, marks: dict<string>): string
  # Everything the rendered string depends on.  Buffer filetype is deliberately
  # absent: it drives the icon but reading it costs a getbufvar() per buffer on
  # every redraw, so a FileType autocommand invalidates instead.  Every other
  # rendering input has to be listed here — an omission does not merely make a
  # change late, it makes the option unusable at runtime, which is exactly what
  # happened to simpletabline_path_mode and simpleline_filetype_icons.
  var parts: list<string> = [
    string(&columns),
    string(bufnr('%')),
    s_tab_render_root,
    TabConfString('simpletabline_item_sep', ' | '),
    TabConfString('simpletabline_ellipsis', ' … '),
    TabConfString('simpletabline_key_sep', ''),
    TabConfString('simpletabline_path_mode', 'abbr'),
    string(get(g:, 'simpleline_filetype_icons', {})),
    SeparatorStyle(),
    string(ConfBool('simpleline_nerdfont', true)),
    string(ConfBool('simpletabline_show_indexes', true)),
    string(TabConfBool('simpletabline_show_modified', true)),
    string(TabConfBool('simpletabline_superscript_index', true)),
    string(TabConfBool('simpletabline_clickable', true)),
    string(get(g:, 'simpletabline_git_status_icons', {})),
  ]
  for b in all
    parts->add(printf('%d:%d:%s:%s', b.bufnr, get(b, 'changed', 0),
      \ get(marks, string(b.bufnr), ''), get(b, 'name', '')))
  endfor
  return join(parts, "\x01")
enddef

# Force the next Tabline() to rebuild.  Anything that changes rendering
# without changing the memo key (a highlight or option change, say) goes
# through here.
export def InvalidateTabline()
  s_tabline_key = ''
  s_tab_render_root = ''
  s_tab_name_cache = {}
enddef

export def Tabline(): string
  if s_pick_mode
    return TablinePickMode()
  endif

  RefreshTabRenderRoot()
  var all = ListedNormalBuffers()
  if len(all) == 0
    s_tabline_key = ''
    return ''
  endif

  var marks = TablineGitMarks(all)
  var memo_key = TablineMemoKey(all, marks)
  if memo_key ==# s_tabline_key
    return s_tabline_cache
  endif

  var sep = RenderEscape(TabConfString('simpletabline_item_sep', ' | '))
  var ellipsis = RenderEscape(TabConfString('simpletabline_ellipsis', ' … '))
  var show_keys = ConfBool('simpletabline_show_indexes', true)

  var empty_keys: dict<string> = {}
  for binfo in all
    empty_keys[string(binfo.bufnr)] = ''
  endfor
  var visible = ComputeVisible(all, empty_keys, false, show_keys ? 10 : 0, marks)
  AssignDigitsForVisible(visible)

  var buf_keys: dict<string> = {}
  for binfo in all
    var dg = get(s_buf_to_idx, binfo.bufnr, -1)
    buf_keys[string(binfo.bufnr)] = !show_keys || dg < 0
          \ ? '' : (dg == 0 ? '0' : string(dg))
  endfor
  var bynr: dict<dict<any>> = {}
  for binfo in all
    bynr[string(binfo.bufnr)] = binfo
  endfor

  var left_omitted = (len(visible) > 0 && visible[0] != all[0].bufnr)
  var right_omitted = (len(visible) > 0 && visible[-1] != all[-1].bufnr)

  var s = ''
  var curbn = bufnr('%')
  var style = SeparatorStyle()
  var use_powerline = (style !=# 'plain') && ConfBool('simpleline_nerdfont', true)
  var clickable = TabConfBool('simpletabline_clickable', true)

  if use_powerline
    # Powerline-style tabline
    if left_omitted
      s ..= '%#SimpleTablineFill#' .. ellipsis
    endif

    var is_first = true
    var prev_is_active = false

    for vbn in visible
      var k = string(vbn)
      if !has_key(bynr, k)
        continue
      endif
      var b = bynr[k]
      var is_cur = (b.bufnr == curbn)

      # Powerline separator before this item
      if is_first
        if is_cur
          s ..= '%#SimpleTabFillToAct#' .. s_sep_l
        else
          s ..= '%#SimpleTabFillToInact#' .. s_sep_l
        endif
      else
        if prev_is_active && is_cur
          s ..= '%#SimpleTabActToInact#' .. s_sep_l
        elseif prev_is_active && !is_cur
          s ..= '%#SimpleTabActToInact#' .. s_sep_l
        elseif !prev_is_active && is_cur
          s ..= '%#SimpleTabInactToAct#' .. s_sep_l
        else
          s ..= '%#SimpleTabInactSep#' .. s_subsep_l
        endif
      endif

      # Buffer content with padding
      var icon = RenderEscape(BufFtIcon(b.bufnr))
      var key_raw = get(buf_keys, string(b.bufnr), '')
      var key_txt = key_raw
      if key_txt !=# '' && TabConfBool('simpletabline_superscript_index', true)
        key_txt = SupDigit(key_txt)
      endif
      var key_part = ''
      if show_keys && key_txt !=# ''
        var key_grp = is_cur ? '%#SimpleTablineIndexActive#' : '%#SimpleTablineIndex#'
        key_part = key_grp .. key_txt .. ' '
      endif

      var grp_item = '%#' .. TabItemGroup(b.bufnr, is_cur, marks) .. '#'
      var name = RenderEscape(BufDisplayName(b))
      var show_mod = TabConfBool('simpletabline_show_modified', true)
      var mod_mark = (show_mod && get(b, 'changed', 0) == 1) ? ' +' : ''

      var label = grp_item .. ' ' .. key_part .. icon .. name .. mod_mark
            \ .. GitIconPart(b.bufnr, marks) .. ' '
      s ..= clickable
            \ ? '%' .. b.bufnr .. '@simpleline#TablineClick@' .. label .. '%X'
            \ : label

      is_first = false
      prev_is_active = is_cur
    endfor

    # Powerline separator after last item
    if !is_first
      if prev_is_active
        s ..= '%#SimpleTabActToFill#' .. s_sep_l
      else
        s ..= '%#SimpleTabInactToFill#' .. s_sep_l
      endif
    endif

    if right_omitted
      s ..= '%#SimpleTablineFill#' .. ellipsis
    endif
  else
    # Plain-style tabline (fallback)
    if left_omitted
      s ..= '%#SimpleTablineInactive#' .. ellipsis
    endif

    var first = true
    var prev_is_cur = false

    for vbn in visible
      var k = string(vbn)
      if !has_key(bynr, k)
        continue
      endif
      var b = bynr[k]
      var is_cur = (b.bufnr == curbn)

      if !first
        var use_cur_sep = (prev_is_cur || is_cur)
        if use_cur_sep
          s ..= '%#SimpleTablineSepCurrent#' .. sep .. '%#None#'
        else
          s ..= '%#SimpleTablineSep#' .. sep .. '%#None#'
        endif
      endif

      var key_raw = get(buf_keys, string(b.bufnr), '')
      var key_txt = key_raw
      if key_txt !=# '' && TabConfBool('simpletabline_superscript_index', true)
        key_txt = SupDigit(key_txt)
      endif
      var key_part = ''
      if show_keys && key_txt !=# ''
        var key_grp = is_cur ? '%#SimpleTablineIndexActive#' : '%#SimpleTablineIndex#'
        var sep_key = RenderEscape(TabConfString('simpletabline_key_sep', ''))
        key_part = key_grp .. key_txt .. '%#None#' .. sep_key
      endif

      var grp_item = '%#' .. TabItemGroup(b.bufnr, is_cur, marks) .. '#'
      var name = RenderEscape(BufDisplayName(b))
      var show_mod = TabConfBool('simpletabline_show_modified', true)
      var mod_mark = (show_mod && get(b, 'changed', 0) == 1) ? ' +' : ''
      var name_part = grp_item .. name .. mod_mark
            \ .. GitIconPart(b.bufnr, marks) .. '%#None#'

      var label = key_part .. name_part
      s ..= clickable
            \ ? '%' .. b.bufnr .. '@simpleline#TablineClick@' .. label .. '%X'
            \ : label

      first = false
      prev_is_cur = is_cur
    endfor

    if right_omitted
      s ..= '%#SimpleTablineInactive#' .. ellipsis .. '%#None#'
    endif
  endif

  s ..= '%=%#SimpleTablineFill#'
  s_tabline_key = memo_key
  s_tabline_cache = s
  return s
enddef

# ----------- Pick mode -----------
def InitPickChars()
  var chars_str = get(g:, 'simpletabline_pick_chars', 'asdfjkl;ghqweruiopzxcvbnm')
  if type(chars_str) != v:t_string
    chars_str = 'asdfjkl;ghqweruiopzxcvbnm'
  endif
  s_pick_chars = []
  var seen: dict<bool> = {}
  for ch in split(chars_str, '\zs')
    if ch !=# '' && ch !=# "\<Esc>" && !has_key(seen, ch)
      seen[ch] = true
      s_pick_chars->add(ch)
    endif
  endfor
enddef

def ForceRedrawTabline()
  try
    redrawtabline
  catch
  endtry
  try
    redraw
  catch
  endtry
enddef

export def BufferPick()
  if s_pick_mode
    call CancelPick()
    return
  endif
  SetupSeparators()
  InitPickChars()
  s_pick_mode = true
  s_char_to_bufnr = {}
  try
    # Populate the visible key map before waiting. getcharstr() avoids touching
    # any user mapping, including single-letter mappings and <Esc>.
    TablinePickMode()
    if empty(s_char_to_bufnr)
      echo '[SimpleLine] no visible buffer to pick'
      CancelPick()
      return
    endif
    ForceRedrawTabline()
    echo '[SimpleLine] pick buffer (' .. VisibleText(join(s_pick_chars, '')) .. ', Esc cancels)'
    var ch = getcharstr()
    if ch ==# "\<Esc>" || ch ==# "\<C-C>"
      CancelPick()
    else
      PickChar(ch)
    endif
  catch
    DebugLog('buffer pick failed: ' .. v:exception)
    CancelPick()
  endtry
enddef

export def CancelPick()
  if !s_pick_mode
    return
  endif
  s_pick_mode = false
  s_char_to_bufnr = {}
  ForceRedrawTabline()
  echo ''
enddef

export def PickChar(ch: string)
  if !has_key(s_char_to_bufnr, ch)
    echo '[SimpleLine] No buffer bound to "' .. ch .. '"'
    call CancelPick()
    return
  endif
  var bn = s_char_to_bufnr[ch]
  if bn > 0 && bufexists(bn)
    execute 'buffer ' .. bn
  else
    echo '[SimpleLine] Invalid buffer'
  endif
  call CancelPick()
enddef

# ----------- BufferJump commands -----------
export def BufferJump(n: number)
  # Recompute indexes so the command never uses a mapping from an older width
  # or buffer set.
  Tabline()
  if !has_key(s_idx_to_buf, n)
    echo '[SimpleLine] No visible buffer bound to ' .. (n == 0 ? '0' : string(n))
    return
  endif
  var bn = s_idx_to_buf[n]
  if bn > 0 && bufexists(bn)
    execute 'buffer ' .. bn
  else
    echo '[SimpleLine] Invalid buffer'
  endif
enddef

export def BufferJumpCommand(argument: string)
  if argument !~# '^\d$'
    echoerr '[SimpleLine] buffer index must be one digit (0-9)'
    return
  endif
  BufferJump(str2nr(argument))
enddef

export def BufferJump1()
  BufferJump(1)
enddef
export def BufferJump2()
  BufferJump(2)
enddef
export def BufferJump3()
  BufferJump(3)
enddef
export def BufferJump4()
  BufferJump(4)
enddef
export def BufferJump5()
  BufferJump(5)
enddef
export def BufferJump6()
  BufferJump(6)
enddef
export def BufferJump7()
  BufferJump(7)
enddef
export def BufferJump8()
  BufferJump(8)
enddef
export def BufferJump9()
  BufferJump(9)
enddef
export def BufferJump0()
  BufferJump(0)
enddef

# =============================================================
# Backend (daemon) management
# =============================================================
def FindDaemon(): string
  SetupCore()
  return simpleline#core#FindExe()
enddef

# The vendored simplecore supervisor owns the daemon process: job_status-based
# liveness, generation-guarded callbacks, backoff restarts and a crash-loop
# breaker.  Only the protocol handshake and git bookkeeping live here.
var s_core_ready: bool = false

def SetupCore()
  if s_core_ready
    return
  endif
  s_core_ready = true
  simpleline#core#Setup({
    name: 'SimpleLine',
    exe: 'simpleline-daemon',
    path_var: 'simpleline_daemon_path',
    debug_var: 'simpleline_debug',
    handshake: {request: {type: 'version'}, reply_type: 'version', proto_key: 'protocol'},
    OnEvent: OnDaemonEvent,
    OnExit: OnDaemonExit,
  })
enddef

def OnDaemonExit(code: number, restarting: bool)
  s_daemon_ready = false
  s_daemon_version = ''
  s_daemon_protocol = 0
  # Requests that were in flight when the daemon died will never be answered,
  # and their directories go back on the waiting list so the next successful
  # handshake re-issues them.  Clearing the list here instead — which is what
  # this did — meant FlushDaemonWaiters() ran over an empty dictionary after
  # every restart: with g:simpleline_git_interval = 0 the Git segment then kept
  # showing pre-crash data until the next BufEnter, which for someone editing
  # one file in one window is forever.
  var orphaned = restarting ? values(s_git_pending) : []
  ClearPending()
  s_daemon_waiting_dirs = {}
  if restarting && s_enabled && ConfBool('simpleline_git_enabled', true)
    for dir in orphaned
      s_daemon_waiting_dirs[dir] = true
    endfor
    # The directory on screen matters even when nothing was in flight: the
    # restart itself is the only event that will ever prompt a refresh.
    s_daemon_waiting_dirs[CurrentGitDir()] = true
  endif
enddef

def ClearPending()
  s_git_pending = {}
  s_git_inflight = {}
  s_git_refresh_again = {}
enddef

def TakePending(id: number): string
  var key = string(id)
  if id <= 0 || !has_key(s_git_pending, key)
    return ''
  endif
  var dir = remove(s_git_pending, key)
  if get(s_git_inflight, dir, -1) == id
    remove(s_git_inflight, dir)
  endif
  return dir
enddef

def ValidGitInfo(ev: dict<any>, dir: string): bool
  var path = get(ev, 'path', v:null)
  var branch = get(ev, 'branch', v:null)
  if type(path) != v:t_string || path !=# dir || type(branch) != v:t_string
    return false
  endif
  for field in ['dirty', 'is_git']
    if type(get(ev, field, v:null)) != v:t_bool
      return false
    endif
  endfor
  for field in ['added', 'modified', 'deleted', 'ahead', 'behind']
    var count = get(ev, field, v:null)
    if type(count) != v:t_number || count < 0
      return false
    endif
  endfor
  # Additive protocol-1 fields; a pre-0.3 daemon simply omits them.
  for field in ['conflicts', 'stash']
    if has_key(ev, field)
      var count = ev[field]
      if type(count) != v:t_number || count < 0
        return false
      endif
    endif
  endfor
  # Also additive: older protocol-1 daemons omit the current repository
  # operation and the client treats it as no operation in progress.
  if has_key(ev, 'operation') && type(ev.operation) != v:t_string
    return false
  endif
  # Protocol-2 per-file status, equally additive.  Every value is checked here
  # rather than at render time: this is the one place a malformed payload can
  # be rejected wholesale, and the renderer must never have to guard a type.
  if has_key(ev, 'repo_root') && type(ev.repo_root) != v:t_string
    return false
  endif
  if has_key(ev, 'files_truncated') && type(ev.files_truncated) != v:t_bool
    return false
  endif
  if has_key(ev, 'files')
    if type(ev.files) != v:t_dict
      return false
    endif
    for mark in values(ev.files)
      if type(mark) != v:t_string
        return false
      endif
    endfor
  endif
  return true
enddef

def OnGitInfo(ev: dict<any>)
  if !s_daemon_ready || index(SUPPORTED_PROTOCOLS, s_daemon_protocol) < 0
    DebugLog('ignored git response before a compatible daemon handshake')
    return
  endif
  var id = get(ev, 'id', 0)
  if type(id) != v:t_number
    DebugLog('daemon returned a git event without a numeric id')
    return
  endif
  var dir = TakePending(id)
  if dir ==# ''
    DebugLog('ignored stale git response ' .. id)
    return
  endif
  if !ValidGitInfo(ev, dir)
    DebugLog('ignored malformed git response for request ' .. id)
    RefreshQueuedGit(dir)
    return
  endif
  var info: dict<any> = {
    branch: get(ev, 'branch', ''),
    dirty: get(ev, 'dirty', false),
    added: get(ev, 'added', 0),
    modified: get(ev, 'modified', 0),
    deleted: get(ev, 'deleted', 0),
    conflicts: get(ev, 'conflicts', 0),
    stash: get(ev, 'stash', 0),
    operation: get(ev, 'operation', ''),
    ahead: get(ev, 'ahead', 0),
    behind: get(ev, 'behind', 0),
    is_git: get(ev, 'is_git', false),
    files: get(ev, 'files', {}),
    files_truncated: get(ev, 'files_truncated', false),
    repo_root: get(ev, 'repo_root', ''),
  }
  if !has_key(s_git_cache, dir) && len(s_git_cache) >= 128
    remove(s_git_cache, keys(s_git_cache)[0])
  endif
  var changed = !has_key(s_git_cache, dir) || s_git_cache[dir] != info
  s_git_cache[dir] = info
  if s_daemon_version !=# ''
    s_last_error = ''
  endif
  if changed
    # Per-buffer marks are resolved against this payload and cached; the tick
    # is what tells that cache its inputs moved.
    s_git_tick += 1
    redrawstatus
    redrawtabline
  endif
  RefreshQueuedGit(dir)
enddef

def OnDaemonError(ev: dict<any>)
  var id = get(ev, 'id', 0)
  var numeric_id = type(id) == v:t_number ? id : -1
  var dir = ''
  if numeric_id >= 0
    dir = TakePending(numeric_id)
  endif
  if numeric_id == 0 && s_daemon_version ==# ''
    s_daemon_incompatible = true
    s_daemon_waiting_dirs = {}
    DebugLog('daemon version is incompatible or unknown; rerun ./install.sh')
  else
    DebugLog('daemon error: ' .. VisibleText(get(ev, 'message', 'unknown error')))
  endif
  if dir !=# ''
    RefreshQueuedGit(dir)
  endif
enddef

def OnDaemonEvent(ev: dict<any>)
  if !has_key(ev, 'type') || type(ev.type) != v:t_string
    DebugLog('malformed daemon response')
    return
  endif
  if ev.type ==# 'version'
    # The supervisor assigned the id and already correlated this reply to its
    # handshake request; only the payload still needs validating.
    var version = get(ev, 'version', '')
    var protocol = get(ev, 'protocol', 0)
    if type(version) == v:t_string && version !=# '' && type(protocol) == v:t_number
      s_daemon_version = version
      s_daemon_protocol = protocol
      if index(SUPPORTED_PROTOCOLS, protocol) < 0
        s_daemon_ready = false
        s_daemon_incompatible = true
        s_daemon_waiting_dirs = {}
        DebugLog('unsupported daemon protocol ' .. protocol .. '; rerun ./install.sh')
      else
        s_daemon_ready = true
        s_daemon_incompatible = false
        s_last_error = ''
        FlushDaemonWaiters()
      endif
    else
      s_daemon_ready = false
      s_daemon_incompatible = true
      s_daemon_waiting_dirs = {}
      DebugLog('malformed daemon version response; rerun ./install.sh')
    endif
  elseif ev.type ==# 'git_info'
    OnGitInfo(ev)
  elseif ev.type ==# 'error'
    OnDaemonError(ev)
  endif
enddef

def StartDaemon(): bool
  SetupCore()
  if simpleline#core#IsRunning()
    return true
  endif
  s_daemon_version = ''
  s_daemon_protocol = 0
  s_daemon_ready = false
  s_daemon_incompatible = false
  s_daemon_waiting_dirs = {}
  return simpleline#core#Ensure()
enddef

def SendReq(req: dict<any>): bool
  return simpleline#core#Send(req)
enddef

def NextId(): number
  s_next_id += 1
  return s_next_id
enddef

# Whether anything is still left to read the daemon's answer.  With
# g:simpleline_git_provider = 'simplegit' GitStr() discards the whole reply
# before it looks at it, so the only remaining consumer is the tabline's
# per-file marks.  When those are off too — or the tabline is not ours — the
# request buys nothing at all, and sending it anyway means spawning the daemon
# and running `git status --porcelain=v2` over the entire worktree on every
# poll, forever, for output nobody reads.  That is precisely the cost the
# option is chosen to avoid.
def DaemonGitNeeded(): bool
  if GitProvider() !=# 'simplegit'
    return true
  endif
  return ConfBool('simpleline_tabline', true)
        \ && TabConfBool('simpletabline_git_status', true)
enddef

def RequestGitDir(dir: string)
  if !s_enabled || !ConfBool('simpleline_git_enabled', true)
    return
  endif
  if !DaemonGitNeeded()
    return
  endif
  if has_key(s_git_inflight, dir)
    s_git_refresh_again[dir] = true
    return
  endif
  if !simpleline#core#IsRunning() && !StartDaemon()
    return
  endif
  if s_daemon_incompatible
    return
  endif
  if !s_daemon_ready
    s_daemon_waiting_dirs[dir] = true
    return
  endif
  var id = NextId()
  s_git_pending[string(id)] = dir
  s_git_inflight[dir] = id
  var request: dict<any> = {type: 'git_info', id: id, path: dir}
  if WantFileStatus()
    # Asked for per request rather than always: collecting and serializing
    # every changed path is only worth its wire cost when something paints it.
    request.want_files = true
  endif
  if !SendReq(request)
    TakePending(id)
  endif
enddef

# The daemon advertises 'git-status' on the handshake, so an older binary that
# knows nothing about per-file marks is simply never asked for them.
def WantFileStatus(): bool
  # The marks have exactly one consumer, the tabline.  With g:simpleline_tabline
  # off, Enable() never touches 'tabline', so simpleline#Tabline() is never
  # called and TablineGitMarks() never runs — asking the daemon to collect,
  # serialize and ship up to 2000 paths on every refresh would buy a payload
  # nobody ever reads.
  if !ConfBool('simpleline_tabline', true)
    return false
  endif
  if !TabConfBool('simpletabline_git_status', true)
    return false
  endif
  try
    return simpleline#core#HasCap('git-status')
  catch
    return false
  endtry
enddef

def FlushDaemonWaiters()
  var dirs = keys(s_daemon_waiting_dirs)
  s_daemon_waiting_dirs = {}
  for dir in dirs
    RequestGitDir(dir)
  endfor
enddef

def RefreshQueuedGit(dir: string)
  if has_key(s_git_refresh_again, dir)
    remove(s_git_refresh_again, dir)
    RequestGitDir(dir)
  endif
enddef

def RequestGitInfo()
  RequestGitDir(CurrentGitDir())
enddef

def GitTimerCb(_id: number)
  RequestGitInfo()
enddef

def StopDaemon()
  SetupCore()
  simpleline#core#Stop()
  s_daemon_ready = false
  s_daemon_incompatible = false
  s_daemon_waiting_dirs = {}
  ClearPending()
enddef

# =============================================================
# Enable / Disable
# =============================================================
def SetWindowStatusline(winid: number, active: bool)
  if !s_enabled || !ConfBool('simpleline_statusline', true)
    return
  endif
  var tabwin = win_id2tabwin(winid)
  if len(tabwin) < 2 || tabwin[0] == 0
    return
  endif
  var key = string(winid)
  if !has_key(s_saved_window_statuslines, key)
    # Read the raw local value, not the effective global-local value. An empty
    # local option must remain empty so the window resumes inheriting the
    # user's global statusline after teardown.
    var old = gettabwinvar(tabwin[0], tabwin[1], '&l:statusline')
    if !s_capturing_existing_windows && type(old) == v:t_string
          \ && old =~# '^%!simpleline#\%(Active\|Inactive\)Statusline()$'
      old = ''
    endif
    s_saved_window_statuslines[key] = type(old) == v:t_string ? old : ''
  endif
  var value = active ? '%!simpleline#ActiveStatusline()'
        \ : '%!simpleline#InactiveStatusline()'
  settabwinvar(tabwin[0], tabwin[1], '&statusline', value)
enddef

export def ActivateWindow()
  SetWindowStatusline(win_getid(), true)
enddef

export def DeactivateWindow()
  SetWindowStatusline(win_getid(), false)
enddef

def RestoreWindowStatuslines()
  for [key, old] in items(s_saved_window_statuslines)
    var winid = str2nr(key)
    var tabwin = win_id2tabwin(winid)
    if len(tabwin) < 2 || tabwin[0] == 0
      continue
    endif
    var current = gettabwinvar(tabwin[0], tabwin[1], '&statusline')
    if type(current) == v:t_string && current =~# '^%!simpleline#\%(Active\|Inactive\)Statusline()$'
      settabwinvar(tabwin[0], tabwin[1], '&statusline', old)
    endif
  endfor
  s_saved_window_statuslines = {}
enddef

export def Enable()
  if s_enabled
    return
  endif

  SetupSeparators()
  SetupHighlights()
  ResetRenderCaches()
  # Separators and highlights have just been re-derived; a render produced
  # under the previous ones must not survive a :SimpleLineReload.
  InvalidateTabline()
  try
    g:SimpleTablineApplyHL()
  catch
  endtry

  s_saved_global_statusline = &g:statusline
  s_saved_global_tabline = &g:tabline
  s_saved_showtabline = &showtabline
  s_saved_laststatus = &laststatus
  s_saved_window_statuslines = {}
  s_owns_statusline = ConfBool('simpleline_statusline', true)
  s_owns_tabline = ConfBool('simpleline_tabline', true)
  s_changed_laststatus = false
  s_enabled = true

  if s_owns_statusline
    if &laststatus < 2
      &laststatus = 2
      s_changed_laststatus = true
    endif
    &g:statusline = '%!simpleline#ActiveStatusline()'
    s_capturing_existing_windows = true
    try
      for info in getwininfo()
        SetWindowStatusline(info.winid, info.winid == win_getid())
      endfor
    finally
      s_capturing_existing_windows = false
    endtry
  endif
  if s_owns_tabline
    &g:tabline = '%!simpleline#Tabline()'
    &showtabline = 2
  endif

  augroup SimpleLineAutoUpdate
    autocmd!
    autocmd WinEnter,BufEnter,BufWinEnter * simpleline#ActivateWindow()
    autocmd WinLeave * simpleline#DeactivateWindow()
    autocmd BufEnter,BufWritePost,DirChanged,FocusGained * simpleline#RequestGitRefresh()
    autocmd ColorScheme * simpleline#ResetHighlights()
    autocmd VimResized * redrawtabline | redrawstatus
    # The diagnostics memo is keyed on the buffer and its changedtick, neither
    # of which moves when a linter or language server finishes in the
    # background.  These are the three supported providers' documented public
    # notifications; without them a memoized count could sit stale until the
    # buffer was edited or left.
    autocmd User CocDiagnosticChange,ALELintPost,ALEJobStarted,lsp_diagnostics_updated
          \ simpleline#RefreshDiagnostics()
    # simplegit fires this whenever the buffer's status dictionary changes; it
    # is what makes the handed-off branch appear without waiting for a poll.
    autocmd User SimpleGitUpdate redrawstatus
    # Repaint the recording indicator immediately where Vim supports the events.
    if exists('##RecordingEnter')
      autocmd RecordingEnter,RecordingLeave * redrawstatus
    endif
  augroup END

  # Event-driven refresh plus optional, bounded polling.
  RequestGitInfo()
  var interval = get(g:, 'simpleline_git_interval', 2000)
  if ConfBool('simpleline_git_enabled', true) && exists('*timer_start')
        \ && type(interval) == v:t_number && interval > 0
    s_git_timer = timer_start(
      max([interval, 250]),
      (id) => GitTimerCb(id),
      {repeat: -1}
    )
  endif
enddef

export def Disable()
  if !s_enabled
    return
  endif

  augroup SimpleLineAutoUpdate
    autocmd!
  augroup END

  if s_git_timer != 0
    try | timer_stop(s_git_timer) | catch | endtry
    s_git_timer = 0
  endif

  if s_pick_mode
    CancelPick()
  endif
  s_enabled = false
  if s_owns_statusline
    RestoreWindowStatuslines()
  else
    s_saved_window_statuslines = {}
  endif

  if s_owns_statusline && &g:statusline ==# '%!simpleline#ActiveStatusline()'
    &g:statusline = s_saved_global_statusline
  endif
  if s_owns_tabline && &g:tabline ==# '%!simpleline#Tabline()'
    &g:tabline = s_saved_global_tabline
  endif
  if s_owns_tabline && &showtabline == 2
    &showtabline = s_saved_showtabline
  endif
  if s_changed_laststatus && &laststatus == 2
    &laststatus = s_saved_laststatus
  endif
  s_owns_statusline = false
  s_owns_tabline = false
  s_changed_laststatus = false
  StopDaemon()
enddef

export def Stop()
  Disable()
  StopDaemon()
enddef

export def Restart()
  SetupCore()
  s_daemon_ready = false
  s_daemon_incompatible = false
  s_daemon_waiting_dirs = {}
  ClearPending()
  if simpleline#core#Restart()
    echom '[SimpleLine] daemon restarted'
  endif
enddef

export def ShowLog()
  simpleline#core#ShowLog()
enddef

export def RequestGitRefresh()
  RequestGitInfo()
enddef

export def ResetHighlights()
  SetupHighlights()
  try
    g:SimpleTablineApplyHL()
  catch
  endtry
  redrawstatus
  redrawtabline
enddef

export def Toggle()
  if s_enabled
    Disable()
  else
    Enable()
  endif
enddef

export def Reload()
  var was_enabled = s_enabled
  if was_enabled
    Disable()
    Enable()
  else
    SetupSeparators()
    SetupHighlights()
    ResetRenderCaches()
    InvalidateTabline()
  endif
enddef

export def IsEnabled(): bool
  return s_enabled
enddef

export def Health()
  var daemon = FindDaemon()
  echo '[SimpleLine] health (v' .. get(g:, 'simpleline_version', 'unknown') .. '):'
  echo '  Vim: ' .. v:version .. ' (vim9=' .. (has('vim9script') ? 'yes' : 'no') .. ')'
  echo '  job/channel/timer: ' .. (has('job') ? 'yes' : 'no') .. '/'
        \ .. (has('channel') ? 'yes' : 'no') .. '/' .. (has('timers') ? 'yes' : 'no')
  echo '  enabled: ' .. (s_enabled ? 'yes' : 'no')
  echo '  UI status/tab/laststatus: ' .. (ConfBool('simpleline_statusline', true) ? 'on' : 'off')
        \ .. '/' .. (ConfBool('simpleline_tabline', true) ? 'on' : 'off') .. '/' .. &laststatus
  echo '  Git enabled/executable: ' .. (ConfBool('simpleline_git_enabled', true) ? 'yes' : 'no')
        \ .. '/' .. (executable('git') ? 'yes' : 'no')
  echo '  Git interval/timer: ' .. string(get(g:, 'simpleline_git_interval', 2000))
        \ .. '/' .. (s_git_timer == 0 ? 'stopped' : string(s_git_timer))
  echo '  Git provider: ' .. GitProvider() .. ' (simplegit '
        \ .. (exists('*simplegit#StatusDict') ? 'available' : 'absent')
        \ .. ', this buffer: ' .. (empty(SimpleGitStatus()) ? 'daemon' : 'simplegit')
        \ .. ', daemon query: ' .. (DaemonGitNeeded() ? 'on' : 'off') .. ')'
  var h = simpleline#core#Health()
  echo '  daemon: ' .. (daemon ==# '' ? 'not found' : daemon)
  echo '  daemon running: ' .. (h.running ? 'yes' : 'no')
  echo '  daemon crashes/restarts: ' .. h.crashes .. '/' .. h.restarts
        \ .. (h.breaker_open ? ' (auto-restart disabled — :SimpleLineRestart)' : '')
  echo '  daemon version/protocol: ' .. (s_daemon_version ==# '' ? 'unknown' : s_daemon_version)
        \ .. '/' .. s_daemon_protocol
  echo '  daemon ready/compatible/waiting: ' .. (s_daemon_ready ? 'yes' : 'no')
        \ .. '/' .. (s_daemon_incompatible ? 'no' : 'yes')
        \ .. '/' .. len(s_daemon_waiting_dirs)
  echo '  diagnostics provider: ' .. DiagProviderName()
  var custom_left = get(g:, 'simpleline_custom_left', [])
  var custom_right = get(g:, 'simpleline_custom_right', [])
  var rendered_custom = len(CustomSegments('simpleline_custom_left', 'SimpleLineMid'))
        \ + len(CustomSegments('simpleline_custom_right', 'SimpleLineRight'))
  var registered_custom = (type(custom_left) == v:t_list ? len(custom_left) : 0)
        \ + (type(custom_right) == v:t_list ? len(custom_right) : 0)
  echo '  custom segments: ' .. rendered_custom .. ' rendering/'
        \ .. registered_custom .. ' registered (left/right '
        \ .. (type(custom_left) == v:t_list ? len(custom_left) : 0) .. '/'
        \ .. (type(custom_right) == v:t_list ? len(custom_right) : 0) .. ')'
  echo '  git cache/pending: ' .. len(s_git_cache) .. '/' .. len(s_git_pending)
  var current = get(s_git_cache, CurrentGitDir(), {})
  var files = get(current, 'files', {})
  # 'on' means "something would paint a mark", which takes both the tabline and
  # the option: with either off the daemon is not asked, and health has to say
  # so or "why are there no marks" has no answer.
  echo '  git file status: ' .. (TabConfBool('simpletabline_git_status', true)
        \ && ConfBool('simpleline_tabline', true) ? 'on' : 'off')
        \ .. '/' .. (WantFileStatus() ? 'negotiated' : 'unavailable')
        \ .. ', ' .. (type(files) == v:t_dict ? len(files) : 0) .. ' path(s)'
        \ .. (get(current, 'files_truncated', false) ? ' (truncated)' : '')
        \ .. ', root ' .. (get(current, 'repo_root', '') ==# ''
        \   ? 'unknown' : get(current, 'repo_root', ''))
  echo '  separator: ' .. SeparatorStyle()
  if s_last_error !=# ''
    echo '  last error: ' .. s_last_error
  endif
enddef

def CacheRate(hits: number, misses: number): string
  var total = hits + misses
  return total == 0 ? 'n/a' : (hits * 100 / total) .. '%'
enddef

export def DebugStatus()
  Health()
  # Both memos exist to keep work out of the redraw path, so report how often
  # they actually avoid it — the tabline memo was justified the same way.
  echo '  search cache: ' .. s_search_hits .. ' hit/' .. s_search_misses
        \ .. ' miss (' .. CacheRate(s_search_hits, s_search_misses) .. '), '
        \ .. len(s_search_slow) .. ' pattern(s) disabled after a timeout'
  echo '  diagnostics cache: ' .. s_diag_hits .. ' hit/' .. s_diag_misses
        \ .. ' miss (' .. CacheRate(s_diag_hits, s_diag_misses) .. '), provider '
        \ .. s_diag_provider
  echo '  git_cache: ' .. string(s_git_cache)
enddef
