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
    # Через временный файл: панель читает состояние цели ('mode --json')
    # параллельно с пересканированием.
    local _tmp
    _tmp=$(_mktemp "$INSTALL_DIR") || { log_error "Не удалось создать временный файл"; return 1; }
    cat > "$_tmp" << EOF
# MTProxyL Reanimator — обнаруженная цель
DETECTED_MODE='${DETECTED_MODE}'
DETECTED_CONTAINER='${DETECTED_CONTAINER}'
DETECTED_CONFIG_PATH='${DETECTED_CONFIG_PATH}'
DETECTED_IP='${DETECTED_IP}'
DETECTED_PORT='${DETECTED_PORT}'
DETECTED_NETWORK_MODE='${DETECTED_NETWORK_MODE}'
DETECT_BRIDGE_STRATEGY='${DETECT_BRIDGE_STRATEGY}'
EOF
    chmod 600 "$_tmp"
    mv "$_tmp" "$DETECT_CONF"
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

# Правка ключа строго внутри своей секции: port/enabled и прочие имена
# встречаются в разных таблицах. cat > сохраняет владельца и права.
_toml_safe_set() {
    local _key="$1" _value="$2" _section="$3" _file="$4"
    [ -f "$_file" ] || return 1

    local _tmp; _tmp=$(_mktemp) || return 1
    local _rc=0
    awk -v sect="[${_section}]" -v k="$_key" -v v="$_value" '
        function flush_blanks(   i) { for (i = 1; i <= nb; i++) print blanks[i]; nb = 0 }
        BEGIN { insect=0; done=0; sect_seen=0; nb=0 }
        {
            line = $0
            t = line; sub(/^[[:space:]]+/, "", t)
            # Пустые строки в конце секции придерживаем: новый ключ должен
            # встать в саму секцию, а не за её пустой строкой.
            if (insect && t == "") { blanks[++nb] = line; next }
            if (t ~ /^\[/) {
                if (insect && !done) { print k " = " v; done=1 }
                flush_blanks()
                insect = (t == sect) ? 1 : 0
                if (insect) sect_seen=1
                print line
                next
            }
            flush_blanks()
            if (insect && !done && t ~ ("^" k "[[:space:]]*=")) {
                print k " = " v
                done = 1
                next
            }
            print line
        }
        END {
            if (insect && !done) { print k " = " v; done=1 }
            flush_blanks()
            exit (sect_seen && done) ? 0 : 1
        }
    ' "$_file" > "$_tmp" || _rc=1

    if [ "$_rc" -ne 0 ] || [ ! -s "$_tmp" ]; then
        rm -f "$_tmp"
        return 1
    fi
    cat "$_tmp" > "$_file" || { rm -f "$_tmp"; return 1; }
    rm -f "$_tmp"
    return 0
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
                # telemt пишет значения в одинарных кавычках — снимаем оба вида.
                gsub(/["'"'"']/, "", line)
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

# [server.api] enabled по умолчанию true, а MTProxyL секцию не пишет вовсе:
# выключенным считаем только явное false.
_telemt_api_enabled() {
    local _cfg="${1:-$DETECTED_CONFIG_PATH}"
    [ -n "$_cfg" ] && [ -f "$_cfg" ] || return 1
    local _en; _en=$(_toml_get_string_in_section "server.api" "enabled" "$_cfg")
    [ "$_en" != "false" ]
}

# [server.api] auth_header цели: ожидаемый движком Authorization заголовок
# («Bearer TOKEN» или пусто). Пусто — авторизация на API выключена.
_get_telemt_auth_header() {
    local _cfg="${1:-$DETECTED_CONFIG_PATH}"
    [ -n "$_cfg" ] && [ -f "$_cfg" ] || return 0
    _toml_get_string_in_section "server.api" "auth_header" "$_cfg"
}

# Адрес, по которому API цели виден с хоста. У контейнера в bridge-сети своя
# петля: 127.0.0.1 внутри него — это он сам, а не мы, и достучаться туда с
# хоста нельзя ни при каких портах. Зато его адрес в сети docker доступен —
# если движок слушает не только петлю. Публикация порта (-p) тоже подходит и
# ловится обычной проверкой 127.0.0.1, поэтому её пробуем первой.
# Адрес в сети docker берём не первый попавшийся, а тот, который ответил:
# из нескольких сетей контейнера с хоста доступна не каждая.
_telemt_api_host() {
    [ "${DETECTED_NETWORK_MODE:-host}" = "bridge" ] || { echo "127.0.0.1"; return 0; }
    local _cfg="${1:-$DETECTED_CONFIG_PATH}"
    local _port; _port=$(_get_telemt_api_port "$_cfg")
    local _auth; _auth=$(_get_telemt_auth_header "$_cfg")
    local -a _auth_h=()
    [ -n "$_auth" ] && _auth_h=(-H "Authorization: ${_auth}")
    # Ответ 401 тоже считается «достучались»: проба про доступность хоста,
    # а не про права. Заголовок всё же шлём — не порождаем лишних отказов.
    if curl -s -o /dev/null --max-time 1 --connect-timeout 1 "${_auth_h[@]}" \
        "http://127.0.0.1:${_port}/v1/health" 2>/dev/null; then
        echo "127.0.0.1"
        return 0
    fi
    local _ip
    while IFS= read -r _ip; do
        [ -n "$_ip" ] || continue
        if curl -s -o /dev/null --max-time 1 --connect-timeout 1 "${_auth_h[@]}" \
            "http://${_ip}:${_port}/v1/health" 2>/dev/null; then
            echo "$_ip"
            return 0
        fi
    done < <(_target_container_ips 2>/dev/null)
    echo "127.0.0.1"
}

# HTTP-код, которым цель отвечает на /v1/users. 000 — не ответила вовсе.
# Спрашиваем отдельно, а не запоминаем в переменной при обычном запросе:
# _get_telemt_users_json зовут из $( ), а это субшелл — присвоенное там
# до вызывающего не доходит.
_telemt_api_probe_code() {
    local _cfg="${1:-$DETECTED_CONFIG_PATH}"
    local _port _host _auth
    _port=$(_get_telemt_api_port "$_cfg")
    _host=$(_telemt_api_host "$_cfg")
    _auth=$(_get_telemt_auth_header "$_cfg")
    local -a _auth_h=()
    [ -n "$_auth" ] && _auth_h=(-H "Authorization: ${_auth}")
    curl -s -o /dev/null -w '%{http_code}' --max-time 3 --connect-timeout 2 \
        "${_auth_h[@]}" "http://${_host}:${_port}/v1/users" 2>/dev/null || echo "000"
}

# JSON с /v1/users API цели.
# Коды: 0 — успех, 2 — API выключен в конфиге, 3 — включён, но не отвечает,
# 4 — отвечает, но отклонил авторизацию ([server.api] auth_header).
_get_telemt_users_json() {
    local _cfg="${1:-$DETECTED_CONFIG_PATH}"
    _telemt_api_enabled "$_cfg" || return 2
    local _port; _port=$(_get_telemt_api_port "$_cfg")
    local _host; _host=$(_telemt_api_host "$_cfg")
    local _auth; _auth=$(_get_telemt_auth_header "$_cfg")
    local -a _auth_h=()
    [ -n "$_auth" ] && _auth_h=(-H "Authorization: ${_auth}")
    # Код ответа дописываем последней строкой через -w и отделяем его тут же:
    # тело дальше парсится построчно, лишний хвост ему не нужен.
    local _resp _code _json
    _resp=$(curl -s --max-time 3 --connect-timeout 2 "${_auth_h[@]}" \
                -w $'\n%{http_code}' "http://${_host}:${_port}/v1/users" 2>/dev/null) || return 3
    [ -z "$_resp" ] && return 3
    _code="${_resp##*$'\n'}"
    case "$_code" in
        200) ;;
        401|403) return 4 ;;
        *)       return 3 ;;
    esac
    _json="${_resp%$'\n'*}"
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
    local _code; _code=$(_telemt_api_probe_code "$_cfg")
    case "$_code" in
        401|403)
            echo "цель требует авторизацию (${_code}) — сверьте [server.api] auth_header в конфиге цели"
            return ;;
    esac
    local _port; _port=$(_get_telemt_api_port "$_cfg")
    if [ "${DETECTED_NETWORK_MODE:-host}" = "bridge" ]; then
        local _listen; _listen=$(_toml_get_string_in_section "server.api" "listen" "$_cfg")
        case "${_listen}" in
            127.*|localhost*|"[::1]"*)
                echo "цель в Docker bridge, а API слушает петлю контейнера ${_listen} — снаружи она недоступна"
                return ;;
        esac
        # Без _telemt_api_host: его пробы уже провалились выше, повторять их
        # ради текста ошибки — ещё секунды ожидания на пустом месте.
        local _ips; _ips=$(_target_container_ips 2>/dev/null | paste -sd ',' - | sed 's/,/, /g')
        if [ -n "$_ips" ]; then
            echo "API не отвечает на порту ${_port} ни на петле, ни по адресам контейнера: ${_ips} (цель в Docker bridge)"
        else
            echo "API не отвечает на 127.0.0.1:${_port} (цель в Docker bridge, адрес контейнера не определён)"
        fi
        return
    fi
    echo "API не отвечает на 127.0.0.1:${_port}"
}

