#!/bin/bash
# MTProxyL — режим Reanimator: обнаружение чужой установки telemt + точечный тюнинг

DETECT_CONF="${INSTALL_DIR}/detect.conf"

# ── Значения по умолчанию ─────────────────────────────────────
DETECTED_MODE="unknown"          # mtproxymax|docker|local|config_only|manual|unknown
DETECTED_CONTAINER=""
DETECTED_CONFIG_PATH=""
DETECTED_IP=""
DETECTED_PORT=""
DETECTED_NETWORK_MODE=""         # host|bridge
DETECT_BRIDGE_STRATEGY="simple"  # simple|precise

save_detect_settings() {
    mkdir -p "$INSTALL_DIR"
    cat > "$DETECT_CONF" << EOF
# MTProxyL Reanimator — обнаруженная цель
DETECTED_MODE='${DETECTED_MODE}'
DETECTED_CONTAINER='${DETECTED_CONTAINER}'
DETECTED_CONFIG_PATH='${DETECTED_CONFIG_PATH}'
DETECTED_IP='${DETECTED_IP}'
DETECTED_PORT='${DETECTED_PORT}'
DETECTED_NETWORK_MODE='${DETECTED_NETWORK_MODE}'
DETECT_BRIDGE_STRATEGY='${DETECT_BRIDGE_STRATEGY}'
EOF
    chmod 600 "$DETECT_CONF"
}

load_detect_settings() {
    [ -f "$DETECT_CONF" ] || return 0
    while IFS= read -r _line; do
        [[ "$_line" =~ ^[[:space:]]*# ]] && continue
        [[ "$_line" =~ ^[[:space:]]*$ ]] && continue
        if [[ "$_line" =~ ^([A-Z_][A-Z0-9_]*)=\'([^\']*)\'$ ]]; then
            local _key="${BASH_REMATCH[1]}" _val="${BASH_REMATCH[2]}"
            case "$_key" in
                DETECTED_MODE|DETECTED_CONTAINER|DETECTED_CONFIG_PATH|\
                DETECTED_IP|DETECTED_PORT|DETECTED_NETWORK_MODE|DETECT_BRIDGE_STRATEGY)
                    printf -v "$_key" '%s' "$_val" ;;
            esac
        fi
    done < "$DETECT_CONF"
    case "$DETECT_BRIDGE_STRATEGY" in
        simple|precise) ;;
        *) DETECT_BRIDGE_STRATEGY="simple" ;;
    esac
}

# ── Работа с произвольным TOML (чужой конфиг, только точечные правки) ──
_toml_get_value() {
    local _key="$1" _file="$2"
    [ -f "$_file" ] || return 0
    awk -v k="$_key" '
        /^[[:space:]]*#/ { next }
        $1 == k && $2 == "=" { gsub(/[^0-9]/, "", $3); print $3; exit }
    ' "$_file" 2>/dev/null
}

_toml_has_section() {
    local _section="$1" _file="$2"
    grep -qE "^\\[${_section}\\]" "$_file" 2>/dev/null
}

_toml_has_key() {
    local _key="$1" _file="$2"
    awk -v k="$_key" '
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (substr(line, 1, length(k)) == k) {
                rest = substr(line, length(k) + 1)
                if (rest ~ /^[[:space:]]*=/) { found=1; exit }
            }
        }
        END { exit !found }
    ' "$_file" 2>/dev/null
}

_toml_safe_set() {
    local _key="$1" _value="$2" _section="$3" _file="$4"
    [ -f "$_file" ] || return 1
    if _toml_has_key "$_key" "$_file"; then
        sed -i "s/^${_key}[[:space:]]*=.*/${_key} = ${_value}/" "$_file"
        return 0
    fi
    if _toml_has_section "$_section" "$_file"; then
        sed -i "/^\\[${_section}\\]/a ${_key} = ${_value}" "$_file"
        return 0
    fi
    return 1
}

