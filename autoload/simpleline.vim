vim9script

# =============================================================
# Simpleline — lightweight statusline & tabline (Vim9 + Rust)
# =============================================================

# ----------- State -----------
var s_enabled: bool = false
var s_job: any = v:null
var s_running: bool = false
var s_job_generation: number = 0
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
  var threshold = get(g:, 'simpleline_compact_width', 80)
  return type(threshold) == v:t_number && threshold > 0 && winwidth(0) < threshold
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

def ModeName(): string
  var kind = ModeKind()
  if kind ==# 'insert'
    return 'INSERT'
  elseif kind ==# 'replace'
    return 'REPLACE'
  elseif kind ==# 'visual'
    return 'VISUAL'
  elseif kind ==# 'select'
    return 'SELECT'
  elseif kind ==# 'command'
    return 'COMMAND'
  elseif kind ==# 'terminal'
    return 'TERMINAL'
  endif
  return 'NORMAL'
enddef

def ModeHl(): string
  var kind = ModeKind()
  if kind ==# 'insert'
    return '%#SimpleLineInsert#'
  elseif kind ==# 'replace'
    return '%#SimpleLineReplace#'
  elseif kind ==# 'visual' || kind ==# 'select'
    return '%#SimpleLineVisual#'
  elseif kind ==# 'command'
    return '%#SimpleLineCommand#'
  elseif kind ==# 'terminal'
    return '%#SimpleLineTerminal#'
  endif
  return '%#SimpleLineNormal#'
enddef

def ModeSepHl(): string
  var kind = ModeKind()
  if kind ==# 'insert'
    return '%#SimpleLineInsertSep#'
  elseif kind ==# 'replace'
    return '%#SimpleLineReplaceSep#'
  elseif kind ==# 'visual' || kind ==# 'select'
    return '%#SimpleLineVisualSep#'
  elseif kind ==# 'command'
    return '%#SimpleLineCommandSep#'
  elseif kind ==# 'terminal'
    return '%#SimpleLineTerminalSep#'
  endif
  return '%#SimpleLineNormalSep#'
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

def GitStr(): string
  if !ConfBool('simpleline_git_enabled', true)
    return ''
  endif
  var dir = CurrentGitDir()
  var info = get(s_git_cache, dir, {})
  if empty(info) || !get(info, 'is_git', false)
    return ''
  endif
  var branch = get(info, 'branch', '')
  if branch ==# ''
    return ''
  endif
  var parts: list<string> = []
  var icon = ConfBool('simpleline_nerdfont', true) ? ' ' : ''
  parts->add(icon .. RenderEscape(branch))
  var ahead = IsCompact() ? 0 : get(info, 'ahead', 0)
  var behind = IsCompact() ? 0 : get(info, 'behind', 0)
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
  return join(parts, ' ')
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

  # LSP (simplecc)
  highlight default SimpleLineLSP       guibg=#3e4452 guifg=#56b6c2 ctermfg=73 ctermbg=238

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
  s ..= ModeHl() .. ' ' .. ModeName() .. ' '
  s ..= ModeSepHl() .. s_sep_l

  # Git info
  var git = GitStr()
  if git !=# ''
    s ..= '%#SimpleLineGit# ' .. git .. ' '
  endif

  # Middle: filename. %< marks the truncation point so a long path is shortened
  # here instead of Vim eating the mode/git segments from the left.
  s ..= '%#SimpleLineMid#'
  s ..= ' ' .. RenderEscape(FtIcon()) .. '%<%f'
  s ..= '%( %m%r%)'

  # Separator to background
  s ..= '%#SimpleLineMidSep#' .. s_sep_l

  # Right align
  s ..= '%='

  # LSP status (simplecc compatibility provider)
  var lsp = get(g:, 'simplecc_status', '')
  if ConfBool('simpleline_show_lsp', true) && type(lsp) == v:t_string && lsp !=# ''
    s ..= '%#SimpleLineLSP# ' .. RenderEscape(lsp) .. ' '
  endif

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
  var value = '%#SimpleLineInactive# %<%f%( %m%r%) %='
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
var s_tab_name_cache: dict<string> = {}

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
  s_tab_name_cache = {}
  s_tab_render_root = TreeRoot()
  if s_tab_render_root ==# '' && ConfBool('simpletabline_fallback_cwd_root', true)
    s_tab_render_root = getcwd()
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
  var key = string(b.bufnr)
  if has_key(s_tab_name_cache, key)
    return s_tab_name_cache[key]
  endif
  var name = RawBufDisplayName(b)
  s_tab_name_cache[key] = name
  return name
