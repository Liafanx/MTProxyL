#!/bin/bash

# MTProxyL — WEB Proxy (движок telemt 3.5.1+)
# Движок TLS не терминирует: публичный порт держит nginx, разводит по SNI и
# отдаёт обычный HTTP/1.1 на приватный listener transport = "web".

WEB_MIN_ENGINE_VERSION="3.5.1"

web_is_enabled() { [ "${WEB_ENABLED:-false}" = "true" ]; }

# Имя WEB обязано отличаться от домена маскировки: FakeTLS-клиент шлёт в SNI
# именно tls_domain, и ssl_preread отправил бы его в nginx вместо движка.
# Поэтому по умолчанию берём поддомен — сертификат и сайт остаются общими.
web_domain() {
    if [ -n "${WEB_DOMAIN:-}" ]; then echo "${WEB_DOMAIN}"; return 0; fi
    local _base="${SELFMASK_DOMAIN:-}"
    [ -n "$_base" ] || return 1
    echo "web.${_base}"
}

web_decoy_dir()  { echo "${WEB_DECOY_DIR:-${SELFMASK_SITE_DIR:-/var/www/mtproxyl-selfmask}}"; }

# Домен маскировки FakeTLS — с ним WEB совпасть не может.
web_faketls_domain() { echo "${PROXY_DOMAIN:-${SELFMASK_DOMAIN:-}}"; }

# public_addr движок принимает только IP-литералом, а CUSTOM_IP у нас бывает
# доменом. Самый верный источник — A-запись самого WEB-домена: она и есть тот
# публичный адрес, на который придёт клиент.
web_public_ip() {
    local _ip _domain
    _domain=$(web_domain)
    if [ -n "$_domain" ]; then
        _ip=$(getent ahostsv4 "$_domain" 2>/dev/null | awk '{print $1; exit}')
        validate_ip_literal "$_ip" 2>/dev/null && { echo "$_ip"; return 0; }
    fi
    _ip=$(get_public_ip 2>/dev/null)
    validate_ip_literal "$_ip" 2>/dev/null && { echo "$_ip"; return 0; }
    _ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
        | grep -vE '^(172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.)' | head -1)
    validate_ip_literal "$_ip" 2>/dev/null && { echo "$_ip"; return 0; }
    return 1
}

# Публичный порт остаётся за PROXY_PORT — на нём стоит nginx, а не движок.
web_public_addr() {
    local _ip; _ip=$(web_public_ip) || return 1
    printf '%s:%s\n' "$_ip" "${PROXY_PORT:-443}"
}

# Клиент Telegram Desktop ходит только на 443 и порт в ссылку не пишет.
web_port_is_443() { [ "${PROXY_PORT:-443}" = "443" ]; }

web_carrier_needs_http2() {
    [ "${WEB_CARRIER:-https-lanes}" = "https-lanes" ]
}

# Отдельное TCP-соединение на каждый поток — SYN-лимитер такое режет.
web_carrier_is_socket_per_stream() {
    [ "${WEB_CARRIER:-https-lanes}" = "websocket-lanes" ]
}

# ── Куски конфига движка ──────────────────────────────────────

# Явные listener'ы отменяют legacy-поля [server] целиком, поэтому MTProxy
# перечисляем вместе с WEB — иначе FakeTLS просто не поднимется.
web_listeners_toml() {
    cat << TOML

[[server.listeners]]
ip = "127.0.0.1"
port = ${WEB_MTPROXY_PORT:-15443}
transport = "mtproxy"
proxy_protocol = true

[[server.listeners]]
ip = "127.0.0.1"
port = ${WEB_LISTEN_PORT:-15080}
transport = "web"
proxy_protocol = false
reuse_allow = false
web_client_ip_source = "x_forwarded_for"
web_trusted_proxy_cidrs = ["127.0.0.1/32"]
TOML
}

_web_decoy_toml() {
    if [ "${WEB_DECOY_MODE:-static_directory}" = "http_upstream" ]; then
        printf 'mode = "http_upstream"\nupstream = "%s"\n' "${WEB_DECOY_UPSTREAM}"
    else
        printf 'mode = "static_directory"\ndirectory = "%s"\nindex = "index.html"\n' "$(web_decoy_dir)"
    fi
}

