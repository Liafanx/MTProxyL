#!/bin/bash
# MTProxyL — генерация config.toml + режим эксперта

_TUNE_FILE="${INSTALL_DIR}/tunings.conf"

# ── Таймауты, которые MTProxyL пишет в свой config.toml ───────
# Единственный источник истины: их же предлагает визард тюнинга в Reanimator
# (у telemt по умолчанию заметно ниже: 10/30/15).
MTPROXYL_TG_CONNECT=30
MTPROXYL_CLIENT_HANDSHAKE=90
MTPROXYL_CLIENT_KEEPALIVE=120

# Набор параметров для тюнинга чужой цели: параметр:секция:значение
_REANIMATOR_TUNE_SET=(
    "client_handshake:timeouts:${MTPROXYL_CLIENT_HANDSHAKE}"
    "tg_connect:general:${MTPROXYL_TG_CONNECT}"
    "client_keepalive:timeouts:${MTPROXYL_CLIENT_KEEPALIVE}"
)

# ── Tune whitelist ────────────────────────────────────────────
_TUNE_WHITELIST=(
    "fake_cert_len:censorship:^[0-9]+$"
    "client_handshake:timeouts:^[0-9]+$"
    "tg_connect:general:^[0-9]+$"
    "client_keepalive:timeouts:^[0-9]+$"
    "client_ack:timeouts:^[0-9]+$"
    "replay_check_len:access:^[0-9]+$"
    "replay_window_secs:access:^[0-9]+$"
    "ignore_time_skew:access:^(true|false)$"
    "listen_backlog:server:^[0-9]+$"
    "max_connections:server:^[0-9]+$"
    "accept_permit_timeout_ms:server:^[0-9]+$"
    "prefer_ipv6:general:^(true|false)$"
    "fast_mode:general:^(true|false)$"
    "log_level:general:^(debug|verbose|normal|silent)$"
    "mask_relay_timeout_ms:censorship:^[0-9]+$"
    "mask_relay_idle_timeout_ms:censorship:^[0-9]+$"
    "client_mss:server:^(extreme-low|tspu|2in8|[0-9]+)$"
    "client_mss_bulk:server:^(extreme-low|tspu|2in8|[0-9]+)$"
)

run_tune_wizard() {
    handle_tune_command list
    echo -e "  ${DIM}[1] Установить  [2] Очистить  [3] Очистить все  [0] Назад${NC}"
    local tc; tc=$(read_choice "выбор" "0")
    case "$tc" in
        1) echo -en "  ${BOLD}Параметр:${NC} "; local tp; read_line tp
           echo -en "  ${BOLD}Значение:${NC} "; local tv; read_line tv
           [ -n "$tp" ] && [ -n "$tv" ] && handle_tune_command set "$tp" "$tv" ;;
        2) echo -en "  ${BOLD}Параметр:${NC} "; local tp; read_line tp
           [ -n "$tp" ] && handle_tune_command clear "$tp" ;;
        3) handle_tune_command clear all ;;
    esac
}

_tune_lookup() {
    local param="$1" entry
    for entry in "${_TUNE_WHITELIST[@]}"; do
        [[ "$entry" =~ ^${param}: ]] && { echo "$entry"; return 0; }
    done
    return 1
}

handle_tune_command() {
    local sub="${1:-list}"; shift 2>/dev/null || true
    case "$sub" in
        list)
            echo ""; draw_header "ПАРАМЕТРЫ ТЮНИНГА ДВИЖКА"; echo ""
            local entry p s v
            for entry in "${_TUNE_WHITELIST[@]}"; do
                IFS=':' read -r p s v <<< "$entry"
                printf "  %-32s ${DIM}[%s]${NC}\n" "$p" "$s"
            done
            echo ""
            [ -f "$_TUNE_FILE" ] && [ -s "$_TUNE_FILE" ] && {
                echo -e "  ${BOLD}Текущие:${NC}"
                while IFS='|' read -r p v; do
                    [ -z "$p" ] && continue; echo "    ${p} = ${v}"
                done < "$_TUNE_FILE"; echo ""
            } ;;
        get)
            local param="$1"
            if [ -z "$param" ]; then
                [ ! -f "$_TUNE_FILE" ] || [ ! -s "$_TUNE_FILE" ] && { log_info "Нет параметров"; return; }
                while IFS='|' read -r p v; do [ -z "$p" ] && continue; echo "  ${p} = ${v}"; done < "$_TUNE_FILE"
            else
                local v; v=$(awk -F'|' -v u="$param" '$1==u{print $2; exit}' "$_TUNE_FILE" 2>/dev/null)
                [ -n "$v" ] && echo "  ${param} = ${v}" || echo -e "  ${DIM}${param}: не задан${NC}"
            fi ;;
        set)
            [ "${MTPROXYL_MODE:-manager}" = "manager" ] && { _require_no_superexpert || return 1; }
            check_root
            local param="$1" value="$2"
            [ -z "$param" ] && { log_error "Использование: tune set <параметр> <значение>"; return 1; }
            local entry; entry=$(_tune_lookup "$param") || { log_error "Неизвестный параметр. Выполните: mtproxyl tune list"; return 1; }
            local p sect regex; IFS=':' read -r p sect regex <<< "$entry"
            [ -z "$value" ] && { log_error "Требуется значение"; return 1; }
            [[ "$value" =~ $regex ]] || { log_error "Некорректное значение (ожидается: ${regex})"; return 1; }
            mkdir -p "$INSTALL_DIR"; touch "$_TUNE_FILE"; chmod 600 "$_TUNE_FILE"
            local tmp; tmp=$(_mktemp "$INSTALL_DIR") || return 1
            grep -v "^${param}|" "$_TUNE_FILE" > "$tmp" 2>/dev/null || true
            echo "${param}|${value}" >> "$tmp"
            mv "$tmp" "$_TUNE_FILE"; chmod 600 "$_TUNE_FILE"
            log_success "${param} = ${value}"
            if [ "${MTPROXYL_MODE:-manager}" = "manager" ]; then
                if is_proxy_running; then
                    echo -en "  ${DIM}Перезапустить? [Y/n]:${NC} "; local r; read_line r 2>/dev/null || r="y"
                    [[ ! "$r" =~ ^[nN] ]] && { load_secrets; restart_proxy_container || true; }
                fi
            else
                apply_target_tuning "$param" "$value" "$sect"
            fi ;;
        clear)
            check_root
            local param="$1"
            [ -z "$param" ] && { log_error "Использование: tune clear <параметр|all>"; return 1; }
            [ ! -f "$_TUNE_FILE" ] && { log_info "Нет параметров"; return 0; }
            if [ "$param" = "all" ]; then rm -f "$_TUNE_FILE"; log_success "Все параметры очищены"
            else
                local tmp; tmp=$(_mktemp "$INSTALL_DIR") || return 1
                grep -v "^${param}|" "$_TUNE_FILE" > "$tmp" 2>/dev/null || true
                mv "$tmp" "$_TUNE_FILE"; chmod 600 "$_TUNE_FILE"
                log_success "${param} очищен"
            fi ;;
    esac
}

