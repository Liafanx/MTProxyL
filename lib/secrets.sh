#!/bin/bash
# MTProxyL — управление секретами пользователей

# Массивы секретов
declare -a SECRETS_LABELS=()
declare -a SECRETS_KEYS=()
declare -a SECRETS_CREATED=()
declare -a SECRETS_ENABLED=()
declare -a SECRETS_MAX_CONNS=()
declare -a SECRETS_MAX_IPS=()
declare -a SECRETS_QUOTA=()
declare -a SECRETS_EXPIRES=()
declare -a SECRETS_NOTES=()

save_secrets() {
    mkdir -p "$INSTALL_DIR"
    local tmp
    tmp=$(_mktemp) || { log_error "Не удалось создать временный файл"; return 1; }

    echo "# MTProxyL — база секретов v${VERSION}" > "$tmp"
    echo "# Формат: LABEL|SECRET|CREATED_TS|ENABLED|MAX_CONNS|MAX_IPS|QUOTA_BYTES|EXPIRES|NOTES" >> "$tmp"

    if [ ${#SECRETS_LABELS[@]} -gt 0 ]; then
        local i
        for i in "${!SECRETS_LABELS[@]}"; do
            echo "${SECRETS_LABELS[$i]}|${SECRETS_KEYS[$i]}|${SECRETS_CREATED[$i]}|${SECRETS_ENABLED[$i]}|${SECRETS_MAX_CONNS[$i]:-0}|${SECRETS_MAX_IPS[$i]:-0}|${SECRETS_QUOTA[$i]:-0}|${SECRETS_EXPIRES[$i]:-0}|${SECRETS_NOTES[$i]:-}" >> "$tmp"
        done
    fi

    chmod 600 "$tmp"
    mv "$tmp" "$SECRETS_FILE"
}

load_secrets() {
    SECRETS_LABELS=(); SECRETS_KEYS=(); SECRETS_CREATED=(); SECRETS_ENABLED=()
    SECRETS_MAX_CONNS=(); SECRETS_MAX_IPS=(); SECRETS_QUOTA=()
    SECRETS_EXPIRES=(); SECRETS_NOTES=()

    [ -f "$SECRETS_FILE" ] || return 0

    while IFS='|' read -r label secret created enabled max_conns max_ips quota expires notes; do
        [[ "$label" =~ ^[[:space:]]*# ]] && continue
        [[ "$label" =~ ^[[:space:]]*$ ]] && continue
        [ -z "$secret" ] && continue
        [[ "$label" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
        [[ "$secret" =~ ^[0-9a-fA-F]{32}$ ]] || continue

        local _mc="${max_conns:-0}" _mi="${max_ips:-0}" _q="${quota:-0}" _en="${enabled:-true}"
        [[ "$_mc" =~ ^[0-9]+$ ]] || _mc="0"
        [[ "$_mi" =~ ^[0-9]+$ ]] || _mi="0"
        [[ "$_q" =~ ^[0-9]+$ ]] || _q="0"
        [ "$_en" != "true" ] && [ "$_en" != "false" ] && _en="true"

        SECRETS_LABELS+=("$label")
        SECRETS_KEYS+=("$secret")
        local _cr="${created:-$(date +%s)}"
        [[ "$_cr" =~ ^[0-9]+$ ]] || _cr=$(date +%s)
        SECRETS_CREATED+=("$_cr")
        SECRETS_ENABLED+=("$_en")
        SECRETS_MAX_CONNS+=("$_mc")
        SECRETS_MAX_IPS+=("$_mi")
        SECRETS_QUOTA+=("$_q")
        local _ex="${expires:-0}"
        if [ "$_ex" != "0" ] && ! [[ "$_ex" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9:Z+.-]+)?$ ]]; then
            _ex="0"
        fi
        SECRETS_EXPIRES+=("$_ex")
        SECRETS_NOTES+=("${notes:-}")
    done < "$SECRETS_FILE"
}

# Добавить секрет
secret_add() {
    local label="$1" custom_secret="${2:-}" no_restart="${3:-false}"

    [ -z "$label" ] && { log_error "Требуется метка"; return 1; }
    [[ "$label" =~ ^[a-zA-Z0-9_-]+$ ]] || { log_error "Метка: только a-z, 0-9, _, -"; return 1; }
    [ ${#label} -gt 32 ] && { log_error "Метка: максимум 32 символа"; return 1; }

    local i
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_LABELS[$i]}" = "$label" ] && { log_error "Секрет '${label}' уже существует"; return 1; }
    done

    local raw_secret="${custom_secret:-$(generate_secret)}"
    [[ "$raw_secret" =~ ^[0-9a-fA-F]{32}$ ]] || { log_error "Секрет: ровно 32 hex-символа"; return 1; }

    SECRETS_LABELS+=("$label")
    SECRETS_KEYS+=("$raw_secret")
    SECRETS_CREATED+=("$(date +%s)")
    SECRETS_ENABLED+=("true")
    SECRETS_MAX_CONNS+=("0")
    SECRETS_MAX_IPS+=("0")
    SECRETS_QUOTA+=("0")
    SECRETS_EXPIRES+=("0")
    SECRETS_NOTES+=("")

    save_secrets
    [ "$no_restart" != "true" ] && reload_proxy_config 2>/dev/null || true

    local full_secret server_ip
    full_secret=$(build_faketls_secret "$raw_secret")
    server_ip=$(get_public_ip)

    log_success "Секрет '${label}' создан"
    echo ""
    echo -e "  ${BOLD}Ссылка для Telegram:${NC}"
    echo -e "  ${CYAN}tg://proxy?server=${server_ip}&port=${PROXY_PORT}&secret=${full_secret}${NC}"
    echo ""
    echo -e "  ${BOLD}Веб-ссылка:${NC}"
    echo -e "  ${CYAN}https://t.me/proxy?server=${server_ip}&port=${PROXY_PORT}&secret=${full_secret}${NC}"

    if command -v qrencode &>/dev/null; then
        echo ""
        qrencode -t ANSIUTF8 "tg://proxy?server=${server_ip}&port=${PROXY_PORT}&secret=${full_secret}" 2>/dev/null | sed 's/^/  /'
    fi
    echo ""
}

# Удалить секрет
secret_remove() {
    local label="$1" force="${2:-false}" no_restart="${3:-false}"

    local idx=-1 i
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_LABELS[$i]}" = "$label" ] && { idx=$i; break; }
    done
    [ $idx -eq -1 ] && { log_error "Секрет '${label}' не найден"; return 1; }
    [ ${#SECRETS_LABELS[@]} -le 1 ] && { log_error "Нельзя удалить последний секрет"; return 1; }

    if [ "$force" != "true" ] && [ -t 0 ]; then
        echo -e "  ${YELLOW}Удалить секрет '${label}'? Пользователи с этим ключом будут отключены.${NC}"
        echo -en "  ${BOLD}Введите 'yes':${NC} "
        local confirm; read -r confirm
        [ "$confirm" != "yes" ] && { log_info "Отменено"; return 0; }
    fi

    local -a nl=() nk=() nc=() ne=() nmc=() nmi=() nq=() nex=() nn=()
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "$i" -eq "$idx" ] && continue
        nl+=("${SECRETS_LABELS[$i]}"); nk+=("${SECRETS_KEYS[$i]}")
        nc+=("${SECRETS_CREATED[$i]}"); ne+=("${SECRETS_ENABLED[$i]}")
        nmc+=("${SECRETS_MAX_CONNS[$i]:-0}"); nmi+=("${SECRETS_MAX_IPS[$i]:-0}")
        nq+=("${SECRETS_QUOTA[$i]:-0}"); nex+=("${SECRETS_EXPIRES[$i]:-0}")
        nn+=("${SECRETS_NOTES[$i]:-}")
    done
    SECRETS_LABELS=("${nl[@]}"); SECRETS_KEYS=("${nk[@]}")
    SECRETS_CREATED=("${nc[@]}"); SECRETS_ENABLED=("${ne[@]}")
    SECRETS_MAX_CONNS=("${nmc[@]}"); SECRETS_MAX_IPS=("${nmi[@]}")
    SECRETS_QUOTA=("${nq[@]}"); SECRETS_EXPIRES=("${nex[@]}")
    SECRETS_NOTES=("${nn[@]}")

    save_secrets
    [ "$no_restart" != "true" ] && reload_proxy_config 2>/dev/null || true
    log_success "Секрет '${label}' удалён"
}

# Ротация секрета
secret_rotate() {
    local label="$1"
    local idx=-1 i
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_LABELS[$i]}" = "$label" ] && { idx=$i; break; }
    done
    [ $idx -eq -1 ] && { log_error "Секрет '${label}' не найден"; return 1; }

    local new_secret
    new_secret=$(generate_secret)
    SECRETS_KEYS[$idx]="$new_secret"
    SECRETS_CREATED[$idx]="$(date +%s)"

    save_secrets
    reload_proxy_config 2>/dev/null || true

    local full_secret server_ip
    full_secret=$(build_faketls_secret "$new_secret")
    server_ip=$(get_public_ip)

    log_success "Секрет '${label}' обновлён"
    echo ""
    echo -e "  ${BOLD}Новая ссылка:${NC}"
    echo -e "  ${CYAN}tg://proxy?server=${server_ip}&port=${PROXY_PORT}&secret=${full_secret}${NC}"
    echo ""
}

# Включить/выключить секрет
secret_toggle() {
    local label="$1" action="${2:-toggle}"
    local idx=-1 i
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_LABELS[$i]}" = "$label" ] && { idx=$i; break; }
    done
    [ $idx -eq -1 ] && { log_error "Секрет '${label}' не найден"; return 1; }

    local _will_disable=false
    case "$action" in
        enable)  SECRETS_ENABLED[$idx]="true" ;;
        disable) _will_disable=true; SECRETS_ENABLED[$idx]="false" ;;
        toggle)
            if [ "${SECRETS_ENABLED[$idx]}" = "true" ]; then
                _will_disable=true; SECRETS_ENABLED[$idx]="false"
            else
                SECRETS_ENABLED[$idx]="true"
            fi ;;
    esac

    if $_will_disable; then
        local _en_count=0
        for i in "${!SECRETS_ENABLED[@]}"; do
            [ "${SECRETS_ENABLED[$i]}" = "true" ] && _en_count=$((_en_count + 1))
        done
        if [ "$_en_count" -eq 0 ]; then
            SECRETS_ENABLED[$idx]="true"
            log_error "Нельзя отключить последний активный секрет"
            return 1
        fi
    fi

    save_secrets
    reload_proxy_config 2>/dev/null || true
    log_success "Секрет '${label}': ${SECRETS_ENABLED[$idx]}"
}

