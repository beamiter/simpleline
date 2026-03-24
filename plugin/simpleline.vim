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
  var id_sel   = synIDtrans(hlID('TabLineSel'))
  var bg_gui_s = synIDattr(id_sel, 'bg#', 'gui')
  var bg_ctm_s = synIDattr(id_sel, 'bg',  'cterm')
  if bg_gui_s ==# '' | bg_gui_s = 'NONE' | endif
  if bg_ctm_s ==# '' || bg_ctm_s =~# '^\D' | bg_ctm_s = 'NONE' | endif

  var cyan_gui   = g:simpletabline_cyan_gui
  var cyan_cterm = g:simpletabline_cyan_cterm

  execute 'highlight SimpleTablineSepCurrent guifg=' .. cyan_gui .. ' guibg=' .. bg_gui_s .. ' gui=bold ctermfg=' .. cyan_cterm .. ' ctermbg=' .. bg_ctm_s .. ' cterm=bold'
  execute 'highlight SimpleTablineActive     guifg=' .. cyan_gui .. ' guibg=' .. bg_gui_s .. ' gui=bold ctermfg=' .. cyan_cterm .. ' ctermbg=' .. bg_ctm_s .. ' cterm=bold'
  execute 'highlight SimpleTablineIndexActive guifg=' .. cyan_gui .. ' guibg=' .. bg_gui_s .. ' gui=bold ctermfg=' .. cyan_cterm .. ' ctermbg=' .. bg_ctm_s .. ' cterm=bold'

  var id_inact    = synIDtrans(hlID('TabLine'))
  var sep_bg_gui  = synIDattr(id_inact, 'bg#', 'gui')
  var sep_bg_ctm  = synIDattr(id_inact, 'bg',  'cterm')
  var sep_fg_gui  = synIDattr(id_inact, 'fg#', 'gui')
  var sep_fg_ctm  = synIDattr(id_inact, 'fg',  'cterm')
  if sep_bg_gui ==# '' | sep_bg_gui = 'NONE' | endif
  if sep_bg_ctm ==# '' || sep_bg_ctm =~# '^\D' | sep_bg_ctm = 'NONE' | endif
  if sep_fg_gui ==# '' | sep_fg_gui = 'NONE' | endif
  if sep_fg_ctm ==# '' || sep_fg_ctm =~# '^\D' | sep_fg_ctm = 'NONE' | endif

  execute 'highlight SimpleTablineSep guifg=' .. sep_fg_gui .. ' guibg=' .. sep_bg_gui .. ' ctermfg=' .. sep_fg_ctm .. ' ctermbg=' .. sep_bg_ctm
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