# ── Режим супер эксперта ──────────────────────────────────────
# Пользователь ведёт конфиг движка сам: MTProxyL только копирует его файл
# на место config.toml, ничего в него не подставляя.
SUPEREXPERT_FILE="${INSTALL_DIR}/superexpert.toml"

_superexpert_active() {
    [ "${SUPEREXPERT_ENABLED:-false}" = "true" ] && [ -f "$SUPEREXPERT_FILE" ]
}

superexpert_status_line() {
    if _superexpert_active; then
        echo -e "${YELLOW}включён${NC} ${DIM}(${SUPEREXPERT_FILE})${NC}"
    elif [ "${SUPEREXPERT_ENABLED:-false}" = "true" ]; then
        echo -e "${RED}включён, но файл не найден${NC} ${DIM}(${SUPEREXPERT_FILE})${NC}"
    else
        echo -e "${DIM}выключен${NC}"
    fi
}

# Порт прокси живёт в конфиге пользователя, а на него завязаны NFT-правила,
# Zapret2 и ссылки. Держим PROXY_PORT в согласии с файлом.
_superexpert_sync_port() {
    local _p
    _p=$(_toml_get_string_in_section "server" "port" "$SUPEREXPERT_FILE" 2>/dev/null)
    [[ "$_p" =~ ^[0-9]+$ ]] || return 0
    [ "$_p" = "${PROXY_PORT:-}" ] && return 0
    local _old="${PROXY_PORT:-не задан}"
    PROXY_PORT="$_p"
    save_settings
    log_warn "Порт из вашего конфига: ${_old} → ${PROXY_PORT}"
    log_info "Правила NFT/Zapret2 наложены на прежний порт — переприменить: меню NFT"
}