# Установить лимиты
secret_set_limits() {
    local label="$1" max_conns="${2:-}" max_ips="${3:-}" quota="${4:-}" expires="${5:-}"
    local idx=-1 i
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_LABELS[$i]}" = "$label" ] && { idx=$i; break; }
    done
    [ $idx -eq -1 ] && { log_error "Секрет '${label}' не найден"; return 1; }

    if [ -n "$max_conns" ]; then
        [[ "$max_conns" =~ ^[0-9]+$ ]] || { log_error "Макс. соединений: число"; return 1; }
        SECRETS_MAX_CONNS[$idx]="$max_conns"
    fi
    if [ -n "$max_ips" ]; then
        [[ "$max_ips" =~ ^[0-9]+$ ]] || { log_error "Макс. IP: число"; return 1; }
        SECRETS_MAX_IPS[$idx]="$max_ips"
    fi
    if [ -n "$quota" ]; then
        local quota_bytes
        quota_bytes=$(parse_human_bytes "$quota") || { log_error "Квота: напр. 5G, 500M, 0"; return 1; }
        SECRETS_QUOTA[$idx]="$quota_bytes"
    fi
    if [ -n "$expires" ]; then
        if [ "$expires" = "0" ] || [ "$expires" = "never" ]; then
            SECRETS_EXPIRES[$idx]="0"
        elif [[ "$expires" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            SECRETS_EXPIRES[$idx]="${expires}T23:59:59Z"
        elif [[ "$expires" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
            SECRETS_EXPIRES[$idx]="$expires"
        else
            log_error "Срок: YYYY-MM-DD или 0"; return 1
        fi
    fi

    save_secrets
    reload_proxy_config 2>/dev/null || true
    log_success "Лимиты обновлены для '${label}'"
}

# Список секретов
secret_list() {
    load_secrets
    if [ ${#SECRETS_LABELS[@]} -eq 0 ]; then
        log_info "Нет настроенных секретов"
        echo -e "  ${DIM}Выполните: mtproxyl secret add <метка>${NC}"
        return
    fi

    echo ""
    draw_header "СЕКРЕТЫ"
    echo ""
    printf "  ${BOLD}%-4s %-16s %-10s %-10s %-12s %-12s${NC}\n" "#" "МЕТКА" "СТАТУС" "СОЗДАН" "СКАЧАНО" "ОТПРАВЛЕНО"
    echo -e "  ${DIM}$(_repeat '─' 70)${NC}"

    local i
    for i in "${!SECRETS_LABELS[@]}"; do
        local label="${SECRETS_LABELS[$i]}"
        local enabled="${SECRETS_ENABLED[$i]}"
        local created="${SECRETS_CREATED[$i]}"

        local status_text
        [ "$enabled" = "true" ] && status_text="${GREEN}активен${NC}" || status_text="${RED}выключен${NC}"

        local created_fmt
        created_fmt=$(printf '%(%Y-%m-%d)T' "$created" 2>/dev/null) || \
            created_fmt=$(date -d "@${created}" '+%Y-%m-%d' 2>/dev/null || echo "?")

        local u_in=0 u_out=0 u_conns=0
        read -r u_in u_out u_conns <<< "$(get_persistent_user_stats "$label" 2>/dev/null)" || true

        printf "  %-4s %-16s %-18b %-10s %-12s %-12s\n" \
            "$((i+1))" "$label" "$status_text" "$created_fmt" \
            "$(format_bytes "${u_in:-0}")" "$(format_bytes "${u_out:-0}")"

        [ -n "${SECRETS_NOTES[$i]:-}" ] && echo -e "       ${DIM}📝 ${SECRETS_NOTES[$i]}${NC}"
    done
    echo ""
}
# Ссылка для секрета
get_proxy_link() {
    local label="${1:-}"
    local server_ip
    server_ip=$(get_public_ip)

    if [ -z "$label" ]; then
        local i
        for i in "${!SECRETS_LABELS[@]}"; do
            [ "${SECRETS_ENABLED[$i]}" = "true" ] && { label="${SECRETS_LABELS[$i]}"; break; }
        done
    fi
    [ -z "$label" ] && { log_error "Нет активных секретов"; return 1; }

    local idx=-1 i
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_LABELS[$i]}" = "$label" ] && { idx=$i; break; }
    done
    [ $idx -eq -1 ] && { log_error "Секрет '${label}' не найден"; return 1; }

    local full_secret
    full_secret=$(build_faketls_secret "${SECRETS_KEYS[$idx]}")
    echo "tg://proxy?server=${server_ip}&port=${PROXY_PORT}&secret=${full_secret}"
}

# Получить список меток включённых секретов для конфига
get_enabled_labels_quoted() {
    local result="" first=true i
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_ENABLED[$i]}" = "true" ] || continue
        if $first; then result="\"${SECRETS_LABELS[$i]}\""; first=false
        else result+=", \"${SECRETS_LABELS[$i]}\""; fi
    done
    echo "$result"
}

# Клонирование секрета
secret_clone() {
    local src="$1" new="$2"
    [ -z "$src" ] || [ -z "$new" ] && { log_error "Использование: secret clone <источник> <новая_метка>"; return 1; }
    [[ "$new" =~ ^[a-zA-Z0-9_-]+$ ]] || { log_error "Метка: только a-z, 0-9, _, -"; return 1; }

    local idx=-1 i
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_LABELS[$i]}" = "$src" ] && { idx=$i; break; }
    done
    [ $idx -eq -1 ] && { log_error "Секрет '${src}' не найден"; return 1; }

    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_LABELS[$i]}" = "$new" ] && { log_error "Секрет '${new}' уже существует"; return 1; }
    done

    SECRETS_LABELS+=("$new")
    SECRETS_KEYS+=("$(generate_secret)")
    SECRETS_CREATED+=("$(date +%s)")
    SECRETS_ENABLED+=("true")
    SECRETS_MAX_CONNS+=("${SECRETS_MAX_CONNS[$idx]:-0}")
    SECRETS_MAX_IPS+=("${SECRETS_MAX_IPS[$idx]:-0}")
    SECRETS_QUOTA+=("${SECRETS_QUOTA[$idx]:-0}")
    SECRETS_EXPIRES+=("${SECRETS_EXPIRES[$idx]:-0}")
    SECRETS_NOTES+=("${SECRETS_NOTES[$idx]:-}")

    save_secrets
    reload_proxy_config 2>/dev/null || true

    local full_secret server_ip
    full_secret=$(build_faketls_secret "${SECRETS_KEYS[-1]}")
    server_ip=$(get_public_ip)
    log_success "Секрет '${new}' клонирован из '${src}'"
    echo -e "  ${CYAN}tg://proxy?server=${server_ip}&port=${PROXY_PORT}&secret=${full_secret}${NC}"
    echo ""
}

# Переименование
secret_rename() {
    local old="$1" new="$2"
    [ -z "$old" ] || [ -z "$new" ] && { log_error "Использование: secret rename <старая> <новая>"; return 1; }
    [[ "$new" =~ ^[a-zA-Z0-9_-]+$ ]] || { log_error "Метка: только a-z, 0-9, _, -"; return 1; }

    local idx=-1 i
    for i in "${!SECRETS_LABELS[@]}"; do [ "${SECRETS_LABELS[$i]}" = "$old" ] && { idx=$i; break; }; done
    [ $idx -eq -1 ] && { log_error "Секрет '${old}' не найден"; return 1; }
    for i in "${!SECRETS_LABELS[@]}"; do [ "${SECRETS_LABELS[$i]}" = "$new" ] && { log_error "'${new}' уже существует"; return 1; }; done

    SECRETS_LABELS[$idx]="$new"
    save_secrets
    reload_proxy_config 2>/dev/null || true
    log_success "Переименован: '${old}' → '${new}'"
}

# Показать лимиты
secret_show_limits() {
    local label="${1:-}"
    if [ -z "$label" ]; then
        echo ""
        draw_header "ЛИМИТЫ ПОЛЬЗОВАТЕЛЕЙ"
        echo ""
        printf "  ${BOLD}%-4s %-16s %-10s %-8s %-12s %-14s${NC}\n" "#" "МЕТКА" "СОЕД." "IP" "КВОТА" "СРОК"
        echo -e "  ${DIM}$(_repeat '─' 70)${NC}"
        local i
        for i in "${!SECRETS_LABELS[@]}"; do
            local c="${SECRETS_MAX_CONNS[$i]:-0}" p="${SECRETS_MAX_IPS[$i]:-0}"
            local q="${SECRETS_QUOTA[$i]:-0}" e="${SECRETS_EXPIRES[$i]:-0}"
            [ "$c" = "0" ] && c="${DIM}∞${NC}" ; [ "$p" = "0" ] && p="${DIM}∞${NC}"
            [ "$q" = "0" ] && q="${DIM}∞${NC}" || q="$(format_bytes "$q")"
            [ "$e" = "0" ] && e="${DIM}нет${NC}" || e="${e%%T*}"
            printf "  %-4s %-16s %-10b %-8b %-12b %-14b\n" "$((i+1))" "${SECRETS_LABELS[$i]}" "$c" "$p" "$q" "$e"
        done
        echo ""
    else
        local idx=-1 i
        for i in "${!SECRETS_LABELS[@]}"; do [ "${SECRETS_LABELS[$i]}" = "$label" ] && { idx=$i; break; }; done
        [ $idx -eq -1 ] && { log_error "Секрет '${label}' не найден"; return 1; }
        local c="${SECRETS_MAX_CONNS[$idx]:-0}" p="${SECRETS_MAX_IPS[$idx]:-0}"
        local q="${SECRETS_QUOTA[$idx]:-0}" e="${SECRETS_EXPIRES[$idx]:-0}"
        echo ""
        echo -e "  ${BOLD}Лимиты '${label}':${NC}"
        echo -e "  Макс. TCP соединений: $([ "$c" = "0" ] && echo "без ограничений" || echo "$c")"
        echo -e "  Макс. уникальных IP:  $([ "$p" = "0" ] && echo "без ограничений" || echo "$p")"
        echo -e "  Квота трафика:        $([ "$q" = "0" ] && echo "без ограничений" || echo "$(format_bytes "$q")")"
        echo -e "  Срок действия:        $([ "$e" = "0" ] && echo "бессрочно" || echo "$e")"
        echo ""
    fi
}

# CLI обработчик
handle_secret_command() {
    local subcmd="${1:-list}"; shift 2>/dev/null || true
    case "$subcmd" in
        add)      check_root; secret_add "$@" ;;
        remove)   check_root; secret_remove "$1" ;;
        list)     secret_list ;;
        rotate)   check_root; secret_rotate "$1" ;;
        enable)   check_root; secret_toggle "$1" enable ;;
        disable)  check_root; secret_toggle "$1" disable ;;
        limits)   secret_show_limits "$1" ;;
        setlimits)
            check_root
            local l="$1"; shift 2>/dev/null || true
            secret_set_limits "$l" "${1:-0}" "${2:-0}" "${3:-0}" "${4:-}" ;;
        link)     get_proxy_link "${1:-}"; echo "" ;;
        clone)    check_root; secret_clone "$1" "$2" ;;
        rename)   check_root; secret_rename "$1" "$2" ;;
        qr)
            local link; link=$(get_proxy_link "${1:-}") || return 1
            if command -v qrencode &>/dev/null; then
                echo ""; qrencode -t ANSIUTF8 "$link" | sed 's/^/  /'
            else
                echo -e "  ${DIM}qrencode не установлен: apt install qrencode${NC}"
            fi
            echo -e "  ${CYAN}${link}${NC}"; echo "" ;;
        *)
            echo -e "  ${BOLD}Управление секретами:${NC}"
            echo -e "    ${GREEN}secret add${NC} <метка>        Добавить"
            echo -e "    ${GREEN}secret remove${NC} <метка>     Удалить"
            echo -e "    ${GREEN}secret list${NC}               Список"
            echo -e "    ${GREEN}secret rotate${NC} <метка>     Обновить ключ"
            echo -e "    ${GREEN}secret enable${NC} <метка>     Включить"
            echo -e "    ${GREEN}secret disable${NC} <метка>    Выключить"
            echo -e "    ${GREEN}secret limits${NC} [метка]     Лимиты"
            echo -e "    ${GREEN}secret setlimits${NC} <метка> <соед> <ip> <квота> [срок]"
            echo -e "    ${GREEN}secret link${NC} [метка]       Ссылка"
            echo -e "    ${GREEN}secret qr${NC} [метка]         QR-код"
            echo -e "    ${GREEN}secret clone${NC} <из> <в>     Клонировать"
            echo -e "    ${GREEN}secret rename${NC} <из> <в>    Переименовать"
            ;;
    esac
}
