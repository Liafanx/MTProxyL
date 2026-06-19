#!/bin/bash
# MTProxyL — утилиты

log_info()    { echo -e "  ${BLUE}[i]${NC} $1"; }
log_success() { echo -e "  ${GREEN}[${SYM_CHECK}]${NC} $1"; }
log_warn()    { echo -e "  ${YELLOW}[${SYM_WARN}]${NC} $1" >&2; }
log_error()   { echo -e "  ${RED}[${SYM_CROSS}]${NC} $1" >&2; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "MTProxyL должен запускаться от root"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|pop|linuxmint|kali) echo "debian" ;;
            centos|rhel|fedora|rocky|alma|oracle) echo "rhel" ;;
            alpine) echo "alpine" ;;
            *) echo "unknown" ;;
        esac
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/redhat-release ]; then
        echo "rhel"
    else
        echo "unknown"
    fi
}

format_bytes() {
    local bytes=$1
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    if [ "$bytes" -lt 1024 ] 2>/dev/null; then
        echo "${bytes} Б"
    elif [ "$bytes" -lt 1048576 ] 2>/dev/null; then
        echo "$(awk -v b="$bytes" 'BEGIN {printf "%.1f", b/1024}') КБ"
    elif [ "$bytes" -lt 1073741824 ] 2>/dev/null; then
        echo "$(awk -v b="$bytes" 'BEGIN {printf "%.2f", b/1048576}') МБ"
    else
        echo "$(awk -v b="$bytes" 'BEGIN {printf "%.2f", b/1073741824}') ГБ"
    fi
}

format_duration() {
    local secs=$1
    [[ "$secs" =~ ^-?[0-9]+$ ]] || secs=0
    [ "$secs" -lt 1 ] && { echo "0с"; return; }
    local days=$((secs / 86400))
    local hours=$(( (secs % 86400) / 3600 ))
    local mins=$(( (secs % 3600) / 60 ))
    if [ "$days" -gt 0 ]; then echo "${days}д ${hours}ч ${mins}м"
    elif [ "$hours" -gt 0 ]; then echo "${hours}ч ${mins}м"
    elif [ "$mins" -gt 0 ]; then echo "${mins}м"
    else echo "${secs}с"; fi
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

validate_domain() {
    local d="$1"
    [ -z "$d" ] && return 1
    [[ "$d" =~ ^[a-zA-Z0-9.-]+$ ]] && [[ "$d" =~ \. ]]
}

parse_human_bytes() {
    local input="${1:-0}"
    input="${input^^}"
    local num unit
    if [[ "$input" =~ ^([0-9]+(\.[0-9]+)?)[[:space:]]*(B|K|KB|M|MB|G|GB|T|TB)?$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[3]:-B}"
    elif [[ "$input" =~ ^[0-9]+$ ]]; then
        echo "$input"; return 0
    else
        echo "0"; return 1
    fi
    case "$unit" in
        B)        awk -v n="$num" 'BEGIN {printf "%d", n}' ;;
        K|KB)     awk -v n="$num" 'BEGIN {printf "%d", n * 1024}' ;;
        M|MB)     awk -v n="$num" 'BEGIN {printf "%d", n * 1048576}' ;;
        G|GB)     awk -v n="$num" 'BEGIN {printf "%d", n * 1073741824}' ;;
        T|TB)     awk -v n="$num" 'BEGIN {printf "%d", n * 1099511627776}' ;;
        *)        echo "0"; return 1 ;;
    esac
}

