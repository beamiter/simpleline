vim9script

if exists('g:loaded_simpleline')
  finish
endif
g:loaded_simpleline = 1

# =============================================================
# Configuration
# =============================================================
g:simpleline_debug = get(g:, 'simpleline_debug', 0)
g:simpleline_daemon_path = get(g:, 'simpleline_daemon_path', '')

# Separator style: 'arrow' (powerline), 'round', 'plain'
g:simpleline_separator = get(g:, 'simpleline_separator', 'arrow')
# Git info refresh interval (ms)
g:simpleline_git_interval = get(g:, 'simpleline_git_interval', 2000)
# Show devicons for filetype (requires Nerd Font)
g:simpleline_nerdfont = get(g:, 'simpleline_nerdfont', 1)

# =============================================================
# Tabline configuration (merged from simpletabline)
# =============================================================
g:simpletabline_show_modified = get(g:, 'simpletabline_show_modified', 1)
g:simpletabline_item_sep      = get(g:, 'simpletabline_item_sep', ' | ')
g:simpletabline_key_sep       = get(g:, 'simpletabline_key_sep', '  ')
g:simpletabline_superscript_index = get(g:, 'simpletabline_superscript_index', 1)
g:simpletabline_listed_only   = get(g:, 'simpletabline_listed_only', 1)
g:simpletabline_pick_chars    = get(g:, 'simpletabline_pick_chars', 'asdfjkl;ghqweruiop')

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
highlight SimpleTablinePickHint guifg=#ff0000 ctermfg=red gui=bold cterm=bold

set showtabline=2

def g:SimpleTablineApplyHL()
  # TabLineSel (active buffer)
  var id_sel   = synIDtrans(hlID('TabLineSel'))
  var sel_bg_gui = synIDattr(id_sel, 'bg#', 'gui')
  var sel_bg_ctm = synIDattr(id_sel, 'bg',  'cterm')
  if sel_bg_gui ==# '' | sel_bg_gui = 'NONE' | endif
  if sel_bg_ctm ==# '' || sel_bg_ctm =~# '^\D' | sel_bg_ctm = 'NONE' | endif

  var cyan_gui   = g:simpletabline_cyan_gui
  var cyan_cterm = g:simpletabline_cyan_cterm

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

nnoremap <silent> <leader>bp :BufferPick<CR>
nnoremap <silent> <leader>bj :BufferPick<CR>

# =============================================================
# Auto-enable
# =============================================================
augroup SimpleLine
  autocmd!
  autocmd VimEnter * ++once simpleline#Enable()
  autocmd VimLeavePre * try | simpleline#Stop() | catch | endtry
augroup END

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
        \ | call g:SimpleTablineApplyHL()
augroup END

augroup SimpleTablineRefresh
  autocmd!
  autocmd User SimpleTablineRefresh redrawtabline
augroup END
