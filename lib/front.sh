#!/bin/bash
# MTProxyL — держатель заглушки Selfmask и WEB: nginx, Caddy или HAProxy.
# nginx живёт в selfmask.sh; здесь выбор, Caddy и HAProxy. Все трое держат
# постквантовый обмен ключами X25519MLKEM768.

FRONT_CADDY_PREFIX="/opt/mtproxyl-caddy"
FRONT_CADDY_SERVICE="mtproxyl-caddy.service"
FRONT_CADDY_VERSION="2.11.7"
FRONT_CADDY_RELEASE_TAG="caddy-${FRONT_CADDY_VERSION}-l4-r1"
FRONT_HAPROXY_PREFIX="/opt/mtproxyl-haproxy"
FRONT_HAPROXY_SERVICE="mtproxyl-haproxy.service"
FRONT_HAPROXY_VERSION="3.2.25"
FRONT_HAPROXY_OPENSSL_VERSION="3.5.7"
FRONT_HAPROXY_RELEASE_TAG="haproxy-${FRONT_HAPROXY_VERSION}-openssl${FRONT_HAPROXY_OPENSSL_VERSION}-r2"
FRONT_STATIC_SERVICE="mtproxyl-static.service"
FRONT_STATIC_PORT="15481"
FRONT_CADDY_CUSTOM_FILE="${INSTALL_DIR:-/opt/mtproxyl}/caddy-custom.Caddyfile"
FRONT_HAPROXY_CUSTOM_FILE="${INSTALL_DIR:-/opt/mtproxyl}/haproxy-custom.cfg"
# Caddy не умеет reload без своего admin API — даём ему сокет, а не порт.
FRONT_CADDY_ADMIN="/run/mtproxyl-caddy/admin.sock"

front_server() {
    case "${FRONT_SERVER:-nginx}" in
        caddy|haproxy) echo "$FRONT_SERVER" ;;
        *) echo "nginx" ;;
    esac
}

front_is() { [ "$(front_server)" = "$1" ]; }

front_title() {
    case "${1:-$(front_server)}" in
        caddy)   echo "Caddy" ;;
        haproxy) echo "HAProxy" ;;
        *)       echo "nginx" ;;
    esac
}

front_service() {
    case "${1:-$(front_server)}" in
        caddy)   echo "$FRONT_CADDY_SERVICE" ;;
        haproxy) echo "$FRONT_HAPROXY_SERVICE" ;;
        *)       echo "${SELFMASK_PQ_SERVICE:-mtproxyl-pq-nginx.service}" ;;
    esac
}

# Все юниты держателя: у HAProxy ещё раздатчик файлов.
front_units() {
    case "${1:-$(front_server)}" in
        haproxy) echo "$FRONT_HAPROXY_SERVICE $FRONT_STATIC_SERVICE" ;;
        *)       front_service "$1" ;;
    esac
}

front_is_active() { systemctl is-active "$(front_service)" &>/dev/null; }

front_stop() {
    local _u
    for _u in $(front_units "${1:-}"); do systemctl stop "$_u" &>/dev/null || true; done
}

# Держатель один: остальные снимаем, иначе они займут те же порты.
front_stop_others() {
    local _f _u _cur; _cur=$(front_server)
    for _f in nginx caddy haproxy; do
        [ "$_f" = "$_cur" ] && continue
        for _u in $(front_units "$_f"); do
            systemctl is-enabled "$_u" &>/dev/null || systemctl is-active "$_u" &>/dev/null || continue
            systemctl disable --now "$_u" &>/dev/null || true
        done
    done
}

front_custom_file() {
    case "${1:-$(front_server)}" in
        caddy)   echo "$FRONT_CADDY_CUSTOM_FILE" ;;
        haproxy) echo "$FRONT_HAPROXY_CUSTOM_FILE" ;;
        *)       echo "${NGINX_CUSTOM_FILE:-${INSTALL_DIR:-/opt/mtproxyl}/nginx-custom.conf}" ;;
    esac
}

front_generated_conf() {
    case "${1:-$(front_server)}" in
        caddy)   echo "${FRONT_CADDY_PREFIX}/conf/Caddyfile" ;;
        haproxy) echo "${FRONT_HAPROXY_PREFIX}/conf/haproxy.cfg" ;;
        *)       _selfmask_generated_pq_conf ;;
    esac
}

front_active_conf() {
    if [ "${NGINX_CUSTOM_ENABLED:-false}" = "true" ]; then front_custom_file; else front_generated_conf; fi
}

_front_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) return 1 ;;
    esac
}

# ── Caddy ─────────────────────────────────────────────────────

# Общему :443 нужен layer4 (разбор SNI без расшифровки) — в обычном Caddy
# его нет. Системный годится, только если его собрали с этим модулем.
_front_system_caddy_ok() {
    local _bin; _bin=$(command -v caddy 2>/dev/null) || return 1
    "$_bin" list-modules 2>/dev/null | grep -q '^layer4$' || return 1
    local _v; _v=$("$_bin" version 2>/dev/null | grep -oE '^v[0-9]+\.[0-9]+\.[0-9]+' | tr -d v)
    # X25519MLKEM768 включён по умолчанию с 2.10 (Go 1.24).
    [ -n "$_v" ] && _version_ge "$_v" "2.10.0"
}