# Профиль на каждого включённого пользователя: у кого есть FakeTLS-ссылка,
# у того будет и WEB-ссылка. Секрет при одном secret_mode задаёт client
# capability целиком, поэтому пользователей с общим секретом движок отвергает —
# берём первого и пропускаем остальных.
_web_profiles_toml() {
    local i _n=0 _seen=" "
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_ENABLED[$i]}" = "true" ] || continue
        case "$_seen" in
            *" ${SECRETS_KEYS[$i]} "*)
                log_warn "WEB: у '${SECRETS_LABELS[$i]}' секрет совпадает с другим пользователем — профиль пропущен" >&2
                continue ;;
        esac
        _seen+="${SECRETS_KEYS[$i]} "
        printf '\n[[web.vhosts.profiles]]\nuser = "%s"\nsecret_mode = "%s"\n' \
            "${SECRETS_LABELS[$i]}" "${WEB_SECRET_MODE:-dd}"
        _n=$((_n + 1))
    done
    [ "$_n" -gt 0 ]
}

# Пользователи, чей профиль не попадёт в vhost из-за общего секрета.
web_duplicate_secret_labels() {
    local i _seen=" " _dup=""
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_ENABLED[$i]}" = "true" ] || continue
        case "$_seen" in
            *" ${SECRETS_KEYS[$i]} "*) _dup+="${SECRETS_LABELS[$i]} "; continue ;;
        esac
        _seen+="${SECRETS_KEYS[$i]} "
    done
    printf '%s' "${_dup% }"
}

web_sections_toml() {
    local _domain _addr
    _domain=$(web_domain)
    _addr=$(web_public_addr) || return 1
    [ -n "$_domain" ] || return 1

    printf '\n[web]\nenabled = true\ncarrier = "%s"\n' "${WEB_CARRIER:-https-lanes}"
    printf '\n[web.debug]\nenabled = %s\n' "$([ "${WEB_DEBUG:-false}" = "true" ] && echo true || echo false)"
    printf '\n[[web.vhosts]]\nhost = "%s"\npublic_addr = "%s"\n' "$_domain" "$_addr"
    printf '\n[web.vhosts.decoy]\n'
    _web_decoy_toml
    _web_profiles_toml
}

# ── Куски конфига nginx ───────────────────────────────────────

# Демультиплексор на публичном порту: по SNI отправляет наше имя в TLS-сервер
# WEB, а всё остальное — движку. proxy_protocol нужен обеим веткам, иначе
# бэкенды увидят вместо клиента loopback.
web_nginx_stream_block() {
    local _domain _port
    _domain=$(web_domain) || return 1
    _port="${PROXY_PORT:-443}"
    cat << NGX
stream {
    map \$ssl_preread_server_name \$mtproxyl_upstream {
        ${_domain}  mtproxyl_web;
        default     mtproxyl_faketls;
    }

    upstream mtproxyl_web     { server 127.0.0.1:${WEB_TLS_PORT:-15444}; }
    upstream mtproxyl_faketls { server 127.0.0.1:${WEB_MTPROXY_PORT:-15443}; }

    server {
        listen ${_port};
        listen [::]:${_port};
        ssl_preread on;
        proxy_pass \$mtproxyl_upstream;
        proxy_protocol on;
        proxy_connect_timeout 5s;
        proxy_timeout 300s;
    }
}
NGX
}

# Таймауты выше long_poll_secs (25 с) и удвоенного liveness WebSocket —
# иначе фронт рвал бы carrier сам.
web_nginx_http_server() {
    local _domain _cert_dir
    _domain=$(web_domain) || return 1
    _cert_dir="$1"
    cat << NGX

    server {
        listen 127.0.0.1:${WEB_TLS_PORT:-15444} ssl proxy_protocol;
        http2 on;
        server_name ${_domain};
        server_tokens off;

        set_real_ip_from 127.0.0.1;
        real_ip_header proxy_protocol;

        ssl_certificate     ${_cert_dir}/fullchain.pem;
        ssl_certificate_key ${_cert_dir}/privkey.pem;

        client_max_body_size 2m;

        location / {
            proxy_pass http://127.0.0.1:${WEB_LISTEN_PORT:-15080};
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Forwarded-For \$remote_addr;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$mtproxyl_connection_upgrade;
            proxy_connect_timeout 5s;
            proxy_send_timeout 65s;
            proxy_read_timeout 65s;
            proxy_request_buffering off;
            proxy_buffering off;
            proxy_next_upstream off;
        }
    }
NGX
}

