vim9script

# =============================================================
# Simpleline — lightweight statusline & tabline (Vim9 + Rust)
# =============================================================

# ----------- State -----------
var s_enabled: bool = false
var s_job: any = v:null
var s_running: bool = false
var s_next_id: number = 0
var s_git_timer: number = 0

# Git info cache (per-directory)
var s_git_cache: dict<dict<any>> = {}
# Last queried directory
var s_git_last_dir: string = ''

# ----------- Nerd Font icon map -----------
var s_ft_icons: dict<string> = {
  vim: '', lua: '', python: '', ruby: '',
  go: '', rust: '', javascript: '', typescript: '',
  c: '', cpp: '', java: '', kotlin: '',
  sh: '', bash: '', zsh: '',
  html: '', css: '', scss: '',
  json: '', yaml: '', toml: '',
  markdown: '', text: '',
  haskell: '', julia: '',
  dart: '', swift: '', r: '',
  sql: '', docker: '', dockerfile: '',
  gitcommit: '', gitrebase: '',
  help: '󰋖', man: '󰋖',
  fugitive: '',
}

# ----------- Separator glyphs -----------
var s_sep_l: string = ''
var s_sep_r: string = ''
var s_subsep_l: string = ''
var s_subsep_r: string = ''

def SetupSeparators()
  var style = get(g:, 'simpleline_separator', 'arrow')
  if style ==# 'round'
    s_sep_l = ''
    s_sep_r = ''
    s_subsep_l = ''
    s_subsep_r = ''
  elseif style ==# 'plain'
    s_sep_l = ''
    s_sep_r = ''
    s_subsep_l = '|'
    s_subsep_r = '|'
  else
    # arrow (powerline)
    s_sep_l = ''
    s_sep_r = ''
    s_subsep_l = ''
    s_subsep_r = ''
  endif
enddef

# ----------- Mode display -----------
def ModeName(): string
  var m = mode()
  if m ==# 'n'
    return 'NORMAL'
  elseif m ==# 'i'
    return 'INSERT'
  elseif m ==# 'R'
    return 'REPLACE'
  elseif m ==# 'v' || m ==# 'V' || m ==# "\<C-V>"
    return 'VISUAL'
  elseif m ==# 's' || m ==# 'S' || m ==# "\<C-S>"
    return 'SELECT'
  elseif m ==# 'c'
    return 'COMMAND'
  elseif m ==# 't'
    return 'TERMINAL'
  else
    return toupper(m)
  endif
enddef

def ModeHl(): string
  var m = mode()
  if m ==# 'i'
    return '%#SimpleLineInsert#'
  elseif m ==# 'R'
    return '%#SimpleLineReplace#'
  elseif m ==# 'v' || m ==# 'V' || m ==# "\<C-V>"
    return '%#SimpleLineVisual#'
  elseif m ==# 'c'
    return '%#SimpleLineCommand#'
  elseif m ==# 't'
    return '%#SimpleLineTerminal#'
  else
    return '%#SimpleLineNormal#'
  endif
enddef

def ModeSepHl(): string
  var m = mode()
  if m ==# 'i'
    return '%#SimpleLineInsertSep#'
  elseif m ==# 'R'
    return '%#SimpleLineReplaceSep#'
  elseif m ==# 'v' || m ==# 'V' || m ==# "\<C-V>"
    return '%#SimpleLineVisualSep#'
  elseif m ==# 'c'
    return '%#SimpleLineCommandSep#'
  elseif m ==# 't'
    return '%#SimpleLineTerminalSep#'
  else
    return '%#SimpleLineNormalSep#'
  endif
enddef

# ----------- Filetype icon -----------
def FtIcon(): string
  if !get(g:, 'simpleline_nerdfont', 1)
    return ''
  endif
  var ft = &filetype
  if has_key(s_ft_icons, ft)
    return s_ft_icons[ft] .. ' '
  endif
  return ''
enddef

def BufFtIcon(bn: number): string
  if !get(g:, 'simpleline_nerdfont', 1)
    return ''
  endif
  var ft = getbufvar(bn, '&filetype')
  if type(ft) != v:t_string || ft ==# ''
    return ''
  endif
  if has_key(s_ft_icons, ft)
    return s_ft_icons[ft] .. ' '
  endif
  return ''
enddef