# Что делать, когда API цели в контейнере недоступен. Печатается там же, где
# показана причина: без этого совет «включите API» не помогает — он уже включён.
_telemt_api_bridge_hint() {
    [ "${DETECTED_NETWORK_MODE:-host}" = "bridge" ] || return 0
    local _cfg="${1:-$DETECTED_CONFIG_PATH}"
    local _port; _port=$(_get_telemt_api_port "$_cfg")
    local _cips; _cips=$(_target_container_ips 2>/dev/null | paste -sd ',' - | sed 's/,/, /g')
    echo ""
    echo -e "  ${BOLD}Цель работает в Docker bridge.${NC}"
    echo -e "  ${DIM}127.0.0.1 внутри контейнера — сам контейнер, а не хост,${NC}"
    echo -e "  ${DIM}поэтому API, привязанный к петле, с хоста не виден.${NC}"
    echo ""
    echo -e "  ${DIM}В конфиге цели:${NC}"
    echo -e "    ${GREEN}[server.api]${NC}"
    echo -e "    ${GREEN}enabled = true${NC}"
    echo -e "    ${GREEN}listen = \"0.0.0.0:${_port}\"${NC}"
    echo -e "    ${GREEN}whitelist = [\"127.0.0.0/8\", \"172.16.0.0/12\", \"10.0.0.0/8\"]${NC}"
    echo -e "  ${DIM}Белый список важен: с хостом контейнер общается через адрес${NC}"
    echo -e "  ${DIM}сети docker, и со списком по умолчанию (только 127.0.0.0/8)${NC}"
    echo -e "  ${DIM}движок отклонит наши запросы уже после подключения.${NC}"
    echo ""
    if [ -n "$_cips" ]; then
        echo -e "  ${DIM}После перезапуска цели MTProxyL сам пойдёт на тот из адресов${NC}"
        echo -e "  ${DIM}контейнера (${_cips}), который ответит на порту ${_port}.${NC}"
    fi
    echo -e "  ${DIM}Наружу это не открывает: порт контейнера доступен только${NC}"
    echo -e "  ${DIM}хосту, пока он не опубликован через -p.${NC}"
    echo -e "  ${DIM}Другой путь — опубликовать порт: -p 127.0.0.1:${_port}:${_port}${NC}"
}

# Строки «пользователь|tg-ссылка» из ответа API цели, только IPv4.
# Ссылки отдаёт telemt — вручную их собирать нельзя, поэтому берём как есть.
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
        _telemt_api_bridge_hint
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
    # Один awk на весь ответ вместо пяти sed на каждого пользователя.
    printf '%s' "$_json" | tr -d '\n' | awk '
        # Первая строка в кавычках после начала записи — само имя.
        function first_string(s,   p, q) {
            p = index(s, "\"")
            if (!p) return ""
            s = substr(s, p + 1)
            q = index(s, "\"")
            return q ? substr(s, 1, q - 1) : ""
        }
        # Значение ключа как есть, от двоеточия до запятой/скобки.
        function raw_after(s, k,   p) {
            p = index(s, "\"" k "\"")
            if (!p) return ""
            s = substr(s, p + length(k) + 2)
            p = index(s, ":")
            if (!p) return ""
            s = substr(s, p + 1)
            sub(/^[ \t]+/, "", s)
            return s
        }
        function num(s, k,   v) {
            v = raw_after(s, k)
            if (match(v, /^[0-9]+/)) return substr(v, RSTART, RLENGTH)
            return ""
        }
        function bool(s, k,   v) {
            v = raw_after(s, k)
            if (substr(v, 1, 4) == "true")  return "true"
            if (substr(v, 1, 5) == "false") return "false"
            return ""
        }
        BEGIN { RS = "\"username\"" }
        NR == 1 { next }
        {
            u = first_string($0)
            if (u == "") u = "?"
            en = bool($0, "enabled");            if (en == "")  en = "true"
            c  = num($0, "current_connections"); if (c == "")   c = 0
            ip = num($0, "active_unique_ips");   if (ip == "")  ip = 0
            oc = num($0, "total_octets");        if (oc == "")  oc = 0
            printf "%s|%s|%s|%s|%s\n", u, en, c, ip, oc
        }
    '
}

# IP-адреса пользователей из того же ответа API: "user|ip" построчно, без
# разделения на active/recent — история копит оба списка одинаково, а живой
# статус конкретного IP экран решает сам по данным API.
_target_user_ip_lists() {
    local _json="$1"
    # Как и в _target_user_stats — один процесс на весь ответ. Здесь прежний
    # вариант был ещё дороже: на каждого пользователя два sed плюс конвейер
    # grep|tr|while на каждый список адресов.
    printf '%s' "$_json" | tr -d '\n' | awk '
        function first_string(s,   p, q) {
            p = index(s, "\"")
            if (!p) return ""
            s = substr(s, p + 1)
            q = index(s, "\"")
            return q ? substr(s, 1, q - 1) : ""
        }
        # Содержимое массива ключа: от "[" до первой "]".
        function array_body(s, k,   p, q) {
            p = index(s, "\"" k "\"")
            if (!p) return ""
            s = substr(s, p + length(k) + 2)
            p = index(s, "[")
            if (!p) return ""
            s = substr(s, p + 1)
            q = index(s, "]")
            return q ? substr(s, 1, q - 1) : ""
        }
        # Адреса из тела массива: всё, что в кавычках и похоже на IP.
        function emit_ips(u, body,   n, i, parts, ip) {
            n = split(body, parts, "\"")
            # Нечётные элементы — то, что между кавычками.
            for (i = 2; i <= n; i += 2) {
                ip = parts[i]
                if (ip ~ /^[0-9a-fA-F:.]+$/ && ip != "") printf "%s|%s\n", u, ip
            }
        }
        BEGIN { RS = "\"username\"" }
        NR == 1 { next }
        {
            u = first_string($0)
            if (u == "") next
            emit_ips(u, array_body($0, "active_unique_ips_list"))
            emit_ips(u, array_body($0, "recent_unique_ips_list"))
        }
    '
}

# Конфиг движка текущего режима: у реаниматора это конфиг чужой цели, у
# менеджера — свой. Тот же выбор, что 'mtproxyl mode --json' делает inline
# для панели, но как функция — для мест, где нужен просто путь, а не JSON.
_engine_config_path() {
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        printf '%s' "${DETECTED_CONFIG_PATH:-}"
    else
        printf '%s' "$(engine_config_path)"
    fi
}

# Строки "пользователь|enabled|соединения|уник. IP|октеты" из API движка
# текущего режима. Уникальные IP есть только у API: Prometheus их не считает,
# поэтому в режиме менеджера без этого вызова колонка всегда была нулевой.
_engine_user_stats() {
    local _json
    _json=$(_get_telemt_users_json "$(_engine_config_path)" 2>/dev/null) || return 1
    _target_user_stats "$_json"
}