enddef

def TabLabelText(b: dict<any>, key: string, pick_mode: bool = false): string
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
  var base = padding .. (key_txt !=# '' ? key_txt .. sep_key : '') .. icon .. name .. mod_mark
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
    index_capacity: number = 0
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
    var txt = TabLabelText(all[i], key, pick_mode)
    var w = strdisplaywidth(txt)
    widths->add(w)
    indexed_widths->add(strdisplaywidth(TabLabelText(all[i], '8', false)))
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
  var visible = ComputeVisible(all, pick_keys, true)

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
      var grp_item = is_cur ? '%#SimpleTablineActive#' : '%#SimpleTablineInactive#'

      if hint_char !=# '' && len(name) > 0
        s ..= grp_item .. ' %#SimpleTablinePickHint#' .. RenderEscape(hint_char) .. grp_item .. ' ' .. icon .. name .. mod_mark .. ' '
      else
        s ..= grp_item .. ' ' .. icon .. name .. mod_mark .. ' '
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

      var grp_item = is_cur ? '%#SimpleTablineActive#' : '%#SimpleTablineInactive#'
      var name_part = ''

      if hint_char !=# '' && len(name) > 0
        name_part = '%#SimpleTablinePickHint#' .. RenderEscape(hint_char) .. '%#None#'
              \ .. grp_item .. name .. mod_mark .. '%#None#'
      else
        name_part = grp_item .. name .. mod_mark .. '%#None#'
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

# ----------- Main tabline -----------
export def Tabline(): string
  if s_pick_mode
    return TablinePickMode()
  endif

  RefreshTabRenderRoot()
  var all = ListedNormalBuffers()
  if len(all) == 0
    return ''
  endif

  var sep = RenderEscape(TabConfString('simpletabline_item_sep', ' | '))
  var ellipsis = RenderEscape(TabConfString('simpletabline_ellipsis', ' … '))
  var show_keys = ConfBool('simpletabline_show_indexes', true)

  var empty_keys: dict<string> = {}
  for binfo in all
    empty_keys[string(binfo.bufnr)] = ''
  endfor
  var visible = ComputeVisible(all, empty_keys, false, show_keys ? 10 : 0)
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

      var grp_item = is_cur ? '%#SimpleTablineActive#' : '%#SimpleTablineInactive#'
      var name = RenderEscape(BufDisplayName(b))
      var show_mod = TabConfBool('simpletabline_show_modified', true)
      var mod_mark = (show_mod && get(b, 'changed', 0) == 1) ? ' +' : ''

      s ..= grp_item .. ' ' .. key_part .. icon .. name .. mod_mark .. ' '

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

      var grp_item = is_cur ? '%#SimpleTablineActive#' : '%#SimpleTablineInactive#'
      var name = RenderEscape(BufDisplayName(b))
      var show_mod = TabConfBool('simpletabline_show_modified', true)
      var mod_mark = (show_mod && get(b, 'changed', 0) == 1) ? ' +' : ''
      var name_part = grp_item .. name .. mod_mark .. '%#None#'

      s ..= key_part .. name_part

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

# ----------- Pick mode -----------
def InitPickChars()
  var chars_str = get(g:, 'simpletabline_pick_chars', 'asdfghjklqwertyuiopzxcvbnm')
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
  var override = get(g:, 'simpleline_daemon_path', '')
  if type(override) == v:t_string && override !=# '' && executable(override)
    return override
  endif
  var names = IsWin() ? ['lib/simpleline-daemon.exe', 'lib/simpleline-daemon']
        \ : ['lib/simpleline-daemon']
  for name in names
    for p in globpath(&runtimepath, name, false, true)
      if executable(p)
        return p
      endif
    endfor
  endfor
  return ''
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
  return true
enddef

def OnGitInfo(ev: dict<any>)
  if !s_daemon_ready || s_daemon_protocol != 1
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
    ahead: get(ev, 'ahead', 0),
    behind: get(ev, 'behind', 0),
    is_git: get(ev, 'is_git', false),
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
    redrawstatus
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

def OnDaemonLine(line: string)
  if line ==# ''
    return
  endif
  var ev: any
  try
    ev = json_decode(line)
  catch
    DebugLog('invalid daemon response: ' .. line)
    return
  endtry
  if type(ev) != v:t_dict || !has_key(ev, 'type') || type(ev.type) != v:t_string
    DebugLog('malformed daemon response')
    return
  endif
  if ev.type ==# 'version'
    var id = get(ev, 'id', -1)
    var version = get(ev, 'version', '')
    var protocol = get(ev, 'protocol', 0)
    if type(id) == v:t_number && id == 0 && type(version) == v:t_string
          \ && version !=# '' && type(protocol) == v:t_number
      s_daemon_version = version
      s_daemon_protocol = protocol
      if protocol != 1
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
  if s_running && s_job != v:null
    try
      if job_status(s_job) ==# 'run'
        return true
      endif
    catch
    endtry
  endif
  var cmd = FindDaemon()
  if cmd ==# '' || !executable(cmd)
    DebugLog('daemon not found; run ./install.sh or set g:simpleline_daemon_path')
    return false
  endif
  s_job_generation += 1
  var generation = s_job_generation
  try
    s_job = job_start([cmd], {
      in_io: 'pipe',
      out_mode: 'nl',
      out_cb: (ch, line) => {
        if generation == s_job_generation
          OnDaemonLine(line)
        endif
      },
      err_mode: 'nl',
      err_cb: (ch, line) => {
        if generation == s_job_generation && line !=# ''
          DebugLog('daemon stderr: ' .. line)
        endif
      },
      exit_cb: (ch, code) => {
        if generation == s_job_generation
          s_running = false
          s_job = v:null
          ClearPending()
          if code != 0
            DebugLog('daemon exited with code ' .. code)
          endif
        endif
      },
      stoponexit: 'term'
    })
    s_running = s_job != v:null && job_status(s_job) ==# 'run'
    if s_running
      s_last_error = ''
      s_daemon_version = ''
      s_daemon_protocol = 0
      s_daemon_ready = false
      s_daemon_incompatible = false
      s_daemon_waiting_dirs = {}
      SendReq({type: 'version', id: 0})
    endif
  catch
    s_job = v:null
    s_running = false
    DebugLog('failed to start daemon: ' .. v:exception)
  endtry
  return s_running
enddef

def SendReq(req: dict<any>): bool
  if !s_running || s_job == v:null
    return false
  endif
  try
    ch_sendraw(s_job, json_encode(req) .. "\n")
    return true
  catch
    DebugLog('failed to send daemon request: ' .. v:exception)
    return false
  endtry
enddef

def NextId(): number
  s_next_id += 1
  return s_next_id
enddef

def RequestGitDir(dir: string)
  if !s_enabled || !ConfBool('simpleline_git_enabled', true)
    return
  endif
  if has_key(s_git_inflight, dir)
    s_git_refresh_again[dir] = true
    return
  endif
  if !s_running && !StartDaemon()
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
  if !SendReq({type: 'git_info', id: id, path: dir})
    TakePending(id)
  endif
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
  s_job_generation += 1
  var old_job = s_job
  s_job = v:null
  s_running = false
  s_daemon_ready = false
  s_daemon_incompatible = false
  s_daemon_waiting_dirs = {}
  ClearPending()
  if old_job != v:null
    try
      job_stop(old_job)
    catch
    endtry
  endif
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
  echo '  daemon: ' .. (daemon ==# '' ? 'not found' : daemon)
  echo '  daemon running: ' .. (s_running ? 'yes' : 'no')
  echo '  daemon version/protocol: ' .. (s_daemon_version ==# '' ? 'unknown' : s_daemon_version)
        \ .. '/' .. s_daemon_protocol
  echo '  daemon ready/waiting: ' .. (s_daemon_ready ? 'yes' : 'no')
        \ .. '/' .. len(s_daemon_waiting_dirs)
  echo '  git cache/pending: ' .. len(s_git_cache) .. '/' .. len(s_git_pending)
  echo '  separator: ' .. SeparatorStyle()
  if s_last_error !=# ''
    echo '  last error: ' .. s_last_error
  endif
enddef

export def DebugStatus()
  Health()
  echo '  git_cache: ' .. string(s_git_cache)
enddef
