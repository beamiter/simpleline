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
# Commands
# =============================================================
command! SimpleLine simpleline#Enable()
command! SimpleLineDisable simpleline#Disable()
command! SimpleLineDebug simpleline#DebugStatus()

# =============================================================
# Auto-enable
# =============================================================
augroup SimpleLine
  autocmd!
  autocmd VimEnter * ++once simpleline#Enable()
  autocmd VimLeavePre * try | simpleline#Stop() | catch | endtry
augroup END