# Пользователи из конфига супер эксперта (секция [access.users])
_superexpert_users() {
    [ -f "$SUPEREXPERT_FILE" ] || return 1
    awk '
        /^[[:space:]]*\[access\.users\]/ { insect=1; next }
        /^[[:space:]]*\[/ { insect=0 }
        insect {
            line=$0
            sub(/[[:space:]]*#.*$/, "", line)
            sub(/^[[:space:]]+/, "", line)
            if (line ~ /^[A-Za-z0-9_.-]+[[:space:]]*=/) {
                split(line, a, "=")
                name=a[1]; val=a[2]
                gsub(/[[:space:]]/, "", name)
                gsub(/[[:space:]"]/, "", val)
                if (name != "" && val != "") print name "|" val
            }
        }
    ' "$SUPEREXPERT_FILE" 2>/dev/null
}

superexpert_show_rules() {
    echo -e "  ${BOLD}Как это работает:${NC}"
    echo -e "  ${DIM}• Конфиг движка — ваш файл ${SUPEREXPERT_FILE}${NC}"
    echo -e "  ${DIM}• Перед каждым запуском он копируется на место $(basename "$(engine_config_path)")${NC}"
    echo -e "  ${DIM}• MTProxyL ничего в него не дописывает: ни секреты, ни настройки,${NC}"
    echo -e "  ${DIM}  ни expert-override, ни tune${NC}"
    echo -e "  ${DIM}• Меню «Управление секретами», «Настройки», «Режим эксперта» и${NC}"
    echo -e "  ${DIM}  команды tune/expert set становятся недоступны${NC}"
    echo -e "  ${DIM}• Изменения применяются перезапуском прокси${NC}"
    echo -e "  ${DIM}• NFT/Zapret2, selfmask, гео-блокировка и бэкапы работают как обычно${NC}"
}

superexpert_enable() {
    _require_manager_mode || return 1
    check_root

    if [ "${SUPEREXPERT_ENABLED:-false}" = "true" ]; then
        log_info "Режим супер эксперта уже включён"
        return 0
    fi

    echo ""
    draw_header "РЕЖИМ СУПЕР ЭКСПЕРТА"
    echo ""
    superexpert_show_rules
    echo ""

    if [ -f "$SUPEREXPERT_FILE" ]; then
        log_info "Найден сохранённый конфиг супер эксперта — он и будет использован"
        echo -e "  ${DIM}Файл сохраняется при выключении режима и переиспользуется при включении.${NC}"
    else
        echo -e "  ${DIM}Файл будет создан копией текущего рабочего конфига.${NC}"
    fi
    echo ""
    local _yn; read_line _yn "  ${BOLD}Включить режим супер эксперта? [y/N]:${NC} "
    [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 0; }

    if [ ! -f "$SUPEREXPERT_FILE" ]; then
        # Копию делаем с действующего конфига; если его ещё нет — генерируем
        if [ ! -f "$(engine_config_path)" ]; then
            log_info "Рабочего конфига пока нет — генерируем его из текущих настроек"
            generate_telemt_config || { log_error "Не удалось сгенерировать конфиг"; return 1; }
        fi
        mkdir -p "$INSTALL_DIR"
        cp "$(engine_config_path)" "$SUPEREXPERT_FILE" || {
            log_error "Не удалось создать ${SUPEREXPERT_FILE}"; return 1; }
        chmod 600 "$SUPEREXPERT_FILE"
        log_success "Создан ваш конфиг: ${SUPEREXPERT_FILE}"
    fi

    SUPEREXPERT_ENABLED="true"
    save_settings
    log_success "Режим супер эксперта включён"
    echo ""
    echo -e "  ${BOLD}Правьте файл:${NC} ${SUPEREXPERT_FILE}"
    echo -e "  ${DIM}Применить изменения: перезапуск прокси (меню «Управление прокси»)${NC}"
    echo ""
    # Редактор запускаем только человеку за терминалом. Под обходом
    # подтверждений (панель, скрипты) он бы стартовал без tty и висел до
    # таймаута — а редактировать файл панель умеет сама.
    if [ "${MTPROXYL_ASSUME_YES:-}" = "1" ]; then
        return 0
    fi
    local _e; read_line _e "  ${BOLD}Открыть файл в редакторе сейчас? [Y/n]:${NC} "
    [[ "$_e" =~ ^[nN] ]] || superexpert_edit
    return 0
}

superexpert_disable() {
    _require_manager_mode || return 1
    check_root

    if [ "${SUPEREXPERT_ENABLED:-false}" != "true" ]; then
        log_info "Режим супер эксперта не включён"
        return 0
    fi

    echo ""
    log_warn "Конфиг снова будет генерировать MTProxyL — из своих настроек и секретов"
    echo -e "  ${DIM}Ваш файл ${SUPEREXPERT_FILE} не удаляется: при повторном включении${NC}"
    echo -e "  ${DIM}режима будет использован он же, а не новая копия.${NC}"
    echo ""
    local _yn; read_line _yn "  ${BOLD}Выключить режим супер эксперта? [y/N]:${NC} "
    [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 0; }

    SUPEREXPERT_ENABLED="false"
    save_settings
    log_success "Режим супер эксперта выключен (файл сохранён)"

    generate_telemt_config && log_success "Конфиг пересобран из настроек MTProxyL" \
        || log_error "Ошибка генерации конфига"
    superexpert_offer_restart
}

superexpert_edit() {
    _require_manager_mode || return 1
    check_root

    if [ ! -f "$SUPEREXPERT_FILE" ]; then
        log_error "Файл ${SUPEREXPERT_FILE} не найден — сначала включите режим"
        return 1
    fi

    # Без терминала редактор запускать нельзя: он либо повиснет в ожидании
    # ввода, либо испортит вывод управляющими последовательностями. Панель
    # правит этот файл через 'superexpert write'.
    if [ "${MTPROXYL_ASSUME_YES:-}" = "1" ] || [ ! -t 0 ]; then
        log_error "Редактор недоступен без терминала"
        log_info "Из панели правьте файл в разделе «Супер эксперт»"
        log_info "Из скрипта: mtproxyl superexpert write < файл.toml"
        return 1
    fi

    local _editor="${EDITOR:-nano}"
    command -v "$_editor" &>/dev/null || _editor="vi"
    local _before; _before=$(md5sum "$SUPEREXPERT_FILE" 2>/dev/null | awk '{print $1}')
    "$_editor" "$SUPEREXPERT_FILE"
    local _after; _after=$(md5sum "$SUPEREXPERT_FILE" 2>/dev/null | awk '{print $1}')

    if [ "$_before" = "$_after" ]; then
        log_info "Файл не изменён"
        return 0
    fi
    log_success "Файл изменён"

    if _superexpert_active; then
        generate_telemt_config || { log_error "Не удалось применить конфиг"; return 1; }
        superexpert_offer_restart
    fi
}

superexpert_offer_restart() {
    is_proxy_running || { log_info "Прокси не запущен — изменения применятся при запуске"; return 0; }
    local _r; read_line _r "  ${BOLD}Перезапустить прокси, чтобы применить? [Y/n]:${NC} "
    [[ "$_r" =~ ^[nN] ]] && { log_info "Позже: меню «Управление прокси» → Перезапустить"; return 0; }
    load_secrets 2>/dev/null || true
    restart_proxy_container || true
}

# Пересоздать файл супер эксперта из конфига, который сгенерировал бы сам
# менеджер (текущие настройки + секреты). Полезно, когда пользователь
# «заигрался» и хочет начать с чистой рабочей базы.
superexpert_recreate() {
    _require_manager_mode || return 1
    check_root

    echo ""
    if [ -f "$SUPEREXPERT_FILE" ]; then
        log_warn "Текущий ${SUPEREXPERT_FILE} будет перезаписан"
        echo -e "  ${DIM}Копия старого файла останется рядом с суффиксом .bak${NC}"
    fi
    echo -e "  ${DIM}Новый файл будет собран из настроек и секретов MTProxyL.${NC}"
    local _yn; read_line _yn "  ${BOLD}Пересоздать? [y/N]:${NC} "
    [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 0; }

    # Генерируем эталонный конфиг менеджера во временный файл: включённый
    # режим супер эксперта иначе просто скопировал бы сам себя.
    local _saved="${SUPEREXPERT_ENABLED:-false}"
    SUPEREXPERT_ENABLED="false"
    generate_telemt_config || { SUPEREXPERT_ENABLED="$_saved"; log_error "Не удалось сгенерировать конфиг"; return 1; }
    SUPEREXPERT_ENABLED="$_saved"

    [ -f "$SUPEREXPERT_FILE" ] && cp "$SUPEREXPERT_FILE" "${SUPEREXPERT_FILE}.bak" 2>/dev/null
    cp "$(engine_config_path)" "$SUPEREXPERT_FILE" || { log_error "Не удалось записать ${SUPEREXPERT_FILE}"; return 1; }
    chmod 600 "$SUPEREXPERT_FILE"
    log_success "Файл пересоздан: ${SUPEREXPERT_FILE}"

    if _superexpert_active; then
        generate_telemt_config || true
        superexpert_offer_restart
    fi
}

handle_superexpert_command() {
    local _sub="${1:-status}"
    case "$_sub" in
        on|enable)   superexpert_enable ;;
        off|disable) superexpert_disable ;;
        edit)        superexpert_edit ;;
        status|"")
            if [ "${2:-}" = "--json" ]; then
                superexpert_status_json
            else
                echo -e "  ${BOLD}Режим супер эксперта:${NC} $(superexpert_status_line)"
                [ -f "$SUPEREXPERT_FILE" ] && echo -e "  ${BOLD}Файл:${NC} ${SUPEREXPERT_FILE}"
            fi ;;
        show)        superexpert_show_file ;;
        write)       superexpert_write_file ;;
        *)
            echo -e "  ${BOLD}Режим супер эксперта:${NC}"
            echo -e "    ${GREEN}superexpert status${NC}   Текущее состояние"
            echo -e "    ${GREEN}superexpert on${NC}       Включить (создать/взять свой конфиг)"
            echo -e "    ${GREEN}superexpert off${NC}      Выключить (файл сохраняется)"
            echo -e "    ${GREEN}superexpert edit${NC}     Правка конфига в \$EDITOR/nano"
            echo -e "    ${GREEN}superexpert show${NC}     Вывести конфиг"
            echo -e "    ${GREEN}superexpert write${NC}    Записать конфиг из stdin" ;;
    esac
}