_front_caddy_bin() {
    if [ -x "${FRONT_CADDY_PREFIX}/bin/caddy" ]; then
        echo "${FRONT_CADDY_PREFIX}/bin/caddy"
    elif _front_system_caddy_ok; then
        command -v caddy
    else
        echo "${FRONT_CADDY_PREFIX}/bin/caddy"
    fi
}

_front_download() {
    local _tag="$1" _asset="$2" _dest="$3"
    curl -fsSL --max-time 300 \
        "https://github.com/${GITHUB_REPO}/releases/download/${_tag}/${_asset}" -o "$_dest" 2>/dev/null
}

_front_install_caddy() {
    if [ "${1:-}" != "force" ] && { [ -x "${FRONT_CADDY_PREFIX}/bin/caddy" ] || _front_system_caddy_ok; }; then
        log_success "Caddy: $(_front_caddy_source)"
    else
        local _arch _tmp
        _arch=$(_front_arch) || { log_error "Архитектура $(uname -m) не поддерживается"; return 1; }
        _tmp=$(mktemp) || return 1
        log_info "Скачивание Caddy ${FRONT_CADDY_VERSION} с layer4..."
        if ! _front_download "$FRONT_CADDY_RELEASE_TAG" \
                "mtproxyl-caddy-${FRONT_CADDY_VERSION}-l4-linux-${_arch}.tar.gz" "$_tmp"; then
            rm -f "$_tmp"
            log_error "Не удалось скачать Caddy (релиз ${FRONT_CADDY_RELEASE_TAG})"
            return 1
        fi
        rm -rf "${FRONT_CADDY_PREFIX}/bin"
        tar xzf "$_tmp" -C / || { rm -f "$_tmp"; log_error "Не удалось распаковать Caddy"; return 1; }
        rm -f "$_tmp"
        [ -x "${FRONT_CADDY_PREFIX}/bin/caddy" ] || { log_error "После распаковки caddy не найден"; return 1; }
        log_success "Caddy установлен: $("${FRONT_CADDY_PREFIX}/bin/caddy" version 2>/dev/null | awk '{print $1}')"
    fi
    mkdir -p "${FRONT_CADDY_PREFIX}/conf" /var/lib/mtproxyl-caddy /var/log/mtproxyl-caddy
}

_front_caddy_source() {
    if [ -x "${FRONT_CADDY_PREFIX}/bin/caddy" ]; then
        echo "сборка MTProxyL ($("${FRONT_CADDY_PREFIX}/bin/caddy" version 2>/dev/null | awk '{print $1}'), layer4)"
    elif _front_system_caddy_ok; then
        echo "системный $(caddy version 2>/dev/null | awk '{print $1}') с layer4"
    else
        echo "не установлен"
    fi
}

_front_caddy_unit() {
    local _bin _conf="$1"
    _bin=$(_front_caddy_bin)
    cat > "/etc/systemd/system/${FRONT_CADDY_SERVICE}" << EOF
[Unit]
Description=MTProxyL Caddy for selfmask and WEB
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
Environment=XDG_DATA_HOME=/var/lib/mtproxyl-caddy
Environment=XDG_CONFIG_HOME=/var/lib/mtproxyl-caddy
RuntimeDirectory=mtproxyl-caddy
RuntimeDirectoryPreserve=yes
ExecStartPre=${_bin} validate --config ${_conf} --adapter caddyfile
ExecStart=${_bin} run --config ${_conf} --adapter caddyfile
ExecReload=${_bin} reload --config ${_conf} --adapter caddyfile --address unix/${FRONT_CADDY_ADMIN} --force
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$FRONT_CADDY_SERVICE" &>/dev/null || true
}

_front_caddy_test() {
    local _conf="$1"
    XDG_DATA_HOME=/var/lib/mtproxyl-caddy XDG_CONFIG_HOME=/var/lib/mtproxyl-caddy \
        "$(_front_caddy_bin)" validate --config "$_conf" --adapter caddyfile 2>&1 \
        | grep -vE '"level":"(info|warn)"'
    return "${PIPESTATUS[0]}"
}

# ── HAProxy ───────────────────────────────────────────────────

