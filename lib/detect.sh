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
        # metrics_listen имеет приоритет над metrics_port (так же, как в telemt)
        _listen=$(_toml_get_string_in_section "server" "metrics_listen" "$_cfg")
        [ -n "$_listen" ] && _port=$(printf '%s\n' "$_listen" | sed -nE 's/.*:([0-9]+)$/\1/p')
        [ -z "$_port" ] && _port=$(_toml_get_string_in_section "server" "metrics_port" "$_cfg")
    fi
    [[ "$_port" =~ ^[0-9]+$ ]] || _port="9090"
    echo "$_port"
}

_telemt_api_enabled() {
    local _cfg="${1:-$DETECTED_CONFIG_PATH}"
    [ -n "$_cfg" ] && [ -f "$_cfg" ] || return 1
    local _en; _en=$(_toml_get_string_in_section "server.api" "enabled" "$_cfg")
    [ "$_en" = "true" ]
}

# Забирает JSON с /v1/users API цели (список пользователей + их
# трафик/соединения/ссылки).
# Коды возврата: 0 — успех, 2 — API выключен в конфиге цели,
# 3 — API включён, но не отвечает/вернул некорректный ответ.
# Валидацию держим мягкой: разные версии telemt отдают ответ либо
# компактным, либо pretty-printed, и поле "ok" может отсутствовать.
# Ориентируемся на наличие массива "data" — именно его мы и разбираем;
# отказываем только если API явно ответил "ok": false.
_get_telemt_users_json() {
    local _cfg="${1:-$DETECTED_CONFIG_PATH}"
    _telemt_api_enabled "$_cfg" || return 2
    local _port; _port=$(_get_telemt_api_port "$_cfg")
    local _json
    _json=$(curl -s --max-time 3 --connect-timeout 2 "http://127.0.0.1:${_port}/v1/users" 2>/dev/null) || return 3
    [ -z "$_json" ] && return 3
    grep -qE '"ok"[[:space:]]*:[[:space:]]*false' <<< "$_json" && return 3
    grep -q '"data"' <<< "$_json" || return 3
    echo "$_json"
}

# Человекочитаемая причина, почему API цели недоступен — для показа
# вместо тихих нулей/«н/д» без объяснения.
_telemt_api_unavailable_reason() {
    local _cfg="${1:-$DETECTED_CONFIG_PATH}"
    if [ -z "$_cfg" ] || [ ! -f "$_cfg" ]; then
        echo "конфиг цели не найден"
        return
    fi
    if ! _telemt_api_enabled "$_cfg"; then
        echo "[server.api] enabled = false в конфиге цели"
        return
    fi
    echo "API не отвечает на 127.0.0.1:$(_get_telemt_api_port "$_cfg")"
}

# Возвращает строки "пользователь|tg-ссылка" из ответа API цели, оставляя
# только IPv4-ссылки. Ссылки берём как есть: секрет в ee-ссылке содержит
# hex-домен, и сама telemt — единственный корректный источник ссылок
# (её docs прямо предупреждают не собирать ссылки вручную), поэтому
# server=/port= не подменяем — за это отвечает [general.links] в конфиге цели.
# IPv6 отбрасываем по наличию ':' в значении server= (адрес может быть и без
# скобок: server=2a13:7c00:...), заодно убираем 0.0.0.0/::.
# Пары username↔links собираем без jq: перед каждым "username" вставляем
# перевод строки, ссылки пользователя лежат в его же объекте после username.
_target_links_ipv4() {
    local _json="$1"
    printf '%s' "$_json" | tr -d '\n' \
        | awk '{gsub(/"username"/, "\n\"username\""); print}' \
        | while IFS= read -r _chunk; do
            case "$_chunk" in *'"username"'*) ;; *) continue ;; esac
            local _u _links _l _srv
            _u=$(sed -nE 's/.*"username"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' <<< "$_chunk")
            _links=$(grep -oE 'tg://proxy\?[^"]+' <<< "$_chunk" | sort -u)
            [ -z "$_links" ] && continue
            while IFS= read -r _l; do
                [ -z "$_l" ] && continue
                _srv=$(sed -nE 's/.*[?&]server=([^&]*).*/\1/p' <<< "$_l")
                case "$_srv" in
                    ""|*:*|0.0.0.0) continue ;;
                esac
                printf '%s|%s\n' "${_u:-?}" "$_l"
            done <<< "$_links"
        done
}