# ----------- Git info -----------
def GitStr(): string
  var dir = expand('%:p:h')
  if dir ==# ''
    dir = getcwd()
  endif
  var info = get(s_git_cache, dir, {})
  if empty(info) || !get(info, 'is_git', false)
    return ''
  endif
  var branch = get(info, 'branch', '')
  if branch ==# ''
    return ''
  endif
  var parts: list<string> = []
  var icon = get(g:, 'simpleline_nerdfont', 1) ? ' ' : ''
  parts->add(icon .. branch)
  var ahead = get(info, 'ahead', 0)
  var behind = get(info, 'behind', 0)
  if ahead > 0
    parts->add('+' .. ahead)
  endif
  if behind > 0
    parts->add('-' .. behind)
  endif
  var added = get(info, 'added', 0)
  var modified = get(info, 'modified', 0)
  var deleted = get(info, 'deleted', 0)
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
  highlight SimpleLineNormal    guibg=#61afef guifg=#282c34 gui=bold ctermfg=235 ctermbg=75 cterm=bold
  highlight SimpleLineInsert    guibg=#98c379 guifg=#282c34 gui=bold ctermfg=235 ctermbg=114 cterm=bold
  highlight SimpleLineVisual    guibg=#c678dd guifg=#282c34 gui=bold ctermfg=235 ctermbg=176 cterm=bold
  highlight SimpleLineReplace   guibg=#e06c75 guifg=#282c34 gui=bold ctermfg=235 ctermbg=168 cterm=bold
  highlight SimpleLineCommand   guibg=#e5c07b guifg=#282c34 gui=bold ctermfg=235 ctermbg=180 cterm=bold
  highlight SimpleLineTerminal  guibg=#56b6c2 guifg=#282c34 gui=bold ctermfg=235 ctermbg=73 cterm=bold

  # Separator (mode -> mid): fg = mode bg, bg = mid bg
  highlight SimpleLineNormalSep   guifg=#61afef guibg=#3e4452 ctermfg=75 ctermbg=238
  highlight SimpleLineInsertSep   guifg=#98c379 guibg=#3e4452 ctermfg=114 ctermbg=238
  highlight SimpleLineVisualSep   guifg=#c678dd guibg=#3e4452 ctermfg=176 ctermbg=238
  highlight SimpleLineReplaceSep  guifg=#e06c75 guibg=#3e4452 ctermfg=168 ctermbg=238
  highlight SimpleLineCommandSep  guifg=#e5c07b guibg=#3e4452 ctermfg=180 ctermbg=238
  highlight SimpleLineTerminalSep guifg=#56b6c2 guibg=#3e4452 ctermfg=73 ctermbg=238

  # Middle section
  highlight SimpleLineMid       guibg=#3e4452 guifg=#abb2bf ctermfg=145 ctermbg=238
  highlight SimpleLineMidSep    guifg=#3e4452 guibg=#282c34 ctermfg=238 ctermbg=235

  # Right section (file info)
  highlight SimpleLineRight     guibg=#3e4452 guifg=#abb2bf ctermfg=145 ctermbg=238
  highlight SimpleLineRightSep  guifg=#3e4452 guibg=#282c34 ctermfg=238 ctermbg=235

  # Position section
  highlight SimpleLinePos       guibg=#61afef guifg=#282c34 gui=bold ctermfg=235 ctermbg=75 cterm=bold
  highlight SimpleLinePosSep    guifg=#61afef guibg=#3e4452 ctermfg=75 ctermbg=238

  # Git
  highlight SimpleLineGit       guibg=#3e4452 guifg=#e5c07b ctermfg=180 ctermbg=238

  # LSP (simplecc)
  highlight SimpleLineLSP       guibg=#3e4452 guifg=#56b6c2 ctermfg=73 ctermbg=238

  # Inactive
  highlight SimpleLineInactive  guibg=#282c34 guifg=#5c6370 ctermfg=241 ctermbg=235

  # Tabline (uses default links, actual colors set by SimpleTablineApplyHL)
enddef