# Читает произвольный ключ (строку или число, без обрезания не-цифр — в
# отличие от _toml_get_value) внутри конкретной секции [section].
_toml_get_string_in_section() {
    local _section="$1" _key="$2" _file="$3"
    [ -f "$_file" ] || return 0
    awk -v sect="[${_section}]" -v k="$_key" '
        $0 == sect { insect=1; next }
        /^\[/ { insect=0 }
        insect {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (line ~ ("^" k "[[:space:]]*=")) {
                sub(("^" k "[[:space:]]*=[[:space:]]*"), "", line)
                sub(/[[:space:]]*#.*$/, "", line)
                gsub(/"/, "", line)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                print line
                exit
            }
        }
    ' "$_file" 2>/dev/null
}

# ── API управления цели (telemt [server.api]) ──────────────────
_get_telemt_api_port() {
    local _cfg="${1:-$DETECTED_CONFIG_PATH}"
    local _listen="" _port=""
    if [ -n "$_cfg" ] && [ -f "$_cfg" ]; then
        _listen=$(_toml_get_string_in_section "server.api" "listen" "$_cfg")
        [ -n "$_listen" ] && _port=$(printf '%s\n' "$_listen" | sed -nE 's/.*:([0-9]+)$/\1/p')
    fi
    [ -z "$_port" ] && _port="9091"
    echo "$_port"
}

_get_telemt_metrics_port() {
    local _cfg="${1:-$DETECTED_CONFIG_PATH}"
    local _listen="" _port=""
    if [ -n "$_cfg" ] && [ -f "$_cfg" ]; then
        _listen=$(_toml_get_string_in_section "server" "metrics_listen" "$_cfg")
        [ -n "$_listen" ] && _port=$(printf '%s\n' "$_listen" | sed -nE 's/.*:([0-9]+)$/\1/p')
    fi
    [ -z "$_port" ] && _port="9090"
    echo "$_port"
}

_telemt_api_enabled() {
    local _cfg="${1:-$DETECTED_CONFIG_PATH}"
    [ -n "$_cfg" ] && [ -f "$_cfg" ] || return 1
    local _en; _en=$(_toml_get_string_in_section "server.api" "enabled" "$_cfg")
    [ "$_en" = "true" ]
}

# Забирает JSON с /v1/users API цели (список пользователей + их
# трафик/соединения/ссылки). Возвращает непустой JSON с "ok":true,
# либо код ошибки, если API выключен/недоступен.
_get_telemt_users_json() {
    local _cfg="${1:-$DETECTED_CONFIG_PATH}"
    _telemt_api_enabled "$_cfg" || return 1
    local _port; _port=$(_get_telemt_api_port "$_cfg")
    local _json
    _json=$(curl -s --max-time 3 --connect-timeout 2 "http://127.0.0.1:${_port}/v1/users" 2>/dev/null) || return 1
    [ -z "$_json" ] && return 1
    echo "$_json" | grep -q '"ok":true' || return 1
    echo "$_json"
}

_target_tls_domain() {
    local _cfg="${1:-$DETECTED_CONFIG_PATH}"
    [ -n "$_cfg" ] && [ -f "$_cfg" ] || return 1
    _toml_get_string_in_section "censorship" "tls_domain" "$_cfg"
}

# Лёгкий парсинг плоских числовых/булевых полей из JSON без внешних
# зависимостей (jq): суммирует/считает поле по всем объектам массива data[].
_json_sum_field() {
    local _json="$1" _field="$2"
    grep -oE "\"${_field}\"[[:space:]]*:[[:space:]]*[0-9]+" <<< "$_json" \
        | grep -oE '[0-9]+$' | awk '{sum+=$1} END {print sum+0}'
}

_json_count_bool_field() {
    local _json="$1" _field="$2" _val="$3"
    grep -oE "\"${_field}\"[[:space:]]*:[[:space:]]*${_val}" <<< "$_json" | wc -l
}

# Агрегированная статистика цели через её собственный API (для
# reanimator-режима): заполняет глобальные TARGET_STATS_*. Возвращает 1,
# если [server.api] выключен или API недоступен — вызывающий код должен
# в этом случае показать явное "н/д", а не тихий ноль.
TARGET_STATS_OCTETS=0
TARGET_STATS_CONNS=0
TARGET_STATS_ACTIVE=0
TARGET_STATS_DISABLED=0

fetch_target_stats() {
    TARGET_STATS_OCTETS=0
    TARGET_STATS_CONNS=0
    TARGET_STATS_ACTIVE=0
    TARGET_STATS_DISABLED=0
    local _json
    _json=$(_get_telemt_users_json) || return 1
    TARGET_STATS_OCTETS=$(_json_sum_field "$_json" "total_octets")
    TARGET_STATS_CONNS=$(_json_sum_field "$_json" "current_connections")
    TARGET_STATS_ACTIVE=$(_json_count_bool_field "$_json" "enabled" "true")
    TARGET_STATS_DISABLED=$(_json_count_bool_field "$_json" "enabled" "false")
}

# Текущий SNI-домен: домен цели в reanimator-режиме (из TOML), иначе
# PROXY_DOMAIN менеджера. Используется и в статус-панели, и в дополнениях
# (проверка PQ/censorcheck), чтобы не проверять чужой дефолтный домен.
_current_sni_domain() {
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        local _d; _d=$(_target_tls_domain 2>/dev/null)
        if [ -n "$_d" ]; then
            echo "$_d"
            return 0
        fi
    fi
    echo "${PROXY_DOMAIN:-}"
}

# ── Исключение чужих панелей / собственного контейнера ────────
_is_excluded_path() {
    local _path="$1"
    case "$_path" in
        *telemt-panel*|*telemt_panel*) return 0 ;;
    esac
    return 1
}

_looks_like_telemt_config() {
    local _file="$1"
    [ -f "$_file" ] || return 1
    grep -qE '^\[access\.users\]|^\[censorship\]|^\[general\.modes\]|^tls_domain[[:space:]]*=' "$_file" 2>/dev/null
}

# ── Обнаружение существующей установки telemt ─────────────────
detect_telemt() {
    DETECTED_MODE="unknown"
    DETECTED_CONTAINER=""
    DETECTED_CONFIG_PATH=""
    DETECTED_IP=""
    DETECTED_PORT=""
    DETECTED_NETWORK_MODE=""

    # 1. MTProxyMax
    if [ -f /opt/mtproxymax/settings.conf ] && command -v mtproxymax &>/dev/null; then
        DETECTED_MODE="mtproxymax"
        DETECTED_CONFIG_PATH="/opt/mtproxymax/mtproxy/config.toml"
        local _port
        _port=$(awk -F"'" '/^PROXY_PORT=/{print $2; exit}' /opt/mtproxymax/settings.conf 2>/dev/null)
        [ -n "$_port" ] && DETECTED_PORT="$_port"
        local _ip
        _ip=$(awk -F"'" '/^CUSTOM_IP=/{print $2; exit}' /opt/mtproxymax/settings.conf 2>/dev/null)
        [ -n "$_ip" ] && DETECTED_IP="$_ip"
        if command -v docker &>/dev/null && docker inspect mtproxymax &>/dev/null 2>&1; then
            if docker inspect -f '{{.HostConfig.NetworkMode}}' mtproxymax 2>/dev/null | grep -q "host"; then
                DETECTED_NETWORK_MODE="host"
            else
                DETECTED_NETWORK_MODE="bridge"
            fi
        else
            DETECTED_NETWORK_MODE="host"
        fi
        DETECTED_CONTAINER="mtproxymax"
        return 0
    fi

    # 2. Docker-контейнер с telemt (не наш собственный)
    if command -v docker &>/dev/null; then
        local _cname
        for _cname in $(docker ps --format '{{.Names}}' 2>/dev/null); do
            [ "$_cname" = "$CONTAINER_NAME" ] && continue
            case "$_cname" in *panel*|*telemt-panel*|*telemt_panel*) continue ;; esac
            local _inspect
            _inspect=$(docker inspect "$_cname" 2>/dev/null) || continue
            local _is_telemt=false
            local _inspect_no_panel
            _inspect_no_panel=$(echo "$_inspect" | grep -viE 'panel')
            if echo "$_inspect_no_panel" | grep -qiE '"Image".*telemt'; then
                _is_telemt=true
            elif echo "$_inspect_no_panel" | grep -qiE 'telemt\.toml|telemt/telemt'; then
                _is_telemt=true
            elif echo "$_inspect_no_panel" | grep -qiE '"Cmd".*telemt'; then
                _is_telemt=true
            fi
            [ "$_is_telemt" = "false" ] && continue
            DETECTED_MODE="docker"
            DETECTED_CONTAINER="$_cname"
            local _mount _candidate _dest
            local _dests="/etc/telemt.toml /etc/telemt /etc/telemt/telemt.toml /app/config.toml"
            for _dest in $_dests; do
                _mount=$(docker inspect -f "{{range .Mounts}}{{if eq .Destination \"${_dest}\"}}{{.Source}}{{end}}{{end}}" "$_cname" 2>/dev/null)
                [ -z "$_mount" ] && continue
                if [ -d "$_mount" ]; then
                    for _candidate in "${_mount}/config.toml" "${_mount}/telemt.toml"; do
                        if [ -f "$_candidate" ] && ! _is_excluded_path "$_candidate" && _looks_like_telemt_config "$_candidate"; then
                            DETECTED_CONFIG_PATH="$_candidate"
                            break 2
                        fi
                    done
                elif [ -f "$_mount" ] && ! _is_excluded_path "$_mount" && _looks_like_telemt_config "$_mount"; then
                    DETECTED_CONFIG_PATH="$_mount"
                    break
                fi
            done
            local _nm
            _nm=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$_cname" 2>/dev/null)
            if [ "$_nm" = "host" ]; then
                DETECTED_NETWORK_MODE="host"
            else
                DETECTED_NETWORK_MODE="bridge"
            fi
            if [ -f "$DETECTED_CONFIG_PATH" ]; then
                local _p
                _p=$(_toml_get_value "port" "$DETECTED_CONFIG_PATH")
                [ -n "$_p" ] && DETECTED_PORT="$_p"
            fi
            return 0
        done
    fi

    # 3. Локальный процесс telemt
    if pgrep -x telemt &>/dev/null || systemctl is-active telemt.service &>/dev/null 2>&1; then
        DETECTED_MODE="local"
        DETECTED_NETWORK_MODE="host"
        local _args
        _args=$(ps -eo args 2>/dev/null | grep '[t]elemt' | grep -v 'telemt-panel' | grep -v 'telemt_panel' | head -1 | grep -oE '/[^ ]+\.toml' | head -1)
        if [ -n "$_args" ] && [ -f "$_args" ] && ! _is_excluded_path "$_args" && _looks_like_telemt_config "$_args"; then
            DETECTED_CONFIG_PATH="$_args"
        fi
        if [ -z "$DETECTED_CONFIG_PATH" ]; then
            local _cf
            for _cf in /etc/telemt/telemt.toml /etc/telemt/config.toml /etc/telemt.toml /opt/telemt/config.toml /opt/telemt/telemt.toml; do
                if [ -f "$_cf" ] && ! _is_excluded_path "$_cf" && _looks_like_telemt_config "$_cf"; then
                    DETECTED_CONFIG_PATH="$_cf"
                    break
                fi
            done
        fi
        if [ -f "$DETECTED_CONFIG_PATH" ]; then
            local _p
            _p=$(_toml_get_value "port" "$DETECTED_CONFIG_PATH")
            [ -n "$_p" ] && DETECTED_PORT="$_p"
        fi
        return 0
    fi

    # 4. Только конфиг (процесс не найден)
    local _cf
    for _cf in /etc/telemt/telemt.toml /etc/telemt/config.toml /etc/telemt.toml \
               /opt/telemt/config.toml /opt/telemt/telemt.toml \
               /opt/mtproxymax/mtproxy/config.toml; do
        if [ -f "$_cf" ] && ! _is_excluded_path "$_cf" && _looks_like_telemt_config "$_cf"; then
            DETECTED_CONFIG_PATH="$_cf"
            DETECTED_MODE="config_only"
            DETECTED_NETWORK_MODE="host"
            local _p
            _p=$(_toml_get_value "port" "$_cf")
            [ -n "$_p" ] && DETECTED_PORT="$_p"
            return 0
        fi
    done
    return 1
}

docker_container_ip() {
    local _container="${1:-$DETECTED_CONTAINER}"
    [ -z "$_container" ] && return 1
    docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\n"}}{{end}}' \
        "$_container" 2>/dev/null | awk 'NF {print; exit}'
}

prompt_bridge_mode() {
    [ "$DETECTED_NETWORK_MODE" = "bridge" ] || return 0
    echo ""
    echo -e "  ${BOLD}Обнаружен Docker bridge режим${NC}"
    echo ""
    echo -e "  ${DIM}[1]${NC} Простой режим — без IP, правило только по порту"
    echo -e "      ${DIM}Плюсы:${NC} надёжно, без watcher, меньше зависимостей"
    echo -e "  ${DIM}[2]${NC} Точный режим — внутренний IP контейнера + watcher"
    echo -e "      ${DIM}Плюсы:${NC} точное совпадение; ${DIM}Минусы:${NC} нужен watcher (IP может меняться)"
    echo ""
    local _bm; _bm=$(read_choice "выбор" "1")
    case "$_bm" in
        2) DETECT_BRIDGE_STRATEGY="precise" ;;
        *) DETECT_BRIDGE_STRATEGY="simple" ;;
    esac
}