# ── Генерация config.toml ────────────────────────────────────
generate_telemt_config() {
    mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"

    # Маршруты собираются из массивов в памяти. Команда, которая не звала
    # load_upstreams (установка аргументами, sni-policy, selfmask), молча
    # вычистила бы из конфига все upstream'ы: после загрузки их всегда хотя бы
    # один — подразумеваемый direct.
    if [ "${#UPSTREAM_NAMES[@]}" -eq 0 ]; then
        load_upstreams 2>/dev/null || true
    fi

    # Пользователи — тем же порядком и по той же причине: команда без
    # load_secrets (selfmask, nft, гео-блокировка) вычистила бы [access.users]
    # целиком, а дальше по цепочке ещё и завела бы взамен одного 'default'.
    if [ "${#SECRETS_LABELS[@]}" -eq 0 ]; then
        load_secrets 2>/dev/null || true
    fi

    # Режим супер эксперта: конфиг ведёт пользователь, мы только кладём его
    # файл на место config.toml. Ни настройки, ни секреты, ни override не
    # применяются — это и есть смысл режима.
    if _superexpert_active; then
        cp "$SUPEREXPERT_FILE" "$(engine_config_path)" || {
            log_error "Не удалось применить ${SUPEREXPERT_FILE}"; return 1; }
        chmod 644 "$(engine_config_path)"
        log_info "Режим супер эксперта: конфиг взят из ${SUPEREXPERT_FILE}"
        _superexpert_sync_port
        return 0
    fi

    if web_is_enabled; then
        selfmask_prepare_web_decoy || log_warn "WEB: не удалось подготовить файлы заглушки"
    fi

    local domain="${PROXY_DOMAIN:-cloudflare.com}"
    local mask_enabled="${MASKING_ENABLED:-true}"
    local mask_host="${MASKING_HOST:-$domain}"
    local mask_port="${MASKING_PORT:-443}"
    local ad_tag="${AD_TAG:-}"
    local port="${PROXY_PORT:-443}"
    local metrics_port="${PROXY_METRICS_PORT:-9090}"
    local api_port="${PROXY_API_PORT:-9091}"

    # При включённом WEB порт PROXY_PORT занимает nginx и разводит по SNI, а
    # движок уходит на loopback. Явные listener'ы отменяют legacy-поля [server]
    # целиком, поэтому MTProxy-listener приходится перечислять тоже.
    local web_listeners=""
    if web_is_enabled; then
        web_listeners=$(web_listeners_toml)
    fi

    local tmp; tmp=$(_mktemp "$CONFIG_DIR") || return 1

    cat > "$tmp" << TOML_EOF
# MTProxyL — конфигурация telemt
# Создано: $(date -u '+%Y-%m-%d %H:%M:%S UTC')

[general]
prefer_ipv6 = false
tg_connect = ${MTPROXYL_TG_CONNECT}
fast_mode = true
use_middle_proxy = true
log_level = "normal"

[general.modes]
classic = false
secure = $([ "$mask_enabled" = "false" ] && echo "true" || echo "false")
tls = true

[general.links]
show = [$(get_enabled_labels_quoted)]
$(_h=$(proxy_public_host) && printf 'public_host = "%s"\n' "$_h")
$(_lp=$(web_link_public_port) && printf 'public_port = %s\n' "$_lp")

[server]
port = ${port}
listen_addr_ipv4 = "0.0.0.0"
listen_addr_ipv6 = "::"
proxy_protocol = ${PROXY_PROTOCOL:-false}
metrics_listen = "127.0.0.1:${metrics_port}"
metrics_whitelist = ["127.0.0.1/32", "::1/128"]
${web_listeners}
[server.api]
enabled = true
listen = "127.0.0.1:${api_port}"
whitelist = ["127.0.0.1/32", "::1/128"]

[timeouts]
client_handshake = ${MTPROXYL_CLIENT_HANDSHAKE}
client_keepalive = ${MTPROXYL_CLIENT_KEEPALIVE}
client_ack = 90

[censorship]
tls_domain = "${domain}"
unknown_sni_action = "${UNKNOWN_SNI_ACTION:-mask}"
mask = ${mask_enabled}
mask_port = ${mask_port}
fake_cert_len = ${FAKE_CERT_LEN:-2048}

[access]
replay_check_len = 65536
replay_window_secs = 1800
ignore_time_skew = false

[access.users]
TOML_EOF

    # Условные параметры — добавляем только если заданы
    [ -n "$ad_tag" ] && \
        sed -i "/^\[general\]$/a ad_tag = \"${ad_tag}\"" "$tmp"
    [ -n "${PROXY_SECRET_URL:-}" ] && \
        sed -i "/^\[general\]$/a proxy_secret_url = \"${PROXY_SECRET_URL}\"" "$tmp"
    [ -n "${PROXY_CONFIG_V4_URL:-}" ] && \
        sed -i "/^\[general\]$/a proxy_config_v4_url = \"${PROXY_CONFIG_V4_URL}\"" "$tmp"
    [ -n "${PROXY_CONFIG_V6_URL:-}" ] && \
        sed -i "/^\[general\]$/a proxy_config_v6_url = \"${PROXY_CONFIG_V6_URL}\"" "$tmp"
    [ "$mask_enabled" = "true" ] && [ -n "$mask_host" ] && \
        sed -i "/^\[censorship\]$/a mask_host = \"${mask_host}\"" "$tmp"
    [ -n "${MASKING_RELAY_MAX_BYTES:-}" ] && \
        sed -i "/^\[censorship\]$/a mask_relay_max_bytes = ${MASKING_RELAY_MAX_BYTES}" "$tmp"

    # Секреты
    local i
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_ENABLED[$i]}" = "true" ] || continue
        echo "${SECRETS_LABELS[$i]} = \"${SECRETS_KEYS[$i]}\"" >> "$tmp"
    done

    # Лимиты
    local has_conns=false has_ips=false has_quota=false has_expires=false
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_ENABLED[$i]}" = "true" ] || continue
        [ "${SECRETS_MAX_CONNS[$i]:-0}" != "0" ] && has_conns=true
        [ "${SECRETS_MAX_IPS[$i]:-0}" != "0" ] && has_ips=true
        [ "${SECRETS_QUOTA[$i]:-0}" != "0" ] && has_quota=true
        [ "${SECRETS_EXPIRES[$i]:-0}" != "0" ] && has_expires=true
    done

    if $has_conns; then
        echo "" >> "$tmp"; echo "[access.user_max_tcp_conns]" >> "$tmp"
        for i in "${!SECRETS_LABELS[@]}"; do
            [ "${SECRETS_ENABLED[$i]}" = "true" ] && [ "${SECRETS_MAX_CONNS[$i]:-0}" != "0" ] && \
                echo "${SECRETS_LABELS[$i]} = ${SECRETS_MAX_CONNS[$i]}" >> "$tmp"
        done
    fi
    if $has_ips; then
        echo "" >> "$tmp"; echo "[access.user_max_unique_ips]" >> "$tmp"
        for i in "${!SECRETS_LABELS[@]}"; do
            [ "${SECRETS_ENABLED[$i]}" = "true" ] && [ "${SECRETS_MAX_IPS[$i]:-0}" != "0" ] && \
                echo "${SECRETS_LABELS[$i]} = ${SECRETS_MAX_IPS[$i]}" >> "$tmp"
        done
    fi
    if $has_quota; then
        echo "" >> "$tmp"; echo "[access.user_data_quota]" >> "$tmp"
        for i in "${!SECRETS_LABELS[@]}"; do
            [ "${SECRETS_ENABLED[$i]}" = "true" ] && [ "${SECRETS_QUOTA[$i]:-0}" != "0" ] && \
                echo "${SECRETS_LABELS[$i]} = ${SECRETS_QUOTA[$i]}" >> "$tmp"
        done
    fi
    if $has_expires; then
        echo "" >> "$tmp"; echo "[access.user_expirations]" >> "$tmp"
        for i in "${!SECRETS_LABELS[@]}"; do
            [ "${SECRETS_ENABLED[$i]}" = "true" ] && [ "${SECRETS_EXPIRES[$i]:-0}" != "0" ] && \
                echo "${SECRETS_LABELS[$i]} = \"${SECRETS_EXPIRES[$i]}\"" >> "$tmp"
        done
    fi
    # Своя рекламная метка пользователя. Общая из [general] остаётся в силе
    # для всех остальных — секция её не отменяет, а перекрывает поимённо.
    local has_adtag=false
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_ENABLED[$i]}" = "true" ] && [ -n "${SECRETS_ADTAG[$i]:-}" ] && has_adtag=true
    done
    if $has_adtag; then
        echo "" >> "$tmp"; echo "[access.user_ad_tags]" >> "$tmp"
        for i in "${!SECRETS_LABELS[@]}"; do
            [ "${SECRETS_ENABLED[$i]}" = "true" ] && [ -n "${SECRETS_ADTAG[$i]:-}" ] && \
                echo "${SECRETS_LABELS[$i]} = \"${SECRETS_ADTAG[$i]}\"" >> "$tmp"
        done
    fi

    # Upstreams
    # Shadowsocks движок принимает только при выключенном ME, а ME можно
    # выключить и включить обратно через экспертный режим уже после запретов.
    local _ss_enabled=0
    for i in "${!UPSTREAM_NAMES[@]}"; do
        [ "${UPSTREAM_ENABLED[$i]}" = "true" ] || continue
        [ "${UPSTREAM_TYPES[$i]}" = "shadowsocks" ] && _ss_enabled=1
    done
    if [ "$_ss_enabled" -eq 1 ] && [ "$(get_expert_override_value general use_middle_proxy 2>/dev/null)" != "false" ]; then
        log_warn "Включён shadowsocks-апстрим, но ME (use_middle_proxy) не выключен — движок отвергнет такой маршрут"
    fi

    for i in "${!UPSTREAM_NAMES[@]}"; do
        [ "${UPSTREAM_ENABLED[$i]}" = "true" ] || continue
        echo "" >> "$tmp"; echo "[[upstreams]]" >> "$tmp"
        echo "type = \"${UPSTREAM_TYPES[$i]}\"" >> "$tmp"
        echo "weight = ${UPSTREAM_WEIGHTS[$i]}" >> "$tmp"
        # У shadowsocks адрес, метод шифрования и пароль приходят одним
        # ss-URL — движок ждёт его в поле url, а не address.
        if [ "${UPSTREAM_TYPES[$i]}" = "shadowsocks" ]; then
            [ -n "${UPSTREAM_ADDRS[$i]}" ] && echo "url = \"${UPSTREAM_ADDRS[$i]}\"" >> "$tmp"
        elif [ "${UPSTREAM_TYPES[$i]}" != "direct" ] && [ -n "${UPSTREAM_ADDRS[$i]}" ]; then
            echo "address = \"${UPSTREAM_ADDRS[$i]}\"" >> "$tmp"
        fi
        if [ "${UPSTREAM_TYPES[$i]}" = "socks5" ]; then
            [ -n "${UPSTREAM_USERS[$i]}" ] && echo "username = \"${UPSTREAM_USERS[$i]}\"" >> "$tmp"
            [ -n "${UPSTREAM_PASSES[$i]}" ] && echo "password = \"${UPSTREAM_PASSES[$i]}\"" >> "$tmp"
        elif [ "${UPSTREAM_TYPES[$i]}" = "socks4" ] && [ -n "${UPSTREAM_USERS[$i]}" ]; then
            echo "user_id = \"${UPSTREAM_USERS[$i]}\"" >> "$tmp"
        fi
        [ -n "${UPSTREAM_IFACES[$i]}" ] && echo "interface = \"${UPSTREAM_IFACES[$i]}\"" >> "$tmp"
        [ -n "${UPSTREAM_SCOPES[$i]:-}" ] && echo "scopes = \"${UPSTREAM_SCOPES[$i]}\"" >> "$tmp"
    done

    # WEB Proxy — после [access.*], иначе профили разорвали бы таблицу секретов
    web_is_enabled && web_sections_toml >> "$tmp"

    # Engine tunings
    if [ -f "${_TUNE_FILE:-/dev/null}" ] && [ -s "${_TUNE_FILE}" ]; then
        while IFS='|' read -r _tp _tv; do
            [ -z "$_tp" ] && continue

            local _entry
            _entry=$(_tune_lookup "$_tp" 2>/dev/null) || continue

            local _p _sect _regex
            IFS=':' read -r _p _sect _regex <<< "$_entry"

            # Форматируем значение
            local _tv_out
            case "$_tp" in
                client_mss|client_mss_bulk)
                    _tv_out="\"$_tv\""
                    ;;
                *)
                    if [[ "$_tv" =~ ^(true|false|[0-9]+(\.[0-9]+)?)$ ]]; then
                        _tv_out="$_tv"
                    else
                        _tv_out="\"$_tv\""
                    fi
                    ;;
            esac

            # Если ключ уже есть где-то в файле — удалим все его вхождения
            # и потом вставим в ПРАВИЛЬНУЮ секцию
            local _esc_tp
            _esc_tp=$(printf '%s' "$_tp" | sed 's/[][\/.*^$]/\\&/g')
            sed -i "/^${_esc_tp}[[:space:]]*=/d" "$tmp"

            # Если секция есть — вставляем в неё
            if grep -qE "^\[${_sect//./\\.}\]$" "$tmp"; then
                awk -v sec="[$_sect]" -v key="$_tp" -v val="$_tv_out" '
                    BEGIN{inserted=0}
                    {
                        print
                        if ($0 == sec && !inserted) {
                            print key " = " val
                            inserted=1
                        }
                    }
                ' "$tmp" > "${tmp}.new" && mv "${tmp}.new" "$tmp"
            else
                # Если секции нет — создаём её в конце файла
                {
                    echo ""
                    echo "[$_sect]"
                    echo "${_tp} = ${_tv_out}"
                } >> "$tmp"
            fi
        done < "$_TUNE_FILE"
    fi

    # Expert overrides
    _apply_expert_overrides "$tmp"

    chmod 644 "$tmp"
    cp "$tmp" "$(engine_config_path)" && rm -f "$tmp"
}