# Печатает ссылки цели (IPv4). Используется и в меню «Ссылки на прокси»,
# и после настройки selfmask, когда домен/маскировка поменялись.
show_target_links_ipv4() {
    local _json _rc
    _json=$(_get_telemt_users_json 2>/dev/null); _rc=$?
    if [ $_rc -ne 0 ]; then
        log_warn "Ссылки недоступны: $(_telemt_api_unavailable_reason)"
        [ $_rc -eq 2 ] && log_info "Включите [server.api] enabled = true в ${DETECTED_CONFIG_PATH:-конфиге цели} и перезапустите цель"
        return 1
    fi

    local _pairs; _pairs=$(_target_links_ipv4 "$_json")
    if [ -z "$_pairs" ]; then
        log_warn "IPv4-ссылки не найдены в ответе API цели"
        log_info "Если цель отдаёт только IPv6 — задайте [general.links] public_host в конфиге цели"
        return 1
    fi

    echo ""
    echo -e "  ${DIM}Источник: API цели (127.0.0.1:$(_get_telemt_api_port)/v1/users)${NC}"
    local _last_u="" _u _l
    while IFS='|' read -r _u _l; do
        [ -z "$_l" ] && continue
        if [ "$_u" != "$_last_u" ]; then
            echo ""
            echo -e "  ${BRIGHT_GREEN}${BOLD}${_u}${NC}"
            echo -e "  ${DIM}$(_repeat '─' 40)${NC}"
            _last_u="$_u"
        fi
        echo -e "  ${BOLD}TG:${NC}  ${CYAN}${_l}${NC}"
        echo -e "  ${BOLD}Веб:${NC} ${CYAN}https://t.me/proxy?${_l#tg://proxy?}${NC}"
    done <<< "$_pairs"
    echo ""
}

# Построчная статистика по пользователям из ответа API цели:
# "username|enabled|current_connections|active_unique_ips|total_octets".
# Разбор без jq — тем же способом, что и ссылки (чанки по "username").
_target_user_stats() {
    local _json="$1"
    printf '%s' "$_json" | tr -d '\n' \
        | awk '{gsub(/"username"/, "\n\"username\""); print}' \
        | while IFS= read -r _chunk; do
            case "$_chunk" in *'"username"'*) ;; *) continue ;; esac
            local _u _en _c _ips _oct
            _u=$(sed -nE 's/.*"username"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' <<< "$_chunk")
            _en=$(sed -nE 's/.*"enabled"[[:space:]]*:[[:space:]]*(true|false).*/\1/p' <<< "$_chunk")
            _c=$(sed -nE 's/.*"current_connections"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' <<< "$_chunk")
            _ips=$(sed -nE 's/.*"active_unique_ips"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' <<< "$_chunk")
            _oct=$(sed -nE 's/.*"total_octets"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' <<< "$_chunk")
            printf '%s|%s|%s|%s|%s\n' "${_u:-?}" "${_en:-true}" "${_c:-0}" "${_ips:-0}" "${_oct:-0}"
        done
}

# Отвечает ли Prometheus-эндпоинт цели. Метрики движка в telemt по
# умолчанию выключены (metrics_listen/metrics_port закомментированы),
# поэтому это отдельная от API проверка.
_target_metrics_available() {
    curl -s --max-time 2 "http://127.0.0.1:$(_get_telemt_metrics_port)/metrics" &>/dev/null
}