# =============================================================
# Statusline builder
# =============================================================
export def ActiveStatusline(): string
  var s = ''

  # Mode
  s ..= ModeHl() .. ' ' .. ModeName() .. ' '
  s ..= ModeSepHl() .. s_sep_l

  # Git info
  var git = GitStr()
  if git !=# ''
    s ..= '%#SimpleLineGit# ' .. git .. ' '
  endif

  # Middle: filename
  s ..= '%#SimpleLineMid#'
  s ..= ' ' .. FtIcon() .. '%f'
  s ..= '%( %m%r%)'

  # Separator to background
  s ..= '%#SimpleLineMidSep#' .. s_sep_l

  # Right align
  s ..= '%='

  # LSP status (simplecc)
  var lsp = get(g:, 'simplecc_status', '')
  if lsp !=# ''
    s ..= '%#SimpleLineLSP# ' .. lsp .. ' '
  endif

  # Right section
  s ..= '%#SimpleLineRightSep#' .. s_sep_r
  s ..= '%#SimpleLineRight#'
  s ..= ' %{&filetype} '
  s ..= s_subsep_r
  s ..= ' %{&fileencoding !=# "" ? &fileencoding : &encoding} '
  s ..= s_subsep_r
  s ..= ' %{&fileformat} '

  # Position
  s ..= '%#SimpleLinePosSep#' .. s_sep_r
  s ..= '%#SimpleLinePos# %l:%c %p%% '

  return s
enddef

export def InactiveStatusline(): string
  return '%#SimpleLineInactive# %f%( %m%r%) %= %l:%c '
enddef

# =============================================================
# Tabline (merged from simpletabline)
# =============================================================

# ----------- Tabline state -----------
var s_pick_mode: bool = false
var s_pick_map: dict<number> = {}
var s_last_visible: list<number> = []
var s_pick_chars: list<string> = []
var s_char_to_bufnr: dict<number> = {}
var s_idx_to_buf: dict<number> = {}
var s_buf_to_idx: dict<number> = {}

# ----------- Tabline helpers -----------
def TabConf(name: string, default: any): any
  return get(g:, name, default)
enddef

def TabConfBool(name: string, default_val: bool): bool
  var v = get(g:, name, default_val)
  if type(v) == v:t_bool
    return v
  endif
  if type(v) == v:t_number
    return v != 0
  endif
  return default_val
enddef