# map для Upgrade живёт в http-контексте и нужен только при включённом WEB.
web_nginx_upgrade_map() {
    cat << 'NGX'
    map $http_upgrade $mtproxyl_connection_upgrade {
        default upgrade;
        ''      '';
    }
NGX
}

# ── Ссылки ────────────────────────────────────────────────────

# API движка WEB-ссылки не отдаёт: в /v1/users есть только classic, secure,
# tls и tls_domains. Поэтому собираем сами.
web_link_for_secret() {
    local _raw="$1" _domain
    _domain=$(web_domain) || return 1
    [ -n "$_domain" ] && [ -n "$_raw" ] || return 1
    local _prefix=""
    [ "${WEB_SECRET_MODE:-dd}" = "dd" ] && _prefix="dd"
    printf 'tg://webproxy?server=%s&secret=%s%s\n' "$_domain" "$_prefix" "$_raw"
}

web_link_for_label() {
    local _label="$1" i
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_LABELS[$i]}" = "$_label" ] || continue
        [ "${SECRETS_ENABLED[$i]}" = "true" ] || return 1
        web_link_for_secret "${SECRETS_KEYS[$i]}"
        return $?
    done
    return 1
}

# ── Включение и выключение ────────────────────────────────────

# Порядок важен: пока движок держит публичный порт, nginx на него не сядет.
# Поэтому сначала уводим движок на loopback и только потом поднимаем nginx.
web_enable() {
    local _problems
    _problems=$(web_preflight_problems)
    if [ -n "$_problems" ]; then
        log_error "WEB Proxy включить нельзя:"
        printf '%s' "$_problems" | sed 's/^/    • /'
        return 1
    fi

    if [ "${SELFMASK_ENABLED:-false}" != "true" ]; then
        log_error "Сначала нужен Selfmask: у WEB от него домен, сертификат и сайт-заглушка"
        return 1
    fi

    web_carrier_is_socket_per_stream && [ "${NFT_ENABLED:-false}" = "true" ] && \
        log_warn "Carrier websocket-lanes открывает соединение на каждый поток — SYN-лимитер будет их резать"

    WEB_ENABLED="true"
    save_settings || return 1

    log_info "Выпуск сертификата с WEB-доменом $(web_domain)..."
    _selfmask_obtain_cert || { WEB_ENABLED="false"; save_settings; return 1; }

    log_info "Движок уходит с порта ${PROXY_PORT:-443} на loopback..."
    generate_telemt_config || { WEB_ENABLED="false"; save_settings; return 1; }
    load_secrets
    restart_proxy_container || true
    # Молча продолжать нельзя: nginx сел бы на 443 перед мёртвым движком.
    if ! is_proxy_running; then
        log_error "Движок не поднялся с WEB-конфигом — откатываем"
        web_disable
        return 1
    fi

    log_info "Настройка nginx на публичном порту..."
    if ! _selfmask_configure_nginx || ! systemctl restart "${SELFMASK_PQ_SERVICE}" &>/dev/null; then
        log_error "nginx не поднялся — возвращаем движок на порт ${PROXY_PORT:-443}"
        web_disable
        return 1
    fi

    log_success "WEB Proxy включён: $(web_domain), carrier ${WEB_CARRIER}"
}

# Обратный порядок: сначала снимаем nginx с публичного порта, иначе движок
# не сможет его занять обратно.
web_disable() {
    web_is_enabled || { log_info "WEB Proxy и так выключен"; return 0; }

    WEB_ENABLED="false"
    save_settings || return 1

    log_info "Снятие nginx с публичного порта..."
    _selfmask_configure_nginx || return 1
    systemctl restart "${SELFMASK_PQ_SERVICE}" &>/dev/null || true

    log_info "Возврат движка на порт ${PROXY_PORT:-443}..."
    generate_telemt_config || return 1
    # Безусловно: движок мог упасть в цикл рестарта и is_proxy_running врёт.
    load_secrets
    restart_proxy_container || true

    log_success "WEB Proxy выключен"
}

