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
# Область применения (scopes) из мануала движка: теги через запятую. Запрос
# без scope берёт только апстримы с пустым scopes — поэтому хотя бы один
# включённый маршрут обязан оставаться без scopes.
declare -a UPSTREAM_SCOPES=()

# Движок объявляет weight как u16 — держим ту же границу, чтобы панель и CLI
# не запрещали значений, которые telemt принимает.
UPSTREAM_WEIGHT_MAX=65535

# «me, fetch, dc2» → «me,fetch,dc2». Движок обрезает пробелы при сравнении, но
# в файле и в конфиге удобнее хранить уже нормализованный список.
_upstream_normalize_scopes() {
    local raw="${1:-}" out="" tok
    declare -a _toks=()
    local oldIFS="$IFS"; IFS=','
    read -ra _toks <<< "$raw"
    IFS="$oldIFS"
    for tok in "${_toks[@]}"; do
        tok="${tok#"${tok%%[![:space:]]*}"}"
        tok="${tok%"${tok##*[![:space:]]}"}"
        [ -z "$tok" ] && continue
        [ -n "$out" ] && out+=","
        out+="$tok"
    done
    printf '%s' "$out"
}

_upstream_scopes_valid() {
    local raw="${1:-}" tok
    [ -z "$raw" ] && return 0
    declare -a _toks=()
    local oldIFS="$IFS"; IFS=','
    read -ra _toks <<< "$raw"
    IFS="$oldIFS"
    for tok in "${_toks[@]}"; do
        [[ "$tok" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
    done
    return 0
}

# Shadowsocks-апстримы движок отвергает при включённом Middle-End — в мануале
# это явное требование `general.use_middle_proxy = false`. Проверяем до записи:
# иначе конфиг сгенерируется, а telemt после рестарта его не примет.
_upstream_me_enabled() {
    local ov
    ov=$(get_expert_override_value "general" "use_middle_proxy" 2>/dev/null)
    [ "$ov" = "false" ] && return 1
    return 0
}

# Предупреждаем, если после правки без scopes не осталось ни одного включённого
# маршрута: конфиг при этом валиден, а трафик без scope идти будет некуда.
_upstream_warn_no_default_route() {
    local i
    for i in "${!UPSTREAM_NAMES[@]}"; do
        [ "${UPSTREAM_ENABLED[$i]}" = "true" ] || continue
        [ -z "${UPSTREAM_SCOPES[$i]:-}" ] && return 0
    done
    log_warn "У всех включённых маршрутов задан scopes — запросы без scope останутся без апстрима"
    log_info "Оставьте хотя бы один включённый маршрут с пустым scopes"
}

# Перезапуск после правки маршрутов. Пачка изменений выставляет
# UPSTREAM_DEFER_RESTART и перезапускает движок один раз в конце.
_upstream_restart_if_needed() {
    [ "${UPSTREAM_DEFER_RESTART:-false}" = "true" ] && return 0
    is_proxy_running && restart_proxy_container
    return 0
}

save_upstreams() {
    mkdir -p "$INSTALL_DIR"
    local tmp; tmp=$(_mktemp "$INSTALL_DIR") || return 1

    echo "# MTProxyL — upstream-маршруты v${VERSION}" > "$tmp"
    echo "# Формат: NAME|TYPE|ADDR|USER|PASS|WEIGHT|IFACE|ENABLED|SCOPES" >> "$tmp"

    local i
    for i in "${!UPSTREAM_NAMES[@]}"; do
        echo "${UPSTREAM_NAMES[$i]}|${UPSTREAM_TYPES[$i]}|${UPSTREAM_ADDRS[$i]}|${UPSTREAM_USERS[$i]}|${UPSTREAM_PASSES[$i]}|${UPSTREAM_WEIGHTS[$i]}|${UPSTREAM_IFACES[$i]}|${UPSTREAM_ENABLED[$i]}|${UPSTREAM_SCOPES[$i]:-}" >> "$tmp"
    done

    chmod 600 "$tmp"
    mv "$tmp" "$UPSTREAMS_FILE"
}

load_upstreams() {
    UPSTREAM_NAMES=(); UPSTREAM_TYPES=(); UPSTREAM_ADDRS=()
    UPSTREAM_USERS=(); UPSTREAM_PASSES=(); UPSTREAM_WEIGHTS=()
    UPSTREAM_IFACES=(); UPSTREAM_ENABLED=(); UPSTREAM_SCOPES=()

    if [ ! -f "$UPSTREAMS_FILE" ]; then
        UPSTREAM_NAMES+=("direct"); UPSTREAM_TYPES+=("direct")
        UPSTREAM_ADDRS+=(""); UPSTREAM_USERS+=(""); UPSTREAM_PASSES+=("")
        UPSTREAM_WEIGHTS+=("10"); UPSTREAM_IFACES+=(""); UPSTREAM_ENABLED+=("true")
        UPSTREAM_SCOPES+=("")
        return 0
    fi

    while IFS='|' read -r name type addr user pass weight iface enabled scopes; do
        [[ "$name" =~ ^[[:space:]]*# ]] && continue
        [[ "$name" =~ ^[[:space:]]*$ ]] && continue
        [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || continue

        # Совместимость со старым 7-колоночным форматом
        if [ "$iface" = "true" ] || [ "$iface" = "false" ]; then
            enabled="$iface"; iface=""
        fi

        local _type="${type:-direct}"
        case "$_type" in direct|socks5|socks4|shadowsocks) ;; *) _type="direct" ;; esac
        local _weight="${weight:-10}"
        [[ "$_weight" =~ ^[0-9]+$ ]] && [ "$_weight" -le "$UPSTREAM_WEIGHT_MAX" ] || _weight="10"
        local _enabled="${enabled:-true}"
        [ "$_enabled" != "true" ] && [ "$_enabled" != "false" ] && _enabled="true"
        [ "$_type" != "direct" ] && [ -z "${addr:-}" ] && continue

        # Мусор в scopes лучше отбросить, чем протащить в конфиг: движок молча
        # не найдёт такой тег, и маршрут окажется недостижимым без объяснений.
        local _scopes; _scopes=$(_upstream_normalize_scopes "${scopes:-}")
        _upstream_scopes_valid "$_scopes" || _scopes=""

        UPSTREAM_NAMES+=("$name"); UPSTREAM_TYPES+=("$_type")
        UPSTREAM_ADDRS+=("${addr:-}"); UPSTREAM_USERS+=("${user:-}")
        UPSTREAM_PASSES+=("${pass:-}"); UPSTREAM_WEIGHTS+=("$_weight")
        UPSTREAM_IFACES+=("${iface:-}"); UPSTREAM_ENABLED+=("$_enabled")
        UPSTREAM_SCOPES+=("$_scopes")
    done < "$UPSTREAMS_FILE"

    if [ ${#UPSTREAM_NAMES[@]} -eq 0 ]; then
        UPSTREAM_NAMES+=("direct"); UPSTREAM_TYPES+=("direct")
        UPSTREAM_ADDRS+=(""); UPSTREAM_USERS+=(""); UPSTREAM_PASSES+=("")
        UPSTREAM_WEIGHTS+=("10"); UPSTREAM_IFACES+=(""); UPSTREAM_ENABLED+=("true")
        UPSTREAM_SCOPES+=("")
    fi
}

upstream_add() {
    local name="$1" type="$2" addr="${3:-}" user="${4:-}" pass="${5:-}" weight="${6:-10}" iface="${7:-}" scopes="${8:-}"

    [ -z "$name" ] || [ -z "$type" ] && { log_error "Требуются имя и тип"; return 1; }
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || { log_error "Имя: a-z, 0-9, _, -"; return 1; }

    local i
    for i in "${!UPSTREAM_NAMES[@]}"; do
        [ "${UPSTREAM_NAMES[$i]}" = "$name" ] && { log_error "Upstream '${name}' уже существует"; return 1; }
    done

    case "$type" in
        direct|socks5|socks4|shadowsocks) ;;
        *) log_error "Тип: direct, socks5, socks4, shadowsocks"; return 1 ;;
    esac

    [ "$type" != "direct" ] && [ -z "$addr" ] && { log_error "Адрес обязателен для ${type}"; return 1; }

    # У shadowsocks вместо host:port — ss-URL: в нём и метод шифрования, и
    # пароль, и адрес. Движок принимает его в поле url.
    if [ "$type" = "shadowsocks" ]; then
        [[ "$addr" =~ ^ss://[A-Za-z0-9+/=:@._-]+$ ]] \
            || { log_error "Для shadowsocks нужен URL вида ss://МЕТОД:ПАРОЛЬ@host:port"; return 1; }
        # Плагины ss движок не поддерживает — «?plugin=» в URL до него не дойдёт.
        [[ "$addr" == *"plugin="* ]] \
            && { log_error "Плагины Shadowsocks движком не поддерживаются"; return 1; }
        if _upstream_me_enabled; then
            log_error "Shadowsocks несовместим с режимом Middle-End (ME)"
            log_info "Сначала выключите ME: mtproxyl expert set general use_middle_proxy false"
            return 1
        fi
    elif [ "$type" != "direct" ] && [ -n "$addr" ]; then
        [[ "$addr" =~ ^[a-zA-Z0-9._-]+:[0-9]+$ ]] || { log_error "Адрес: host:port"; return 1; }
    fi

    [[ "$weight" =~ ^[0-9]+$ ]] && [ "$weight" -le "$UPSTREAM_WEIGHT_MAX" ] \
        || { log_error "Вес: 0-${UPSTREAM_WEIGHT_MAX}"; return 1; }

    scopes=$(_upstream_normalize_scopes "$scopes")
    _upstream_scopes_valid "$scopes" \
        || { log_error "Область (scopes): теги через запятую, символы a-z, 0-9, _, ., -"; return 1; }

    # Привязка к интерфейсу у SOCKS работает, только когда адрес задан как
    # IP:port — по имени хоста движок её игнорирует. Молчать здесь нельзя:
    # маршрут добавится, а привязки не будет.
    if [ -n "$iface" ] && { [ "$type" = "socks4" ] || [ "$type" = "socks5" ]; }; then
        [[ "$addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]] \
            || log_warn "Для ${type} привязка к интерфейсу работает только при адресе вида IP:port — здесь она будет проигнорирована"
    fi

    UPSTREAM_NAMES+=("$name"); UPSTREAM_TYPES+=("$type")
    UPSTREAM_ADDRS+=("$addr"); UPSTREAM_USERS+=("$user")
    UPSTREAM_PASSES+=("$pass"); UPSTREAM_WEIGHTS+=("$weight")
    UPSTREAM_IFACES+=("$iface"); UPSTREAM_ENABLED+=("true")
    UPSTREAM_SCOPES+=("$scopes")

    save_upstreams
    _upstream_restart_if_needed
    log_success "Upstream '${name}' добавлен (${type})"
    [ -n "$scopes" ] && _upstream_warn_no_default_route
    return 0
}

upstream_remove() {
    local name="$1"
    [ ${#UPSTREAM_NAMES[@]} -le 1 ] && { log_error "Нельзя удалить последний upstream"; return 1; }

    local idx=-1 i
    for i in "${!UPSTREAM_NAMES[@]}"; do
        [ "${UPSTREAM_NAMES[$i]}" = "$name" ] && { idx=$i; break; }
    done
    [ $idx -eq -1 ] && { log_error "Upstream '${name}' не найден"; return 1; }

    # Переносим все массивы разом: пропустить хоть один — значит сдвинуть его
    # относительно остальных, и поле одного маршрута молча достанется другому.
    local -a nn=() nt=() na=() nu=() np=() nw=() ni=() ne=() ns=()
    for i in "${!UPSTREAM_NAMES[@]}"; do
        [ "$i" -eq "$idx" ] && continue
        nn+=("${UPSTREAM_NAMES[$i]}"); nt+=("${UPSTREAM_TYPES[$i]}")
        na+=("${UPSTREAM_ADDRS[$i]}"); nu+=("${UPSTREAM_USERS[$i]}")
        np+=("${UPSTREAM_PASSES[$i]}"); nw+=("${UPSTREAM_WEIGHTS[$i]}")
        ni+=("${UPSTREAM_IFACES[$i]}"); ne+=("${UPSTREAM_ENABLED[$i]}")
        ns+=("${UPSTREAM_SCOPES[$i]:-}")
    done
    UPSTREAM_NAMES=("${nn[@]}"); UPSTREAM_TYPES=("${nt[@]}")
    UPSTREAM_ADDRS=("${na[@]}"); UPSTREAM_USERS=("${nu[@]}")
    UPSTREAM_PASSES=("${np[@]}"); UPSTREAM_WEIGHTS=("${nw[@]}")
    UPSTREAM_IFACES=("${ni[@]}"); UPSTREAM_ENABLED=("${ne[@]}")
    UPSTREAM_SCOPES=("${ns[@]}")

    save_upstreams
    _upstream_restart_if_needed
    log_success "Upstream '${name}' удалён"
}

upstream_list() {
    load_upstreams
    echo ""
    draw_header "UPSTREAM-МАРШРУТЫ"
    echo ""
    # Ширины считаем через _pad: printf с %-Ns меряет байты, и кириллические
    # заголовки разъезжаются относительно латинских значений.
    echo -e "  ${BOLD}$(_pad '#' 4)$(_pad 'ИМЯ' 15)$(_pad 'ТИП' 14)$(_pad 'АДРЕС' 23)$(_pad 'ВЕС' 6)$(_pad 'ОБЛАСТЬ' 12)СТАТУС${NC}"
    echo -e "  ${DIM}$(_repeat '─' 80)${NC}"

    local i has_scopes=0
    for i in "${!UPSTREAM_NAMES[@]}"; do
        local addr_plain="${UPSTREAM_ADDRS[$i]:-—}"
        [ -n "${UPSTREAM_IFACES[$i]}" ] && addr_plain="${addr_plain} (${UPSTREAM_IFACES[$i]})"
        addr_plain=$(_ellipsis "$addr_plain" 22)

        local scopes_plain="${UPSTREAM_SCOPES[$i]:-}"
        if [ -n "$scopes_plain" ]; then
            has_scopes=1
            scopes_plain=$(_ellipsis "$scopes_plain" 11)
        else
            scopes_plain="все"
        fi

        local status_str
        if [ "${UPSTREAM_ENABLED[$i]}" = "true" ]; then
            status_str="${GREEN}${SYM_OK} активен${NC}"
        else
            status_str="${RED}${SYM_CROSS} выключен${NC}"
        fi

        echo -e "  $(_pad "$((i+1))" 4)$(_pad "${UPSTREAM_NAMES[$i]}" 15)$(_pad "${UPSTREAM_TYPES[$i]}" 14)$(_pad "$addr_plain" 23)$(_pad "${UPSTREAM_WEIGHTS[$i]}" 6)$(_pad "$scopes_plain" 12)${status_str}"
    done
    echo ""
    if [ "$has_scopes" -eq 1 ]; then
        echo -e "  ${DIM}Область — теги маршрута. Запрос со scope идёт только через маршруты${NC}"
        echo -e "  ${DIM}с этим тегом; запрос без scope — только через маршруты «все».${NC}"
        echo ""
    fi
}

upstream_toggle() {
    local name="$1" action="${2:-toggle}"
    local idx=-1 i
    for i in "${!UPSTREAM_NAMES[@]}"; do
        [ "${UPSTREAM_NAMES[$i]}" = "$name" ] && { idx=$i; break; }
    done
    [ $idx -eq -1 ] && { log_error "Upstream '${name}' не найден"; return 1; }

    # Включение shadowsocks при живом ME даёт тот же нерабочий конфиг, что и
    # добавление — проверяем и здесь, иначе запрет обходится в два шага.
    if [ "${UPSTREAM_TYPES[$idx]}" = "shadowsocks" ] && [ "$action" != "disable" ] \
       && [ "${UPSTREAM_ENABLED[$idx]}" != "true" ] && _upstream_me_enabled; then
        log_error "Shadowsocks несовместим с режимом Middle-End (ME)"
        log_info "Сначала выключите ME: mtproxyl expert set general use_middle_proxy false"
        return 1
    fi

    case "$action" in
        enable)  UPSTREAM_ENABLED[$idx]="true" ;;
        disable) UPSTREAM_ENABLED[$idx]="false" ;;
        toggle)
            [ "${UPSTREAM_ENABLED[$idx]}" = "true" ] && UPSTREAM_ENABLED[$idx]="false" || UPSTREAM_ENABLED[$idx]="true" ;;
    esac

    save_upstreams
    _upstream_restart_if_needed
    log_success "Upstream '${name}': ${UPSTREAM_ENABLED[$idx]}"
    _upstream_warn_no_default_route
    return 0
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

    # ss-URL curl прокинуть не умеет — сквозной проверки выхода не получится.
    # Честнее сказать это прямо и проверить хотя бы доступность порта, чем
    # выдать «не отвечает» на прокси, который на самом деле жив.
    if [ "$type" = "shadowsocks" ]; then
        local ss_hostport="${addr##*@}"
        ss_hostport="${ss_hostport%%[/?#]*}"
        if [[ ! "$ss_hostport" =~ ^[a-zA-Z0-9._-]+:[0-9]+$ ]]; then
            log_warn "Не удалось разобрать host:port из ss-URL — проверка пропущена"
            return 0
        fi
        log_info "Проверка shadowsocks ${ss_hostport} (только доступность порта)..."
        if timeout 8 bash -c "exec 3<>/dev/tcp/${ss_hostport%:*}/${ss_hostport##*:}" 2>/dev/null; then
            log_success "Порт ${ss_hostport} открыт"
            log_info "Работу шифрования и пароля проверит только сам движок"
        else
            log_error "Порт ${ss_hostport} недоступен"
        fi
        return 0
    fi

    log_info "Проверка ${type} прокси ${addr}..."

    local proxy_url
    local pu="${UPSTREAM_USERS[$idx]}" pp="${UPSTREAM_PASSES[$idx]}"
    if [ "$type" = "socks4" ]; then
        # В SOCKS4 нет пароля: там только user_id, и он идёт в поле логина.
        if [ -n "$pu" ]; then proxy_url="socks4://${pu}@${addr}"; else proxy_url="socks4://${addr}"; fi
    elif [ -n "$pu" ] && [ -n "$pp" ]; then
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
    _require_manager_mode || return 1
    case "$subcmd" in
        list)
            if [ "${1:-}" = "--json" ]; then
                upstream_list_json
            else
                upstream_list
            fi
            ;;
        add)     check_root; upstream_add "$@" ;;
        remove)  check_root; upstream_remove "$1" ;;
        enable)  check_root; upstream_toggle "$1" enable ;;
        disable) check_root; upstream_toggle "$1" disable ;;
        test)    upstream_test "$1" ;;
        *)
            echo -e "  ${BOLD}Upstream-маршруты:${NC}"
            echo -e "    ${GREEN}upstream list${NC}                             Список"
            echo -e "    ${GREEN}upstream add${NC} <имя> <тип> <адрес> [логин] [пароль] [вес] [интерфейс] [область]"
            echo -e "    ${GREEN}upstream remove${NC} <имя>                     Удалить"
            echo -e "    ${GREEN}upstream enable${NC} <имя>                     Включить"
            echo -e "    ${GREEN}upstream disable${NC} <имя>                    Выключить"
            echo -e "    ${GREEN}upstream test${NC} <имя>                       Проверить"
            echo ""
            echo -e "  ${BOLD}Типы:${NC}"
            echo -e "    ${DIM}direct${NC}        прямое соединение; адрес не нужен, в интерфейс можно"
            echo -e "    ${DIM}${NC}              задать локальный IP или имя интерфейса"
            echo -e "    ${DIM}socks5${NC}        адрес host:port, логин и пароль — необязательны"
            echo -e "    ${DIM}socks4${NC}        адрес host:port, логин = user_id, пароля нет"
            echo -e "    ${DIM}shadowsocks${NC}   вместо адреса ss-URL; требует выключенного ME"
            echo -e "    ${DIM}${NC}              (general.use_middle_proxy = false)"
            echo ""
            echo -e "  ${BOLD}Вес:${NC} 0-${UPSTREAM_WEIGHT_MAX}, чем больше — тем чаще маршрут выбирается."
            echo -e "  ${BOLD}Область:${NC} теги через запятую (${DIM}me,fetch,dc2${NC}). Запрос со scope идёт"
            echo -e "  только через маршруты с этим тегом, запрос без scope — только через"
            echo -e "  маршруты с пустой областью."
            ;;
    esac
}

