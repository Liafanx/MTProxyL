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

detect_tls_cert_len() {
    local domain="$1"
    [ -n "$domain" ] || return 1
    command -v openssl &>/dev/null || return 1

    local _pem=""
    if command -v timeout &>/dev/null; then
        _pem=$(timeout 8 openssl s_client -servername "$domain" -connect "${domain}:443" -showcerts </dev/null 2>/dev/null | \
            awk '/-----BEGIN CERTIFICATE-----/{p=1} p{print} /-----END CERTIFICATE-----/{exit}')
    else
        _pem=$(openssl s_client -servername "$domain" -connect "${domain}:443" -showcerts </dev/null 2>/dev/null | \
            awk '/-----BEGIN CERTIFICATE-----/{p=1} p{print} /-----END CERTIFICATE-----/{exit}')
    fi

    [ -n "$_pem" ] || return 1

    local _len
    _len=$(printf '%s\n' "$_pem" | openssl x509 -outform DER 2>/dev/null | wc -c | tr -d ' ')
    [[ "$_len" =~ ^[0-9]+$ ]] || return 1
    [ "$_len" -ge 512 ] && [ "$_len" -le 65535 ] || return 1

    echo "$_len"
}

auto_set_fake_cert_len() {
    local domain="$1"
    [ -n "$domain" ] || return 1
    local _old="${FAKE_CERT_LEN:-2048}"
    local _new
    _new=$(detect_tls_cert_len "$domain" 2>/dev/null) || return 1
    if [ "$_new" != "$_old" ]; then
        FAKE_CERT_LEN="$_new"
        log_info "Auto-detected TLS cert length for '${domain}': ${FAKE_CERT_LEN} bytes (was ${_old})"
    else
        log_info "TLS cert length for '${domain}': ${FAKE_CERT_LEN} bytes"
    fi
    return 0
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

# ── Проверка обновлений ───────────────────────────────────────
_UPDATE_AVAILABLE=""

check_for_update() {
    local _remote_ver
    _remote_ver=$(curl -fsS --max-time 5 "${GITHUB_RAW}/version" 2>/dev/null | tr -d '[:space:]')
    [ -z "$_remote_ver" ] && return 0
    if [ "$_remote_ver" != "$VERSION" ]; then
        _UPDATE_AVAILABLE="$_remote_ver"
    else
        _UPDATE_AVAILABLE=""
    fi
}

self_update() {
    log_info "Скачивание обновления..."
    local _tmp="/tmp/mtproxyl-update-$$.sh"
    if ! curl -fsS --max-time 30 "${GITHUB_RAW}/mtproxyl.sh" -o "$_tmp" 2>/dev/null; then
        log_error "Не удалось скачать обновление"; rm -f "$_tmp"; return 1
    fi
    if ! bash -n "$_tmp" 2>/dev/null; then
        log_error "Ошибка синтаксиса — отменено"; rm -f "$_tmp"; return 1
    fi
    local _new_ver
    _new_ver=$(grep -m1 '^VERSION="' "$_tmp" | cut -d'"' -f2)
    if [ -z "$_new_ver" ]; then
        log_error "Не удалось определить версию"; rm -f "$_tmp"; return 1
    fi
    if [ "$_new_ver" = "$VERSION" ]; then
        log_info "Версия актуальна (v${VERSION})"; rm -f "$_tmp"; return 0
    fi
    cp "${INSTALL_DIR}/mtproxyl.sh" "${INSTALL_DIR}/mtproxyl.sh.backup-$(date +%s)" 2>/dev/null || true
    mv "$_tmp" "${INSTALL_DIR}/mtproxyl.sh"; chmod +x "${INSTALL_DIR}/mtproxyl.sh"
    log_info "Обновление библиотек..."
    for lib in colors utils settings secrets config docker engine traffic geoblock upstream backup nft tui_main tui_proxy tui_secrets tui_links tui_settings tui_security tui_traffic tui_engine tui_backup tui_expert tui_nft expert_catalog expert_mode install; do
        curl -fsS --max-time 15 "${GITHUB_RAW}/lib/${lib}.sh" -o "${LIB_DIR}/${lib}.sh" 2>/dev/null || true
    done
    log_success "Обновлено до v${_new_ver}"
    log_info "Перезапуск..."
    exec "${INSTALL_DIR}/mtproxyl.sh"
}

# ── CLI-обработчики для быстрых команд ────────────────────────
handle_port_command() {
    local new_port="${1:-}"
    if [ -z "$new_port" ]; then
        echo -e "  ${BOLD}Порт:${NC} ${PROXY_PORT}"
        return 0
    fi
    check_root
    if validate_port "$new_port"; then
        PROXY_PORT="$new_port"
        save_settings
        log_success "Порт: ${PROXY_PORT}"
        if is_proxy_running; then
            load_secrets
            restart_proxy_container || true
        fi
    else
        log_error "Некорректный порт: ${new_port} (допустимо 1..65535)"
        return 1
    fi
}

handle_ip_command() {
    local new_ip="${1:-}"
    if [ -z "$new_ip" ]; then
        local current="${CUSTOM_IP:-$(get_public_ip 2>/dev/null)}"
        echo -e "  ${BOLD}IP:${NC} ${current}$([ -z "$CUSTOM_IP" ] && echo " ${DIM}(авто)${NC}")"
        return 0
    fi
    check_root
    case "$new_ip" in
        auto|clear|reset)
            CUSTOM_IP=""
            save_settings
            log_success "IP: авто ($(get_public_ip 2>/dev/null || echo '?'))"
            ;;
        *)
            CUSTOM_IP="$new_ip"
            save_settings
            log_success "IP: ${CUSTOM_IP}"
            ;;
    esac
}