def SupDigit(s: string): string
  if s ==# ''
    return ''
  endif
  var m: dict<string> = {
    '0': '⓪', '1': '①', '2': '②', '3': '③', '4': '④',
    '5': '⑤', '6': '⑥', '7': '⑦', '8': '⑧', '9': '⑨'
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
  var rprefix = (R =~? '^[A-Za-z]:/$') ? R : (R .. '/')
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
  var use_listed = TabConf('simpletabline_listed_only', 1) != 0
  var bis = use_listed ? getbufinfo({'buflisted': 1}) : getbufinfo({'bufloaded': 1})
  var res: list<dict<any>> = []
  for b in bis
    var bt = getbufvar(b.bufnr, '&buftype')
    if type(bt) == v:t_string && bt ==# ''
      res->add(b)
    endif
  endfor
  var side = get(g:, 'simpletabline_newbuf_side', 'right')
  if side ==# 'left'
    sort(res, (a, b) => b.bufnr - a.bufnr)
  else
    sort(res, (a, b) => a.bufnr - b.bufnr)
  endif
  return res
enddef

def BufDisplayName(b: dict<any>): string
  var n = bufname(b.bufnr)
  if n ==# ''
    return '[No Name]'
  endif
  var bmode = get(g:, 'simpletabline_path_mode', 'abbr')
  if bmode ==# 'tail'
    return fnamemodify(n, ':t')
  endif
  var abs = fnamemodify(n, ':p')
  var root = TreeRoot()
  if root ==# '' && !!get(g:, 'simpletabline_fallback_cwd_root', 1)
    root = getcwd()
  endif
  var rel = (root !=# '') ? RelToRoot(abs, root) : ''
  if rel ==# ''
    return fnamemodify(n, ':t')
  endif
  if bmode ==# 'rel'
    return rel
  elseif bmode ==# 'abbr'
    return AbbrevRelPath(rel)
  elseif bmode ==# 'abs'
    return abs
  else
    return AbbrevRelPath(rel)
  endif
enddef

def TabLabelText(b: dict<any>, key: string): string
  var name = BufDisplayName(b)
  var sep_key = TabConf('simpletabline_key_sep', '')
  var show_mod = TabConf('simpletabline_show_modified', 1) != 0
  var mod_mark = (show_mod && get(b, 'changed', 0) == 1) ? ' +' : ''
  var key_txt = key
  if key_txt !=# '' && TabConfBool('simpletabline_superscript_index', true)
    key_txt = SupDigit(key_txt)
  endif
  var base = (key_txt !=# '' ? key_txt .. sep_key : '') .. name .. mod_mark
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

def ComputeVisible(all: list<dict<any>>, buf_keys: dict<string>): list<number>
  var cols = max([&columns, 20])
  var sep = TabConf('simpletabline_item_sep', ' | ')
  var sep_w = strdisplaywidth(sep)

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
  var widths_by_bn: dict<number> = {}
  var i = 0
  while i < len(all)
    var key = get(buf_keys, string(all[i].bufnr), '')
    var txt = TabLabelText(all[i], key)
    var w = strdisplaywidth(txt)
    widths->add(w)
    widths_by_bn[all[i].bufnr] = w
    i += 1
  endwhile

  var budget = cols - 2

  # Sticky branch
  if len(s_last_visible) > 0
    var present: dict<number> = {}
    for bi in all
      present[bi.bufnr] = 1
    endfor
    var cand: list<number> = []
    for bn in s_last_visible
      if has_key(present, bn)
        cand->add(bn)
      endif
    endfor

    if index(cand, curbn) >= 0
      def ComputeUsed(lst: list<number>): number
        var used = 0
        var k = 0
        while k < len(lst)
          used += get(widths_by_bn, lst[k], 1)
          if k > 0
            used += sep_w
          endif
          k += 1
        endwhile
        return used
      enddef

      var used_cand = ComputeUsed(cand)
      if used_cand <= budget
        s_last_visible = cand
        return copy(cand)
      endif

      var bs = copy(cand)
      while len(bs) > 0 && ComputeUsed(bs) > budget
        var idx_cur = index(bs, curbn)
        if idx_cur < 0
          break
        endif
        var dist_left = idx_cur
        var dist_right = len(bs) - 1 - idx_cur
        if dist_right >= dist_left
          try | bs->remove(len(bs) - 1) | catch | break | endtry
        else
          try | bs->remove(0) | catch | break | endtry
        endif
      endwhile
      s_last_visible = bs
      return bs
    endif
  endif

  # Expand from center
  var visible_idx: list<number> = [cur_idx]
  var used = widths[cur_idx]
  var left = cur_idx - 1
  var right = cur_idx + 1

  while true
    var added = 0
    if right < len(all)
      var want = used + sep_w + widths[right]
      if want <= budget
        visible_idx->add(right)
        used = want
        right += 1
        added = 1
      endif
    endif
    if left >= 0
      var want2 = used + sep_w + widths[left]
      if want2 <= budget
        visible_idx->insert(left, 0)
        used = want2
        left -= 1
        added = 1
      endif
    endif
    if added == 0
      break
    endif
  endwhile

  s_last_visible = []
  for j in range(len(visible_idx))
    s_last_visible->add(all[visible_idx[j]].bufnr)
  endfor

  return s_last_visible
enddef

# ----------- Pick mode tabline -----------
def TablinePickMode(): string
  var all = ListedNormalBuffers()
  if len(all) == 0
    return ''
  endif

  var buf_keys_empty: dict<string> = {}
  for binfo in all
    buf_keys_empty[string(binfo.bufnr)] = ''
  endfor
  var visible = ComputeVisible(all, buf_keys_empty)

  var bynr: dict<dict<any>> = {}
  for binfo in all
    bynr[string(binfo.bufnr)] = binfo
  endfor

  var sep = TabConf('simpletabline_item_sep', ' | ')
  var ellipsis = TabConf('simpletabline_ellipsis', ' … ')
  var left_omitted = (len(visible) > 0 && visible[0] != all[0].bufnr)
  var right_omitted = (len(visible) > 0 && visible[-1] != all[-1].bufnr)

  var s = ''
  var curbn = bufnr('%')

  var style = get(g:, 'simpleline_separator', 'arrow')
  var use_powerline = (style !=# 'plain')

  s_char_to_bufnr = {}
  var char_idx = 0

  if use_powerline
    # Powerline-style pick mode
    if left_omitted
      s ..= '%#SimpleTablineFill# … '
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

      var icon = BufFtIcon(b.bufnr)
      var name = BufDisplayName(b)
      var show_mod = TabConf('simpletabline_show_modified', 1) != 0
      var mod_mark = (show_mod && get(b, 'changed', 0) == 1) ? ' +' : ''
      var grp_item = is_cur ? '%#SimpleTablineActive#' : '%#SimpleTablineInactive#'

      if hint_char !=# '' && len(name) > 0
        s ..= grp_item .. ' %#SimpleTablinePickHint#' .. hint_char .. grp_item .. ' ' .. icon .. name .. mod_mark .. ' '
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
      s ..= '%#SimpleTablineFill# … '
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

      var name = BufDisplayName(b)
      var show_mod = TabConf('simpletabline_show_modified', 1) != 0
      var mod_mark = (show_mod && get(b, 'changed', 0) == 1) ? ' +' : ''

      var grp_item = is_cur ? '%#SimpleTablineActive#' : '%#SimpleTablineInactive#'
      var name_part = ''

      if hint_char !=# '' && len(name) > 0
        name_part = '%#SimpleTablinePickHint#' .. hint_char .. '%#None#'
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

  var all = ListedNormalBuffers()
  if len(all) == 0
    return ''
  endif

  var sep = TabConf('simpletabline_item_sep', ' | ')
  var ellipsis = TabConf('simpletabline_ellipsis', ' … ')
  var show_keys = 1

  var buf_keys1: dict<string> = {}
  for binfo in all
    buf_keys1[string(binfo.bufnr)] = ''
  endfor
  var visible1 = ComputeVisible(all, buf_keys1)

  AssignDigitsForVisible(visible1)

  var buf_keys2: dict<string> = {}
  for binfo in all
    var dg2 = get(s_buf_to_idx, binfo.bufnr, -1)
    buf_keys2[string(binfo.bufnr)] = dg2 < 0 ? '' : (dg2 == 0 ? '0' : string(dg2))
  endfor
  var visible2 = ComputeVisible(all, buf_keys2)

  AssignDigitsForVisible(visible2)

  var buf_keys: dict<string> = {}
  for binfo in all
    var dg = get(s_buf_to_idx, binfo.bufnr, -1)
    buf_keys[string(binfo.bufnr)] = dg < 0 ? '' : (dg == 0 ? '0' : string(dg))
  endfor
  var visible = visible2

  var bynr: dict<dict<any>> = {}
  for binfo in all
    bynr[string(binfo.bufnr)] = binfo
  endfor

  var left_omitted = (len(visible) > 0 && visible[0] != all[0].bufnr)
  var right_omitted = (len(visible) > 0 && visible[-1] != all[-1].bufnr)

  var s = ''
  var curbn = bufnr('%')
  s_pick_map = copy(s_idx_to_buf)

  var style = get(g:, 'simpleline_separator', 'arrow')
  var use_powerline = (style !=# 'plain')

  if use_powerline
    # Powerline-style tabline
    if left_omitted
      s ..= '%#SimpleTablineFill# … '
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
      var icon = BufFtIcon(b.bufnr)
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
      var name = BufDisplayName(b)
      var show_mod = TabConf('simpletabline_show_modified', 1) != 0
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
      s ..= '%#SimpleTablineFill# … '
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
        var sep_key = TabConf('simpletabline_key_sep', '')
        key_part = key_grp .. key_txt .. '%#None#' .. sep_key
      endif

      var grp_item = is_cur ? '%#SimpleTablineActive#' : '%#SimpleTablineInactive#'
      var name = BufDisplayName(b)
      var show_mod = TabConf('simpletabline_show_modified', 1) != 0
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
  s_pick_chars = split(chars_str, '\zs')
enddef

def ForceRedrawTabline()
  try
    redrawtabline
  catch
  endtry
  try
    redraw!
  catch
  endtry
  try
    execute 'doautocmd User SimpleTablineRefresh'
  catch
  endtry
enddef

export def BufferPick()
  if s_pick_mode
    call CancelPick()
    return
  endif
  InitPickChars()
  s_pick_mode = true
  s_char_to_bufnr = {}
  for ch in s_pick_chars
    try
      execute 'nnoremap <nowait> <silent> ' .. ch .. ' :call simpleline#PickChar("' .. ch .. '")<CR>'
    catch
    endtry
  endfor
  try
    nnoremap <nowait> <silent> <Esc> :call simpleline#CancelPick()<CR>
  catch
  endtry
  ForceRedrawTabline()
enddef

export def CancelPick()
  if !s_pick_mode
    return
  endif
  s_pick_mode = false
  s_char_to_bufnr = {}
  for ch in s_pick_chars
    try
      execute 'nunmap ' .. ch
    catch
    endtry
  endfor
  try
    nunmap <Esc>
  catch
  endtry
  ForceRedrawTabline()
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
  if empty(keys(s_idx_to_buf))
    try | redrawstatus | catch | endtry
  endif
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
  for dir in split(&runtimepath, ',')
    var p = dir .. '/lib/simpleline-daemon'
    if executable(p)
      return p
    endif
  endfor
  return ''
enddef

def StartDaemon(): bool
  if s_running
    return true
  endif
  var cmd = FindDaemon()
  if cmd ==# '' || !executable(cmd)
    return false
  endif
  try
    s_job = job_start([cmd], {
      in_io: 'pipe',
      out_mode: 'nl',
      out_cb: (ch, line) => {
        if line ==# ''
          return
        endif
        var ev: any
        try
          ev = json_decode(line)
        catch
          return
        endtry
        if type(ev) != v:t_dict || !has_key(ev, 'type')
          return
        endif
        if ev.type ==# 'git_info'
          OnGitInfo(ev)
        endif
      },
      err_mode: 'nl',
      err_cb: (ch, line) => {
        # stderr - debug only
      },
      exit_cb: (ch, code) => {
        s_running = false
        s_job = v:null
      },
      stoponexit: 'term'
    })
  catch
    s_job = v:null
    s_running = false
    return false
  endtry
  s_running = (s_job != v:null)
  return s_running
enddef

def SendReq(req: dict<any>)
  if !s_running
    return
  endif
  try
    var json = json_encode(req) .. "\n"
    ch_sendraw(s_job, json)
  catch
  endtry
enddef

def NextId(): number
  s_next_id += 1
  return s_next_id
enddef

def OnGitInfo(ev: dict<any>)
  var dir = s_git_last_dir
  if dir ==# ''
    return
  endif
  s_git_cache[dir] = {
    branch: get(ev, 'branch', ''),
    dirty: get(ev, 'dirty', false),
    added: get(ev, 'added', 0),
    modified: get(ev, 'modified', 0),
    deleted: get(ev, 'deleted', 0),
    ahead: get(ev, 'ahead', 0),
    behind: get(ev, 'behind', 0),
    is_git: get(ev, 'is_git', false),
  }
  # Force statusline redraw
  redrawstatus
enddef

def RequestGitInfo()
  var dir = expand('%:p:h')
  if dir ==# ''
    dir = getcwd()
  endif
  s_git_last_dir = dir
  if !s_running
    if !StartDaemon()
      return
    endif
  endif
  SendReq({type: 'git_info', id: NextId(), path: dir})
enddef

def GitTimerCb(_id: number)
  RequestGitInfo()
enddef

# =============================================================
# Enable / Disable
# =============================================================
export def Enable()
  if s_enabled
    return
  endif
  s_enabled = true

  SetupSeparators()
  SetupHighlights()

  set statusline=%!simpleline#ActiveStatusline()
  set tabline=%!simpleline#Tabline()

  augroup SimpleLineAutoUpdate
    autocmd!
    autocmd WinEnter,BufEnter * setlocal statusline=%!simpleline#ActiveStatusline()
    autocmd WinLeave * setlocal statusline=%!simpleline#InactiveStatusline()
    autocmd BufEnter,BufWritePost * simpleline#RequestGitRefresh()
    autocmd ColorScheme * simpleline#ResetHighlights()
  augroup END

  # Start git polling
  StartDaemon()
  RequestGitInfo()
  if exists('*timer_start')
    s_git_timer = timer_start(
      get(g:, 'simpleline_git_interval', 2000),
      (id) => GitTimerCb(id),
      {repeat: -1}
    )
  endif
enddef

export def Disable()
  if !s_enabled
    return
  endif
  s_enabled = false

  augroup SimpleLineAutoUpdate
    autocmd!
  augroup END

  if s_git_timer != 0
    try | timer_stop(s_git_timer) | catch | endtry
    s_git_timer = 0
  endif

  set statusline=
  set tabline=
enddef

export def Stop()
  Disable()
  if s_job != v:null
    try
      call('job_stop', [s_job])
    catch
    endtry
  endif
  s_running = false
  s_job = v:null
enddef

export def RequestGitRefresh()
  RequestGitInfo()
enddef

export def ResetHighlights()
  SetupHighlights()
enddef

export def DebugStatus()
  echo '[SimpleLine] status:'
  echo '  enabled: ' .. (s_enabled ? 'yes' : 'no')
  echo '  daemon_running: ' .. (s_running ? 'yes' : 'no')
  echo '  git_cache: ' .. string(s_git_cache)
  echo '  separator: ' .. get(g:, 'simpleline_separator', 'arrow')
enddef