_front_haproxy_openssl() {
    "$1" -vv 2>/dev/null | awk -F': ' '/^Running on (OpenSSL|SSL library) version/ { print $2; exit }' \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# Системный HAProxy годится, если и он, и его OpenSSL умеют ML-KEM:
# crt-store нужен с 3.0, X25519MLKEM768 — с OpenSSL 3.5.
_front_system_haproxy_ok() {
    local _bin _v _ssl; _bin=$(command -v haproxy 2>/dev/null) || return 1
    _v=$("$_bin" -v 2>/dev/null | grep -oE 'version [0-9]+\.[0-9]+' | awk '{print $2}')
    [ -n "$_v" ] && _version_ge "${_v}.0" "3.0.0" || return 1
    _ssl=$(_front_haproxy_openssl "$_bin")
    [ -n "$_ssl" ] && _version_ge "$_ssl" "${SELFMASK_MIN_SYSTEM_OPENSSL:-3.5.0}"
}

_front_haproxy_bin() {
    if [ -x "${FRONT_HAPROXY_PREFIX}/sbin/haproxy" ]; then
        echo "${FRONT_HAPROXY_PREFIX}/sbin/haproxy"
    elif _front_system_haproxy_ok; then
        command -v haproxy
    else
        echo "${FRONT_HAPROXY_PREFIX}/sbin/haproxy"
    fi
}

_front_static_bin() { echo "${FRONT_HAPROXY_PREFIX}/bin/mtproxyl-static"; }

_front_haproxy_source() {
    local _b; _b=$(_front_haproxy_bin)
    [ -x "$_b" ] || { echo "не установлен"; return 0; }
    local _v; _v=$("$_b" -v 2>/dev/null | grep -oE 'version [0-9.]+' | awk '{print $2}' | head -1)
    if [ "$_b" = "${FRONT_HAPROXY_PREFIX}/sbin/haproxy" ]; then
        echo "сборка MTProxyL (HAProxy ${_v}, OpenSSL $(_front_haproxy_openssl "$_b"))"
    else
        echo "системный HAProxy ${_v} (OpenSSL $(_front_haproxy_openssl "$_b"))"
    fi
}

_front_install_haproxy() {
    local _force="${1:-}" _arch _tmp
    _arch=$(_front_arch) || { log_error "Архитектура $(uname -m) не поддерживается"; return 1; }
    if [ "$_force" = "force" ] || { [ ! -x "${FRONT_HAPROXY_PREFIX}/sbin/haproxy" ] && ! _front_system_haproxy_ok; }; then
        _tmp=$(mktemp) || return 1
        log_info "Скачивание HAProxy ${FRONT_HAPROXY_VERSION} (OpenSSL ${FRONT_HAPROXY_OPENSSL_VERSION})..."
        if ! _front_download "$FRONT_HAPROXY_RELEASE_TAG" \
                "mtproxyl-haproxy-${FRONT_HAPROXY_VERSION}-openssl${FRONT_HAPROXY_OPENSSL_VERSION}-linux-${_arch}.tar.gz" "$_tmp"; then
            rm -f "$_tmp"
            log_error "Не удалось скачать HAProxy (релиз ${FRONT_HAPROXY_RELEASE_TAG})"
            return 1
        fi
        rm -rf "${FRONT_HAPROXY_PREFIX}/sbin" "${FRONT_HAPROXY_PREFIX}/bin"
        tar xzf "$_tmp" -C / || { rm -f "$_tmp"; log_error "Не удалось распаковать HAProxy"; return 1; }
        rm -f "$_tmp"
        [ -x "${FRONT_HAPROXY_PREFIX}/sbin/haproxy" ] || { log_error "После распаковки haproxy не найден"; return 1; }
    fi
    # Раздатчик файлов есть только в нашем архиве — при системном HAProxy
    # берём его отдельным файлом.
    if [ ! -x "$(_front_static_bin)" ]; then
        mkdir -p "${FRONT_HAPROXY_PREFIX}/bin"
        _front_download "$FRONT_HAPROXY_RELEASE_TAG" "mtproxyl-static-linux-${_arch}" "$(_front_static_bin)" \
            && chmod 755 "$(_front_static_bin)" \
            || { rm -f "$(_front_static_bin)"; log_error "Не удалось скачать раздатчик сайта mtproxyl-static"; return 1; }
    fi
    mkdir -p "${FRONT_HAPROXY_PREFIX}/conf"
    log_success "HAProxy: $(_front_haproxy_source)"
}

_front_haproxy_units() {
    local _bin _conf="$1"
    _bin=$(_front_haproxy_bin)
    cat > "/etc/systemd/system/${FRONT_HAPROXY_SERVICE}" << EOF
[Unit]
Description=MTProxyL HAProxy for selfmask and WEB
After=network-online.target ${FRONT_STATIC_SERVICE}
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=${_bin} -c -q -f ${_conf}
ExecStart=${_bin} -W -f ${_conf} -p /run/mtproxyl-haproxy.pid
ExecReload=${_bin} -c -q -f ${_conf}
ExecReload=/bin/kill -USR2 \$MAINPID
KillMode=mixed
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    cat > "/etc/systemd/system/${FRONT_STATIC_SERVICE}" << EOF
[Unit]
Description=MTProxyL site files behind HAProxy
After=network.target

[Service]
Type=simple
ExecStart=$(_front_static_bin) -listen 127.0.0.1:${FRONT_STATIC_PORT} -root ${SELFMASK_SITE_DIR:-/var/www/mtproxyl-selfmask}
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$FRONT_HAPROXY_SERVICE" "$FRONT_STATIC_SERVICE" &>/dev/null || true
}

_front_haproxy_test() {
    "$(_front_haproxy_bin)" -c -q -f "$1" 2>&1
}

# ── Общие куски ───────────────────────────────────────────────

front_install() {
    case "$(front_server)" in
        caddy)   _front_install_caddy "${1:-}" ;;
        haproxy) _front_install_haproxy "${1:-}" ;;
        *)       _selfmask_install_pq_nginx nginx "${1:-}" ;;
    esac
}

front_source() {
    case "$(front_server)" in
        caddy)   _front_caddy_source ;;
        haproxy) _front_haproxy_source ;;
        *)       _selfmask_nginx_source ;;
    esac
}

front_test_conf() {
    case "$(front_server)" in
        caddy)   _front_caddy_test "$1" ;;
        haproxy) _front_haproxy_test "$1" ;;
        *)       "$(_selfmask_nginx_bin_for_conf "$1")" -t -c "$1" 2>&1 ;;
    esac
}