# Override попадает в конфиг только при его генерации, поэтому предлагаем
# пересборку сразу — иначе «сохранено» вводит в заблуждение.
# Панель сохраняет пачкой: там пересборка отдельным шагом.
# Общий хвост для expert_apply_now и _expert_apply_prompt: генерация конфига
# и решение, хватит ли SIGHUP. tls_domains, exclusive_mask и вообще всё
# помеченное в каталоге как hot=✘ (или заданное через --raw мимо каталога)
# на лету не подхватывается — движок читает такие параметры только при
# полном старте, поэтому здесь честно говорим о restart, а не рапортуем
# успех, которого не было.
_expert_generate_and_apply() {
    generate_telemt_config || { log_error "Ошибка генерации конфига"; return 1; }
    log_success "Конфиг обновлён"
    if ! is_proxy_running; then
        log_warn "Прокси не запущен — значения применятся при запуске"
        return 0
    fi
    reload_target_config &>/dev/null || true
    if _expert_needs_restart; then
        log_warn "Среди заданных параметров есть без hot-reload — на лету не применились"
        log_info "Чтобы вступили в силу: mtproxyl restart"
    else
        log_success "Hot-reload отправлен"
    fi
}

expert_apply_now() {
    _expert_generate_and_apply
}

_expert_apply_prompt() {
    local _yn; read_line _yn "  ${BOLD}Пересобрать конфиг и применить сейчас? [Y/n]:${NC} "
    [[ "$_yn" =~ ^[nN] ]] && { log_info "Позже: mtproxyl config или меню → Режим эксперта → Пересобрать"; return 0; }
    _expert_generate_and_apply
}