# Машинный список маршрутов для панели.
# Пароли наружу не отдаём — панели они не нужны, а утечка в лог браузера
# или в историю запросов нежелательна.
upstream_list_json() {
    load_upstreams
    local i _first=1
    printf '['
    for i in "${!UPSTREAM_NAMES[@]}"; do
        [ $_first -eq 1 ] || printf ','
        _first=0
        printf '{"name":"%s","type":"%s","address":"%s","user":"%s","has_password":%s,"weight":%d,"iface":"%s","scopes":"%s","enabled":%s}' \
            "$(json_escape "${UPSTREAM_NAMES[$i]}")" \
            "$(json_escape "${UPSTREAM_TYPES[$i]}")" \
            "$(json_escape "${UPSTREAM_ADDRS[$i]}")" \
            "$(json_escape "${UPSTREAM_USERS[$i]}")" \
            "$([ -n "${UPSTREAM_PASSES[$i]}" ] && echo true || echo false)" \
            "${UPSTREAM_WEIGHTS[$i]:-0}" \
            "$(json_escape "${UPSTREAM_IFACES[$i]}")" \
            "$(json_escape "${UPSTREAM_SCOPES[$i]:-}")" \
            "$([ "${UPSTREAM_ENABLED[$i]}" = "true" ] && echo true || echo false)"
    done
    printf ']\n'
}