# Что держатель должен отдать: домен сайта, сертификат, есть ли Selfmask и
# :80. Повторяет начало _selfmask_configure_nginx, чтобы конфиги совпадали.
_front_context() {
    _FC_SELFMASK="false"
    if [ "${SELFMASK_ENABLED:-false}" = "true" ] || [ "${SELFMASK_CONFIGURE_ACTIVE:-false}" = "true" ]; then
        _FC_SELFMASK="true"
        _FC_CERT_DIR="$(_selfmask_cert_dir)"
        _FC_DOMAIN="${SELFMASK_DOMAIN}"
    else
        _FC_CERT_DIR="$(web_cert_dir 2>/dev/null)"
        _FC_DOMAIN=$(web_domain 2>/dev/null)
    fi
    _FC_WEB="false"
    web_is_enabled 2>/dev/null && _FC_WEB="true"
    _FC_HTTP80="false"
    [ "${SELFMASK_CERT_MODE:-letsencrypt}" != "selfsigned" ] && _FC_HTTP80="true"
    [ -f "${_FC_CERT_DIR}/fullchain.pem" ] || { log_error "Сертификат не найден"; return 1; }
    if [ "$_FC_WEB" = "true" ]; then
        _FC_WEB_DOMAIN=$(web_domain 2>/dev/null) || return 1
        _FC_WEB_CERT_DIR=$(web_cert_dir 2>/dev/null)
        [ -n "$_FC_WEB_CERT_DIR" ] || _FC_WEB_CERT_DIR="$_FC_CERT_DIR"
        _FC_WEB_CONNECT=$(web_listener_connect_addr)
    fi
    return 0
}

# HSTS и Permissions-Policy — те же правила, что у nginx.
_front_hsts_age() {
    if [ "${HTTPS_HSTS_ENABLED:-true}" = "true" ] && [ "${SELFMASK_CERT_MODE:-letsencrypt}" != "selfsigned" ]; then
        echo 15552000
    else
        echo 0
    fi
}

# ── Генератор Caddyfile ───────────────────────────────────────

_front_caddy_security_headers() {
    local _ind="$1"
    echo "${_ind}header {"
    echo "${_ind}	-Server"
    echo "${_ind}	X-Content-Type-Options nosniff"
    [ "${2:-site}" = "site" ] && {
        echo "${_ind}	X-Frame-Options SAMEORIGIN"
        echo "${_ind}	Referrer-Policy no-referrer"
    }
    [ "${SELFMASK_CERT_MODE:-letsencrypt}" = "selfsigned" ] \
        || echo "${_ind}	Strict-Transport-Security \"max-age=$(_front_hsts_age)\""
    [ "${HTTPS_PERMISSIONS_ENABLED:-true}" = "true" ] \
        && echo "${_ind}	Permissions-Policy \"camera=(), microphone=(), geolocation=()\""
    echo "${_ind}}"
}