_target_metrics_hint() {
    echo ""
    log_warn "Метрики движка у цели не включены"
    echo -e "  ${DIM}Добавьте в конфиг цели (${DETECTED_CONFIG_PATH:-путь не определён})${NC}"
    echo -e "  ${DIM}и перезапустите цель:${NC}"
    echo -e "    ${BOLD}[server]${NC}"
    echo -e "    ${BOLD}metrics_listen = \"127.0.0.1:9090\"${NC}"
    echo -e "    ${BOLD}metrics_whitelist = [\"127.0.0.1/32\", \"::1/128\"]${NC}"
    echo -e "  ${DIM}Трафик и соединения берутся из API цели — они работают без метрик.${NC}"
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
    # Если версия API не отдаёт "enabled" — считаем всех найденных
    # пользователей активными, чтобы не показывать 0 при живых ссылках.
    if [ "$((TARGET_STATS_ACTIVE + TARGET_STATS_DISABLED))" -eq 0 ]; then
        TARGET_STATS_ACTIVE=$(grep -oE '"username"[[:space:]]*:' <<< "$_json" | wc -l)
    fi
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

# Юнит telemt.service существует (пусть и остановлен/не enabled).
# Проверяем LoadState, а не is-active и не grep по list-unit-files:
# остановленную службу надо уметь запустить, а вывод list-unit-files
# зависит от версии systemd и может не совпасть по префиксу.
_telemt_unit_exists() {
    [ "$(systemctl show telemt.service -p LoadState --value 2>/dev/null)" = "loaded" ] && return 0
    local _u
    for _u in /etc/systemd/system/telemt.service \
              /lib/systemd/system/telemt.service \
              /usr/lib/systemd/system/telemt.service; do
        [ -f "$_u" ] && return 0
    done
    return 1
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

    # 3. Локальный telemt: процесс, активная служба ИЛИ установленный юнит.
    # Юнит учитываем даже остановленным — иначе остановленную службу
    # определяет как config_only, и её нельзя запустить из меню.
    if pgrep -x telemt &>/dev/null || systemctl is-active telemt.service &>/dev/null 2>&1 \
       || _telemt_unit_exists; then
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
    local param="$1" value="$2" section="$3" _batch="${4:-false}"

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
    backup_target_config "tune" "true" || true

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

    # В пакетном режиме (несколько параметров подряд) перезапуск делает
    # вызывающий код — один раз в конце, а не после каждого параметра.
    [ "$_batch" = "true" ] && return 0

    if is_proxy_running; then
        echo -en "  ${BOLD}Перезапустить цель, чтобы применить изменения? [Y/n]:${NC} "
        local _r; read -r _r
        [[ ! "$_r" =~ ^[nN] ]] && restart_target
    fi
}

# ── Тюнинг таймаутов цели (визард при установке) ───────────────
# Применяем только тот набор, который MTProxyL держит в своём конфиге
# (_REANIMATOR_TUNE_SET в lib/config.sh) — одним подтверждением и одним
# перезапуском, без ручного ввода параметров.
run_reanimator_tuning_wizard() {
    if [ -z "${DETECTED_CONFIG_PATH:-}" ] || [ ! -f "$DETECTED_CONFIG_PATH" ]; then
        log_warn "Конфиг цели не найден — тюнинг таймаутов пропущен"
        return 1
    fi

    echo ""
    draw_header "ТЮНИНГ ТАЙМАУТОВ ЦЕЛИ"
    echo ""
    echo -e "  ${DIM}Значения, которые MTProxyL использует в своём конфиге.${NC}"
    echo -e "  ${DIM}У telemt по умолчанию они ниже — на нестабильных сетях${NC}"
    echo -e "  ${DIM}клиенты чаще отваливаются и дольше переподключаются.${NC}"
    echo ""

    # Заголовок таблицы не выравниваем через printf: %-Ns считает байты,
    # а не символы, поэтому кириллица разъезжается с ASCII-строками ниже.
    local _entry _p _sect _val _cur _changes=0
    echo -e "  ${DIM}параметр            секция      сейчас → станет${NC}"
    for _entry in "${_REANIMATOR_TUNE_SET[@]}"; do
        IFS=':' read -r _p _sect _val <<< "$_entry"
        _cur=$(_toml_get_string_in_section "$_sect" "$_p" "$DETECTED_CONFIG_PATH")
        if [ "$_cur" = "$_val" ]; then
            printf "  %-19s %-11s %-6s ${DIM}(уже применено)${NC}\n" "$_p" "[$_sect]" "$_cur"
        else
            printf "  %-19s %-11s %-6s → ${GREEN}%s${NC}\n" "$_p" "[$_sect]" "${_cur:-—}" "$_val"
            _changes=$((_changes + 1))
        fi
    done
    echo ""

    if [ "$_changes" -eq 0 ]; then
        log_success "Таймауты цели уже соответствуют рекомендуемым — менять нечего"
        return 0
    fi

    echo -en "  ${BOLD}Применить эти значения в конфиге цели? [Y/n]:${NC} "
    local _yn; read -r _yn
    if [[ "$_yn" =~ ^[nN]$ ]]; then
        log_info "Тюнинг пропущен. Позже: mtproxyl tune set <параметр> <значение>"
        return 0
    fi

    local _ok=true
    for _entry in "${_REANIMATOR_TUNE_SET[@]}"; do
        IFS=':' read -r _p _sect _val <<< "$_entry"
        apply_target_tuning "$_p" "$_val" "$_sect" true || _ok=false
    done

    [ "$_ok" = "true" ] && log_success "Таймауты применены" \
                        || log_warn "Не все параметры удалось применить"

    if is_proxy_running; then
        echo -en "  ${BOLD}Перезапустить цель, чтобы значения вступили в силу? [Y/n]:${NC} "
        local _r; read -r _r
        [[ ! "$_r" =~ ^[nN] ]] && restart_target
    else
        log_info "Цель не запущена — значения применятся при её запуске"
    fi
}

# ── Резервная копия конфига цели ───────────────────────────────
# Единая точка бэкапа чужого конфига. tag попадает в имя файла, чтобы
# было понятно, откуда копия (install / tune / pre-edit).
# Путь возвращается через TARGET_CONFIG_BACKUP, а не через stdout: log_*
# пишет в stdout, и при $(...) сообщение попало бы в переменную вместо пути.
TARGET_CONFIG_BACKUP=""

backup_target_config() {
    local _tag="${1:-tune}" _quiet="${2:-false}"
    TARGET_CONFIG_BACKUP=""
    [ -n "${DETECTED_CONFIG_PATH:-}" ] && [ -f "$DETECTED_CONFIG_PATH" ] || return 1

    mkdir -p "$BACKUP_DIR"
    local _dst="${BACKUP_DIR}/$(basename "$DETECTED_CONFIG_PATH").${_tag}-$(date +%Y%m%d-%H%M%S)"
    if cp "$DETECTED_CONFIG_PATH" "$_dst" 2>/dev/null; then
        TARGET_CONFIG_BACKUP="$_dst"
        [ "$_quiet" = "true" ] || log_success "Резервная копия конфига цели: ${_dst}"
        return 0
    fi
    log_warn "Не удалось создать резервную копию конфига цели"
    return 1
}

# ── Ручное редактирование конфига цели ─────────────────────────
# Открывает чужой toml в редакторе, и только если файл реально изменился —
# предлагает перезапустить цель. Перед правкой делает резервную копию.
edit_target_config() {
    if [ -z "${DETECTED_CONFIG_PATH:-}" ] || [ ! -f "$DETECTED_CONFIG_PATH" ]; then
        log_error "Конфиг цели не найден — выполните 'mtproxyl detect'"
        return 1
    fi

    local _editor="${EDITOR:-}"
    if [ -z "$_editor" ]; then
        local _e
        for _e in nano vi vim; do
            command -v "$_e" &>/dev/null && { _editor="$_e"; break; }
        done
    fi
    if [ -z "$_editor" ]; then
        log_error "Не найден редактор (nano/vi/vim) — установите nano: apt install nano"
        return 1
    fi

    backup_target_config "pre-edit" || true
    local _bak="$TARGET_CONFIG_BACKUP"

    local _sum_before _sum_after
    _sum_before=$(md5sum "$DETECTED_CONFIG_PATH" 2>/dev/null | awk '{print $1}')

    "$_editor" "$DETECTED_CONFIG_PATH"

    _sum_after=$(md5sum "$DETECTED_CONFIG_PATH" 2>/dev/null | awk '{print $1}')

    if [ "$_sum_before" = "$_sum_after" ]; then
        log_info "Изменений нет — перезапуск не требуется"
        return 0
    fi

    log_success "Конфиг изменён"

    # Не даём молча уехать в нерабочее состояние: сверяем, что файл
    # всё ещё выглядит как конфиг telemt.
    if ! _looks_like_telemt_config "$DETECTED_CONFIG_PATH"; then
        log_warn "Файл больше не похож на конфиг telemt — проверьте правки"
        echo -e "  ${DIM}Откатить: cp ${_bak} ${DETECTED_CONFIG_PATH}${NC}"
    fi

    if ! is_proxy_running; then
        log_info "Цель не запущена — запустите её, чтобы применить изменения"
        return 0
    fi

    echo -en "  ${BOLD}Перезапустить цель, чтобы применить изменения? [Y/n]:${NC} "
    local _r; read -r _r
    if [[ ! "$_r" =~ ^[nN] ]]; then
        restart_target
        sleep 1
        if is_proxy_running; then
            log_success "Цель перезапущена"
        else
            log_error "Цель не поднялась после перезапуска — проверьте правки и логи"
            echo -e "  ${DIM}Откатить: cp ${_bak} ${DETECTED_CONFIG_PATH}${NC}"
        fi
    else
        log_info "Перезапуск отложен — изменения вступят в силу после restart"
    fi
}

# ── Переключение режима работы ─────────────────────────────────
# В reanimator-режиме порт цели — источник истины: на него навешиваются
# zapret2/NFT-правила. Если PROXY_PORT остался от менеджера, фиксы уйдут
# на чужой порт, поэтому синхронизируем и предлагаем переприменить правила.
sync_port_from_target() {
    [ "${MTPROXYL_MODE:-manager}" = "reanimator" ] || return 0

    local _p="${DETECTED_PORT:-}"
    if [ -z "$_p" ] || ! validate_port "$_p"; then
        echo ""
        log_warn "Порт цели определить не удалось (текущий: ${PROXY_PORT:-не задан})"
        echo -en "  ${BOLD}Укажите порт цели [${PROXY_PORT:-443}]:${NC} "
        local _in; read -r _in
        _in="${_in:-${PROXY_PORT:-443}}"
        validate_port "$_in" || { log_error "Некорректный порт — оставляем ${PROXY_PORT:-443}"; return 1; }
        _p="$_in"
    fi

    [ "$_p" = "${PROXY_PORT:-}" ] && return 0

    local _old="${PROXY_PORT:-не задан}"
    PROXY_PORT="$_p"
    save_settings
    log_success "Порт переключён на порт цели: ${_old} → ${PROXY_PORT}"

    # Правила, уже наложенные на старый порт, надо переналожить.
    load_nft_settings 2>/dev/null || true
    local _need_reapply="false"
    [ "${ZAPRET2_APPLIED:-false}" = "true" ] && _need_reapply="true"
    [ "${NFT_ENABLED:-false}" = "true" ] && _need_reapply="true"
    nft list table ip "${ZAPRET2_NFT_TABLE:-MTProtoL}" &>/dev/null 2>&1 && _need_reapply="true"
    nft list table inet "${NFT_TABLE:-mtproxyl_limit}" &>/dev/null 2>&1 && _need_reapply="true"
    [ "$_need_reapply" = "true" ] || return 0

    echo ""
    log_warn "Правила фиксов наложены на прежний порт ${_old} — их нужно переприменить"
    echo -en "  ${BOLD}Переприменить сейчас? [Y/n]:${NC} "
    local _yn; read -r _yn
    [[ "$_yn" =~ ^[nN]$ ]] && { log_info "Переприменить позже: меню NFT/Zapret2"; return 0; }

    if [ "${ZAPRET2_APPLIED:-false}" = "true" ]; then
        zapret2_update_config || log_warn "Не удалось обновить zapret2"
    fi
    if [ "${NFT_ENABLED:-false}" = "true" ]; then
        apply_nft_rules || log_warn "Не удалось применить NFT-правила"
        install_nft_service || true
    elif nft list table inet "${NFT_TABLE:-mtproxyl_limit}" &>/dev/null 2>&1; then
        apply_nft_rules || log_warn "Не удалось применить NFT-правила"
    fi
}

# Есть ли у нас собственная установка (контейнер в любом состоянии
# либо сгенерированный конфиг)
_own_install_exists() {
    [ "$(own_container_state 2>/dev/null)" != "absent" ] && return 0
    [ -f "${CONFIG_DIR}/config.toml" ]
}

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

    # Своей установки нет — в режиме manager управлять нечем, поэтому
    # сразу предлагаем установку (иначе меню открывается «пустым»).
    if _own_install_exists; then
        log_info "Найдена собственная установка — управление доступно из меню"
        return 0
    fi

    echo ""
    log_warn "Собственный telemt не установлен — в режиме Manager управлять нечем"
    if [ -n "${DETECTED_PORT:-}" ] || [ -n "${PROXY_PORT:-}" ]; then
        local _p="${PROXY_PORT:-$DETECTED_PORT}"
        if ! is_port_available "$_p" 2>/dev/null; then
            echo ""
            log_warn "Порт ${_p} сейчас занят (вероятно, прежней целью реаниматора)"
            show_port_listener "$_p"
            echo -e "  ${DIM}В мастере выберите другой порт либо сначала остановите то,${NC}"
            echo -e "  ${DIM}что занимает порт — иначе контейнер не запустится.${NC}"
        fi
    fi
    echo ""
    echo -en "  ${BOLD}Запустить установку сейчас? [Y/n]:${NC} "
    local _yn; read -r _yn
    if [[ "$_yn" =~ ^[nN]$ ]]; then
        log_info "Установку можно запустить позже: mtproxyl install"
        return 0
    fi
    run_installer
}