# Сумма активных уникальных IP по движку текущего режима.
# Ненулевой код возврата = API недоступен, показывать «н/д», а не ноль.
_engine_unique_ips() {
    local _json
    _json=$(_get_telemt_users_json "$(_engine_config_path)" 2>/dev/null) || return 1
    _json_sum_field "$_json" "active_unique_ips"
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
    echo -e "  ${DIM}Нужно добавить в конфиг цели (${DETECTED_CONFIG_PATH:-путь не определён})${NC}"
    echo -e "  ${DIM}и перезапустить цель:${NC}"
    echo -e "    ${BOLD}[server]${NC}"
    echo -e "    ${BOLD}metrics_listen = \"127.0.0.1:<порт>\"${NC}"
    echo -e "    ${BOLD}metrics_whitelist = [\"127.0.0.1/32\", \"::1/128\"]${NC}"
    echo -e "  ${DIM}Трафик и соединения берутся из API цели — они работают без метрик.${NC}"
    offer_enable_target_metrics
}

# Включить метрики в конфиге цели вместо голой инструкции. Порт выбираем
# свободный: 9090 часто занят (сам MTProxyL в режиме менеджера, node_exporter,
# чужая панель), и цель бы просто не поднялась.
offer_enable_target_metrics() {
    [ "${MTPROXYL_MODE:-manager}" = "reanimator" ] || return 0
    if [ -z "${DETECTED_CONFIG_PATH:-}" ] || [ ! -f "${DETECTED_CONFIG_PATH}" ]; then
        return 0
    fi
    if [ "${DETECTED_MODE:-}" = "mtproxymax" ]; then
        return 0
    fi

    local _port="9090"
    if ! is_port_available "$_port"; then
        local _free; _free=$(find_free_metrics_port 9090 9199 2>/dev/null)
        if [ -z "$_free" ]; then
            echo ""
            log_warn "Свободный порт для метрик в диапазоне 9090..9199 не найден"
            return 1
        fi
        _port="$_free"
        echo ""
        log_info "Порт 9090 занят — метрики повесим на ${_port}"
        show_port_listener 9090
    fi

    echo ""
    echo -en "  ${BOLD}Включить метрики в конфиге цели на 127.0.0.1:${_port}? [y/N]:${NC} "
    local _yn; read_line _yn
    [[ "$_yn" =~ ^[yY] ]] || { log_info "Пропущено"; return 0; }

    backup_target_config "metrics" "true" || true

    local _ok=true
    apply_target_tuning "metrics_listen" "127.0.0.1:${_port}" "server" true || _ok=false
    apply_target_tuning "metrics_whitelist" '["127.0.0.1/32", "::1/128"]' "server" true || _ok=false

    if [ "$_ok" != "true" ]; then
        log_warn "Не удалось применить настройки метрик — добавьте их вручную"
        return 1
    fi
    log_success "Метрики включены: 127.0.0.1:${_port}"

    if is_proxy_running; then
        echo -en "  ${BOLD}Перезапустить цель, чтобы метрики поднялись? [Y/n]:${NC} "
        local _r; read_line _r
        if [[ ! "$_r" =~ ^[nN] ]]; then
            restart_target
            if _wait_target_metrics 12; then
                log_success "Метрики цели отвечают на 127.0.0.1:${_port}"
            elif ! is_proxy_running; then
                log_error "Цель не поднялась после перезапуска — проверьте конфиг"
                echo -e "  ${DIM}journalctl -u telemt -n 20 --no-pager${NC}"
            else
                log_warn "Метрики пока не отвечают — проверьте: journalctl -u telemt -n 20"
            fi
        else
            log_info "Метрики появятся после перезапуска цели"
        fi
    else
        log_info "Цель не запущена — метрики поднимутся при её запуске"
    fi
}

# Метрики — отдельный слушатель, он поднимается позже API, поэтому ждём
# именно его, а не «цель вообще ожила».
_wait_target_metrics() {
    local _timeout="${1:-10}" _i=0
    while [ "$_i" -lt "$_timeout" ]; do
        if _target_metrics_available; then
            [ "$_i" -gt 0 ] && echo ""
            return 0
        fi
        [ "$_i" -eq 0 ] && echo -en "  ${DIM}Ждём, пока цель поднимет метрики${NC}"
        echo -en "${DIM}.${NC}"
        sleep 1
        _i=$((_i + 1))
    done
    echo ""
    return 1
}

# [general.links] telemt заполняет уже после старта API — ждём ссылок.
_wait_target_links() {
    local _timeout="${1:-15}" _i=0 _json
    _telemt_api_enabled || return 1
    while [ "$_i" -lt "$_timeout" ]; do
        _json=$(_get_telemt_users_json 2>/dev/null) \
            && [ -n "$(_target_links_ipv4 "$_json")" ] && {
                [ "$_i" -gt 0 ] && echo ""
                return 0
            }
        [ "$_i" -eq 0 ] && echo -en "  ${DIM}Ждём, пока цель отдаст ссылки${NC}"
        echo -en "${DIM}.${NC}"
        sleep 1
        _i=$((_i + 1))
    done
    echo ""
    return 1
}