handle_expert_command() {
    local subcmd="${1:-list}"; shift 2>/dev/null || true
    [ "$subcmd" = "list" ] || _require_manager_mode || return 1
    [ "$subcmd" = "list" ] || _require_no_superexpert || return 1
    case "$subcmd" in
        list)
            case "${1:-}" in
                --json)      expert_overrides_json ;;
                --catalog)   expert_catalog_json ;;
                *)           show_expert_overrides ;;
            esac ;;
        set)
            check_root
            local _raw="false" _apply="true"
            local -a _pos=()
            local _a
            for _a in "$@"; do
                case "$_a" in
                    --raw)      _raw="true" ;;
                    --no-apply) _apply="false" ;;
                    *)          _pos+=("$_a") ;;
                esac
            done
            local _sec="${_pos[0]:-}" _key="${_pos[1]:-}" _val="${_pos[2]:-}"
            if [ -z "$_sec" ] || [ -z "$_key" ] || [ -z "$_val" ]; then
                log_error "Использование: mtproxyl expert set [--raw] <секция> <ключ> <значение>"
                return 1
            fi
            local _entry; _entry=$(_expert_find "$_sec" "$_key")
            if [ -z "$_entry" ]; then
                if [ "$_raw" != "true" ]; then
                    log_error "Параметр [${_sec}] ${_key} не найден в каталоге"
                    log_info "Список доступных: меню → Режим эксперта"
                    log_info "Записать всё равно: mtproxyl expert set --raw ${_sec} ${_key} <значение>"
                    return 1
                fi
                _expert_validate_raw "$_sec" "$_key" "$_val" || return 1
            else
                _expert_parse "$_entry"
                local _verr
                _verr=$(_expert_validate "$EXPERT_P_VALIDATOR" "$_val" 2>&1)
                if [ -n "$_verr" ]; then
                    log_error "Некорректное значение: ${_verr}"
                    return 1
                fi
            fi
            save_expert_override "$_sec" "$_key" "$_val" || return 1
            log_success "Override сохранён: [${_sec}] ${_key} = ${_val}"
            [ -z "$_entry" ] && log_warn "Параметра нет в каталоге — значение не проверялось"
            [ "$_apply" = "true" ] || return 0
            _expert_apply_prompt ;;
        clear)
            check_root
            local _what="${1:-}"
            case "$_what" in
                "")
                    log_error "Использование: mtproxyl expert clear <секция> <ключ> | all"
                    return 1 ;;
                all)
                    clear_all_expert_overrides
                    log_success "Все expert override удалены"
                    _expert_apply_prompt ;;
                *)
                    local _key="${2:-}"
                    if [ -z "$_key" ]; then
                        log_error "Использование: mtproxyl expert clear <секция> <ключ> | all"
                        return 1
                    fi
                    if [ -z "$(get_expert_override_value "$_what" "$_key")" ]; then
                        log_info "Override [${_what}] ${_key} не задан"
                        return 0
                    fi
                    delete_expert_override "$_what" "$_key" || return 1
                    log_success "Override удалён: [${_what}] ${_key}"
                    [ "${3:-}" = "--no-apply" ] && return 0
                    _expert_apply_prompt ;;
            esac ;;
        apply)
            check_root
            expert_apply_now ;;
        edit)
            check_root
            local config; config=$(engine_config_path)
            if [ -f "$config" ]; then
                local editor="${EDITOR:-nano}"
                log_warn "Изменения будут перезаписаны при генерации конфига!"
                log_info "Для постоянных: mtproxyl expert set <секция> <ключ> <значение>"
                "$editor" "$config"
            else log_error "Конфиг не найден"; fi ;;
        *)
            echo -e "  ${BOLD}Режим эксперта:${NC}"
            echo -e "    ${GREEN}expert list${NC}                            Параметры"
            echo -e "    ${GREEN}expert list --json${NC}                     Заданные override (JSON)"
            echo -e "    ${GREEN}expert list --catalog${NC}                  Весь каталог с валидаторами (JSON)"
            echo -e "    ${GREEN}expert set${NC} <секция> <ключ> <значение>   Добавить"
            echo -e "    ${GREEN}expert set --raw${NC} <секция> <ключ> <знач>  Параметр вне каталога, без проверки"
            echo -e "    ${GREEN}expert clear${NC} <секция> <ключ> | all      Удалить"
            echo -e "    ${GREEN}expert apply${NC}                           Пересобрать конфиг и применить"
            echo -e "    ${DIM}У set/clear есть --no-apply: отложить применение${NC}"
            echo -e "    ${GREEN}expert edit${NC}                            Редактор" ;;
    esac
}

