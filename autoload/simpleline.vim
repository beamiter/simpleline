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

  # Inactive
  highlight SimpleLineInactive  guibg=#282c34 guifg=#5c6370 ctermfg=241 ctermbg=235

  # Tabline
  highlight SimpleLineTabFill   guibg=#282c34 guifg=#5c6370 ctermfg=241 ctermbg=235
  highlight SimpleLineTabActive guibg=#61afef guifg=#282c34 gui=bold ctermfg=235 ctermbg=75 cterm=bold
  highlight SimpleLineTabActiveSep guifg=#61afef guibg=#282c34 ctermfg=75 ctermbg=235
  highlight SimpleLineTab       guibg=#3e4452 guifg=#abb2bf ctermfg=145 ctermbg=238
  highlight SimpleLineTabSep    guifg=#3e4452 guibg=#282c34 ctermfg=238 ctermbg=235
  highlight SimpleLineTabNum    guibg=#3e4452 guifg=#e5c07b gui=bold ctermfg=180 ctermbg=238 cterm=bold
  highlight SimpleLineTabNumActive guibg=#61afef guifg=#282c34 gui=bold ctermfg=235 ctermbg=75 cterm=bold
  highlight SimpleLineTabMod    guibg=#3e4452 guifg=#e06c75 gui=bold ctermfg=168 ctermbg=238 cterm=bold
  highlight SimpleLineTabModActive guibg=#61afef guifg=#e06c75 gui=bold ctermfg=168 ctermbg=75 cterm=bold
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
# Tabline builder
# =============================================================
export def Tabline(): string
  var s = ''
  var bufs = BufList()
  var cur = bufnr('%')
  var idx = 0
  for b in bufs
    idx += 1
    var is_cur = (b == cur)
    var bname = bufname(b)
    var fname = bname ==# '' ? '[No Name]' : fnamemodify(bname, ':t')
    var is_mod = getbufvar(b, '&modified')

    if is_cur
      s ..= '%#SimpleLineTabActiveSep#' .. s_sep_r
      s ..= '%#SimpleLineTabNumActive# ' .. idx .. ' '
      s ..= '%#SimpleLineTabActive# ' .. fname
      if is_mod
        s ..= ' %#SimpleLineTabModActive#+'
      endif
      s ..= ' %#SimpleLineTabActiveSep#' .. s_sep_l
    else
      s ..= '%#SimpleLineTabSep#' .. s_sep_r
      s ..= '%#SimpleLineTabNum# ' .. idx .. ' '
      s ..= '%#SimpleLineTab# ' .. fname
      if is_mod
        s ..= ' %#SimpleLineTabMod#+'
      endif
      s ..= ' %#SimpleLineTabSep#' .. s_sep_l
    endif
  endfor

  s ..= '%#SimpleLineTabFill#%='
  return s
enddef

# Get the ordered list of "visible" buffers for tabline
def BufList(): list<number>
  var result: list<number> = []
  for b in range(1, bufnr('$'))
    if buflisted(b) && getbufvar(b, '&buftype') ==# ''
      result->add(b)
    endif
  endfor
  return result
enddef

# =============================================================
# BufferJump commands
# =============================================================
export def BufferJump(idx: number)
  var bufs = BufList()
  if idx >= 1 && idx <= len(bufs)
    execute 'buffer ' .. bufs[idx - 1]
  endif
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

  # BufferJump commands
  for i in range(0, 9)
    execute printf('command! BufferJump%d simpleline#BufferJump(%d)', i, i == 0 ? 10 : i)
  endfor

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
