#!/bin/bash
# MTProxyL — upstream маршрутизация

declare -a UPSTREAM_NAMES=()
declare -a UPSTREAM_TYPES=()
declare -a UPSTREAM_ADDRS=()
declare -a UPSTREAM_USERS=()
declare -a UPSTREAM_PASSES=()
declare -a UPSTREAM_WEIGHTS=()
declare -a UPSTREAM_IFACES=()
declare -a UPSTREAM_ENABLED=()

save_upstreams() {
    mkdir -p "$INSTALL_DIR"
    local tmp; tmp=$(_mktemp) || return 1

    echo "# MTProxyL — upstream-маршруты v${VERSION}" > "$tmp"
    echo "# Формат: NAME|TYPE|ADDR|USER|PASS|WEIGHT|IFACE|ENABLED" >> "$tmp"

    local i
    for i in "${!UPSTREAM_NAMES[@]}"; do
        echo "${UPSTREAM_NAMES[$i]}|${UPSTREAM_TYPES[$i]}|${UPSTREAM_ADDRS[$i]}|${UPSTREAM_USERS[$i]}|${UPSTREAM_PASSES[$i]}|${UPSTREAM_WEIGHTS[$i]}|${UPSTREAM_IFACES[$i]}|${UPSTREAM_ENABLED[$i]}" >> "$tmp"
    done

    chmod 600 "$tmp"
    mv "$tmp" "$UPSTREAMS_FILE"
}