# После рестарта цель поднимает API не мгновенно: запрос ссылок или
# статистики сразу после restart упирался в «API не отвечает». Ждём, пока
# API ответит, но не дольше _timeout секунд.
_wait_target_api() {
    local _timeout="${1:-8}" _i=0
    _telemt_api_enabled || return 1
    while [ "$_i" -lt "$_timeout" ]; do
        if _get_telemt_users_json >/dev/null 2>&1; then
            [ "$_i" -gt 0 ] && echo ""
            return 0
        fi
        [ "$_i" -eq 0 ] && echo -en "  ${DIM}Ждём, пока цель поднимет API${NC}"
        echo -en "${DIM}.${NC}"
        sleep 1
        _i=$((_i + 1))
    done
    echo ""
    return 1
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

# Агрегированная статистика цели через её API, заполняет TARGET_STATS_*.
# 1 — API выключен или недоступен: вызывающий показывает «н/д», а не ноль.
TARGET_STATS_OCTETS=0
TARGET_STATS_CONNS=0
TARGET_STATS_ACTIVE=0
TARGET_STATS_DISABLED=0
TARGET_STATS_IPS=0

fetch_target_stats() {
    TARGET_STATS_OCTETS=0
    TARGET_STATS_CONNS=0
    TARGET_STATS_ACTIVE=0
    TARGET_STATS_DISABLED=0
    TARGET_STATS_IPS=0
    local _json
    _json=$(_get_telemt_users_json) || return 1
    TARGET_STATS_OCTETS=$(_json_sum_field "$_json" "total_octets")
    TARGET_STATS_CONNS=$(_json_sum_field "$_json" "current_connections")
    TARGET_STATS_IPS=$(_json_sum_field "$_json" "active_unique_ips")
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
    elif _superexpert_active 2>/dev/null; then
        # Конфиг ведёт пользователь — домен берём из его файла, а не из
        # настроек менеджера, которые на движок больше не влияют.
        local _sd; _sd=$(_toml_get_string_in_section "censorship" "tls_domain" "$SUPEREXPERT_FILE" 2>/dev/null)
        if [ -n "$_sd" ]; then
            echo "$_sd"
            return 0
        fi
    fi
    echo "${PROXY_DOMAIN:-}"
}

# Юнит telemt.service существует, пусть и остановлен. Смотрим LoadState.
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

# Процесс принадлежит контейнеру (docker/podman/lxc/k8s)
_pid_in_container() {
    local _cg="/proc/${1}/cgroup"
    [ -r "$_cg" ] || return 1
    grep -qE '(docker|containerd|libpod|kubepods|/lxc)' "$_cg" 2>/dev/null
}

# PID'ы telemt именно на хосте: процессы контейнеров видны в хостовом
# namespace под тем же именем.
_telemt_host_pids() {
    local _pid _rc=1
    for _pid in $(pgrep -x telemt 2>/dev/null); do
        _pid_in_container "$_pid" && continue
        echo "$_pid"
        _rc=0
    done
    return $_rc
}

# ── Исключение чужих панелей / собственного контейнера ────────
_is_excluded_path() {
    local _path="$1"
    case "$_path" in
        *telemt-panel*|*telemt_panel*|*mtproxyl-panel*) return 0 ;;
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
            # Перебираем все точки монтирования, а не заранее известный список
            # путей внутри контейнера: конфиг могли подключить куда угодно.
            local _source _candidate
            while IFS= read -r _source; do
                [ -n "$_source" ] || continue
                if [ -d "$_source" ]; then
                    for _candidate in "${_source}/config.toml" "${_source}/telemt.toml"; do
                        if [ -f "$_candidate" ] && ! _is_excluded_path "$_candidate" && _looks_like_telemt_config "$_candidate"; then
                            DETECTED_CONFIG_PATH="$_candidate"
                            break 2
                        fi
                    done
                elif [ -f "$_source" ] && ! _is_excluded_path "$_source" && _looks_like_telemt_config "$_source"; then
                    DETECTED_CONFIG_PATH="$_source"
                    break
                fi
            done < <(docker inspect -f '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$_cname" 2>/dev/null)
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
    if _telemt_host_pids >/dev/null || systemctl is-active telemt.service &>/dev/null 2>&1 \
       || _telemt_unit_exists; then
        DETECTED_MODE="local"
        DETECTED_NETWORK_MODE="host"
        local _args _pid _cmd
        _args=""
        for _pid in $(_telemt_host_pids); do
            _cmd=$(tr '\0' ' ' < "/proc/${_pid}/cmdline" 2>/dev/null)
            case "$_cmd" in *telemt-panel*|*telemt_panel*|*mtproxyl-panel*) continue ;; esac
            _args=$(grep -oE '/[^ ]+\.toml' <<< "$_cmd" | head -1)
            [ -n "$_args" ] && break
        done
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

# Сетей у контейнера бывает несколько, и не каждая доступна с хоста: overlay
# и macvlan (dokploy-network и подобные), пересечение подсети с LAN. Отдаём
# все адреса, выбор оставляем вызывающему. IPv6-only сети отсеиваются сами:
# поле IPAddress у них пустое.
_target_container_ips() {
    local _container="${1:-$DETECTED_CONTAINER}"
    [ -z "$_container" ] && return 1
    # Пустой IPAddress свежий docker печатает в шаблоне как «invalid IP»:
    # у сети host и у неназначенных endpoint'ов. Отсеиваем по форме адреса,
    # иначе эта строка уходила бы в curl и в правила nft.
    docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\n"}}{{end}}' \
        "$_container" 2>/dev/null | awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}$/'
}

# Первый адрес — для мест, где перебирать нечем и не по чему проверять.
docker_container_ip() {
    _target_container_ips "${1:-$DETECTED_CONTAINER}" | sed -n '1p'
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
        *)
            case "$value" in
                # Массив TOML и уже закавыченную строку оборачивать нельзя —
                # получится ""["a", "b"]"" и конфиг перестанет читаться.
                \[*\]|\"*\") _tv_out="$value" ;;
                *) [[ "$value" =~ ^(true|false|[0-9]+(\.[0-9]+)?)$ ]] || _tv_out="\"$value\"" ;;
            esac ;;
    esac

    if _toml_safe_set "$param" "$_tv_out" "$section" "$_cfg"; then
        log_success "${param} = ${value} (${_cfg})"
    else
        log_warn "Секция [${section}] отсутствует в ${_cfg}"
        echo -en "  ${BOLD}Создать секцию и применить? [Y/n]:${NC} "
        local _cr; read_line _cr
        if [[ ! "$_cr" =~ ^[nN] ]]; then
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
        local _r; read_line _r
        [[ ! "$_r" =~ ^[nN] ]] && restart_target
    fi
}

# ── Тюнинг таймаутов цели (визард при установке) ───────────────
# Только набор _REANIMATOR_TUNE_SET, одним подтверждением и рестартом.
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
    local _yn; read_line _yn
    if [[ "$_yn" =~ ^[nN] ]]; then
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
        local _r; read_line _r
        [[ ! "$_r" =~ ^[nN] ]] && restart_target
    else
        log_info "Цель не запущена — значения применятся при её запуске"
    fi
}

# ── Резервная копия конфига цели ───────────────────────────────
# Путь возвращается через TARGET_CONFIG_BACKUP: log_* пишет в stdout.
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
    local _r; read_line _r
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

# ── Конфиг цели для панели ─────────────────────────────────────
# Панель непривилегированная и конфиг цели ей недоступен: читаем и пишем
# от root через CLI, содержимое — по stdin.
show_target_config() {
    if [ -z "${DETECTED_CONFIG_PATH:-}" ] || [ ! -f "$DETECTED_CONFIG_PATH" ]; then
        log_error "Конфиг цели не найден — выполните 'mtproxyl detect'"
        return 1
    fi
    cat "$DETECTED_CONFIG_PATH"
}

write_target_config() {
    local _restart="${1:-false}"

    if [ -z "${DETECTED_CONFIG_PATH:-}" ] || [ ! -f "$DETECTED_CONFIG_PATH" ]; then
        log_error "Конфиг цели не найден — выполните 'mtproxyl detect'"
        return 1
    fi

    local _new; _new=$(cat)
    if [ -z "${_new//[[:space:]]/}" ]; then
        log_error "Пустой конфиг — запись отменена"
        return 1
    fi

    local _tmp; _tmp=$(_mktemp "$(dirname "$DETECTED_CONFIG_PATH")") || {
        log_error "Не удалось создать временный файл рядом с конфигом цели"
        return 1
    }
    printf '%s' "$_new" > "$_tmp"
    # Перенос строки в конце: движок читает файл построчно, а редактор в
    # браузере последнюю пустую строку не сохраняет.
    [ "${_new: -1}" = $'\n' ] || printf '\n' >> "$_tmp"

    if ! _looks_like_telemt_config "$_tmp"; then
        log_error "Текст не похож на конфиг telemt — запись отменена"
        rm -f "$_tmp"
        return 1
    fi

    backup_target_config "panel" "true" || true

    # Владельца и права держим от исходного файла: движок читает конфиг под
    # своим пользователем, и запись от root сменила бы их на root:root.
    chown --reference="$DETECTED_CONFIG_PATH" "$_tmp" 2>/dev/null || true
    chmod --reference="$DETECTED_CONFIG_PATH" "$_tmp" 2>/dev/null || true

    if ! mv -f "$_tmp" "$DETECTED_CONFIG_PATH"; then
        log_error "Не удалось записать конфиг цели"
        rm -f "$_tmp"
        return 1
    fi
    log_success "Конфиг цели записан: ${DETECTED_CONFIG_PATH}"
    [ -n "${TARGET_CONFIG_BACKUP:-}" ] && log_info "Резервная копия: ${TARGET_CONFIG_BACKUP}"

    if [ "$_restart" = "true" ]; then
        restart_target
        sleep 1
        if is_proxy_running; then
            log_success "Цель перезапущена"
        else
            log_error "Цель не поднялась после перезапуска — проверьте правки и логи"
            return 1
        fi
    fi
    return 0
}

handle_target_config_command() {
    case "${1:-}" in
        show)  show_target_config ;;
        write)
            case "${2:-}" in
                --restart) write_target_config "true" ;;
                "")        write_target_config "false" ;;
                *)         log_error "Использование: mtproxyl target-config write [--restart]"; return 1 ;;
            esac
            ;;
        *)
            log_error "Использование: mtproxyl target-config show|write [--restart]"
            return 1
            ;;
    esac
}