_front_caddy_panel_block() {
    local _p; _p=$(_selfmask_panel_proxy_params) || return 0
    local _path _scheme _port; read -r _path _scheme _port <<< "$_p"
    cat << EOF
	redir ${_path} ${_path}/ 308
	handle ${_path}/* {
		request_body {
			max_size 8MB
		}
		reverse_proxy ${_scheme}://127.0.0.1:${_port} {
			header_up Host {host}
			header_up X-Forwarded-Host {host}
			header_up X-Forwarded-Proto https
			header_up X-Forwarded-For {remote_host}
			flush_interval -1
EOF
    [ "$_scheme" = "https" ] && printf '\t\t\ttransport http {\n\t\t\t\ttls_insecure_skip_verify\n\t\t\t}\n'
    printf '\t\t}\n\t}\n'
}

_front_caddy_conf() {
    local _web_port="${WEB_TLS_PORT:-15444}" _pub="${PROXY_PORT:-443}"
    local _shared="false" _direct="false"
    if [ "$_FC_WEB" = "true" ]; then
        if web_frontend_is_direct; then _direct="true"; else _shared="true"; fi
    fi

    echo "# MTProxyL — сгенерировано автоматически, правки будут перезаписаны."
    echo "{"
    echo "	admin unix/${FRONT_CADDY_ADMIN}"
    echo "	auto_https off"
    echo "	persist_config off"
    echo "	log {"
    echo "		output discard"
    echo "	}"
    # HTTP/3 не входит в WEB-контракт движка.
    echo "	servers {"
    echo "		protocols h1 h2"
    echo "	}"
    if [ "$_shared" = "true" ]; then
        cat << EOF
	servers 127.0.0.1:${_web_port} {
		protocols h1 h2
		listener_wrappers {
			proxy_protocol {
				allow 127.0.0.1/32
			}
			tls
		}
	}
	layer4 {
		:${_pub} {
			@web tls sni ${_FC_WEB_DOMAIN}
			route @web {
				proxy {
					proxy_protocol v1
					upstream 127.0.0.1:${_web_port}
				}
			}
			route {
				proxy {
					proxy_protocol v1
					upstream ${_FC_WEB_CONNECT}:${WEB_MTPROXY_PORT:-15443}
				}
			}
		}
	}
EOF
    fi
    echo "}"

    if [ "$_FC_HTTP80" = "true" ]; then
        cat << EOF

http://:80 {
	handle /.well-known/acme-challenge/* {
		root * ${SELFMASK_SITE_DIR}
		file_server
	}
	@front host ${_FC_DOMAIN}
	handle @front {
		redir https://${_FC_DOMAIN}{uri} 301
	}
	handle {
		abort
	}
}
EOF
    fi

    if [ "$_FC_SELFMASK" = "true" ]; then
        cat << EOF

https://${SELFMASK_DOMAIN}:${SELFMASK_NGINX_BACKEND_PORT} {
	bind 127.0.0.1
	tls ${_FC_CERT_DIR}/fullchain.pem ${_FC_CERT_DIR}/privkey.pem {
		protocols tls1.3
		curves x25519mlkem768 x25519 secp256r1
	}
$(_front_caddy_security_headers "	" site)
$(_front_caddy_panel_block)
	@mtproxyl_bad path_regexp "(?i)(wget|curl|chmod|/tmp/|eval\\(|base64)"
	respond @mtproxyl_bad 403
	root * ${SELFMASK_SITE_DIR}
	file_server
	handle_errors 404 {
		rewrite * /404.html
		file_server
	}
}

https://:${SELFMASK_NGINX_BACKEND_PORT} {
	bind 127.0.0.1
	tls ${_FC_CERT_DIR}/fullchain.pem ${_FC_CERT_DIR}/privkey.pem {
		protocols tls1.3
		curves x25519mlkem768 x25519 secp256r1
	}
	abort
}
EOF
    fi

    if [ "$_FC_WEB" = "true" ]; then
        local _addr _bind
        if [ "$_direct" = "true" ]; then
            _addr="${WEB_PUBLIC_PORT:-443}"; _bind=""
        else
            _addr="$_web_port"; _bind="	bind 127.0.0.1"
        fi
        local _tls="	tls ${_FC_WEB_CERT_DIR}/fullchain.pem ${_FC_WEB_CERT_DIR}/privkey.pem {
		curves x25519mlkem768 x25519 secp256r1
	}"
        # Свои CSP/XFO/Referrer только у заглушки движка: её политика
        # начинается с default-src 'self'. Страница bridge идёт как есть.
        cat << EOF

https://${_FC_WEB_DOMAIN}:${_addr} {
${_bind}
${_tls}
	request_body {
		max_size 2MB
	}
$(_front_caddy_panel_block)
	reverse_proxy ${_FC_WEB_CONNECT}:${WEB_LISTEN_PORT:-15080} {
		header_up X-Forwarded-For {remote_host}
		header_up -If-None-Match
		header_down -ETag
		header_down -Last-Modified
		header_down -Strict-Transport-Security
		header_down -Permissions-Policy
		header_down -Server
		flush_interval -1
		stream_close_delay 5m
	}
$(_front_caddy_security_headers "	" web)
	header >Content-Security-Policy "$(web_csp_policy)" {
		match header Content-Security-Policy "default-src 'self'*"
	}
	header >X-Frame-Options SAMEORIGIN {
		match header Content-Security-Policy "default-src 'self'*"
	}
	header >Referrer-Policy no-referrer {
		match header Content-Security-Policy "default-src 'self'*"
	}
}

https://:${_addr} {
${_bind}
${_tls}
	respond 421
}
EOF
    fi
}

# ── Генератор haproxy.cfg ─────────────────────────────────────

_front_haproxy_binds() {
    local _port="$1" _extra="${2:-}"
    echo "    bind :${_port} ${_extra}"
    web_nginx_ipv6_available 2>/dev/null && echo "    bind :::${_port} v6only ${_extra}"
}

_front_haproxy_resp_headers() {
    local _age; _age=$(_front_hsts_age)
    echo "    http-response del-header Strict-Transport-Security"
    echo "    http-response del-header Permissions-Policy"
    echo "    http-response del-header Server"
    echo "    http-response set-header X-Content-Type-Options nosniff"
    [ "${SELFMASK_CERT_MODE:-letsencrypt}" = "selfsigned" ] \
        || echo "    http-response set-header Strict-Transport-Security \"max-age=${_age}\""
    [ "${HTTPS_PERMISSIONS_ENABLED:-true}" = "true" ] \
        && echo '    http-response set-header Permissions-Policy "camera=(), microphone=(), geolocation=()"'
    return 0
}

_front_haproxy_panel_rules() {
    local _p; _p=$(_selfmask_panel_proxy_params) || return 0
    local _path; read -r _path _ _ <<< "$_p"
    echo "    http-request redirect location ${_path}/ code 308 if { path ${_path} }"
    echo "    use_backend mtproxyl_panel if { path_beg ${_path}/ }"
}

_front_haproxy_panel_backend() {
    local _p; _p=$(_selfmask_panel_proxy_params) || return 0
    local _path _scheme _port _ssl=""; read -r _path _scheme _port <<< "$_p"
    [ "$_scheme" = "https" ] && _ssl=" ssl verify none sni req.hdr(host)"
    cat << EOF

backend mtproxyl_panel
    mode http
    timeout server 3600s
    timeout tunnel 3600s
    http-request set-header X-Forwarded-Host %[req.hdr(host)]
    http-request set-header X-Forwarded-Proto https
    http-request del-header X-Forwarded-For
    http-request set-header X-Forwarded-For %[src]
    server panel 127.0.0.1:${_port}${_ssl}
EOF
}

_front_haproxy_conf() {
    local _web_port="${WEB_TLS_PORT:-15444}" _pub="${PROXY_PORT:-443}"
    local _shared="false" _direct="false"
    if [ "$_FC_WEB" = "true" ]; then
        if web_frontend_is_direct; then _direct="true"; else _shared="true"; fi
    fi
    local _host_acl="hdr(host),field(1,:) -i"

    cat << EOF
# MTProxyL — сгенерировано автоматически, правки будут перезаписаны.
global
    uid 65534
    gid 65534
    ssl-default-bind-curves X25519MLKEM768:X25519:P-256
    ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets
    tune.ssl.default-dh-param 2048

defaults
    mode http
    no log
    option dontlognull
    timeout connect 5s
    timeout client 65s
    timeout server 65s
    timeout tunnel 65s
    timeout http-request 10s

crt-store mtproxyl
    load crt "${_FC_CERT_DIR}/fullchain.pem" key "${_FC_CERT_DIR}/privkey.pem" alias "site"
EOF
    if [ "$_FC_WEB" = "true" ] && [ "$_FC_WEB_CERT_DIR" != "$_FC_CERT_DIR" ]; then
        echo "    load crt \"${_FC_WEB_CERT_DIR}/fullchain.pem\" key \"${_FC_WEB_CERT_DIR}/privkey.pem\" alias \"web\""
    fi
    local _web_crt="@mtproxyl/site"
    [ "$_FC_WEB" = "true" ] && [ "$_FC_WEB_CERT_DIR" != "$_FC_CERT_DIR" ] && _web_crt="@mtproxyl/web"

    if [ "$_FC_HTTP80" = "true" ]; then
        cat << EOF

frontend mtproxyl_http
$(_front_haproxy_binds 80)
    acl acme path_beg /.well-known/acme-challenge/
    http-request redirect location https://${_FC_DOMAIN}%[capture.req.uri] code 301 if !acme { ${_host_acl} ${_FC_DOMAIN} }
    http-request reject if !acme
    default_backend mtproxyl_static
EOF
    fi

    if [ "$_shared" = "true" ]; then
        cat << EOF

frontend mtproxyl_public
    mode tcp
$(_front_haproxy_binds "$_pub")
    timeout client 300s
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }
    use_backend mtproxyl_web_tls if { req.ssl_sni -i ${_FC_WEB_DOMAIN} }
    default_backend mtproxyl_mtproto

backend mtproxyl_web_tls
    mode tcp
    retries 0
    server web_tls 127.0.0.1:${_web_port} send-proxy

backend mtproxyl_mtproto
    mode tcp
    retries 0
    timeout server 300s
    server mtproto ${_FC_WEB_CONNECT}:${WEB_MTPROXY_PORT:-15443} send-proxy
EOF
    fi

    if [ "$_FC_SELFMASK" = "true" ]; then
        cat << EOF

frontend mtproxyl_selfmask
    bind 127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT} ssl crt "@mtproxyl/site" alpn h2,http/1.1 ssl-min-ver TLSv1.3
    http-request reject if !{ ${_host_acl} ${SELFMASK_DOMAIN} }
$(_front_haproxy_panel_rules)
    http-request deny deny_status 403 if { path_reg -i (wget|curl|chmod|/tmp/|eval\\(|base64) }
    default_backend mtproxyl_site

backend mtproxyl_site
$(_front_haproxy_resp_headers)
    http-response set-header X-Frame-Options SAMEORIGIN
    http-response set-header Referrer-Policy no-referrer
    server site 127.0.0.1:${FRONT_STATIC_PORT}
EOF
    fi

    if [ "$_FC_HTTP80" = "true" ] || [ "$_FC_SELFMASK" = "true" ]; then
        cat << EOF

backend mtproxyl_static
    server static 127.0.0.1:${FRONT_STATIC_PORT}
EOF
    fi

    if [ "$_FC_WEB" = "true" ]; then
        local _bind
        if [ "$_direct" = "true" ]; then
            _bind=$(_front_haproxy_binds "${WEB_PUBLIC_PORT:-443}" "ssl crt \"${_web_crt}\" alpn h2,http/1.1")
        else
            _bind="    bind 127.0.0.1:${_web_port} accept-proxy ssl crt \"${_web_crt}\" alpn h2,http/1.1"
        fi
        # Как у nginx: свои CSP/XFO/Referrer подставляются только ответам,
        # чья политика есть и не разрешает скрипты, — то есть заглушке.
        local _decoy='{ res.hdr(content-security-policy) -m found } !{ res.hdr(content-security-policy) -m sub nonce- } !{ res.hdr(content-security-policy) -m sub unsafe- } !{ res.hdr(content-security-policy) -m sub script-src }'
        cat << EOF

frontend mtproxyl_web
${_bind}
    # Браузер переиспользует HTTP/2-соединение для другого имени с тем же
    # сертификатом — 421 заставляет открыть своё.
    http-request return status 421 if !{ ${_host_acl} ${_FC_WEB_DOMAIN} }
$(_front_haproxy_panel_rules)
    default_backend mtproxyl_web

backend mtproxyl_web
    option http-keep-alive
    retries 0
    http-request del-header X-Forwarded-For
    http-request set-header X-Forwarded-For %[src]
    http-request del-header If-None-Match
    http-response del-header ETag
    http-response del-header Last-Modified
$(_front_haproxy_resp_headers)
    # Решение — до подмены: своя CSP уже содержит script-src.
    http-response set-var(txn.mtproxyl_decoy) bool(true) if ${_decoy}
    http-response set-header Content-Security-Policy "$(web_csp_policy)" if { var(txn.mtproxyl_decoy) -m bool }
    http-response set-header X-Frame-Options SAMEORIGIN if { var(txn.mtproxyl_decoy) -m bool }
    http-response set-header Referrer-Policy no-referrer if { var(txn.mtproxyl_decoy) -m bool }
    server web ${_FC_WEB_CONNECT}:${WEB_LISTEN_PORT:-15080}
EOF
    fi
    _front_haproxy_panel_backend
}

# ── Применение ────────────────────────────────────────────────

# Записать конфиг, проверить, перезапустить службу. Свой конфиг
# пользователя только проверяется и подключается.
_front_activate() {
    local _conf="$1" _out
    _out=$(front_test_conf "$_conf") || {
        log_error "Ошибка конфига $(front_title)"
        printf '%s\n' "$_out" | sed 's/^/    /' | tail -20
        return 1
    }
    case "$(front_server)" in
        caddy)   _front_caddy_unit "$_conf" ;;
        haproxy) _front_haproxy_units "$_conf" ;;
    esac
    front_stop_others
    _selfmask_free_ports || { _selfmask_restore_port80_holders; return 1; }
    local _u
    for _u in $(front_units); do
        [ "$_u" = "$(front_service)" ] && continue
        systemctl restart "$_u" &>/dev/null || {
            log_error "Не удалось запустить ${_u}"
            journalctl -u "$_u" -n 20 --no-pager 2>/dev/null | sed 's/^/    /'
            return 1
        }
    done
    systemctl restart "$(front_service)" &>/dev/null || {
        log_error "Не удалось перезапустить $(front_title)"
        journalctl -u "$(front_service)" -n 20 --no-pager 2>/dev/null | sed 's/^/    /'
        _selfmask_restore_port80_holders
        return 1
    }
    _front_wait_listen
}

# Служба «запущена» раньше, чем держатель занял порты, а certbot и
# проверки стучатся сразу. Ждём до 5 секунд, пока процесс не начнёт слушать.
_front_wait_listen() {
    local _name _i
    case "$(front_server)" in caddy) _name="caddy" ;; haproxy) _name="haproxy" ;; *) return 0 ;; esac
    for _i in $(seq 1 25); do
        ss -lntp 2>/dev/null | grep -q "\"${_name}\"" && return 0
        sleep 0.2
    done
    return 0
}

# Временный конфиг на время выпуска сертификата: на :80 только файлы
# сайта, откуда certbot --webroot отдаёт ответ на проверку.
front_start_acme() {
    local _conf; _conf=$(front_generated_conf)
    mkdir -p "$(dirname "$_conf")"
    case "$(front_server)" in
        caddy)
            cat > "$_conf" << EOF
{
	admin unix/${FRONT_CADDY_ADMIN}
	auto_https off
	persist_config off
}

http://:80 {
	root * ${SELFMASK_SITE_DIR}
	file_server
}
EOF
            ;;
        haproxy)
            cat > "$_conf" << EOF
defaults
    mode http
    timeout connect 5s
    timeout client 30s
    timeout server 30s

frontend mtproxyl_acme
$(_front_haproxy_binds 80)
    default_backend mtproxyl_static

backend mtproxyl_static
    server static 127.0.0.1:${FRONT_STATIC_PORT}
EOF
            ;;
    esac
    chmod 600 "$_conf"
    _front_activate "$_conf"
}

# Caddy и HAProxy вместо nginx: та же раскладка портов и те же ответы.
front_configure_alt() {
    log_info "Настройка $(front_title)..."
    _front_context || return 1
    local _conf
    if [ "${NGINX_CUSTOM_ENABLED:-false}" = "true" ]; then
        _conf=$(front_custom_file)
        [ -f "$_conf" ] || { log_error "Свой конфиг $(front_title) не найден: ${_conf}"; return 1; }
        _front_activate "$_conf" || return 1
        log_success "$(front_title) настроен (свой конфиг)"
        return 0
    fi
    _conf=$(front_generated_conf)
    mkdir -p "$(dirname "$_conf")"
    local _tmp; _tmp=$(_mktemp "$(dirname "$_conf")") || return 1
    case "$(front_server)" in
        caddy)   _front_caddy_conf > "$_tmp" ;;
        haproxy) _front_haproxy_conf > "$_tmp" ;;
    esac
    chmod 600 "$_tmp"
    mv -f "$_tmp" "$_conf"
    _front_activate "$_conf" || return 1
    log_success "$(front_title) настроен"
}

# Перенос заглушки на другой держатель: ставим новый, переписываем конфиг,
# старый останавливаем. Свой конфиг к другому держателю не подходит.
front_switch() {
    local _new="$1" _old; _old=$(front_server)
    case "$_new" in
        nginx|caddy|haproxy) ;;
        *) log_error "Держатель: nginx, caddy или haproxy"; return 1 ;;
    esac
    [ "$_new" = "$_old" ] && { log_info "Уже выбран: $(front_title "$_new")"; return 0; }
    if [ "$_new" != "nginx" ] && web_frontend_has_haproxy 2>/dev/null; then
        log_error "WEB сейчас за внешним HAProxy — сначала верните frontend nginx: mtproxyl web set WEB_FRONTEND nginx"
        return 1
    fi
    local _in_use="false"
    { [ "${SELFMASK_ENABLED:-false}" = "true" ] || { web_is_enabled 2>/dev/null && web_uses_managed_nginx 2>/dev/null; }; } \
        && _in_use="true"
    FRONT_SERVER="$_new"
    if [ "${NGINX_CUSTOM_ENABLED:-false}" = "true" ]; then
        log_warn "Свой конфиг $(front_title "$_old") к $(front_title "$_new") не подходит — возвращаем сгенерированный"
        NGINX_CUSTOM_ENABLED="false"
    fi
    if [ "$_in_use" = "true" ]; then
        if ! front_install || ! _selfmask_configure_nginx; then
            log_error "$(front_title "$_new") не поднялся — возвращаем $(front_title "$_old")"
            FRONT_SERVER="$_old"
            front_install >/dev/null 2>&1 || true
            _selfmask_configure_nginx >/dev/null 2>&1 || true
            return 1
        fi
    fi
    save_settings || return 1
    log_success "Держатель заглушки: $(front_title "$_new")"
}

# Снять держателя при выключении заглушки: службы и сгенерированный конфиг.
front_disable_current() {
    local _u
    for _u in $(front_units); do
        systemctl disable --now "$_u" &>/dev/null || true
        rm -f "/etc/systemd/system/${_u}" 2>/dev/null || true
    done
    systemctl daemon-reload &>/dev/null || true
    rm -f "$(front_generated_conf)" 2>/dev/null || true
}

# Удаление MTProxyL: Caddy и HAProxy уходят вместе с ним.
front_remove_alt() {
    local _f _u
    for _f in caddy haproxy; do
        for _u in $(front_units "$_f"); do
            systemctl disable --now "$_u" &>/dev/null || true
            rm -f "/etc/systemd/system/${_u}" 2>/dev/null || true
        done
    done
    rm -rf "$FRONT_CADDY_PREFIX" "$FRONT_HAPROXY_PREFIX" /var/lib/mtproxyl-caddy /var/log/mtproxyl-caddy 2>/dev/null || true
    systemctl daemon-reload &>/dev/null || true
}

# Обновить сборку текущего держателя и перезапустить его на ней.
front_update() {
    front_install force || return 1
    if [ "${SELFMASK_ENABLED:-false}" = "true" ] || web_is_enabled 2>/dev/null; then
        _selfmask_configure_nginx || return 1
        log_success "$(front_title) перезапущен на новой сборке"
    fi
}

# Заглушку уже кто-то держит — Selfmask или наш WEB.
front_in_use() {
    [ "${SELFMASK_ENABLED:-false}" = "true" ] && return 0
    web_is_enabled 2>/dev/null && web_uses_managed_nginx 2>/dev/null
}

# Выбор перед первой установкой заглушки. Работающего держателя здесь не
# меняем: это перенос, у него своя команда.
front_pick_tui() {
    if front_in_use; then
        echo -e "  ${DIM}Заглушку держит $(front_title); сменить — mtproxyl front set nginx|caddy|haproxy${NC}"
        return 0
    fi
    echo ""
    echo -e "  ${BOLD}Чем держать заглушку и TLS${NC} ${DIM}(у всех постквантовый X25519MLKEM768)${NC}"
    echo -e "  ${DIM}[1]${NC} nginx   ${DIM}OpenSSL 3.5.7 — вариант по умолчанию${NC}"
    echo -e "  ${DIM}[2]${NC} Caddy   ${DIM}с модулем layer4 для общего :443${NC}"
    echo -e "  ${DIM}[3]${NC} HAProxy ${DIM}OpenSSL 3.5.7, файлы сайта отдаёт mtproxyl-static${NC}"
    local _def=1 _c
    front_is caddy && _def=2
    front_is haproxy && _def=3
    _c=$(read_choice "выбор" "$_def")
    case "$_c" in
        2) FRONT_SERVER="caddy" ;;
        3) FRONT_SERVER="haproxy" ;;
        *) FRONT_SERVER="nginx" ;;
    esac
    if [ "$FRONT_SERVER" != "nginx" ] && web_frontend_has_haproxy 2>/dev/null; then
        WEB_FRONTEND="nginx"
    fi
    return 0
}

front_status_json() {
    local _active=false; front_is_active && _active=true
    jq -n --arg server "$(front_server)" --arg title "$(front_title)" --arg source "$(front_source 2>/dev/null)" \
        --arg service "$(front_service)" --argjson active "$_active" \
        --argjson custom "$([ "${NGINX_CUSTOM_ENABLED:-false}" = "true" ] && echo true || echo false)" \
        --arg custom_file "$(front_custom_file)" \
        '{server: $server, title: $title, source: $source, service: $service, active: $active,
          custom: $custom, custom_file: $custom_file, choices: ["nginx", "caddy", "haproxy"]}'
}

front_show_status() {
    echo ""
    echo -e "  ${BOLD}Держатель заглушки:${NC} $(front_title)"
    echo -e "  ${DIM}Источник:${NC} $(front_source 2>/dev/null)"
    echo -e "  ${DIM}Служба:${NC} $(front_service) — $(front_is_active && echo "работает" || echo "остановлена")"
    [ "${NGINX_CUSTOM_ENABLED:-false}" = "true" ] && echo -e "  ${DIM}Свой конфиг:${NC} $(front_custom_file)"
    echo ""
}

handle_front_command() {
    local _sub="${1:-status}"; shift || true
    case "$_sub" in
        status)
            if [ "${1:-}" = "--json" ]; then front_status_json; else front_show_status; fi ;;
        update)
            check_root; front_update ;;
        set)
            [ -n "${1:-}" ] || { log_error "Использование: mtproxyl front set nginx|caddy|haproxy"; return 1; }
            front_switch "$1" ;;
        *)
            echo -e "  ${CYAN}front status [--json]${NC}           Кто держит заглушку Selfmask и WEB"
            echo -e "  ${CYAN}front set nginx|caddy|haproxy${NC}   Перенести заглушку на другой держатель"
            echo -e "  ${CYAN}front update${NC}                    Переустановить сборку держателя"
            ;;
    esac
}