switch_to_reanimator_mode() {
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        log_info "Уже в режиме reanimator"
        return 0
    fi
    echo ""
    log_warn "Переход в режим Reanimator. Свой контейнер/конфиг MTProxyL больше не будет управляться из меню."
    echo -en "  ${BOLD}Введите 'yes' для подтверждения:${NC} "
    local _c; read -r _c
    [ "$_c" != "yes" ] && { log_info "Отменено"; return 1; }

    # Свой контейнер держит порт — а он же нужен цели реаниматора.
    # Предлагаем убрать его сразу, чтобы не делать это вручную.
    local _own_state; _own_state=$(own_container_state 2>/dev/null)
    if [ "$_own_state" != "absent" ]; then
        echo ""
        echo -e "  ${BOLD}Свой контейнер ${CONTAINER_NAME}:${NC} ${_own_state}"
        echo -e "  ${DIM}Он занимает порт ${PROXY_PORT:-443} и будет мешать цели реаниматора.${NC}"
        echo ""
        echo -e "  ${DIM}[1]${NC} Остановить и удалить контейнер ${DIM}(рекомендуется)${NC}"
        echo -e "  ${DIM}[2]${NC} Только остановить, контейнер оставить"
        echo -e "  ${DIM}[3]${NC} Не трогать"
        local _oc; _oc=$(read_choice "выбор" "1")
        case "$_oc" in
            1) remove_own_container ;;
            2) docker update --restart=no "$CONTAINER_NAME" &>/dev/null || true
               docker stop --timeout 10 "$CONTAINER_NAME" &>/dev/null \
                   && log_success "Контейнер остановлен (не удалён)" \
                   || log_warn "Не удалось остановить контейнер" ;;
            *) log_info "Контейнер оставлен как есть" ;;
        esac
    fi

    MTPROXYL_MODE="reanimator"
    save_settings
    run_target_detection
    save_detect_settings
    # Порт менеджера здесь уже не актуален — переходим на порт цели,
    # иначе фиксы останутся навешенными на прежний порт.
    sync_port_from_target
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

    # Резервная копия чужого конфига ДО любых правок — и сразу сообщаем
    # пользователю, где она лежит.
    backup_target_config "install" || true

    run_fix_arsenal_wizard

    run_reanimator_tuning_wizard || true

    echo ""
    draw_header "REANIMATOR НАСТРОЕН"
    echo ""
    echo -e "  ${BOLD}Режим:${NC}       Reanimator"
    echo -e "  ${BOLD}Цель:${NC}        ${DETECTED_MODE}$([ -n "$DETECTED_CONTAINER" ] && echo " (${DETECTED_CONTAINER})")"
    echo -e "  ${BOLD}Конфиг цели:${NC} ${DETECTED_CONFIG_PATH:-нет}"
    echo -e "  ${BOLD}Порт:${NC}        ${PROXY_PORT}"
    echo -e "  ${BOLD}Домен(SNI):${NC}  $(_current_sni_domain 2>/dev/null || echo '?')"
    echo ""
    echo -e "  ${DIM}Тюнинг параметров: mtproxyl tune set <параметр> <значение>${NC}"
    echo -e "  ${DIM}Повторный детект:  mtproxyl detect${NC}"
    echo -e "  ${DIM}Правка конфига:    mtproxyl edit-config${NC}"
    echo ""

    ln -sf "${INSTALL_DIR}/mtproxyl.sh" /usr/local/bin/mtproxyl

    echo -en "  ${DIM}Нажмите клавишу для входа в меню...${NC}"
    read -rsn1
    read -rn 256 -t 0.05 _ 2>/dev/null || true
    load_settings
    show_main_menu
}