handle_domain_command() {
    local new_domain="${1:-}"
    if [ -z "$new_domain" ]; then
        echo -e "  ${BOLD}Домен:${NC} ${PROXY_DOMAIN}"
        return 0
    fi
    check_root
    if validate_domain "$new_domain"; then
        local _old_domain="$PROXY_DOMAIN"
        PROXY_DOMAIN="$new_domain"
        auto_set_fake_cert_len "$PROXY_DOMAIN" 2>/dev/null || \
            log_warn "Не удалось определить TLS cert length для '${PROXY_DOMAIN}', оставляем ${FAKE_CERT_LEN:-2048}"
        save_settings
        log_success "Домен: ${PROXY_DOMAIN}"
        # Предложить обновить mask backend
        if [ "$MASKING_ENABLED" = "true" ] && [ "$PROXY_DOMAIN" != "$_old_domain" ]; then
            local _cur_mask="${MASKING_HOST:-$_old_domain}"
            if [ "$_cur_mask" = "$_old_domain" ] || [ -z "$MASKING_HOST" ]; then
                echo -en "  ${BOLD}Обновить mask backend на ${PROXY_DOMAIN}? [Y/n]:${NC} "
                local _mask_yn; read -r _mask_yn
                if [[ ! "$_mask_yn" =~ ^[nN]$ ]]; then
                    MASKING_HOST="$PROXY_DOMAIN"
                    save_settings
                    log_success "Mask backend: ${MASKING_HOST}:${MASKING_PORT:-443}"
                fi
            fi
        fi
        if is_proxy_running; then
            load_secrets
            restart_proxy_container || true
        fi
    else
        log_error "Некорректный домен: ${new_domain}"
        return 1
    fi
}

handle_mask_backend() {
    local input="${1:-}"
    if [ -z "$input" ]; then
        echo -e "  ${BOLD}Mask backend:${NC} ${MASKING_HOST:-${PROXY_DOMAIN}}:${MASKING_PORT:-443}"
        return 0
    fi
    check_root
    # Парсим host:port или только host
    local new_host new_port
    if [[ "$input" =~ ^(.+):([0-9]+)$ ]]; then
        new_host="${BASH_REMATCH[1]}"
        new_port="${BASH_REMATCH[2]}"
    else
        new_host="$input"
        new_port=""
    fi
    [ -n "$new_host" ] && MASKING_HOST="$new_host"
    if [ -n "$new_port" ]; then
        if validate_port "$new_port"; then
            MASKING_PORT="$new_port"
        else
            log_error "Некорректный порт: ${new_port}"
            return 1
        fi
    fi
    save_settings
    log_success "Mask backend: ${MASKING_HOST:-${PROXY_DOMAIN}}:${MASKING_PORT:-443}"
    if is_proxy_running; then
        load_secrets
        restart_proxy_container || true
    fi
}

handle_sni_policy() {
    local new_policy="${1:-}"
    if [ -z "$new_policy" ]; then
        echo -e "  ${BOLD}SNI-политика:${NC} ${UNKNOWN_SNI_ACTION}"
        return 0
    fi
    check_root
    case "$new_policy" in
        mask|drop|accept|reject_handshake)
            UNKNOWN_SNI_ACTION="$new_policy"
            save_settings
            reload_proxy_config 2>/dev/null || true
            log_success "SNI-политика: ${UNKNOWN_SNI_ACTION}"
            ;;
        *)
            log_error "Допустимые значения: mask, drop, accept, reject_handshake"
            return 1
            ;;
    esac
}

validate_ip_literal() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    local -a octets=($ip)
    local o
    for o in "${octets[@]}"; do
        [ "$o" -ge 0 ] && [ "$o" -le 255 ] 2>/dev/null || return 1
    done
    return 0
}

show_cli_help() {
    echo ""
    echo -e "  ${BRIGHT_CYAN}${BOLD}MTProxyL${NC} ${DIM}v${VERSION}${NC} — Менеджер Telegram MTProto прокси"
    echo ""
    echo -e "  ${BOLD}Использование:${NC} mtproxyl <команда> [параметры]"
    echo ""
    echo -e "  ${BOLD}Прокси:${NC}         start | stop | restart | status [--json]"
    echo -e "  ${BOLD}Секреты:${NC}        secret add|remove|list|rotate|enable|disable|limits|link|qr|clone|rename"
    echo -e "  ${BOLD}Настройки:${NC}      port | ip | domain | mask-backend | config"
    echo -e "  ${BOLD}Движок:${NC}         engine status|list|update|rollback|rebuild"
    echo -e "  ${BOLD}Эксперт:${NC}        expert list|set|clear|edit"
    echo -e "  ${BOLD}NFT:${NC}            nft apply|remove|service|drop|preset|ios1|ios2"
    echo -e "  ${BOLD}Безопасность:${NC}   geoblock add|remove|list | upstream list|add|remove | sni-policy"
    echo -e "  ${BOLD}Мониторинг:${NC}     traffic | connections | metrics [live] | logs | health | info"
    echo -e "  ${BOLD}Бэкапы:${NC}         backup [--encrypt] | restore <файл>"
    echo -e "  ${BOLD}Система:${NC}        install | menu | update | uninstall | version | help"
    echo ""
}

# ── Проверка доступности порта ────────────────────────────────
is_port_available() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ! ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
    elif command -v netstat &>/dev/null; then
        ! netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
    else
        return 0
    fi
}

find_free_metrics_port() {
    local start="${1:-9090}"
    local end="${2:-9199}"
    local p
    for ((p=start; p<=end; p++)); do
        if is_port_available "$p"; then
            echo "$p"
            return 0
        fi
    done
    return 1
}