# ── Переключение режима работы ─────────────────────────────────
# В reanimator порт цели — источник истины: на него вешаются zapret2/NFT.
sync_port_from_target() {
    [ "${MTPROXYL_MODE:-manager}" = "reanimator" ] || return 0

    local _p="${DETECTED_PORT:-}"
    if [ -z "$_p" ] || ! validate_port "$_p"; then
        echo ""
        log_warn "Порт цели определить не удалось (текущий: ${PROXY_PORT:-не задан})"
        echo -en "  ${BOLD}Укажите порт цели [${PROXY_PORT:-443}]:${NC} "
        local _in; read_line _in
        _in="${_in:-${PROXY_PORT:-443}}"
        validate_port "$_in" || { log_error "Некорректный порт — оставляем ${PROXY_PORT:-443}"; return 1; }
        _p="$_in"
    fi

    [ "$_p" = "${PROXY_PORT:-}" ] && return 0

    local _old="${PROXY_PORT:-не задан}"
    PROXY_PORT="$_p"
    save_settings
    log_success "Порт переключён на порт цели: ${_old} → ${PROXY_PORT}"

    offer_reapply_fixes "$_old"
}

# Правила zapret2/NFT привязаны к порту. После смены порта их надо
# переналожить, иначе фиксы остаются висеть на прежнем порту.
offer_reapply_fixes() {
    local _old="${1:-прежний порт}"
    load_nft_settings 2>/dev/null || true

    local _need="false"
    [ "${ZAPRET2_APPLIED:-false}" = "true" ] && _need="true"
    [ "${NFT_ENABLED:-false}" = "true" ] && _need="true"
    nft list table ip "${ZAPRET2_NFT_TABLE:-MTProtoL}" &>/dev/null 2>&1 && _need="true"
    nft list table inet "${NFT_TABLE:-mtproxyl_limit}" &>/dev/null 2>&1 && _need="true"
    # Гео-блокировка тоже прибита к порту
    [ -n "${BLOCKLIST_COUNTRIES:-}" ] && _need="true"
    [ "$_need" = "true" ] || return 0

    echo ""
    log_warn "Правила фиксов наложены на порт ${_old} — их нужно переприменить"
    echo -en "  ${BOLD}Переприменить сейчас? [Y/n]:${NC} "
    local _yn; read_line _yn
    [[ "$_yn" =~ ^[nN] ]] && { log_info "Переприменить позже: меню NFT/Zapret2"; return 0; }

    if [ "${ZAPRET2_APPLIED:-false}" = "true" ]; then
        zapret2_update_config || log_warn "Не удалось обновить zapret2"
    fi
    if [ "${NFT_ENABLED:-false}" = "true" ]; then
        apply_nft_rules || log_warn "Не удалось применить NFT-правила"
        install_nft_service || true
    elif nft list table inet "${NFT_TABLE:-mtproxyl_limit}" &>/dev/null 2>&1; then
        apply_nft_rules || log_warn "Не удалось применить NFT-правила"
    fi
    if [ -n "${BLOCKLIST_COUNTRIES:-}" ]; then
        geoblock_remove_all >/dev/null 2>&1 || true
        geoblock_reapply_all >/dev/null 2>&1 || true
        geoblock_rules_active && log_success "Гео-блокировка переприменена на порт ${PROXY_PORT}" \
            || log_warn "Гео-блокировку переприменить не удалось: mtproxyl geoblock reapply"
    fi
}

# Есть ли у нас собственная установка (контейнер в любом состоянии
# либо сгенерированный конфиг)
_own_install_exists() {
    [ "$(own_container_state 2>/dev/null)" != "absent" ] && return 0
    [ -f "$(engine_config_path)" ]
}

switch_to_manager_mode() {
    if [ "${MTPROXYL_MODE:-manager}" = "manager" ]; then
        log_info "Уже в режиме manager"
        return 0
    fi
    echo ""
    log_warn "Переход в режим Manager. MTProxyL начнёт устанавливать/владеть СВОИМ telemt."
    echo -en "  ${BOLD}Введите 'yes' для подтверждения:${NC} "
    local _c; read_line _c
    [ "$_c" != "yes" ] && { log_info "Отменено"; return 1; }
    local _port_before="${PROXY_PORT:-}"
    local _port_changed="false"
    switch_port_profile "manager" && _port_changed="true"
    switch_selfmask_profile "manager"
    save_settings
    log_success "Режим: manager"
    if [ "$_port_changed" = "true" ]; then
        log_success "Порт режима manager восстановлен: ${_port_before} → ${PROXY_PORT}"
        offer_reapply_fixes "$_port_before"
    fi

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
    local _yn; read_line _yn
    if [[ "$_yn" =~ ^[nN] ]]; then
        log_info "Установку можно запустить позже: mtproxyl install"
        return 0
    fi
    run_installer
}

# Что сделать со своим контейнером при уходе в реаниматор.
# Аргументом, а не вопросом: панель спрашивает пользователя сама.
_dispose_own_container() {
    local _choice="$1"
    if engine_is_binary; then
        case "$_choice" in
            remove) binengine_remove_service ;;
            stop)
                systemctl stop "$ENGINE_SERVICE" &>/dev/null \
                    && log_success "Движок остановлен (служба оставлена)" \
                    || log_warn "Не удалось остановить ${ENGINE_SERVICE}" ;;
            keep)
                log_info "Движок оставлен как есть"
                log_warn "Он продолжит занимать порт ${PROXY_PORT:-443} — цель реаниматора может не запуститься" ;;
            *) log_error "Неизвестное решение по движку: ${_choice}"; return 1 ;;
        esac
        return
    fi
    case "$_choice" in
        remove)
            remove_own_container ;;
        stop)
            docker update --restart=no "$CONTAINER_NAME" &>/dev/null || true
            docker stop --timeout 10 "$CONTAINER_NAME" &>/dev/null \
                && log_success "Контейнер остановлен (не удалён)" \
                || log_warn "Не удалось остановить контейнер" ;;
        keep)
            log_info "Контейнер оставлен как есть"
            log_warn "Он продолжит занимать порт ${PROXY_PORT:-443} — цель реаниматора может не запуститься" ;;
        *)
            log_error "Неизвестное решение по контейнеру: ${_choice}"
            return 1 ;;
    esac
}

# switch_to_reanimator_mode [remove|stop|keep] — судьба своего контейнера.
# Без аргумента вопрос задаётся интерактивно.
switch_to_reanimator_mode() {
    local _container_choice="${1:-}"

    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        log_info "Уже в режиме reanimator"
        return 0
    fi

    if [ -n "$_container_choice" ]; then
        case "$_container_choice" in
            remove|stop|keep) ;;
            *) log_error "Использование: mode reanimator [remove|stop|keep]"; return 1 ;;
        esac
    fi

    echo ""
    log_warn "Переход в режим Reanimator. Свой контейнер/конфиг MTProxyL больше не будет управляться из меню."
    echo -en "  ${BOLD}Введите 'yes' для подтверждения:${NC} "
    local _c; read_line _c
    [ "$_c" != "yes" ] && { log_info "Отменено"; return 1; }

    # Свой контейнер держит порт — а он же нужен цели реаниматора.
    # Предлагаем убрать его сразу, чтобы не делать это вручную.
    local _own_state; _own_state=$(own_container_state 2>/dev/null)
    if [ "$_own_state" != "absent" ]; then
        echo ""
        if engine_is_binary; then
            echo -e "  ${BOLD}Свой движок ${ENGINE_SERVICE}:${NC} ${_own_state}"
        else
            echo -e "  ${BOLD}Свой контейнер ${CONTAINER_NAME}:${NC} ${_own_state}"
        fi
        echo -e "  ${DIM}Он занимает порт ${PROXY_PORT:-443} и будет мешать цели реаниматора.${NC}"
        if [ -z "$_container_choice" ]; then
            echo ""
            echo -e "  ${DIM}[1]${NC} Остановить и снять службу/контейнер ${DIM}(рекомендуется)${NC}"
            echo -e "  ${DIM}[2]${NC} Только остановить, не снимать"
            echo -e "  ${DIM}[3]${NC} Не трогать"
            local _oc; _oc=$(read_choice "выбор" "1")
            case "$_oc" in
                1) _container_choice="remove" ;;
                2) _container_choice="stop" ;;
                *) _container_choice="keep" ;;
            esac
        fi
        _dispose_own_container "$_container_choice"
    fi

    switch_port_profile "reanimator" || true
    switch_selfmask_profile "reanimator"
    save_settings
    run_target_detection
    save_detect_settings
    # Порт менеджера здесь уже не актуален — переходим на порт цели,
    # иначе фиксы останутся навешенными на прежний порт.
    sync_port_from_target
    log_success "Режим: reanimator"
}

