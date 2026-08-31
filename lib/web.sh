#!/bin/bash

# MTProxyL — WEB Proxy (движок telemt 3.5.1+)
# Движок TLS не терминирует: публичный порт держит nginx, разводит по SNI и
# отдаёт обычный HTTP/1.1 на приватный listener transport = "web".

WEB_MIN_ENGINE_VERSION="3.5.1"

web_is_enabled() { [ "${WEB_ENABLED:-false}" = "true" ]; }
mtproto_is_enabled() { [ "${PROXY_MODE:-mtproto}" != "web" ]; }
web_is_only_mode() { [ "${PROXY_MODE:-mtproto}" = "web" ]; }

proxy_transport_mode_title() {
    case "${PROXY_MODE:-mtproto}" in
        web) echo "Только WEB" ;;
        combined) echo "MTProto + WEB" ;;
        *) echo "Только MTProto" ;;
    esac
}

# shared — один публичный порт на двоих, nginx разводит по SNI.
# split — у WEB свой порт, движок остаётся на PROXY_PORT напрямую.
web_layout_is_split() { [ "${WEB_LAYOUT:-shared}" = "split" ]; }
web_frontend_is_direct() { web_is_only_mode || web_layout_is_split; }

# Порт, на который приходит клиент WEB. В ссылку он не пишется, но именно
# он идёт в public_addr.
web_public_port() {
    if web_frontend_is_direct; then echo "${WEB_PUBLIC_PORT:-443}"; else echo "${PROXY_PORT:-443}"; fi
}

# В shared имя WEB обязано отличаться от домена маскировки: FakeTLS-клиент шлёт
# в SNI именно tls_domain, и ssl_preread отправил бы его в nginx вместо движка.
# В split порты разные, и совпадение безобидно. Поддомен берём по умолчанию в
# обоих режимах — так переключение раскладки не меняет ссылки.
web_domain() {
    if [ -n "${WEB_DOMAIN:-}" ]; then echo "${WEB_DOMAIN}"; return 0; fi
    local _base="${SELFMASK_DOMAIN:-}"
    [ -n "$_base" ] || return 1
    echo "web.${_base}"
}

web_decoy_dir()  { echo "${WEB_DECOY_DIR:-${SELFMASK_SITE_DIR:-/var/www/mtproxyl-selfmask}}"; }

# Домен маскировки FakeTLS — с ним WEB совпасть не может.
web_faketls_domain() { echo "${PROXY_DOMAIN:-${SELFMASK_DOMAIN:-}}"; }

# Каталог отдельного сертификата WEB. Он появляется, только если общий с
# Selfmask выпустить не удалось: тогда имена развязываются, и проблема с одним
# доменом перестаёт блокировать второй.
web_own_cert_dir() {
    local _d; _d=$(web_domain 2>/dev/null) || return 1
    [ -n "$_d" ] || return 1
    echo "/etc/letsencrypt/live/${_d}"
}

web_has_own_cert() {
    local _dir; _dir=$(web_own_cert_dir) || return 1
    [ -f "${_dir}/fullchain.pem" ] && [ -f "${_dir}/privkey.pem" ]
}

# Какой сертификат подставлять в nginx для WEB-ветки.
web_cert_dir() {
    if web_has_own_cert; then web_own_cert_dir; else _selfmask_cert_dir; fi
}

# Клиент приходит снаружи, поэтому адресом сервера может быть только
# маршрутизируемый IP. Loopback и частные сети сюда попадали через /etc/hosts:
# домен прокси разрешался в 127.0.0.1, и проверка домена сравнивала A-запись
# с локальной заглушкой.
_web_ip_is_routable() {
    local _ip="$1"
    validate_ip_literal "$_ip" 2>/dev/null || return 1
    case "$_ip" in
        127.*|0.*|10.*|192.168.*|169.254.*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 1 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 1 ;;
    esac
    return 0
}

# Адрес самого сервера, определяемый мимо WEB-домена. Нужен именно так: сверять
# A-запись домена с ней же — тавтология, которая никогда не срабатывает.
web_server_ip() {
    local _ip
    _ip="${CUSTOM_IP:-}"
    _web_ip_is_routable "$_ip" && { echo "$_ip"; return 0; }
    # CUSTOM_IP бывает доменом прокси — он указывает на этот же сервер.
    if [ -n "$_ip" ]; then
        local _r; _r=$(getent ahostsv4 "$_ip" 2>/dev/null | awk '{print $1; exit}')
        _web_ip_is_routable "$_r" && { echo "$_r"; return 0; }
    fi
    _ip=$(CUSTOM_IP="" get_public_ip 2>/dev/null)
    _web_ip_is_routable "$_ip" && { echo "$_ip"; return 0; }
    _ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
        | while read -r _a; do _web_ip_is_routable "$_a" && { echo "$_a"; break; }; done)
    validate_ip_literal "$_ip" 2>/dev/null && { echo "$_ip"; return 0; }
    return 1
}