run_target_detection() {
    log_info "Поиск установленного telemt на хосте..."
    if detect_telemt; then
        echo ""
        echo -e "  ${BOLD}Найдено:${NC} ${DETECTED_MODE}"
        [ -n "$DETECTED_CONTAINER" ]   && echo -e "  ${BOLD}Контейнер:${NC}      ${DETECTED_CONTAINER}"
        [ -n "$DETECTED_CONFIG_PATH" ] && echo -e "  ${BOLD}Конфиг:${NC}         ${DETECTED_CONFIG_PATH}"
        [ -n "$DETECTED_PORT" ]        && echo -e "  ${BOLD}Порт:${NC}           ${DETECTED_PORT}"
        [ -n "$DETECTED_NETWORK_MODE" ] && echo -e "  ${BOLD}Сеть Docker:${NC}    ${DETECTED_NETWORK_MODE}"
        return 0
    else
        log_warn "Автоматически найти telemt не удалось"
        return 1
    fi
}

# ── Безопасный точечный тюнинг чужого конфига (reanimator) ────
apply_target_tuning() {
    local param="$1" value="$2" section="$3"

    if [ "$DETECTED_MODE" = "mtproxymax" ]; then
        command -v mtproxymax &>/dev/null || { log_error "mtproxymax не найден в PATH"; return 1; }
        echo "n" | mtproxymax tune set "$param" "$value" &>/dev/null \
            && log_success "mtproxymax: ${param} = ${value}" \
            || { log_warn "Не удалось применить через 'mtproxymax tune set'"; return 1; }
        return 0
    fi

    if [ -z "$DETECTED_CONFIG_PATH" ] || [ ! -f "$DETECTED_CONFIG_PATH" ]; then
        log_warn "Конфиг цели не найден — добавьте вручную: [${section}] ${param} = ${value}"
        return 1
    fi

    local _cfg="$DETECTED_CONFIG_PATH"
    mkdir -p "$BACKUP_DIR"
    if ! cp "$_cfg" "${BACKUP_DIR}/$(basename "$_cfg").mtpr-backup-$(date +%s)" 2>/dev/null; then
        log_warn "Не удалось создать резервную копию конфига цели"
    fi

    local _tv_out="$value"
    case "$param" in
        client_mss|client_mss_bulk) _tv_out="\"$value\"" ;;
        *) [[ "$value" =~ ^(true|false|[0-9]+(\.[0-9]+)?)$ ]] || _tv_out="\"$value\"" ;;
    esac

    if _toml_safe_set "$param" "$_tv_out" "$section" "$_cfg"; then
        log_success "${param} = ${value} (${_cfg})"
    else
        log_warn "Секция [${section}] отсутствует в ${_cfg}"
        echo -en "  ${BOLD}Создать секцию и применить? [Y/n]:${NC} "
        local _cr; read -r _cr
        if [[ ! "$_cr" =~ ^[nN]$ ]]; then
            printf '\n[%s]\n%s = %s\n' "$section" "$param" "$_tv_out" >> "$_cfg"
            log_success "Секция [${section}] создана"
        else
            return 1
        fi
    fi

    if is_proxy_running; then
        echo -en "  ${BOLD}Перезапустить цель, чтобы применить изменения? [Y/n]:${NC} "
        local _r; read -r _r
        [[ ! "$_r" =~ ^[nN] ]] && restart_target
    fi
}