# ── Установка оригинального telemt (telemt/telemt) ─────────────
# Запускаем официальный установщик проекта telemt как есть.
TELEMT_INSTALLER_URL="https://raw.githubusercontent.com/${TELEMT_GITHUB:-telemt/telemt}/main/install.sh"

# Цели нет: ни процесса на хосте, ни юнита, ни бинарника, ни контейнера
_no_telemt_target() {
    # Проверяем реальность, а не запомненный результат детекта: цель могли
    # снести уже после него.
    case "${DETECTED_MODE:-unknown}" in
        docker|mtproxymax)
            [ -n "${DETECTED_CONTAINER:-}" ] \
                && docker inspect "$DETECTED_CONTAINER" &>/dev/null && return 1 ;;
    esac
    _telemt_host_pids >/dev/null && return 1
    _telemt_unit_exists && return 1
    command -v telemt &>/dev/null && return 1
    [ -x /bin/telemt ] && return 1
    [ -x /usr/local/bin/telemt ] && return 1
    return 0
}

# Порт, который установщик telemt предложит по умолчанию: он читает
# существующий /etc/telemt/telemt.toml, иначе берёт 443. Спросит он всё
# равно, но конфликт честнее показать до запуска.
_telemt_installer_default_port() {
    local _cfg="/etc/telemt/telemt.toml" _p=""
    [ -f "$_cfg" ] && _p=$(_toml_get_value "port" "$_cfg")
    [[ "$_p" =~ ^[0-9]+$ ]] && { echo "$_p"; return; }
    echo "443"
}

# Порт под telemt занят — разбираемся до установки.
# Свой контейнер работает в сети host и в ss виден как telemt: установщик
# сочтёт порт своим и продолжит, а служба потом уйдёт в рестарт-луп.
_port_listener_pids() {
    local _port="$1" _out=""
    if command -v ss &>/dev/null; then
        _out=$(ss -ltnp 2>/dev/null | awk -v p=":${_port}\$" '$4 ~ p {print}')
    elif command -v netstat &>/dev/null; then
        _out=$(netstat -ltnp 2>/dev/null | awk -v p=":${_port}\$" '$4 ~ p {print}')
    fi
    [ -n "$_out" ] || return 1
    {
        grep -oE 'pid=[0-9]+' <<< "$_out" | cut -d= -f2
        grep -oE '(^|[[:space:]])[0-9]+/' <<< "$_out" | tr -d ' /'
    } | sort -un
}

# Процесс принадлежит службе telemt.service — той самой, которую
# официальный установщик и обновляет.
_pid_in_telemt_unit() {
    local _pid="$1"
    grep -q 'telemt\.service' "/proc/${_pid}/cgroup" 2>/dev/null && return 0
    local _mp; _mp=$(systemctl show telemt.service -p MainPID --value 2>/dev/null)
    [ "$_mp" = "$_pid" ] && [ "$_pid" != "0" ]
}

# telemt.service установщик остановит сам, а telemt в контейнере или мимо
# systemd он ошибочно посчитает своим и продолжит.
_preflight_telemt_port() {
    local _port="$1"
    is_port_available "$_port" && return 0

    local _pids _p _in_unit="false" _in_container="false" _foreign="false"
    _pids=$(_port_listener_pids "$_port" 2>/dev/null)
    for _p in $_pids; do
        if _pid_in_container "$_p"; then
            _in_container="true"
        elif _pid_in_telemt_unit "$_p"; then
            _in_unit="true"
        else
            _foreign="true"
        fi
    done

    if [ "$_in_unit" = "true" ] && [ "$_in_container" != "true" ] && [ "$_foreign" != "true" ]; then
        echo ""
        log_info "Порт ${_port} занимает служба telemt.service — это и есть цель обновления"
        echo -e "  ${DIM}Установщик остановит её сам перед заменой бинарника: конфликта нет.${NC}"
        return 0
    fi

    echo ""
    log_warn "Порт ${_port} занят — telemt на него не встанет"
    show_port_listener "$_port"

    local _own; _own=$(own_container_state 2>/dev/null)
    if [ "$_in_container" = "true" ] && { [ "$_own" = "running" ] || [ "$_own" = "restarting" ]; }; then
        echo ""
        log_warn "Порт держит собственный контейнер MTProxyL (${CONTAINER_NAME}, сеть host)"
        echo -e "  ${DIM}Установщик telemt увидит в ss имя процесса telemt, посчитает порт${NC}"
        echo -e "  ${DIM}своим и продолжит установку — служба потом не поднимется.${NC}"
        echo ""
        echo -e "  ${DIM}[1]${NC} Остановить и удалить контейнер ${DIM}(рекомендуется)${NC}"
        echo -e "  ${DIM}[2]${NC} Только остановить, контейнер оставить"
        echo -e "  ${DIM}[3]${NC} Не трогать — укажу другой порт в установщике"
        local _oc; _oc=$(read_choice "выбор" "1")
        case "$_oc" in
            1) remove_own_container ;;
            2) docker update --restart=no "$CONTAINER_NAME" &>/dev/null || true
               docker stop --timeout 10 "$CONTAINER_NAME" &>/dev/null \
                   && log_success "Контейнер остановлен (не удалён)" \
                   || log_warn "Не удалось остановить контейнер" ;;
            *) log_info "Контейнер оставлен — укажите в установщике свободный порт" ;;
        esac
        sleep 1
        if is_port_available "$_port"; then
            log_success "Порт ${_port} свободен"
            return 0
        fi
        echo ""
        log_warn "Порт ${_port} всё ещё занят"
        show_port_listener "$_port"
    elif [ "$_in_container" = "true" ]; then
        echo ""
        log_warn "Порт держит telemt в чужом контейнере — установщик его не остановит"
        echo -e "  ${DIM}Он поставит отдельную службу telemt.service, которая не сможет${NC}"
        echo -e "  ${DIM}занять порт. Остановите контейнер или укажите другой порт.${NC}"
        return 1
    fi

    echo ""
    echo -e "  ${DIM}Установщик telemt либо откажется ставиться, либо поставит службу,${NC}"
    echo -e "  ${DIM}которая не сможет занять порт. Освободите ${_port} или укажите${NC}"
    echo -e "  ${DIM}другой порт, когда установщик спросит.${NC}"
    return 1
}