# A-запись WEB-домена. Пусто — записи нет вовсе.
# Спрашиваем DNS, а не getent: клиенты и Let's Encrypt ходят в публичный DNS,
# а строка в /etc/hosts видна только этой машине и врала бы про домен.
web_domain_ip() {
    local _d _ip; _d=$(web_domain) || return 1
    [ -n "$_d" ] || return 1
    if command -v dig >/dev/null 2>&1; then
        _ip=$(dig +short +time=3 +tries=1 A "$_d" 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
    elif command -v host >/dev/null 2>&1; then
        _ip=$(host -t A "$_d" 2>/dev/null | awk '/has address/{print $NF; exit}')
    fi
    [ -n "$_ip" ] || _ip=$(getent ahostsv4 "$_d" 2>/dev/null | awk '{print $1; exit}')
    printf '%s' "$_ip"
}

# public_addr движок принимает только IP-литералом. Берём A-запись домена — она
# и есть тот публичный адрес, на который придёт клиент; если её нет, отдаём
# адрес сервера, чтобы конфиг хотя бы собрался.
web_public_ip() {
    local _ip; _ip=$(web_domain_ip 2>/dev/null)
    validate_ip_literal "$_ip" 2>/dev/null && { echo "$_ip"; return 0; }
    web_server_ip
}

web_public_addr() {
    local _ip; _ip=$(web_public_ip) || return 1
    printf '%s:%s\n' "$_ip" "$(web_public_port)"
}

# Клиент ходит в WEB только на 443 и порт в ссылку не пишет.
web_port_is_443() { [ "$(web_public_port)" = "443" ]; }

# В shared движок слушает MTProxy на loopback и в свои tg://-ссылки пишет
# именно этот приватный порт. Публичный держит nginx — его и подставляем через
# [general.links] public_port. В split движок и так стоит на публичном порту.
web_link_public_port() {
    web_is_enabled && mtproto_is_enabled || return 1
    web_layout_is_split && return 1
    echo "${PROXY_PORT:-443}"
}

web_carrier_needs_http2() {
    [ "${WEB_CARRIER:-websocket}" = "https-lanes" ]
}

# Zapret2 зажимает окно в SYN+ACK и на пустых ACK, то есть до того, как придёт
# ClientHello и станет известен SNI. Исключить по домену это нельзя в принципе,
# и https-carrier'ы от такого зажима заметно теряют в скорости.
#
# WebSocket-carrier'ы переживают его нормально: после Upgrade остаются долгие
# сокеты, и зажим окна на рукопожатии окупается за первые же секунды. В split
# фильтр идёт по порту прокси, и WEB не задевается вовсе.
web_carrier_survives_zapret2() {
    case "${WEB_CARRIER:-websocket}" in
        websocket-lanes|websocket) return 0 ;;
        *) return 1 ;;
    esac
}

web_zapret2_hurts() {
    web_is_only_mode && return 1
    web_layout_is_split && return 1
    web_carrier_survives_zapret2 && return 1
    zapret2_in_effect 2>/dev/null
}

web_warn_zapret2() {
    web_zapret2_hurts || return 0
    log_warn "Zapret2 активен и режет скорость WEB Proxy на carrier ${WEB_CARRIER}"
    log_info "Зажим TCP-окна ставится в SYN+ACK, когда SNI ещё неизвестен — по домену его не обойти"
    log_info "Варианты: carrier websocket (он с zapret2 работает нормально),"
    log_info "раскладка split либо SYN-лимитер вместо zapret2"
}

# ── Куски конфига движка ──────────────────────────────────────

# Явные listener'ы отменяют legacy-поля [server] целиком, поэтому MTProxy
# перечисляем вместе с WEB — иначе FakeTLS просто не поднимется.
web_listeners_toml() {
    if ! mtproto_is_enabled; then
        :
    elif web_layout_is_split; then
        # Порт у прокси свой, движок остаётся публичным: ни PROXY-заголовка,
        # ни переезда на loopback не нужно.
        cat << TOML

[[server.listeners]]
ip = "0.0.0.0"
port = ${PROXY_PORT:-443}
transport = "mtproxy"
proxy_protocol = ${PROXY_PROTOCOL:-false}
TOML
    else
        cat << TOML

[[server.listeners]]
ip = "127.0.0.1"
port = ${WEB_MTPROXY_PORT:-15443}
transport = "mtproxy"
proxy_protocol = true
TOML
    fi
    cat << TOML

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

# Сколько профилей уйдёт в конфиг: столько же, сколько пользователей с
# уникальным секретом.
web_profile_count() {
    local i _n=0 _seen=" "
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_ENABLED[$i]}" = "true" ] || continue
        case "$_seen" in *" ${SECRETS_KEYS[$i]} "*) continue ;; esac
        _seen+="${SECRETS_KEYS[$i]} "
        _n=$((_n + 1))
    done
    echo "$_n"
}

# Движок отказывается стартовать, если профилей больше max_profiles, а по
# умолчанию их разрешено 32. Округляем вверх до кратного 32: следующий
# пользователь тогда не потребует ещё одного перезапуска.
WEB_PROFILES_STEP=32

web_profiles_limit() {
    local _n; _n=$(web_profile_count)
    [ "${_n:-0}" -le "$WEB_PROFILES_STEP" ] && { echo "$WEB_PROFILES_STEP"; return 0; }
    echo $(( ( (_n + WEB_PROFILES_STEP - 1) / WEB_PROFILES_STEP ) * WEB_PROFILES_STEP ))
}