# ── Переключение режима работы ─────────────────────────────────
switch_to_manager_mode() {
    if [ "${MTPROXYL_MODE:-manager}" = "manager" ]; then
        log_info "Уже в режиме manager"
        return 0
    fi
    echo ""
    log_warn "Переход в режим Manager. MTProxyL начнёт устанавливать/владеть СВОИМ telemt."
    echo -en "  ${BOLD}Введите 'yes' для подтверждения:${NC} "
    local _c; read -r _c
    [ "$_c" != "yes" ] && { log_info "Отменено"; return 1; }
    MTPROXYL_MODE="manager"
    save_settings
    log_success "Режим: manager"
}

switch_to_reanimator_mode() {
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        log_info "Уже в режиме reanimator"
        return 0
    fi
    echo ""
    log_warn "Переход в режим Reanimator. Свой контейнер/конфиг MTProxyL (если есть) больше не будет управляться из меню — используйте 'docker rm ${CONTAINER_NAME}' вручную, если он больше не нужен."
    echo -en "  ${BOLD}Введите 'yes' для подтверждения:${NC} "
    local _c; read -r _c
    [ "$_c" != "yes" ] && { log_info "Отменено"; return 1; }
    MTPROXYL_MODE="reanimator"
    save_settings
    run_target_detection
    save_detect_settings
    log_success "Режим: reanimator"
}