# Машинное состояние режима супер эксперта для панели.
superexpert_status_json() {
    local _size=0 _mtime=0
    if [ -f "$SUPEREXPERT_FILE" ]; then
        _size=$(stat -c '%s' "$SUPEREXPERT_FILE" 2>/dev/null || echo 0)
        _mtime=$(stat -c '%Y' "$SUPEREXPERT_FILE" 2>/dev/null || echo 0)
    fi
    printf '{"enabled":%s,"active":%s,"file":"%s","file_exists":%s,"size":%d,"mtime":%d}\n' \
        "$([ "${SUPEREXPERT_ENABLED:-false}" = "true" ] && echo true || echo false)" \
        "$(_superexpert_active && echo true || echo false)" \
        "$(json_escape "$SUPEREXPERT_FILE")" \
        "$([ -f "$SUPEREXPERT_FILE" ] && echo true || echo false)" \
        "${_size:-0}" "${_mtime:-0}"
}

# Содержимое пользовательского конфига для редактора панели: конфиг супер
# эксперта, а если его ещё нет — действующий сейчас. Включение режима
# копирует рабочий конфиг, он и станет отправной точкой.
superexpert_show_file() {
    if [ -f "$SUPEREXPERT_FILE" ]; then
        cat "$SUPEREXPERT_FILE"
        return 0
    fi
    local _live; _live=$(engine_config_path)
    if [ -f "$_live" ]; then
        cat "$_live"
        return 0
    fi
    # Конфига нет вовсе (прокси ещё не разворачивали) — соберём из текущих
    # настроек, чтобы показать хоть что-то осмысленное.
    if generate_telemt_config >/dev/null 2>&1 && [ -f "$_live" ]; then
        cat "$_live"
        return 0
    fi
    log_error "Конфиг не найден: ни ${SUPEREXPERT_FILE}, ни ${_live}"
    return 1
}

