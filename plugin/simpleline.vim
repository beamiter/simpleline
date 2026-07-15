vim9script

if exists('g:loaded_simpleline')
  finish
endif
g:loaded_simpleline = 1
g:simpleline_version = '0.2.0'

def ConfigFlag(name: string, default_value: number): number
  var value = get(g:, name, default_value)
  if type(value) == v:t_bool
    return value ? 1 : 0
  endif
  if type(value) == v:t_number
    return value != 0 ? 1 : 0
  endif
  return default_value
enddef

# =============================================================
# Configuration
# =============================================================
g:simpleline_debug = ConfigFlag('simpleline_debug', 0)
g:simpleline_daemon_path = get(g:, 'simpleline_daemon_path', '')
g:simpleline_auto_enable = ConfigFlag('simpleline_auto_enable', 1)
g:simpleline_statusline = ConfigFlag('simpleline_statusline', 1)
g:simpleline_tabline = ConfigFlag('simpleline_tabline', 1)
g:simpleline_git_enabled = ConfigFlag('simpleline_git_enabled', 1)
g:simpleline_git_show_status = ConfigFlag('simpleline_git_show_status', 1)
g:simpleline_enable_default_mappings = ConfigFlag('simpleline_enable_default_mappings', 1)

# Separator style: 'arrow' (powerline), 'round', 'plain'
g:simpleline_separator = get(g:, 'simpleline_separator', 'arrow')
# Git info refresh interval (ms)
g:simpleline_git_interval = get(g:, 'simpleline_git_interval', 2000)
# Show devicons for filetype (requires Nerd Font)
g:simpleline_nerdfont = ConfigFlag('simpleline_nerdfont', 1)
# Statusline sections. Narrow windows automatically hide metadata first.
g:simpleline_compact_width = get(g:, 'simpleline_compact_width', 80)
g:simpleline_show_filetype = ConfigFlag('simpleline_show_filetype', 1)
g:simpleline_show_encoding = ConfigFlag('simpleline_show_encoding', 1)
g:simpleline_show_fileformat = ConfigFlag('simpleline_show_fileformat', 1)
g:simpleline_show_position = ConfigFlag('simpleline_show_position', 1)
g:simpleline_show_lsp = ConfigFlag('simpleline_show_lsp', 1)
g:simpleline_filetype_icons = get(g:, 'simpleline_filetype_icons', {})

# =============================================================
# Tabline configuration (merged from simpletabline)
# =============================================================
g:simpletabline_show_modified = ConfigFlag('simpletabline_show_modified', 1)
g:simpletabline_item_sep      = get(g:, 'simpletabline_item_sep', ' | ')
g:simpletabline_key_sep       = get(g:, 'simpletabline_key_sep', '  ')
g:simpletabline_superscript_index = ConfigFlag('simpletabline_superscript_index', 1)
g:simpletabline_listed_only   = ConfigFlag('simpletabline_listed_only', 1)
g:simpletabline_pick_chars    = get(g:, 'simpletabline_pick_chars', 'asdfjkl;ghqweruiopzxcvbnm')
g:simpletabline_show_indexes  = ConfigFlag('simpletabline_show_indexes', 1)
g:simpletabline_path_mode     = get(g:, 'simpletabline_path_mode', 'abbr')
g:simpletabline_fallback_cwd_root = ConfigFlag('simpletabline_fallback_cwd_root', 1)
g:simpletabline_newbuf_side   = get(g:, 'simpletabline_newbuf_side', 'right')
g:simpletabline_ellipsis      = get(g:, 'simpletabline_ellipsis', ' … ')

g:simpletabline_cyan_gui   = get(g:, 'simpletabline_cyan_gui', '#00ffff')
g:simpletabline_cyan_cterm = get(g:, 'simpletabline_cyan_cterm', '14')

# Tabline highlight defaults
highlight default link SimpleTablineActive        TabLineSel
highlight default link SimpleTablineInactive      TabLine
highlight default link SimpleTablineFill          TabLineFill
highlight default link SimpleTablinePickDigit     Title
highlight default link SimpleTablineIndex         TabLine
highlight default link SimpleTablineIndexActive   TabLineSel
highlight default link SimpleTablineSep           TabLine
highlight default link SimpleTablineSepCurrent    TabLineSel
highlight default SimpleTablinePickHint guifg=#ff0000 ctermfg=red gui=bold cterm=bold