web_status_json() {
    local _d _addr _problems
    _d=$(web_domain 2>/dev/null)
    _addr=$(web_public_addr 2>/dev/null)
    _problems=$(web_preflight_problems 2>/dev/null | tr '\n' ';')
    printf '{"enabled":%s,"domain":"%s","carrier":"%s","secret_mode":"%s","public_addr":"%s","listen_port":%s,"tls_port":%s,"mtproxy_port":%s,"decoy_mode":"%s","decoy_dir":"%s","debug":%s,"problems":"%s"}\n' \
        "$(web_is_enabled && echo true || echo false)" \
        "$(json_escape "$_d")" "$(json_escape "${WEB_CARRIER:-}")" \
        "$(json_escape "${WEB_SECRET_MODE:-}")" "$(json_escape "$_addr")" \
        "${WEB_LISTEN_PORT:-15080}" "${WEB_TLS_PORT:-15444}" "${WEB_MTPROXY_PORT:-15443}" \
        "$(json_escape "${WEB_DECOY_MODE:-}")" "$(json_escape "$(web_decoy_dir)")" \
        "$([ "${WEB_DEBUG:-false}" = "true" ] && echo true || echo false)" \
        "$(json_escape "$_problems")"
}

# ── Проверка предусловий ──────────────────────────────────────

# Возвращает список причин, по которым WEB включать нельзя. Пусто — можно.
web_preflight_problems() {
    local _p="" _d _ft
    _d=$(web_domain 2>/dev/null)
    _ft=$(web_faketls_domain 2>/dev/null)
    [ -n "$_d" ] || _p+="не задан домен: нужен свой FQDN с сертификатом"$'\n'
    # Совпадение имён увело бы FakeTLS-клиентов в nginx: по SNI они неотличимы.
    if [ -n "$_d" ] && [ "$_d" = "$_ft" ]; then
        _p+="домен WEB совпадает с доменом маскировки ${_ft} — нужны разные имена"$'\n'
    fi
    if [ -n "$_d" ] && [ "$(getent ahostsv4 "$_d" 2>/dev/null | awk '{print $1; exit}')" != "$(web_public_ip 2>/dev/null)" ]; then
        _p+="домен ${_d} не указывает на этот сервер"$'\n'
    fi
    if [ "${WEB_DECOY_MODE:-static_directory}" = "static_directory" ]; then
        [ -d "$(web_decoy_dir)" ] || _p+="каталог сайта-заглушки не найден: $(web_decoy_dir)"$'\n'
    else
        [ -n "${WEB_DECOY_UPSTREAM:-}" ] || _p+="не задан upstream для заглушки"$'\n'
    fi
    web_port_is_443 || _p+="публичный порт ${PROXY_PORT}, а Telegram Desktop ходит в WEB только на 443"$'\n'
    web_public_addr >/dev/null 2>&1 || _p+="не определён публичный IP"$'\n'
    web_nginx_has_stream || _p+="nginx собран без stream — обновите его: mtproxyl selfmask pq-install"$'\n'
    web_engine_supports || _p+="движок $(engine_current_version 2>/dev/null) не умеет WEB, нужен ${WEB_MIN_ENGINE_VERSION} или новее"$'\n'
    local _busy; _busy=$(web_busy_ports)
    [ -z "$_busy" ] || _p+="порты уже заняты: ${_busy} — смените их через mtproxyl web set"$'\n'
    printf '%s' "$_p"
}

# До 3.5.1 движок ключей WEB не знает: он их молча игнорирует, и listener
# с transport = "web" превращается во второй MTProxy-порт.
web_engine_supports() {
    local _v; _v=$(engine_current_version 2>/dev/null | tr -d ' \t\r\n')
    _v="${_v#v}"; _v="${_v%%-*}"
    [ -n "$_v" ] || return 1
    _version_ge "$_v" "$WEB_MIN_ENGINE_VERSION"
}