# Запись конфига из stdin: TOML многострочный и с кавычками, передавать его
# аргументом неудобно и опасно.
superexpert_write_file() {
    check_root || return 1
    mkdir -p "$(dirname "$SUPEREXPERT_FILE")"

    # Пишем во временный файл: оборванная передача не должна оставить
    # обрезанный конфиг, по которому движок потом не поднимется. Временный
    # файл кладём рядом с целевым, чтобы подменить его одним mv.
    local _tmp; _tmp=$(_mktemp "$(dirname "$SUPEREXPERT_FILE")") || return 1
    cat > "$_tmp"

    if [ ! -s "$_tmp" ]; then
        rm -f "$_tmp"
        log_error "Пустой конфиг отклонён"
        return 1
    fi
    # Минимальная проверка: у telemt-конфига обязательно есть секции.
    if ! grep -qE '^\[[a-z]' "$_tmp"; then
        rm -f "$_tmp"
        log_error "Не похоже на TOML движка — нет ни одной секции"
        return 1
    fi

    chmod 600 "$_tmp"
    mv "$_tmp" "$SUPEREXPERT_FILE"
    log_success "Конфиг сохранён: ${SUPEREXPERT_FILE}"
    log_info "Перезапустите прокси, чтобы применить: mtproxyl restart"
}