def g:SimpleTablineApplyHL()
  # TabLineSel (active buffer)
  var id_sel   = synIDtrans(hlID('TabLineSel'))
  var sel_bg_gui = synIDattr(id_sel, 'bg#', 'gui')
  var sel_bg_ctm = synIDattr(id_sel, 'bg',  'cterm')
  if sel_bg_gui ==# '' | sel_bg_gui = 'NONE' | endif
  if sel_bg_ctm ==# '' || sel_bg_ctm =~# '^\D' | sel_bg_ctm = 'NONE' | endif

  var cyan_gui = type(g:simpletabline_cyan_gui) == v:t_string
        \ && g:simpletabline_cyan_gui =~# '^\%(#[0-9A-Fa-f]\{6}\|[A-Za-z][A-Za-z0-9]*\)$'
        \ ? g:simpletabline_cyan_gui : '#00ffff'
  var cyan_cterm = type(g:simpletabline_cyan_cterm) == v:t_string
        \ && g:simpletabline_cyan_cterm =~# '^\%([0-9]\{1,3}\|[A-Za-z][A-Za-z0-9]*\)$'
        \ ? g:simpletabline_cyan_cterm : '14'

  execute 'highlight SimpleTablineSepCurrent guifg=' .. cyan_gui .. ' guibg=' .. sel_bg_gui .. ' gui=bold ctermfg=' .. cyan_cterm .. ' ctermbg=' .. sel_bg_ctm .. ' cterm=bold'
  execute 'highlight SimpleTablineActive     guifg=' .. cyan_gui .. ' guibg=' .. sel_bg_gui .. ' gui=bold ctermfg=' .. cyan_cterm .. ' ctermbg=' .. sel_bg_ctm .. ' cterm=bold'
  execute 'highlight SimpleTablineIndexActive guifg=' .. cyan_gui .. ' guibg=' .. sel_bg_gui .. ' gui=bold ctermfg=' .. cyan_cterm .. ' ctermbg=' .. sel_bg_ctm .. ' cterm=bold'

  # TabLine (inactive buffer)
  var id_inact    = synIDtrans(hlID('TabLine'))
  var tl_bg_gui  = synIDattr(id_inact, 'bg#', 'gui')
  var tl_bg_ctm  = synIDattr(id_inact, 'bg',  'cterm')
  var tl_fg_gui  = synIDattr(id_inact, 'fg#', 'gui')
  var tl_fg_ctm  = synIDattr(id_inact, 'fg',  'cterm')
  if tl_bg_gui ==# '' | tl_bg_gui = 'NONE' | endif
  if tl_bg_ctm ==# '' || tl_bg_ctm =~# '^\D' | tl_bg_ctm = 'NONE' | endif
  if tl_fg_gui ==# '' | tl_fg_gui = 'NONE' | endif
  if tl_fg_ctm ==# '' || tl_fg_ctm =~# '^\D' | tl_fg_ctm = 'NONE' | endif

  execute 'highlight SimpleTablineSep guifg=' .. tl_fg_gui .. ' guibg=' .. tl_bg_gui .. ' ctermfg=' .. tl_fg_ctm .. ' ctermbg=' .. tl_bg_ctm

  # TabLineFill (background)
  var id_fill    = synIDtrans(hlID('TabLineFill'))
  var fill_bg_gui = synIDattr(id_fill, 'bg#', 'gui')
  var fill_bg_ctm = synIDattr(id_fill, 'bg',  'cterm')
  if fill_bg_gui ==# '' | fill_bg_gui = 'NONE' | endif
  if fill_bg_ctm ==# '' || fill_bg_ctm =~# '^\D' | fill_bg_ctm = 'NONE' | endif

  # Powerline transition highlights (fg = left section bg, bg = right section bg)
  execute 'highlight SimpleTabFillToAct    guifg=' .. fill_bg_gui .. ' guibg=' .. sel_bg_gui .. ' ctermfg=' .. fill_bg_ctm .. ' ctermbg=' .. sel_bg_ctm
  execute 'highlight SimpleTabFillToInact  guifg=' .. fill_bg_gui .. ' guibg=' .. tl_bg_gui .. ' ctermfg=' .. fill_bg_ctm .. ' ctermbg=' .. tl_bg_ctm
  execute 'highlight SimpleTabActToFill    guifg=' .. sel_bg_gui .. ' guibg=' .. fill_bg_gui .. ' ctermfg=' .. sel_bg_ctm .. ' ctermbg=' .. fill_bg_ctm
  execute 'highlight SimpleTabInactToFill  guifg=' .. tl_bg_gui .. ' guibg=' .. fill_bg_gui .. ' ctermfg=' .. tl_bg_ctm .. ' ctermbg=' .. fill_bg_ctm
  execute 'highlight SimpleTabActToInact   guifg=' .. sel_bg_gui .. ' guibg=' .. tl_bg_gui .. ' ctermfg=' .. sel_bg_ctm .. ' ctermbg=' .. tl_bg_ctm
  execute 'highlight SimpleTabInactToAct   guifg=' .. tl_bg_gui .. ' guibg=' .. sel_bg_gui .. ' ctermfg=' .. tl_bg_ctm .. ' ctermbg=' .. sel_bg_ctm
  execute 'highlight SimpleTabInactSep     guifg=' .. fill_bg_gui .. ' guibg=' .. tl_bg_gui .. ' ctermfg=' .. fill_bg_ctm .. ' ctermbg=' .. tl_bg_ctm