# Список релизов telemt с GitHub, постранично по 10 — как в меню движка.
# Возвращает выбранный тег в _TELEMT_PICKED_VERSION ("" = latest).
_TELEMT_PICKED_VERSION=""
_telemt_pick_version() {
    _TELEMT_PICKED_VERSION=""

    local _json
    _json=$(curl -fsS --max-time 10 "https://api.github.com/repos/${TELEMT_GITHUB:-telemt/telemt}/releases?per_page=100" 2>/dev/null) || {
        log_warn "Не удалось получить список версий — ставим latest"
        return 0
    }

    local _list
    _list=$(python3 -c "
import json, sys
try:
    rel = json.load(sys.stdin)
    for r in rel:
        if r.get('draft'): continue
        tag = r.get('tag_name') or ''
        if not tag: continue
        date = (r.get('published_at') or '')[:10]
        pre = ' (pre-release)' if r.get('prerelease') else ''
        print(f'{tag}|{date}{pre}')
except Exception:
    pass
" <<< "$_json" 2>/dev/null)

    if [ -z "$_list" ]; then
        log_warn "Список версий пуст — ставим latest"
        return 0
    fi

    local -a _tags=() _rows=()
    local _line
    while IFS= read -r _line; do
        [ -z "$_line" ] && continue
        _tags+=("${_line%%|*}")
        _rows+=("$_line")
    done <<< "$_list"

    local _total=${#_tags[@]}
    local _per=10 _page=0 _pages
    # Отдельным присваиванием: в одном `local` арифметика раскрывается до
    # того, как переменные из этой же строки получат значения.
    _pages=$(( (_total + _per - 1) / _per ))

    while true; do
        local _from=$(( _page * _per ))
        local _to=$(( _from + _per ))
        [ "$_to" -gt "$_total" ] && _to="$_total"

        echo ""
        echo -e "  ${BOLD}Версия telemt${NC} ${DIM}(страница $((_page + 1))/${_pages}, всего ${_total})${NC}"
        echo ""
        local _i _n=0
        for (( _i = _from; _i < _to; _i++ )); do
            _n=$(( _i - _from + 1 ))
            local _tag="${_rows[$_i]%%|*}" _meta="${_rows[$_i]#*|}"
            if [ "$_i" -eq 0 ]; then
                echo -e "  ${DIM}[${_n}]${NC} ${_tag}  ${DIM}${_meta} — последняя${NC}"
            else
                echo -e "  ${DIM}[${_n}]${NC} ${_tag}  ${DIM}${_meta}${NC}"
            fi
        done
        echo ""
        local _next=$(( _n + 1 )) _prev=0
        [ "$_pages" -gt 1 ] && echo -e "  ${DIM}[${_next}]${NC} Следующие 10"
        if [ "$_page" -gt 0 ]; then
            _prev=$(( _next + 1 ))
            echo -e "  ${DIM}[${_prev}]${NC} Предыдущие 10"
        fi
        echo -e "  ${DIM}[0]${NC} Последняя версия (latest)"

        local _c; _c=$(read_choice "выбор" "0")
        case "$_c" in
            0|"") _TELEMT_PICKED_VERSION=""; return 0 ;;
        esac
        if [ "$_c" = "$_next" ] && [ "$_pages" -gt 1 ]; then
            _page=$(( (_page + 1) % _pages ))
            continue
        fi
        if [ "$_page" -gt 0 ] && [ "$_c" = "$_prev" ]; then
            _page=$(( _page - 1 ))
            continue
        fi
        if [[ "$_c" =~ ^[0-9]+$ ]] && [ "$_c" -ge 1 ] && [ "$_c" -le "$_n" ]; then
            _TELEMT_PICKED_VERSION="${_tags[$(( _from + _c - 1 ))]}"
            return 0
        fi
        log_warn "Некорректный выбор"
    done
}

# Скачивает официальный установщик telemt во временный файл.
# Путь — в _TELEMT_INSTALLER_TMP.
_TELEMT_INSTALLER_TMP=""
_telemt_fetch_installer() {
    _TELEMT_INSTALLER_TMP=""
    local _tmp
    _tmp=$(mktemp "${TMPDIR:-/tmp}/telemt-install.XXXXXX") || { log_error "Не удалось создать временный файл"; return 1; }

    log_info "Загрузка установщика..."
    if command -v curl &>/dev/null; then
        curl -fsSL "$TELEMT_INSTALLER_URL" -o "$_tmp" 2>/dev/null || true
    elif command -v wget &>/dev/null; then
        wget -qO "$_tmp" "$TELEMT_INSTALLER_URL" 2>/dev/null || true
    else
        rm -f "$_tmp"
        log_error "Нужен curl или wget"
        return 1
    fi
    if [ ! -s "$_tmp" ]; then
        rm -f "$_tmp"
        log_error "Не удалось загрузить установщик telemt"
        return 1
    fi
    _TELEMT_INSTALLER_TMP="$_tmp"
}

# Установщик telemt отказывает при uid=0 с чужими USER/LOGNAME.
# Снимаем и его переменные путей: у MTProxyL имена совпадают.
_telemt_run_installer() {
    local _script="$1"; shift
    local _rc=0
    echo ""
    echo -e "  ${DIM}$(_repeat '─' 60)${NC}"
    env -u REPO -u BIN_NAME -u INSTALL_DIR -u CONFIG_DIR -u CONFIG_FILE \
        -u WORK_DIR -u TLS_DOMAIN -u SERVER_PORT -u VERSION \
        USER=root LOGNAME=root sh "$_script" "$@" || _rc=$?
    echo -e "  ${DIM}$(_repeat '─' 60)${NC}"
    echo ""
    return $_rc
}

install_original_telemt() {
    # _offer_tuning=false — когда тюнинг предлагает вызывающий мастер
    local _offer_tuning="${1:-true}"
    if [ "${MTPROXYL_MODE:-manager}" != "reanimator" ]; then
        log_error "Установка оригинального telemt доступна только в режиме reanimator"
        log_info "В режиме manager MTProxyL ставит и обслуживает собственный telemt: mtproxyl install"
        return 1
    fi
    check_root

    draw_header "УСТАНОВКА / ОБНОВЛЕНИЕ TELEMT"
    echo ""
    echo -e "  Будет запущен официальный установщик проекта telemt:"
    echo -e "  ${DIM}${TELEMT_INSTALLER_URL}${NC}"
    echo ""
    echo -e "  ${DIM}Он спросит язык, порт и TLS-домен, затем поставит бинарник${NC}"
    echo -e "  ${DIM}/bin/telemt, конфиг /etc/telemt/telemt.toml и службу${NC}"
    echo -e "  ${DIM}telemt.service с включённым API на 127.0.0.1:9091.${NC}"
    echo -e "  ${DIM}MTProxyL запускает его как есть и ничего не подменяет.${NC}"

    # Установщик управляет только своей службой telemt.service и своим
    # конфигом. Контейнер чужой панели или MTProxyMax он не обновит — для
    # такой цели это будет ВТОРАЯ, отдельная установка.
    case "${DETECTED_MODE:-unknown}" in
        docker|mtproxymax)
            echo ""
            log_warn "Текущая цель — ${DETECTED_MODE}$([ -n "${DETECTED_CONTAINER:-}" ] && echo " (${DETECTED_CONTAINER})"), её этот установщик не обновляет"
            echo -e "  ${DIM}Он ставит отдельную службу telemt.service с собственным конфигом${NC}"
            echo -e "  ${DIM}/etc/telemt/telemt.toml — рядом с текущей целью, а не вместо неё.${NC}"
            echo -e "  ${DIM}Порт у них будет общий, поэтому вторая установка не поднимется,${NC}"
            echo -e "  ${DIM}пока первая занимает порт.${NC}"
            ;;
        local|config_only|manual)
            if ! _no_telemt_target; then
                echo ""
                log_info "telemt на сервере уже есть — это будет обновление"
                echo -e "  ${DIM}Конфиг целиком не перезаписывается: обновятся только порт и${NC}"
                echo -e "  ${DIM}tls_domain (те значения, что подтвердите), остальное — тюнинг,${NC}"
                echo -e "  ${DIM}[server.api], секреты пользователей — останется как есть.${NC}"
            fi
            ;;
    esac

    _preflight_telemt_port "$(_telemt_installer_default_port)" || true

    echo ""
    echo -en "  ${BOLD}Запустить установщик telemt? [y/N]:${NC} "
    local _yn; read_line _yn
    [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 1; }

    # Версию выбираем до запуска: установщик принимает её первым аргументом
    _telemt_pick_version
    local _ver="${_TELEMT_PICKED_VERSION}"
    [ -n "$_ver" ] && log_info "Версия: ${_ver}" || log_info "Версия: latest"

    _telemt_fetch_installer || return 1

    local _rc=0
    if [ -n "$_ver" ]; then
        _telemt_run_installer "$_TELEMT_INSTALLER_TMP" "$_ver" || _rc=$?
    else
        _telemt_run_installer "$_TELEMT_INSTALLER_TMP" || _rc=$?
    fi
    rm -f "$_TELEMT_INSTALLER_TMP"; _TELEMT_INSTALLER_TMP=""

    if [ "$_rc" -ne 0 ]; then
        log_warn "Установщик telemt завершился с кодом ${_rc}"
        return 1
    fi

    log_info "Повторное обнаружение цели..."
    if ! run_target_detection; then
        log_warn "telemt установлен, но цель не определилась — проверьте: systemctl status telemt"
        save_detect_settings
        return 1
    fi
    save_detect_settings
    sync_port_from_target || true
    # Служба только что стартовала — API поднимается на пару секунд позже
    _wait_target_api 8 >/dev/null 2>&1 || true

    # Конфиг только что создан установщиком — самое время предложить наш
    # набор таймаутов, пока пользователь здесь.
    if [ "$_offer_tuning" != "false" ] && [ -n "${DETECTED_CONFIG_PATH:-}" ] && [ -f "${DETECTED_CONFIG_PATH}" ]; then
        echo ""
        run_reanimator_tuning_wizard || true
    fi
    return 0
}