load_upstreams() {
    UPSTREAM_NAMES=(); UPSTREAM_TYPES=(); UPSTREAM_ADDRS=()
    UPSTREAM_USERS=(); UPSTREAM_PASSES=(); UPSTREAM_WEIGHTS=()
    UPSTREAM_IFACES=(); UPSTREAM_ENABLED=()

    if [ ! -f "$UPSTREAMS_FILE" ]; then
        UPSTREAM_NAMES+=("direct"); UPSTREAM_TYPES+=("direct")
        UPSTREAM_ADDRS+=(""); UPSTREAM_USERS+=(""); UPSTREAM_PASSES+=("")
        UPSTREAM_WEIGHTS+=("10"); UPSTREAM_IFACES+=(""); UPSTREAM_ENABLED+=("true")
        return 0
    fi

    while IFS='|' read -r name type addr user pass weight iface enabled; do
        [[ "$name" =~ ^[[:space:]]*# ]] && continue
        [[ "$name" =~ ^[[:space:]]*$ ]] && continue
        [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || continue

        # Совместимость со старым 7-колоночным форматом
        if [ "$iface" = "true" ] || [ "$iface" = "false" ]; then
            enabled="$iface"; iface=""
        fi

        local _type="${type:-direct}"
        case "$_type" in direct|socks5|socks4) ;; *) _type="direct" ;; esac
        local _weight="${weight:-10}"
        [[ "$_weight" =~ ^[0-9]+$ ]] && [ "$_weight" -ge 1 ] && [ "$_weight" -le 100 ] || _weight="10"
        local _enabled="${enabled:-true}"
        [ "$_enabled" != "true" ] && [ "$_enabled" != "false" ] && _enabled="true"
        [ "$_type" != "direct" ] && [ -z "${addr:-}" ] && continue

        UPSTREAM_NAMES+=("$name"); UPSTREAM_TYPES+=("$_type")
        UPSTREAM_ADDRS+=("${addr:-}"); UPSTREAM_USERS+=("${user:-}")
        UPSTREAM_PASSES+=("${pass:-}"); UPSTREAM_WEIGHTS+=("$_weight")
        UPSTREAM_IFACES+=("${iface:-}"); UPSTREAM_ENABLED+=("$_enabled")
    done < "$UPSTREAMS_FILE"

    if [ ${#UPSTREAM_NAMES[@]} -eq 0 ]; then
        UPSTREAM_NAMES+=("direct"); UPSTREAM_TYPES+=("direct")
        UPSTREAM_ADDRS+=(""); UPSTREAM_USERS+=(""); UPSTREAM_PASSES+=("")
        UPSTREAM_WEIGHTS+=("10"); UPSTREAM_IFACES+=(""); UPSTREAM_ENABLED+=("true")
    fi
}

upstream_add() {
    local name="$1" type="$2" addr="${3:-}" user="${4:-}" pass="${5:-}" weight="${6:-10}" iface="${7:-}"

    [ -z "$name" ] || [ -z "$type" ] && { log_error "Требуются имя и тип"; return 1; }
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || { log_error "Имя: a-z, 0-9, _, -"; return 1; }

    local i
    for i in "${!UPSTREAM_NAMES[@]}"; do
        [ "${UPSTREAM_NAMES[$i]}" = "$name" ] && { log_error "Upstream '${name}' уже существует"; return 1; }
    done

    case "$type" in
        direct|socks5|socks4) ;;
        *) log_error "Тип: direct, socks5, socks4"; return 1 ;;
    esac

    [ "$type" != "direct" ] && [ -z "$addr" ] && { log_error "Адрес обязателен для ${type}"; return 1; }

    if [ "$type" != "direct" ] && [ -n "$addr" ]; then
        [[ "$addr" =~ ^[a-zA-Z0-9._-]+:[0-9]+$ ]] || { log_error "Адрес: host:port"; return 1; }
    fi

    [[ "$weight" =~ ^[0-9]+$ ]] && [ "$weight" -ge 1 ] && [ "$weight" -le 100 ] || { log_error "Вес: 1-100"; return 1; }

    UPSTREAM_NAMES+=("$name"); UPSTREAM_TYPES+=("$type")
    UPSTREAM_ADDRS+=("$addr"); UPSTREAM_USERS+=("$user")
    UPSTREAM_PASSES+=("$pass"); UPSTREAM_WEIGHTS+=("$weight")
    UPSTREAM_IFACES+=("$iface"); UPSTREAM_ENABLED+=("true")

    save_upstreams
    is_proxy_running && restart_proxy_container
    log_success "Upstream '${name}' добавлен (${type})"
}

upstream_remove() {
    local name="$1"
    [ ${#UPSTREAM_NAMES[@]} -le 1 ] && { log_error "Нельзя удалить последний upstream"; return 1; }

    local idx=-1 i
    for i in "${!UPSTREAM_NAMES[@]}"; do
        [ "${UPSTREAM_NAMES[$i]}" = "$name" ] && { idx=$i; break; }
    done
    [ $idx -eq -1 ] && { log_error "Upstream '${name}' не найден"; return 1; }

    local -a nn=() nt=() na=() nu=() np=() nw=() ni=() ne=()
    for i in "${!UPSTREAM_NAMES[@]}"; do
        [ "$i" -eq "$idx" ] && continue
        nn+=("${UPSTREAM_NAMES[$i]}"); nt+=("${UPSTREAM_TYPES[$i]}")
        na+=("${UPSTREAM_ADDRS[$i]}"); nu+=("${UPSTREAM_USERS[$i]}")
        np+=("${UPSTREAM_PASSES[$i]}"); nw+=("${UPSTREAM_WEIGHTS[$i]}")
        ni+=("${UPSTREAM_IFACES[$i]}"); ne+=("${UPSTREAM_ENABLED[$i]}")
    done
    UPSTREAM_NAMES=("${nn[@]}"); UPSTREAM_TYPES=("${nt[@]}")
    UPSTREAM_ADDRS=("${na[@]}"); UPSTREAM_USERS=("${nu[@]}")
    UPSTREAM_PASSES=("${np[@]}"); UPSTREAM_WEIGHTS=("${nw[@]}")
    UPSTREAM_IFACES=("${ni[@]}"); UPSTREAM_ENABLED=("${ne[@]}")

    save_upstreams
    is_proxy_running && restart_proxy_container
    log_success "Upstream '${name}' удалён"
}

upstream_list() {
    load_upstreams
    echo ""
    draw_header "UPSTREAM-МАРШРУТЫ"
    echo ""
    printf "  ${BOLD}%-4s %-18s %-8s %-28s %-8s %-10s${NC}\n" "#" "ИМЯ" "ТИП" "АДРЕС" "ВЕС" "СТАТУС"
    echo -e "  ${DIM}$(_repeat '─' 80)${NC}"

    local i
    for i in "${!UPSTREAM_NAMES[@]}"; do
        local addr_plain="${UPSTREAM_ADDRS[$i]:-—}"
        [ -n "${UPSTREAM_IFACES[$i]}" ] && addr_plain="${addr_plain} (${UPSTREAM_IFACES[$i]})"

        local status_str
        if [ "${UPSTREAM_ENABLED[$i]}" = "true" ]; then
            status_str="${GREEN}${SYM_OK} активен${NC}"
        else
            status_str="${RED}${SYM_CROSS} выключен${NC}"
        fi

        printf "  %-4s %-18s %-8s %-28s %-8s " \
            "$((i+1))" "${UPSTREAM_NAMES[$i]}" "${UPSTREAM_TYPES[$i]}" "$addr_plain" "${UPSTREAM_WEIGHTS[$i]}"
        echo -e "$status_str"
    done
    echo ""
}

upstream_toggle() {
    local name="$1" action="${2:-toggle}"
    local idx=-1 i
    for i in "${!UPSTREAM_NAMES[@]}"; do
        [ "${UPSTREAM_NAMES[$i]}" = "$name" ] && { idx=$i; break; }
    done
    [ $idx -eq -1 ] && { log_error "Upstream '${name}' не найден"; return 1; }

    case "$action" in
        enable)  UPSTREAM_ENABLED[$idx]="true" ;;
        disable) UPSTREAM_ENABLED[$idx]="false" ;;
        toggle)
            [ "${UPSTREAM_ENABLED[$idx]}" = "true" ] && UPSTREAM_ENABLED[$idx]="false" || UPSTREAM_ENABLED[$idx]="true" ;;
    esac

    save_upstreams
    is_proxy_running && restart_proxy_container
    log_success "Upstream '${name}': ${UPSTREAM_ENABLED[$idx]}"
}