enddef

# =============================================================
# Commands
# =============================================================
command! SimpleLine simpleline#Enable()
command! SimpleLineDisable simpleline#Disable()
command! SimpleLineDebug simpleline#DebugStatus()
command! SimpleLineHealth simpleline#Health()
command! SimpleLineToggle simpleline#Toggle()
command! SimpleLineReload simpleline#Reload()
command! SimpleLineGitRefresh simpleline#RequestGitRefresh()

# Tabline commands
command! BufferPick  call simpleline#BufferPick()
command! BufferJump1 call simpleline#BufferJump1()
command! BufferJump2 call simpleline#BufferJump2()
command! BufferJump3 call simpleline#BufferJump3()
command! BufferJump4 call simpleline#BufferJump4()
command! BufferJump5 call simpleline#BufferJump5()
command! BufferJump6 call simpleline#BufferJump6()
command! BufferJump7 call simpleline#BufferJump7()
command! BufferJump8 call simpleline#BufferJump8()
command! BufferJump9 call simpleline#BufferJump9()
command! BufferJump0 call simpleline#BufferJump0()
command! -nargs=1 SimpleLineBufferJump call simpleline#BufferJumpCommand(<q-args>)

nnoremap <silent> <Plug>(simpleline-buffer-pick) :<C-U>BufferPick<CR>
for i in range(10)
  execute 'nnoremap <silent> <Plug>(simpleline-buffer-jump-' .. i .. ') :<C-U>call simpleline#BufferJump(' .. i .. ')<CR>'
endfor

# Preserve the historical defaults, but never replace a mapping owned by the user.
if g:simpleline_enable_default_mappings
  if maparg('<leader>bp', 'n') ==# ''
    nmap <silent> <leader>bp <Plug>(simpleline-buffer-pick)
  endif
  if maparg('<leader>bj', 'n') ==# ''
    nmap <silent> <leader>bj <Plug>(simpleline-buffer-pick)
  endif
endif

# =============================================================
# Auto-enable
# =============================================================
augroup SimpleLine
  autocmd!
  if g:simpleline_auto_enable
    autocmd VimEnter * ++once simpleline#Enable()
  endif
  autocmd VimLeavePre * try | simpleline#Stop() | catch | endtry
augroup END

if g:simpleline_auto_enable && v:vim_did_enter
  simpleline#Enable()
endif

augroup SimpleTablineAuto
  autocmd!
  autocmd VimEnter * call g:SimpleTablineApplyHL() | redrawstatus
  autocmd ColorScheme * highlight default link SimpleTablineActive        TabLineSel
        \ | highlight default link SimpleTablineInactive      TabLine
        \ | highlight default link SimpleTablineFill          TabLineFill
        \ | highlight default link SimpleTablinePickDigit     Title
        \ | highlight default link SimpleTablineIndex         TabLine
        \ | highlight default link SimpleTablineIndexActive   TabLineSel
        \ | highlight default link SimpleTablineSep           TabLine
        \ | highlight default link SimpleTablineSepCurrent    TabLineSel
        \ | highlight default SimpleTablinePickHint guifg=#ff0000 ctermfg=red gui=bold cterm=bold
        \ | call g:SimpleTablineApplyHL()
augroup END

augroup SimpleTablineRefresh
  autocmd!
  autocmd User SimpleTablineRefresh redrawtabline
augroup END