# Удаление telemt официальным установщиком: uninstall — бинарник и служба,
# purge — вместе с конфигом и данными. Чужие установки не трогает.
uninstall_original_telemt() {
    if [ "${MTPROXYL_MODE:-manager}" != "reanimator" ]; then
        log_error "Удаление telemt доступно только в режиме reanimator"
        return 1
    fi
    check_root

    draw_header "УДАЛЕНИЕ TELEMT"
    echo ""
    case "${DETECTED_MODE:-unknown}" in
        docker|mtproxymax)
            log_warn "Текущая цель — ${DETECTED_MODE}, её этот установщик не удаляет"
            echo -e "  ${DIM}Будут удалены только /bin/telemt, telemt.service и (при purge)${NC}"
            echo -e "  ${DIM}/etc/telemt, /opt/telemt и системный пользователь telemt.${NC}"
            echo "" ;;
    esac
    echo -e "  ${BOLD}Что делает официальный установщик:${NC}"
    echo -e "  ${DIM}[1]${NC} uninstall — остановить службу, снять юнит и бинарник"
    echo -e "      ${DIM}конфиг /etc/telemt/telemt.toml остаётся${NC}"
    echo -e "  ${DIM}[2]${NC} purge — то же плюс конфиг, /opt/telemt и пользователь telemt"
    echo -e "      ${RED}данные и секреты пользователей будут потеряны${NC}"
    echo -e "  ${DIM}[0]${NC} Отмена"
    local _c; _c=$(read_choice "выбор" "0")
    local _action=""
    case "$_c" in
        1) _action="uninstall" ;;
        2) _action="purge" ;;
        *) log_info "Отменено"; return 0 ;;
    esac

    echo ""
    log_warn "MTProxyL после этого останется без цели: фиксы (NFT/Zapret2) продолжат висеть на порту ${PROXY_PORT}"
    echo -en "  ${BOLD}Введите 'yes' для подтверждения (${_action}):${NC} "
    local _confirm; read_line _confirm
    [ "$_confirm" = "yes" ] || { log_info "Отменено"; return 0; }

    _telemt_fetch_installer || return 1
    local _rc=0
    _telemt_run_installer "$_TELEMT_INSTALLER_TMP" "$_action" || _rc=$?
    rm -f "$_TELEMT_INSTALLER_TMP"; _TELEMT_INSTALLER_TMP=""

    if [ "$_rc" -ne 0 ]; then
        log_warn "Установщик telemt завершился с кодом ${_rc}"
        return 1
    fi

    log_info "Повторное обнаружение цели..."
    run_target_detection || log_info "Цель не найдена — это ожидаемо после удаления"
    save_detect_settings
    return 0
}

# Предложить установку, если чинить нечего. Возвращает 0, если telemt
# в итоге установлен.
offer_install_original_telemt() {
    _no_telemt_target || return 0
    echo ""
    log_warn "Установленный telemt на сервере не найден — реаниматору нечем управлять"
    echo -e "  ${DIM}Можно поставить оригинальный telemt официальным установщиком проекта${NC}"
    echo -en "  ${BOLD}Установить telemt сейчас? [Y/n]:${NC} "
    local _yn; read_line _yn
    [[ "$_yn" =~ ^[nN] ]] && { log_info "Позже: меню «Цель / режим» → «Установить telemt»"; return 1; }
    # Тюнинг предложит сам мастер установки реаниматора — здесь не дублируем
    install_original_telemt "false"
}

# ── Установочный визард для режима Reanimator ──────────────────
run_reanimator_installer() {
    draw_header "REANIMATOR — ПОИСК СУЩЕСТВУЮЩЕЙ УСТАНОВКИ TELEMT"
    echo ""

    check_root

    if ! run_target_detection; then
        # Чинить нечего — сначала предлагаем поставить оригинальный telemt
        # и только потом уходим в ручной путь к конфигу.
        if _no_telemt_target; then
            offer_install_original_telemt && run_target_detection >/dev/null 2>&1 || true
        fi
    fi

    # Прокси на сервере может быть не telemt вовсе: свой, teleproxy, что угодно.
    # Тогда движок нам не нужен целиком — нужны только фиксы хоста, и спрашивать
    # про конфиг, порт и домен незачем.
    if _no_telemt_target && { [ -z "${DETECTED_CONFIG_PATH:-}" ] || [ ! -f "${DETECTED_CONFIG_PATH:-}" ]; }; then
        echo ""
        echo -e "  ${BOLD}Нужны только оптимизация и фиксы?${NC}"
        echo -e "  ${DIM}Если прокси у вас свой — другая реализация MTProto или${NC}"
        echo -e "  ${DIM}вообще другой сервис — MTProxyL может работать как набор${NC}"
        echo -e "  ${DIM}host-фиксов: zapret2, SYN-лимитер, оптимизация By-MEKO,${NC}"
        echo -e "  ${DIM}гео-блокировка, дополнения. Конфиг и домен не спросим,${NC}"
        echo -e "  ${DIM}про отсутствие telemt больше не напомним.${NC}"
        echo -en "  ${BOLD}Включить режим «только оптимизация»? [y/N]:${NC} "
        local _tools_yn; read_line _tools_yn
        if [[ "$_tools_yn" =~ ^[yY] ]]; then
            TOOLS_ONLY="true"
            MTPROXYL_MODE="reanimator"
            DETECTED_MODE="none"
            DETECTED_NETWORK_MODE="host"
            PROXY_PORT="${DETECTED_PORT:-443}"
            save_settings
            save_detect_settings 2>/dev/null || true
            log_success "Режим «только оптимизация» включён"
            log_info "Фиксы настраиваются в меню «NFT лимитер, Zapret2 и фиксы»"
            log_info "Вернуть работу с движком: Цель / режим → «Только оптимизация»"
            show_main_menu
            return 0
        fi
    fi

    if [ -z "${DETECTED_CONFIG_PATH:-}" ] || [ ! -f "${DETECTED_CONFIG_PATH:-}" ]; then
        echo ""
        echo -e "  ${BOLD}Укажите путь к конфигу telemt вручную (Enter — пропустить):${NC}"
        echo -en "  ${DIM}Путь:${NC} "
        local _manual_path; read_line _manual_path
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
        local _override; read_line _override
        if [[ "$_override" =~ ^[yY] ]]; then
            echo -en "  ${DIM}Путь:${NC} "
            local _p; read_line _p
            [ -n "$_p" ] && [ -f "$_p" ] && DETECTED_CONFIG_PATH="$_p"
        fi
    fi

    echo ""
    echo -e "  ${BOLD}Порт прокси${NC} ${DIM}(обнаружен: ${DETECTED_PORT:-?})${NC}"
    echo -en "  ${DIM}Порт [${DETECTED_PORT:-443}]:${NC} "
    local _port_in; read_line _port_in
    if [ -n "$_port_in" ] && validate_port "$_port_in"; then
        PROXY_PORT="$_port_in"
    else
        PROXY_PORT="${DETECTED_PORT:-443}"
    fi

    echo ""
    local _det_ip="${DETECTED_IP:-$(get_public_ip 2>/dev/null)}"
    echo -e "  ${BOLD}IP сервера${NC} ${DIM}(обнаружен/определён: ${_det_ip:-?})${NC}"
    echo -en "  ${DIM}IP [${_det_ip:-авто}]:${NC} "
    local _ip_in; read_line _ip_in
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
    echo ""
    # Цель мы только что ставили/перезапускали — панель меню сразу же
    # спрашивает её API, а он поднимается на пару секунд позже.
    _wait_target_api 5 >/dev/null 2>&1 || true
    load_settings
    show_main_menu
}