upstream_test() {
    local name="$1"
    local idx=-1 i
    for i in "${!UPSTREAM_NAMES[@]}"; do
        [ "${UPSTREAM_NAMES[$i]}" = "$name" ] && { idx=$i; break; }
    done
    [ $idx -eq -1 ] && { log_error "Upstream '${name}' не найден"; return 1; }

    local type="${UPSTREAM_TYPES[$idx]}" addr="${UPSTREAM_ADDRS[$idx]}"

    if [ "$type" = "direct" ]; then
        log_info "Проверка прямого соединения..."
        local result
        result=$(curl -sf --max-time 10 https://api.ipify.org 2>/dev/null)
        if [[ "$result" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log_success "Прямое соединение OK — IP: ${result}"
        else
            log_error "Прямое соединение не удалось"
        fi
        return
    fi

    [ -z "$addr" ] && { log_error "Нет адреса для '${name}'"; return 1; }
    log_info "Проверка ${type} прокси ${addr}..."

    local proxy_url
    local pu="${UPSTREAM_USERS[$idx]}" pp="${UPSTREAM_PASSES[$idx]}"
    if [ -n "$pu" ] && [ -n "$pp" ]; then
        proxy_url="${type}://${pu}:${pp}@${addr}"
    elif [ -n "$pu" ]; then
        proxy_url="${type}://${pu}@${addr}"
    else
        proxy_url="${type}://${addr}"
    fi
    proxy_url="${proxy_url/socks5:\/\//socks5h:\/\/}"

    local result
    result=$(curl -sf --max-time 15 -x "$proxy_url" https://api.ipify.org 2>/dev/null)
    if [[ "$result" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_success "${type} прокси OK — IP выхода: ${result}"
    else
        log_error "${type} прокси ${addr} не отвечает"
    fi
}

handle_upstream_command() {
    local subcmd="${1:-list}"; shift 2>/dev/null || true
    case "$subcmd" in
        list)    upstream_list ;;
        add)     check_root; upstream_add "$@" ;;
        remove)  check_root; upstream_remove "$1" ;;
        enable)  check_root; upstream_toggle "$1" enable ;;
        disable) check_root; upstream_toggle "$1" disable ;;
        test)    upstream_test "$1" ;;
        *)
            echo -e "  ${BOLD}Upstream-маршруты:${NC}"
            echo -e "    ${GREEN}upstream list${NC}                             Список"
            echo -e "    ${GREEN}upstream add${NC} <имя> <тип> <адрес> [логин] [пароль] [вес] [интерфейс]"
            echo -e "    ${GREEN}upstream remove${NC} <имя>                     Удалить"
            echo -e "    ${GREEN}upstream enable${NC} <имя>                     Включить"
            echo -e "    ${GREEN}upstream disable${NC} <имя>                    Выключить"
            echo -e "    ${GREEN}upstream test${NC} <имя>                       Проверить"
            ;;
    esac
}