# Слепок таблицы [web.limits] из конфига движка. Она process-owned: если
# слепок изменился, SIGHUP её не применит и нужен полный перезапуск.
web_limits_fingerprint() {
    local _f; _f=$(engine_config_path 2>/dev/null) || return 0
    [ -f "$_f" ] || return 0
    awk '
        /^[[:space:]]*\[web\.limits\][[:space:]]*$/ { inl=1; next }
        /^[[:space:]]*\[/ { inl=0 }
        inl && NF { gsub(/[[:space:]]/, ""); print }
    ' "$_f" | sort | tr '\n' ';'
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

    printf '\n[web]\nenabled = true\ncarrier = "%s"\n' "${WEB_CARRIER:-websocket}"
    printf '\n[web.debug]\nenabled = %s\n' "$([ "${WEB_DEBUG:-false}" = "true" ] && echo true || echo false)"
    printf '\n[[web.vhosts]]\nhost = "%s"\npublic_addr = "%s"\n' "$_domain" "$_addr"
    printf '\n[web.vhosts.decoy]\n'
    _web_decoy_toml
    # vhost без профилей движок не примет, и он не стартует вовсе — сказать
    # об этом надо здесь, а не в логах падения.
    _web_profiles_toml || log_warn "WEB: нет включённых пользователей — движок не примет vhost без профилей" >&2
    # Профилей больше, чем движок разрешает по умолчанию, — поднимаем лимит
    # сами, иначе он откажется стартовать с «WEB profiles exceed».
    local _lim; _lim=$(web_profiles_limit)
    [ "${_lim:-32}" -gt "$WEB_PROFILES_STEP" ] && printf '\n[web.limits]\nmax_profiles = %s\n' "$_lim"
    return 0
}

# ── Куски конфига nginx ───────────────────────────────────────

# Демультиплексор на публичном порту: по SNI отправляет наше имя в TLS-сервер
# WEB, а всё остальное — движку. proxy_protocol нужен обеим веткам, иначе
# бэкенды увидят вместо клиента loopback.
web_nginx_ipv6_available() {
    [ -s /proc/net/if_inet6 ]
}

web_nginx_stream_block() {
    # В split разводить нечего: у WEB свой порт, nginx слушает его напрямую.
    web_frontend_is_direct && return 0
    local _domain _port _listen6=""
    _domain=$(web_domain) || return 1
    _port="${PROXY_PORT:-443}"
    web_nginx_ipv6_available && _listen6="        listen [::]:${_port};"
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
${_listen6}
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
    local _domain _cert_dir _listen _realip=""
    _domain=$(web_domain) || return 1
    # Общий каталог приходит аргументом, но у WEB может быть свой сертификат.
    _cert_dir=$(web_cert_dir 2>/dev/null)
    [ -n "$_cert_dir" ] || _cert_dir="$1"
    if web_frontend_is_direct; then
        # Клиент приходит прямо в nginx, адрес виден и без PROXY-заголовка.
        _listen="listen ${WEB_PUBLIC_PORT:-443} ssl;"
        if web_nginx_ipv6_available; then
            _listen="${_listen}
        listen [::]:${WEB_PUBLIC_PORT:-443} ssl;"
        fi
    else
        _listen="listen 127.0.0.1:${WEB_TLS_PORT:-15444} ssl proxy_protocol;"
        _realip="set_real_ip_from 127.0.0.1;
        real_ip_header proxy_protocol;
"
    fi
    cat << NGX

    server {
        ${_listen}
        http2 on;
        server_name ${_domain};
        server_tokens off;

        ${_realip}
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

_web_prepare_frontend() {
    local _domain
    _domain=$(web_domain 2>/dev/null) || return 1
    [ -n "$_domain" ] || { log_error "WEB: домен не задан"; return 1; }

    if [ "${SELFMASK_ENABLED:-false}" != "true" ]; then
        SELFMASK_DOMAIN="$_domain"
        SELFMASK_CERT_MODE="letsencrypt"
    fi
    WEB_DECOY_DIR="${WEB_DECOY_DIR:-${SELFMASK_SITE_DIR}}"

    if engine_is_binary; then
        binengine_ensure_installed || return 1
    else
        build_telemt_image || return 1
    fi

    _selfmask_install_deps || return 1
    _selfmask_install_pq_nginx || return 1
    if ! web_frontend_is_direct && ! web_nginx_has_stream; then
        log_info "Для общей раскладки нужен nginx со stream — устанавливаем сборку MTProxyL..."
        _selfmask_install_pq_nginx nginx force || return 1
        web_nginx_has_stream || { log_error "Установленный nginx не поддерживает stream"; return 1; }
    fi
    if [ "${WEB_DECOY_MODE:-static_directory}" = "static_directory" ] \
       && [ ! -f "$(web_decoy_dir)/index.html" ]; then
        _selfmask_deploy_site || return 1
    fi
    return 0
}

_web_restore_runtime() {
    local _mode="$1" _enabled="$2" _was_running="${3:-true}"
    PROXY_MODE="$_mode"
    WEB_ENABLED="$_enabled"
    save_settings || true
    generate_telemt_config >/dev/null 2>&1 || true
    if [ "$_was_running" = "true" ]; then
        MTPROXYL_QUIET_LINKS="true" restart_proxy_container >/dev/null 2>&1 || true
    else
        stop_proxy_container >/dev/null 2>&1 || true
    fi
    if web_is_enabled || [ "${SELFMASK_ENABLED:-false}" = "true" ]; then
        _selfmask_configure_nginx >/dev/null 2>&1 || true
    else
        systemctl stop "${SELFMASK_PQ_SERVICE}" >/dev/null 2>&1 || true
    fi
}

_web_suspend_mtproto_fixes() {
    load_nft_settings 2>/dev/null || true
    if nft list table inet "${NFT_TABLE:-mtproxyl_limit}" &>/dev/null; then
        WEB_ONLY_PREV_NFT="true"
        systemctl disable --now "${NFT_SYSTEMD_UNIT}" >/dev/null 2>&1 || true
        remove_nft_rules >/dev/null 2>&1 || true
    fi
    if zapret2_in_effect 2>/dev/null; then
        WEB_ONLY_PREV_ZAPRET2="true"
        zapret2_stop >/dev/null 2>&1 || true
    fi
    save_settings || true
}

_web_resume_mtproto_fixes() {
    load_nft_settings 2>/dev/null || true
    if [ "${WEB_ONLY_PREV_NFT:-false}" = "true" ]; then
        apply_nft_rules >/dev/null 2>&1 && install_nft_service >/dev/null 2>&1 || \
            log_warn "SYN-лимитер не удалось вернуть автоматически"
    fi
    if [ "${WEB_ONLY_PREV_ZAPRET2:-false}" = "true" ]; then
        zapret2_start_existing >/dev/null 2>&1 || log_warn "Zapret2 не удалось вернуть автоматически"
    fi
    WEB_ONLY_PREV_NFT="false"
    WEB_ONLY_PREV_ZAPRET2="false"
    save_settings || true
}

# Порядок важен: пока движок держит публичный порт, nginx на него не сядет.
# Поэтому сначала уводим движок на loopback и только потом поднимаем nginx.
web_enable() {
    if web_is_reanimator; then
        log_error "В режиме реаниматора конфигом владеет цель — WEB включает её хозяин"
        log_info "Мы покажем состояние и соберём ссылки: mtproxyl web status, mtproxyl web links"
        return 1
    fi
    if _superexpert_active; then
        log_error "В режиме супер эксперта transport задаётся в пользовательском конфиге"
        return 1
    fi
    local _old_mode="${1:-${PROXY_MODE:-mtproto}}" _old_enabled="${2:-${WEB_ENABLED:-false}}"
    local _old_running="${3:-}"
    [ -n "$_old_running" ] || { is_proxy_running && _old_running="true" || _old_running="false"; }
    if [ "$_old_enabled" != "true" ] && [ "$_old_mode" != "mtproto" ]; then
        _old_mode="mtproto"
    fi
    [ "${PROXY_MODE:-mtproto}" = "mtproto" ] && PROXY_MODE="combined"
    WEB_ENABLED="true"

    _web_prepare_frontend || {
        _web_restore_runtime "$_old_mode" "$_old_enabled" "$_old_running"
        return 1
    }

    local _problems
    _problems=$(web_preflight_problems "$_old_enabled")
    if [ -n "$_problems" ]; then
        log_error "WEB Proxy включить нельзя:"
        printf '%s' "$_problems" | sed 's/^/    • /'
        _web_restore_runtime "$_old_mode" "$_old_enabled" "$_old_running"
        return 1
    fi

    web_warn_zapret2

    save_settings || return 1

    log_info "Выпуск сертификата с WEB-доменом $(web_domain)..."
    _selfmask_obtain_cert || {
        _web_restore_runtime "$_old_mode" "$_old_enabled" "$_old_running"
        return 1
    }
    [ "${SELFMASK_CERT_MODE:-letsencrypt}" = "letsencrypt" ] && _selfmask_setup_renewal || true

    if web_is_only_mode; then
        log_info "WEB listener запускается на loopback, nginx займёт порт $(web_public_port)..."
    elif web_layout_is_split; then
        log_info "Прокси остаётся на порту ${PROXY_PORT:-443}, WEB займёт $(web_public_port)..."
    else
        log_info "Движок уходит с порта ${PROXY_PORT:-443} на loopback..."
    fi
    generate_telemt_config || {
        _web_restore_runtime "$_old_mode" "$_old_enabled" "$_old_running"
        return 1
    }
    load_secrets
    # До настройки nginx движок сидит на loopback, и его ссылки сейчас нерабочие.
    MTPROXYL_QUIET_LINKS="true" restart_proxy_container || true
    # Молча продолжать нельзя: nginx сел бы на 443 перед мёртвым движком.
    if ! is_proxy_running; then
        log_error "Движок не поднялся с WEB-конфигом — откатываем"
        _web_restore_runtime "$_old_mode" "$_old_enabled" "$_old_running"
        return 1
    fi

    log_info "Настройка nginx на публичном порту..."
    if ! _selfmask_configure_nginx || ! systemctl restart "${SELFMASK_PQ_SERVICE}" &>/dev/null; then
        log_error "nginx не поднялся — возвращаем прежний режим"
        _web_restore_runtime "$_old_mode" "$_old_enabled" "$_old_running"
        return 1
    fi

    _web_reapply_geoblock
    log_success "WEB Proxy включён: $(web_domain), carrier ${WEB_CARRIER}"
    _web_enable_links_tail
}

# Итог включения — именно WEB-ссылки: обычные не менялись, а показывать их
# вместо новых значит не показать результат операции вовсе.
_web_enable_links_tail() {
    echo ""
    draw_header "ССЫЛКИ WEB PROXY (${WEB_SECRET_MODE:-dd})"
    web_links_print || return 0
    echo -e "  ${DIM}Порта в ссылке нет: клиент WEB ходит только на 443.${NC}"
    if web_is_only_mode; then
        echo -e "  ${DIM}Обычный MTProto отключён; работают только ссылки WEB.${NC}"
    elif web_layout_is_split; then
        echo -e "  ${DIM}Обычные ссылки не изменились, прокси остался на порту ${PROXY_PORT:-443}:${NC}"
    else
        echo -e "  ${DIM}Обычные ссылки не изменились, порт ${PROXY_PORT:-443} у них общий с WEB:${NC}"
    fi
    echo -e "  ${DIM}mtproxyl secret link${NC}"
    echo ""
}

# Обратный порядок: сначала снимаем nginx с публичного порта, иначе движок
# не сможет его занять обратно.
web_disable() {
    web_is_reanimator && { log_error "В режиме реаниматора WEB выключает хозяин конфига цели"; return 1; }
    web_is_enabled || { log_info "WEB Proxy и так выключен"; return 0; }
    if web_is_only_mode; then
        log_error "WEB нельзя выключить в режиме «Только WEB»: движок останется без транспорта"
        log_info "Сначала переключите режим: mtproxyl web mode combined"
        return 1
    fi

    PROXY_MODE="mtproto"
    WEB_ENABLED="false"
    save_settings || return 1

    log_info "Снятие nginx с порта $(web_public_port)..."
    if [ "${SELFMASK_ENABLED:-false}" = "true" ]; then
        _selfmask_configure_nginx || return 1
    else
        systemctl stop "${SELFMASK_PQ_SERVICE}" &>/dev/null || true
    fi

    log_info "Перестройка конфига движка..."
    generate_telemt_config || return 1
    # Безусловно: движок мог упасть в цикл рестарта и is_proxy_running врёт.
    load_secrets
    restart_proxy_container || true

    _web_reapply_geoblock
    log_success "WEB Proxy выключен"
}

web_set_proxy_mode() {
    web_is_reanimator && { log_error "Режим транспорта настраивает хозяин цели"; return 1; }
    _superexpert_active && {
        log_error "В режиме супер эксперта transport задаётся в пользовательском конфиге"
        return 1
    }
    local _new="$1"
    case "$_new" in
        web|combined) ;;
        *) log_error "Режим: web или combined"; return 1 ;;
    esac
    [ "${PROXY_MODE:-mtproto}" = "$_new" ] && web_is_enabled && {
        log_info "Уже выбран режим: $(proxy_transport_mode_title)"; return 0; }

    local _old_mode="${PROXY_MODE:-mtproto}" _old_enabled="${WEB_ENABLED:-false}" _old_running="false"
    is_proxy_running && _old_running="true"
    PROXY_MODE="$_new"
    WEB_ENABLED="true"
    if web_enable "$_old_mode" "$_old_enabled" "$_old_running"; then
        if [ "$_new" = "web" ]; then
            _web_suspend_mtproto_fixes
        else
            _web_resume_mtproto_fixes
        fi
        log_success "Режим переключён: $(proxy_transport_mode_title)"
        return 0
    fi
    return 1
}

_web_reapply_geoblock() {
    [ -n "${BLOCKLIST_COUNTRIES:-}" ] || return 0
    geoblock_remove_all >/dev/null 2>&1 || true
    if geoblock_reapply_all >/dev/null 2>&1; then
        log_success "Гео-блокировка переприменена на порты: $(geoblock_ports_label)"
    else
        log_warn "Гео-блокировку переприменить не удалось: mtproxyl geoblock reapply"
    fi
}

# В реаниматоре WEB живёт в конфиге цели, и наши WEB_* к нему не относятся:
# панель и бот, читая их, показывали WEB выключенным при работающем WEB у цели
# и наоборот. Отдаём то, что в конфиге цели, а раскладка портов там не наша.
_web_status_json_target() {
    local _en="false" _host="" _mode=""
    if web_target_enabled 2>/dev/null; then
        _en="true"
        _host=$(web_target_host 2>/dev/null)
        _mode=$(_web_target_secret_mode 2>/dev/null)
    fi
    printf '{"enabled":%s,"proxy_mode":"target","mtproto_enabled":true,"layout":"target","public_port":%s,"domain":"%s","carrier":"","secret_mode":"%s","public_addr":"","listen_port":0,"tls_port":0,"mtproxy_port":0,"decoy_mode":"","decoy_dir":"","debug":false,"problems":"","owner":"target"}\n' \
        "$_en" "${DETECTED_PORT:-443}" "$(json_escape "$_host")" "$(json_escape "$_mode")"
}

# В менеджере профили пересобираются вместе со всем конфигом, у цели правим
# только их: остальное в чужом файле не наше.
web_sync_profiles() {
    if web_is_reanimator; then
        web_target_sync_profiles || return 1
        # Цель чужая, и перезапускать её из-за профилей мы не спрашиваем и не
        # делаем: панель зовёт эту команду на создание пользователя, а рвать
        # всем соединения по такому поводу нельзя. Если движок не подхватит
        # сам — скажем, что нужен перезапуск, и решать будет хозяин.
        if is_proxy_running 2>/dev/null && ! _target_users_hot_applied 2>/dev/null; then
            log_info "Цель не применила профили на ходу — нужен её перезапуск: mtproxyl restart"
        fi
        return 0
    fi
    web_is_enabled || { log_info "WEB Proxy выключен — синхронизировать нечего"; return 0; }
    reload_proxy_config || return 1
    log_success "Профили WEB пересобраны: $(web_profile_count) шт."
}

web_status_json() {
    web_is_reanimator && { _web_status_json_target; return 0; }
    local _d _addr _problems
    _d=$(web_domain 2>/dev/null)
    _addr=$(web_public_addr 2>/dev/null)
    _problems=$(web_preflight_problems 2>/dev/null | tr '\n' ';')
    printf '{"enabled":%s,"proxy_mode":"%s","mtproto_enabled":%s,"layout":"%s","public_port":%s,"domain":"%s","carrier":"%s","secret_mode":"%s","public_addr":"%s","listen_port":%s,"tls_port":%s,"mtproxy_port":%s,"decoy_mode":"%s","decoy_dir":"%s","debug":%s,"problems":"%s"}\n' \
        "$(web_is_enabled && echo true || echo false)" \
        "$(json_escape "${PROXY_MODE:-mtproto}")" "$(mtproto_is_enabled && echo true || echo false)" \
        "$(json_escape "$([ "${PROXY_MODE:-mtproto}" = web ] && echo web || echo "${WEB_LAYOUT:-shared}")")" "$(web_public_port)" \
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
    local _p="" _d _ft _already="${1:-${WEB_ENABLED:-false}}"
    _d=$(web_domain 2>/dev/null)
    _ft=$(web_faketls_domain 2>/dev/null)
    [ -n "$_d" ] || _p+="не задан домен: нужен свой FQDN с сертификатом"$'\n'
    if [ "${SELFMASK_ENABLED:-false}" = "true" ] \
       && [ "${SELFMASK_CERT_MODE:-letsencrypt}" = "selfsigned" ]; then
        _p+="WEB требует доверенный сертификат — переключите Selfmask на Let's Encrypt либо отключите его"$'\n'
    fi
    # В shared совпадение имён увело бы FakeTLS-клиентов в nginx: по SNI они
    # неотличимы. В split порты разные, и совпадение никому не мешает.
    if mtproto_is_enabled && ! web_layout_is_split && [ -n "$_d" ] && [ "$_d" = "$_ft" ]; then
        _p+="домен WEB совпадает с доменом маскировки ${_ft} — в раскладке shared нужны разные имена"$'\n'
    fi
    # Сверяем с адресом сервера, а не с самим доменом: без этого проверка
    # проходила всегда, а Let's Encrypt потом упирался в неподтверждаемый домен.
    if [ -n "$_d" ]; then
        local _dip _sip
        _dip=$(web_domain_ip 2>/dev/null)
        _sip=$(web_server_ip 2>/dev/null)
        if [ -z "$_sip" ]; then
            _p+="не удалось определить публичный адрес сервера — задайте его: mtproxyl ip set <IP>"$'\n'
        elif [ -z "$_dip" ]; then
            _p+="у домена ${_d} нет A-записи — заведите её у регистратора на ${_sip}"$'\n'
        elif [ "$_dip" != "$_sip" ]; then
            _p+="A-запись ${_d} ведёт на ${_dip}, а сервер — ${_sip}: исправьте её у регистратора на ${_sip} (если домен за прокси CDN, отключите проксирование)"$'\n'
        fi
    fi
    if [ "${WEB_DECOY_MODE:-static_directory}" = "static_directory" ]; then
        [ -d "$(web_decoy_dir)" ] || _p+="каталог сайта-заглушки не найден: $(web_decoy_dir)"$'\n'
    else
        [ -n "${WEB_DECOY_UPSTREAM:-}" ] || _p+="не задан upstream для заглушки"$'\n'
    fi
    web_port_is_443 || _p+="публичный порт WEB $(web_public_port), а клиент ходит туда только на 443"$'\n'
    web_public_addr >/dev/null 2>&1 || _p+="не определён публичный IP"$'\n'
    if [ "$_already" = "true" ] && ! web_frontend_is_direct && ! web_nginx_has_stream; then
        _p+="nginx активного WEB не поддерживает stream — примените WEB заново: mtproxyl web enable"$'\n'
    fi
    if mtproto_is_enabled && web_layout_is_split && [ "${PROXY_PORT:-443}" = "$(web_public_port)" ]; then
        _p+="в раскладке split у прокси и WEB должны быть разные порты, сейчас оба ${PROXY_PORT}"$'\n'
    fi
    web_engine_supports || _p+="движок $(engine_current_version 2>/dev/null) не умеет WEB, нужен ${WEB_MIN_ENGINE_VERSION} или новее"$'\n'
    # У каждого vhost должен быть хотя бы один профиль, а профиль — это
    # включённый пользователь с уникальным секретом.
    local _pn; _pn=$(web_profile_count 2>/dev/null)
    if [ "${_pn:-0}" -eq 0 ]; then
        _p+="нет включённых пользователей — vhost без профилей движок не примет"$'\n'
    else
        # Свой лимит мы поднимаем сами, но экспертный оверрайд главнее, и
        # заниженное значение роняет движок на старте.
        local _pl; _pl=$(get_expert_override_value web.limits max_profiles 2>/dev/null)
        if [ -n "$_pl" ] && [ "$_pn" -gt "$_pl" ]; then
            _p+="пользователей ${_pn}, а web.limits.max_profiles = ${_pl} — движок откажется стартовать"$'\n'
        fi
    fi
    # При повторном применении наши же порты заняты нами — это не помеха.
    if [ "$_already" != "true" ]; then
        local _busy; _busy=$(web_busy_ports)
        [ -z "$_busy" ] || _p+="порты уже заняты: ${_busy} — смените их через mtproxyl web set"$'\n'
    fi
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
    local _p _busy="" _ports
    if web_frontend_is_direct; then
        _ports="${WEB_LISTEN_PORT:-15080} $(web_public_port)"
    else
        _ports="${WEB_MTPROXY_PORT:-15443} ${WEB_LISTEN_PORT:-15080} ${WEB_TLS_PORT:-15444}"
    fi
    for _p in $_ports; do
        local _who; _who=$(ss -lntp "sport = :${_p}" 2>/dev/null | grep LISTEN)
        [ -n "$_who" ] || continue
        # Свои же процессы помехой не считаем: после неудачного включения
        # nginx или движок могли остаться на приватном порту, и порт числился
        # занятым навсегда — кнопка «Включить» больше не срабатывала.
        case "$_who" in
            *nginx*|*telemt*|*mtproxyl*|*docker-proxy*) continue ;;
        esac
        _busy+="${_p} "
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

# В реаниматоре конфигом владеет цель: мы ничего не настраиваем, только
# показываем, что там поднято, и отдаём ссылки.
web_is_reanimator() { [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; }

_web_status_print_target() {
    echo ""
    echo -e "  ${BOLD}🌐 WEB Proxy у цели${NC}"
    echo -e "  ──────────────────────────────────────────────"
    if web_target_enabled; then
        echo -e "   🟢 Состояние        ${GREEN}включён в конфиге цели${NC}"
        echo -e "   🔗 Домен            $(web_target_host 2>/dev/null || echo '—')"
        local _u _m _n=0
        while IFS='|' read -r _u _m; do
            [ -n "$_u" ] || continue
            [ "$_n" -eq 0 ] && echo -e "   👤 Профили:"
            echo -e "      ${_u} ${DIM}(${_m})${NC}"
            _n=$((_n + 1))
        done <<< "$(web_target_profiles)"
        [ "$_n" -gt 0 ] || echo -e "   ${YELLOW}профилей нет — ссылки не построить${NC}"
    else
        echo -e "   🔴 Состояние        ${DIM}в конфиге цели не включён${NC}"
    fi
    echo ""
    echo -e "  ${DIM}Конфигом владеет цель: включает и настраивает WEB её хозяин.${NC}"
    echo -e "  ${DIM}MTProxyL показывает состояние и собирает ссылки: mtproxyl web links${NC}"
    echo ""
}

web_status_print() {
    web_is_reanimator && { _web_status_print_target; return 0; }
    echo ""
    echo -e "  ${BOLD}🌐 WEB Proxy${NC}"
    echo -e "  ──────────────────────────────────────────────"
    if web_is_enabled; then
        echo -e "   🟢 Состояние        ${GREEN}включён${NC}"
    else
        echo -e "   🔴 Состояние        ${DIM}выключен${NC}"
    fi
    echo -e "   🧩 Режим            $(proxy_transport_mode_title)"
    echo -e "   🔗 Домен            $(web_domain 2>/dev/null || echo '—')"
    if mtproto_is_enabled; then
        echo -e "   🎭 Домен маскировки $(web_faketls_domain 2>/dev/null || echo '—')"
    fi
    echo -e "   🚚 Carrier          ${WEB_CARRIER:-—}"
    echo -e "   🔑 Режим секрета    ${WEB_SECRET_MODE:-—}"
    echo -e "   📍 public_addr      $(web_public_addr 2>/dev/null || echo '—')"
    if web_is_only_mode; then
        echo -e "   🧭 Раскладка        ${BOLD}WEB-only${NC} — без обычного MTProto"
        echo -e "   🪟 Порты            nginx :$(web_public_port) → WEB :${WEB_LISTEN_PORT:-15080}"
    elif web_layout_is_split; then
        echo -e "   🧭 Раскладка        ${BOLD}split${NC} — свой порт у WEB"
        echo -e "   🪟 Порты            nginx :$(web_public_port) → WEB :${WEB_LISTEN_PORT:-15080}, прокси :${PROXY_PORT:-443} напрямую"
    else
        echo -e "   🧭 Раскладка        ${BOLD}shared${NC} — один порт, разбор по SNI"
        echo -e "   🪟 Порты            nginx :${PROXY_PORT:-443} → движок :${WEB_MTPROXY_PORT:-15443}, WEB :${WEB_LISTEN_PORT:-15080}"
    fi
    echo -e "   🕸  Заглушка         $(web_decoy_dir)"
    if web_zapret2_hurts 2>/dev/null; then
        echo -e "   ⚠️  Zapret2          ${YELLOW}режет скорость на ${WEB_CARRIER}${NC} — возьмите websocket"
    fi
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
    if web_is_reanimator; then
        web_target_enabled || { log_warn "У цели WEB Proxy не включён"; return 1; }
        local _u _m _l _k=0
        echo ""
        while IFS='|' read -r _u _m; do
            [ -n "$_u" ] || continue
            _l=$(web_target_link "$_u") || continue
            echo -e "  ${BOLD}${_u}${NC}"
            echo -e "  ${CYAN}${_l}${NC}\n"
            _k=$((_k + 1))
        done <<< "$(web_target_profiles)"
        [ "$_k" -gt 0 ] || { log_warn "Не удалось собрать ни одной ссылки"; return 1; }
        return 0
    fi
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
        json)    load_secrets 2>/dev/null; web_status_json ;;
        enable)  check_root; load_secrets; web_enable ;;
        disable) check_root; load_secrets; web_disable ;;
        mode)    check_root; load_secrets; web_set_proxy_mode "${1:-}" ;;
        links)   load_secrets; web_links_print ;;
        sync)    check_root; load_secrets; web_sync_profiles ;;
        nginx-config) handle_nginx_custom_command "$@" ;;
        set)     check_root; web_set_param "${1:-}" "${2:-}" ;;
        settable) web_settable_json ;;
        *)
            echo -e "  ${BOLD}WEB Proxy:${NC}"
            echo -e "    ${GREEN}web status${NC}    Статус"
            echo -e "    ${GREEN}web enable${NC}    Включить"
            echo -e "    ${GREEN}web disable${NC}   Выключить"
            echo -e "    ${GREEN}web mode${NC} web|combined  Переключить транспорт"
            echo -e "    ${GREEN}web links${NC}     Ссылки tg://webproxy"
            echo -e "    ${GREEN}web sync${NC}      Свести профили WEB со списком пользователей"
            echo -e "    ${GREEN}web nginx-config${NC} Управление пользовательским nginx.conf"
            echo -e "    ${GREEN}web set${NC} K V    Изменить параметр"
            echo -e "    ${GREEN}web json${NC}      Статус в JSON"
            ;;
    esac
}