get_public_ip() {
    if [ -n "${CUSTOM_IP}" ]; then
        echo "${CUSTOM_IP}"; return 0
    fi
    local ip=""
    ip=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null) ||
    ip=$(curl -s --max-time 3 https://ifconfig.me 2>/dev/null) ||
    ip=$(curl -s --max-time 3 https://icanhazip.com 2>/dev/null) ||
    ip=""
    echo "$ip"
}

generate_secret() {
    openssl rand -hex 16 2>/dev/null || {
        head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 32
    }
}

domain_to_hex() {
    printf '%s' "$1" | od -An -tx1 | tr -d ' \n'
}

build_faketls_secret() {
    local raw_secret="$1" domain="${2:-$PROXY_DOMAIN}"
    if [ "${MASKING_ENABLED:-true}" = "false" ]; then
        echo "dd${raw_secret}"
    else
        local domain_hex
        domain_hex=$(domain_to_hex "$domain")
        echo "ee${raw_secret}${domain_hex}"
    fi
}

_iso_to_epoch() {
    local ts="$1"
    [ -z "$ts" ] && { echo "0"; return; }
    local ts_clean="${ts%%.*}"
    [[ "$ts" == *Z ]] && ts_clean="${ts_clean}Z"
    local epoch
    epoch=$(date -d "${ts_clean}" +%s 2>/dev/null) && [ "$epoch" -gt 0 ] 2>/dev/null && { echo "$epoch"; return; }
    local ts_bb="${ts_clean%Z}"
    epoch=$(date -D '%Y-%m-%dT%H:%M:%S' -d "${ts_bb}" +%s 2>/dev/null) && [ "$epoch" -gt 0 ] 2>/dev/null && { echo "$epoch"; return; }
    echo "0"
}

# Ожидание apt lock
_wait_apt() {
    local _waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        [ $_waited -eq 0 ] && log_info "apt занят, ждём..."
        sleep 3; _waited=$((_waited + 3))
        [ $_waited -ge 60 ] && break
    done
}

# TUI helpers
_strlen() {
    local clean="$1"
    local esc=$'\033'
    clean="${clean//$'\\033'/$esc}"
    while [[ "$clean" == *"${esc}["* ]]; do
        local before="${clean%%${esc}\[*}"
        local rest="${clean#*${esc}\[}"
        local after="${rest#*m}"
        [ "$rest" = "$after" ] && break
        clean="${before}${after}"
    done
    echo "${#clean}"
}

_repeat() {
    local char="$1" count="$2" str
    printf -v str '%*s' "$count" ''
    printf '%s' "${str// /$char}"
}

draw_line() {
    local width="${1:-$TERM_WIDTH}" char="${2:-$BOX_H}" color="${3:-$DIM}"
    echo -e "${color}$(_repeat "$char" "$width")${NC}"
}

draw_header() {
    local title="$1"
    echo ""
    echo -e "  ${BRIGHT_CYAN}${SYM_ARROW} ${BOLD}${title}${NC}"
    echo -e "  ${DIM}$(_repeat '─' $((${#title} + 2)))${NC}"
}

draw_status() {
    local status="$1" label="${2:-}"
    case "$status" in
        running|up|true|enabled|active)
            echo -e "${BRIGHT_GREEN}${SYM_OK}${NC} ${GREEN}${label:-РАБОТАЕТ}${NC}" ;;
        stopped|down|false|disabled|inactive)
            echo -e "${BRIGHT_RED}${SYM_OK}${NC} ${RED}${label:-ОСТАНОВЛЕН}${NC}" ;;
        *)
            echo -e "${DIM}${SYM_OK}${NC} ${DIM}${label:-НЕИЗВЕСТНО}${NC}" ;;
    esac
}

press_any_key() {
    echo ""
    echo -en "  ${DIM}Нажмите любую клавишу...${NC}"
    read -rsn1
    read -rn 256 -t 0.05 _ 2>/dev/null || true
    echo ""
}

read_choice() {
    local prompt="${1:-выбор}"
    local default="${2:-}"
    read -rn 256 -t 0.05 _ 2>/dev/null || true
    echo -en "\n  Введите ${prompt,,}" >&2
    [ -n "$default" ] && echo -en " [${default}]" >&2
    echo -en ": " >&2
    local choice
    read -r choice
    [ -z "$choice" ] && choice="$default"
    echo "$choice"
}

clear_screen() {
    clear 2>/dev/null || printf '\033[2J\033[H'
    echo -e "${BRIGHT_CYAN}${BOLD}  MTProxyL${NC} ${DIM}v${VERSION}${NC} ${DIM}by LiafanX${NC}"
    echo -e "  ${DIM}$(_repeat '─' 30)${NC}"
}