# Порты движка и nginx должны быть свободны до того, как мы уведём движок
# с публичного порта: иначе он не поднимется, а 443 останется без хозяина.
web_busy_ports() {
    local _p _busy=""
    for _p in "${WEB_MTPROXY_PORT:-15443}" "${WEB_LISTEN_PORT:-15080}" "${WEB_TLS_PORT:-15444}"; do
        ss -lnt "sport = :${_p}" 2>/dev/null | grep -q LISTEN && _busy+="${_p} "
    done
    printf '%s' "${_busy% }"
}

# Без stream и ssl_preread разводить по SNI нечем. Проверяем до того, как
# движок уйдёт с публичного порта, иначе он останется мёртвым.
web_nginx_has_stream() {
    local _bin
    _bin=$(_selfmask_nginx_bin 2>/dev/null) || return 1
    [ -x "$_bin" ] || return 1
    "$_bin" -V 2>&1 | grep -q -- '--with-stream_ssl_preread_module'
}

# ── Команда CLI ───────────────────────────────────────────────

web_status_print() {
    echo ""
    echo -e "  ${BOLD}🌐 WEB Proxy${NC}"
    echo -e "  ──────────────────────────────────────────────"
    if web_is_enabled; then
        echo -e "   🟢 Состояние        ${GREEN}включён${NC}"
    else
        echo -e "   🔴 Состояние        ${DIM}выключен${NC}"
    fi
    echo -e "   🔗 Домен            $(web_domain 2>/dev/null || echo '—')"
    echo -e "   🎭 Домен маскировки $(web_faketls_domain 2>/dev/null || echo '—')"
    echo -e "   🚚 Carrier          ${WEB_CARRIER:-—}"
    echo -e "   🔑 Режим секрета    ${WEB_SECRET_MODE:-—}"
    echo -e "   📍 public_addr      $(web_public_addr 2>/dev/null || echo '—')"
    echo -e "   🪟 Порты            nginx :${PROXY_PORT:-443} → движок :${WEB_MTPROXY_PORT:-15443}, WEB :${WEB_LISTEN_PORT:-15080}"
    echo -e "   🕸  Заглушка         $(web_decoy_dir)"
    local _dup; _dup=$(web_duplicate_secret_labels 2>/dev/null)
    [ -n "$_dup" ] && echo -e "   ⚠️  Общий секрет     ${YELLOW}${_dup}${NC} — без профиля WEB"
    local _p; _p=$(web_preflight_problems 2>/dev/null)
    if [ -n "$_p" ]; then
        echo ""
        echo -e "  ${YELLOW}Мешает включению:${NC}"
        printf '%s' "$_p" | sed 's/^/    • /'
    fi
    echo ""
}

web_links_print() {
    web_is_enabled || { log_warn "WEB Proxy выключен"; return 1; }
    local i _link _n=0 _seen=" "
    echo ""
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_ENABLED[$i]}" = "true" ] || continue
        # Профиля у дубля секрета нет — ссылка на него не работала бы.
        case "$_seen" in *" ${SECRETS_KEYS[$i]} "*) continue ;; esac
        _seen+="${SECRETS_KEYS[$i]} "
        _link=$(web_link_for_secret "${SECRETS_KEYS[$i]}") || continue
        echo -e "  ${BOLD}${SECRETS_LABELS[$i]}${NC}"
        echo -e "  ${CYAN}${_link}${NC}\n"
        _n=$((_n + 1))
    done
    [ "$_n" -gt 0 ] || { log_warn "Нет включённых пользователей"; return 1; }
}

handle_web_command() {
    local subcmd="${1:-status}"
    shift 2>/dev/null || true
    case "$subcmd" in
        status)  load_secrets 2>/dev/null; web_status_print ;;
        json)    web_status_json ;;
        enable)  check_root; load_secrets; web_enable ;;
        disable) check_root; load_secrets; web_disable ;;
        links)   load_secrets; web_links_print ;;
        set)     check_root; web_set_param "${1:-}" "${2:-}" ;;
        settable) web_settable_json ;;
        *)
            echo -e "  ${BOLD}WEB Proxy:${NC}"
            echo -e "    ${GREEN}web status${NC}    Статус"
            echo -e "    ${GREEN}web enable${NC}    Включить"
            echo -e "    ${GREEN}web disable${NC}   Выключить"
            echo -e "    ${GREEN}web links${NC}     Ссылки tg://webproxy"
            echo -e "    ${GREEN}web set${NC} K V    Изменить параметр"
            echo -e "    ${GREEN}web json${NC}      Статус в JSON"
            ;;
    esac
}