# Формат как в каталогах NFT и Selfmask: КЛЮЧ|валидатор|описание.
_WEB_SETTABLE=(
    "WEB_LAYOUT|enum:shared,split|shared — один порт с FakeTLS по SNI, split — свой порт"
    "WEB_PUBLIC_PORT|range:1:65535|Публичный порт WEB в раскладке split"
    "WEB_DOMAIN|custom:_validate_web_domain|Публичный домен WEB Proxy"
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
    if [ -z "$_v" ]; then
        [ "${SELFMASK_ENABLED:-false}" = "true" ] && [ -n "${SELFMASK_DOMAIN:-}" ] && return 0
        echo "без Selfmask домен WEB обязателен" >&2
        return 1
    fi
    [[ "$_v" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]] || {
        echo "не похоже на доменное имя" >&2; return 1; }
    web_is_only_mode || web_layout_is_split || [ "$_v" != "$(web_faketls_domain)" ] || {
        echo "совпадает с доменом маскировки, а в раскладке shared их различают по SNI" >&2; return 1; }
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

# Короткая строка для шапки главного меню.
web_status_line() {
    if web_is_enabled; then
        echo -e "${GREEN}включён${NC} ($(web_domain 2>/dev/null), $(proxy_transport_mode_title))"
    else
        echo -e "${DIM}выключен${NC}"
    fi
}

# ── Реаниматор: WEB в чужом конфиге ───────────────────────────
# Конфигом владеет пользователь, поэтому мы ничего не настраиваем — только
# читаем, что он поднял, и помогаем достать ссылку.

web_target_enabled() {
    local _f="${DETECTED_CONFIG_PATH:-}"
    [ -f "$_f" ] || return 1
    [ "$(_toml_get_string_in_section "web" "enabled" "$_f" 2>/dev/null)" = "true" ]
}

# Первый vhost: host лежит в [[web.vhosts]], до вложенных таблиц decoy/profiles.
web_target_host() {
    local _f="${DETECTED_CONFIG_PATH:-}"
    [ -f "$_f" ] || return 1
    awk '
        /^[[:space:]]*\[\[web\.vhosts\]\][[:space:]]*$/ { inv=1; next }
        /^[[:space:]]*\[/ { if (inv) inv=0 }
        inv && /^[[:space:]]*host[[:space:]]*=/ {
            line=$0; sub(/^[^=]*=[[:space:]]*/, "", line)
            gsub(/^"|"[[:space:]]*$/, "", line); print line; exit
        }' "$_f"
}

# Пары «пользователь|secret_mode» из [[web.vhosts.profiles]].
web_target_profiles() {
    local _f="${DETECTED_CONFIG_PATH:-}"
    [ -f "$_f" ] || return 1
    awk '
        /^[[:space:]]*\[\[web\.vhosts\.profiles\]\][[:space:]]*$/ {
            if (u != "") print u "|" (m == "" ? "dd" : m)
            inp=1; u=""; m=""; next
        }
        /^[[:space:]]*\[/ { if (inp) { if (u != "") print u "|" (m == "" ? "dd" : m); inp=0; u=""; m="" } }
        inp {
            line=$0; sub(/^[[:space:]]+/, "", line)
            if (line ~ /^user[[:space:]]*=/)        { sub(/^[^=]*=[[:space:]]*/, "", line); gsub(/"/, "", line); u=line }
            if (line ~ /^secret_mode[[:space:]]*=/) { sub(/^[^=]*=[[:space:]]*/, "", line); gsub(/"/, "", line); m=line }
        }
        END { if (u != "") print u "|" (m == "" ? "dd" : m) }' "$_f"
}

# Движок не заводит профиль WEB вместе с пользователем — ни через конфиг, ни
# через /v1/users. Без профиля у нового пользователя не будет WEB-ссылки, а
# профиль без пользователя делает конфиг невалидным: держим их в паре.

# secret_mode берём у уже заведённых профилей, чтобы не смешивать представления.
_web_target_secret_mode() {
    local _u _m
    while IFS='|' read -r _u _m; do
        [ -n "$_m" ] && { printf '%s' "$_m"; return 0; }
    done <<< "$(web_target_profiles 2>/dev/null)"
    printf 'dd'
}

web_target_has_profile() {
    local _label="$1" _u _m
    while IFS='|' read -r _u _m; do
        [ "$_u" = "$_label" ] && return 0
    done <<< "$(web_target_profiles 2>/dev/null)"
    return 1
}

# Блок дописывается в конец файла: массив таблиц привязывается к последнему
# объявленному [[web.vhosts]], где бы он ни стоял выше.
web_target_add_profile() {
    local _label="$1" _f="${DETECTED_CONFIG_PATH:-}"
    web_target_enabled || return 0
    [ -n "$_label" ] && [ -f "$_f" ] || return 0
    web_target_has_profile "$_label" && return 0

    printf '\n[[web.vhosts.profiles]]\nuser = "%s"\nsecret_mode = "%s"\n' \
        "$_label" "$(_web_target_secret_mode)" >> "$_f" || {
        log_warn "Не удалось добавить WEB-профиль для '${_label}' — ссылки WEB у него не будет"
        return 1
    }
    log_success "WEB-профиль для '${_label}' добавлен в конфиг цели"

    # max_profiles применяется только перезапуском, и заниженный лимит роняет
    # движок на старте — сказать об этом надо здесь, а не в логах падения.
    local _n _lim
    _n=$(web_target_profiles 2>/dev/null | grep -c .)
    _lim=$(_toml_get_string_in_section "web.limits" "max_profiles" "$_f" 2>/dev/null)
    [ -n "$_lim" ] || _lim=32
    if [ "${_n:-0}" -gt "${_lim:-32}" ]; then
        log_warn "Профилей WEB ${_n}, а web.limits.max_profiles = ${_lim} — цель не стартует"
        log_info "Поднимите лимит в её конфиге: [web.limits] max_profiles = $(( ((_n + 31) / 32) * 32 ))"
    fi
}

# Профиль, ссылающийся на удалённого пользователя, движок конфигом не примет.
web_target_remove_profile() {
    local _label="$1" _f="${DETECTED_CONFIG_PATH:-}"
    [ -n "$_label" ] && [ -f "$_f" ] || return 0
    web_target_has_profile "$_label" || return 0

    local _tmp; _tmp=$(_mktemp "$(dirname "$_f")") || return 1
    awk -v u="$_label" '
        /^[[:space:]]*\[\[web\.vhosts\.profiles\]\][[:space:]]*$/ {
            if (n > 0 && !drop) for (i = 1; i <= n; i++) print buf[i]
            n = 1; buf[1] = $0; inp = 1; drop = 0; next
        }
        /^[[:space:]]*\[/ {
            if (inp) { if (!drop) for (i = 1; i <= n; i++) print buf[i]; inp = 0; n = 0 }
            print; next
        }
        inp {
            n++; buf[n] = $0
            line = $0; sub(/^[[:space:]]+/, "", line)
            if (line ~ /^user[[:space:]]*=/) {
                sub(/^[^=]*=[[:space:]]*/, "", line); gsub(/"/, "", line)
                if (line == u) drop = 1
            }
            next
        }
        { print }
        END { if (inp && !drop) for (i = 1; i <= n; i++) print buf[i] }
    ' "$_f" > "$_tmp" || { rm -f "$_tmp"; return 1; }

    cat "$_tmp" > "$_f" && rm -f "$_tmp" \
        && log_success "WEB-профиль '${_label}' убран из конфига цели"
}

# Приводит профили в соответствие со списком пользователей цели. Нужно, когда
# пользователя завели мимо нас — например панель в реаниматоре создаёт его
# через /v1/users движка, а тот профиль WEB не заводит.
web_target_sync_profiles() {
    web_target_enabled 2>/dev/null || { log_info "У цели WEB Proxy не включён — синхронизировать нечего"; return 0; }
    local _f="${DETECTED_CONFIG_PATH:-}"
    [ -f "$_f" ] || { log_error "Конфиг цели не найден"; return 1; }
    backup_target_config "web-profiles" "true" || true

    local _added=0 _removed=0 _st _lb _u _m
    local _users=" "
    while IFS='|' read -r _st _lb _; do
        [ -n "$_lb" ] || continue
        _users+="${_lb} "
    done < <(_target_section_pairs "access.users" 2>/dev/null)

    while IFS='|' read -r _u _m; do
        [ -n "$_u" ] || continue
        case "$_users" in
            *" ${_u} "*) ;;
            *) web_target_remove_profile "$_u" >/dev/null 2>&1 && _removed=$((_removed + 1)) ;;
        esac
    done <<< "$(web_target_profiles 2>/dev/null)"

    for _lb in $_users; do
        web_target_has_profile "$_lb" && continue
        web_target_add_profile "$_lb" >/dev/null 2>&1 && _added=$((_added + 1))
    done

    log_success "Профили WEB у цели: добавлено ${_added}, снято ${_removed}"
}

# Ссылка для пользователя цели, если он заведён профилем WEB.
web_target_link() {
    local _label="$1" _host _u _m _raw
    web_target_enabled || return 1
    _host=$(web_target_host) || return 1
    [ -n "$_host" ] || return 1
    while IFS='|' read -r _u _m; do
        [ "$_u" = "$_label" ] || continue
        _raw=$(_target_user_secret "$_label" 2>/dev/null)
        [ -n "$_raw" ] || return 1
        printf 'tg://webproxy?server=%s&secret=%s%s\n' \
            "$_host" "$([ "$_m" = "dd" ] && echo dd)" "$_raw"
        return 0
    done <<< "$(web_target_profiles)"
    return 1
}
