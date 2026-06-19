#!/bin/bash
# MTProxyL — цвета, символы, константы UI

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

readonly BRIGHT_GREEN='\033[1;32m'
readonly BRIGHT_CYAN='\033[1;36m'
readonly BRIGHT_YELLOW='\033[1;33m'
readonly BRIGHT_RED='\033[1;31m'
readonly BRIGHT_MAGENTA='\033[1;35m'

# Box drawing
readonly BOX_TL='┌' BOX_TR='┐' BOX_BL='└' BOX_BR='┘'
readonly BOX_H='─' BOX_V='│' BOX_LT='├' BOX_RT='┤'

# Symbols
readonly SYM_OK='●'
readonly SYM_CHECK='✓'
readonly SYM_CROSS='✗'
readonly SYM_WARN='!'
readonly SYM_ARROW='►'
readonly SYM_UP='↑'
readonly SYM_DOWN='↓'

# Terminal width
TERM_WIDTH=$(tput cols 2>/dev/null || echo 60)
[ "$TERM_WIDTH" -gt 80 ] && TERM_WIDTH=80
[ "$TERM_WIDTH" -lt 40 ] && TERM_WIDTH=60