# Формат как в каталогах NFT и Selfmask: КЛЮЧ|валидатор|описание.
_WEB_SETTABLE=(
    "WEB_DOMAIN|custom:_validate_web_domain|Домен WEB Proxy, отличный от домена маскировки"
    "WEB_CARRIER|enum:https,https-lanes,websocket,websocket-lanes|Транспорт carrier"
    "WEB_SECRET_MODE|enum:plain,dd|Представление секрета в ссылке"
    "WEB_LISTEN_PORT|range:1:65535|Приватный порт listener'а движка"
    "WEB_TLS_PORT|range:1:65535|Порт TLS-сервера nginx на loopback"
    "WEB_MTPROXY_PORT|range:1:65535|Порт FakeTLS-listener'а движка на loopback"
    "WEB_DECOY_MODE|enum:static_directory,http_upstream|Тип сайта-заглушки"
    "WEB_DECOY_DIR|custom:_validate_web_decoy_dir|Каталог сайта-заглушки"
    "WEB_DECOY_UPSTREAM|custom:_validate_web_upstream|HTTP-origin заглушки"
    "WEB_DEBUG|enum:true,false|Страница диагностики /web-status"
)

_validate_web_domain() {
    local _v="$1"
    [ -n "$_v" ] || return 0
    [[ "$_v" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]] || {
        echo "не похоже на доменное имя" >&2; return 1; }
    [ "$_v" != "$(web_faketls_domain)" ] || {
        echo "совпадает с доменом маскировки" >&2; return 1; }
}

_validate_web_decoy_dir() {
    local _v="$1"
    [ -n "$_v" ] || return 0
    [ -d "$_v" ] || { echo "каталог не найден" >&2; return 1; }
}

_validate_web_upstream() {
    local _v="$1"
    [ -n "$_v" ] || return 0
    [[ "$_v" =~ ^http://(127\.[0-9.]+|10\.[0-9.]+|192\.168\.[0-9.]+|169\.254\.[0-9.]+|\[::1\])(:[0-9]+)?$ ]] || {
        echo "движок принимает только loopback, link-local или частный IP без пути" >&2; return 1; }
}

web_settable_json() {
    local _e _k _v _d _first=1
    printf '['
    for _e in "${_WEB_SETTABLE[@]}"; do
        IFS='|' read -r _k _v _d <<< "$_e"
        [ "$_first" -eq 1 ] || printf ','
        _first=0
        printf '{"key":"%s","validator":"%s","desc":"%s","value":"%s"}' \
            "$_k" "$(json_escape "$_v")" "$(json_escape "$_d")" "$(json_escape "${!_k:-}")"
    done
    printf ']\n'
}

_web_find_settable() {
    local _k="$1" _e
    for _e in "${_WEB_SETTABLE[@]}"; do
        [ "${_e%%|*}" = "$_k" ] && { echo "$_e"; return 0; }
    done
    return 1
}

# Меняет только сохранённое значение. Конфиги перестраивает web enable.
web_set_param() {
    local _key="$1" _val="$2" _entry
    if [ -z "$_key" ]; then
        log_error "Использование: mtproxyl web set <ключ> <значение>"
        return 1
    fi
    if ! _entry=$(_web_find_settable "$_key"); then
        log_error "Параметр '${_key}' недоступен для изменения"
        log_info "Список: mtproxyl web settable"
        return 1
    fi
    local _rest="${_entry#*|}"
    local _validator="${_rest%%|*}"

    local _err
    if ! _err=$(_expert_validate "$_validator" "$_val" 2>&1); then
        log_error "Недопустимое значение для ${_key}: ${_err}"
        return 1
    fi

    printf -v "$_key" '%s' "$_val"
    save_settings
    log_success "${_key} = ${_val}"
    web_is_enabled && log_info "Примените заново: mtproxyl web enable"
    return 0
}