# ── Установочный визард для режима Reanimator ──────────────────
run_reanimator_installer() {
    draw_header "REANIMATOR — ПОИСК СУЩЕСТВУЮЩЕЙ УСТАНОВКИ TELEMT"
    echo ""

    check_root

    if ! run_target_detection; then
        echo ""
        echo -e "  ${BOLD}Укажите путь к конфигу telemt вручную (Enter — пропустить):${NC}"
        echo -en "  ${DIM}Путь:${NC} "
        local _manual_path; read -r _manual_path
        if [ -n "$_manual_path" ] && [ -f "$_manual_path" ]; then
            DETECTED_CONFIG_PATH="$_manual_path"
            DETECTED_MODE="manual"
            DETECTED_NETWORK_MODE="host"
        else
            log_warn "Продолжаем без обнаруженного конфига — фиксы будут применены только на уровне хоста (NFT/sysctl)"
            DETECTED_MODE="manual"
            DETECTED_NETWORK_MODE="host"
        fi
    else
        echo ""
        echo -en "  ${BOLD}Указать другой путь к конфигу? [y/N]:${NC} "
        local _override; read -r _override
        if [[ "$_override" =~ ^[yY]$ ]]; then
            echo -en "  ${DIM}Путь:${NC} "
            local _p; read -r _p
            [ -n "$_p" ] && [ -f "$_p" ] && DETECTED_CONFIG_PATH="$_p"
        fi
    fi

    echo ""
    echo -e "  ${BOLD}Порт прокси${NC} ${DIM}(обнаружен: ${DETECTED_PORT:-?})${NC}"
    echo -en "  ${DIM}Порт [${DETECTED_PORT:-443}]:${NC} "
    local _port_in; read -r _port_in
    if [ -n "$_port_in" ] && validate_port "$_port_in"; then
        PROXY_PORT="$_port_in"
    else
        PROXY_PORT="${DETECTED_PORT:-443}"
    fi

    echo ""
    local _det_ip="${DETECTED_IP:-$(get_public_ip 2>/dev/null)}"
    echo -e "  ${BOLD}IP сервера${NC} ${DIM}(обнаружен/определён: ${_det_ip:-?})${NC}"
    echo -en "  ${DIM}IP [${_det_ip:-авто}]:${NC} "
    local _ip_in; read -r _ip_in
    if [ -n "$_ip_in" ] && validate_ip_literal "$_ip_in"; then
        CUSTOM_IP="$_ip_in"
    else
        CUSTOM_IP="$_det_ip"
    fi
    NFT_SERVER_IP="$CUSTOM_IP"

    prompt_bridge_mode

    mkdir -p "$INSTALL_DIR" "$BACKUP_DIR"
    chmod 700 "$INSTALL_DIR"
    save_settings
    save_detect_settings

    run_fix_arsenal_wizard

    echo ""
    draw_header "REANIMATOR НАСТРОЕН"
    echo ""
    echo -e "  ${BOLD}Режим:${NC}       Reanimator"
    echo -e "  ${BOLD}Цель:${NC}        ${DETECTED_MODE}$([ -n "$DETECTED_CONTAINER" ] && echo " (${DETECTED_CONTAINER})")"
    echo -e "  ${BOLD}Конфиг цели:${NC} ${DETECTED_CONFIG_PATH:-нет}"
    echo -e "  ${BOLD}Порт:${NC}        ${PROXY_PORT}"
    echo ""
    echo -e "  ${DIM}Точечный тюнинг: mtproxyl tune set <параметр> <значение>${NC}"
    echo -e "  ${DIM}Повторный детект: mtproxyl detect${NC}"
    echo ""

    ln -sf "${INSTALL_DIR}/mtproxyl.sh" /usr/local/bin/mtproxyl

    echo -en "  ${BOLD}Настроить точечный тюнинг сейчас? [Y/n]:${NC} "
    local _tune_yn; read -r _tune_yn
    if [[ ! "$_tune_yn" =~ ^[nN]$ ]]; then
        echo ""
        run_tune_wizard
    fi

    echo -en "  ${DIM}Нажмите клавишу для входа в меню...${NC}"
    read -rsn1
    read -rn 256 -t 0.05 _ 2>/dev/null || true
    load_settings
    show_main_menu
}
