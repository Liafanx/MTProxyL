#!/bin/bash
# MTProxyL — Selfmask через локальный nginx + Let's Encrypt
# Важно: backend nginx для mask работает на TLS 1.3

SELFMASK_PQ_PREFIX="/opt/mtproxyl-nginx"
SELFMASK_PQ_SERVICE="mtproxyl-pq-nginx.service"
SELFMASK_PQ_RELEASE_TAG="pq-nginx-1.28.3-openssl3.5.7"
SELFMASK_PQ_NGINX_VERSION="1.28.3"
SELFMASK_PQ_OPENSSL_VERSION="3.5.7"

_selfmask_pq_nginx_bin() {
    echo "${SELFMASK_PQ_PREFIX}/sbin/nginx"
}

_selfmask_pq_openssl_bin() {
    echo "${SELFMASK_PQ_PREFIX}/bin/openssl"
}

_selfmask_pq_conf() {
    echo "${SELFMASK_PQ_PREFIX}/conf/nginx.conf"
}

selfmask_supported_os() {
    [ "$(detect_os)" = "debian" ]
}

selfmask_status_line() {
    if [ "${SELFMASK_ENABLED:-false}" = "true" ]; then
        echo -e "${GREEN}включён${NC} (${SELFMASK_DOMAIN:-?} → 127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT:-8444}, TLSv1.3 + PQ)"
    else
        echo -e "${DIM}выключен${NC}"
    fi
}

selfmask_show_requirements() {
    echo ""
    echo -e "  ${YELLOW}${BOLD}Важно для Selfmask / FakeTLS:${NC}"
    echo -e "  ${DIM}• Домен для FakeTLS должен поддерживать PQ hybrid:${NC}"
    echo -e "  ${DIM}  X25519MLKEM768 + классическую эллиптическую кривую.${NC}"
    echo -e "  ${DIM}• Проверка: отправьте домен боту ${CYAN}@Sni_checker_bot${NC}"
    echo -e "  ${DIM}• Если PQ не поддерживается и Peer Temp Key = X25519,${NC}"
    echo -e "  ${DIM}  iOS-клиенты с высокой вероятностью не смогут подключиться.${NC}"
    echo ""
    echo -e "  ${DIM}• Внутренний backend nginx для selfmask работает на ${BOLD}TLS 1.3${NC}${DIM}.${NC}"
    echo -e "  ${DIM}• Постквантовый обмен ключами X25519MLKEM768 включён.${NC}"
    echo ""
}

selfmask_show_status() {
    echo ""
    draw_header "SELFMASK"
    echo ""
    echo -e "  ${BOLD}Статус:${NC}         $(selfmask_status_line)"
    echo -e "  ${BOLD}Домен:${NC}          ${SELFMASK_DOMAIN:-${DIM}не задан${NC}}"
    local _src_display
    case "${SELFMASK_SITE_SOURCE:-stub}" in
        stub)        _src_display="Простая заглушка" ;;
        filemanager) _src_display="Файловый менеджер" ;;
        catrunner)   _src_display="Cat Runner" ;;
        http*)       _src_display="${SELFMASK_SITE_SOURCE}" ;;
        *)           _src_display="${SELFMASK_SITE_SOURCE:-stub}" ;;
    esac
    echo -e "  ${BOLD}Источник сайта:${NC} ${_src_display}"
    echo -e "  ${BOLD}Каталог сайта:${NC}  ${SELFMASK_SITE_DIR:-/var/www/mtproxyl-selfmask}"
    echo -e "  ${BOLD}Backend:${NC}        127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT:-8444}"
    echo -e "  ${BOLD}TLS backend:${NC}    TLSv1.3 (X25519MLKEM768)"
    echo -e "  ${BOLD}Продление cert:${NC} ${SELFMASK_AUTO_RENEW:-true}"
    echo ""

    local _site_conf="$(_selfmask_pq_conf)"
    [ -f "$_site_conf" ] && echo -e "  ${BOLD}Nginx conf:${NC}     ${_site_conf}" || echo -e "  ${BOLD}Nginx conf:${NC}     ${DIM}не найден${NC}"

    if [ -n "${SELFMASK_DOMAIN:-}" ] && [ -f "/etc/letsencrypt/live/${SELFMASK_DOMAIN}/fullchain.pem" ]; then
        echo -e "  ${BOLD}Сертификат:${NC}     ${GREEN}найден${NC}"
    else
        echo -e "  ${BOLD}Сертификат:${NC}     ${DIM}не найден${NC}"
    fi

    if systemctl is-active "${SELFMASK_PQ_SERVICE}" &>/dev/null; then
        echo -e "  ${BOLD}PQ nginx:${NC}       ${GREEN}активен${NC}"
    else
        echo -e "  ${BOLD}PQ nginx:${NC}       ${DIM}не запущен${NC}"
    fi

    selfmask_show_requirements
}

_selfmask_collect_params() {
    echo ""
    draw_header "ПАРАМЕТРЫ SELFMASK"
    echo ""
    echo -e "  ${DIM}Selfmask маскирует прокси под реальный сайт на вашем домене.${NC}"
    echo -e "  ${DIM}MTProto остаётся на :443, браузерные запросы и mask идут в локальный nginx.${NC}"
    echo -e "  ${DIM}Нужен домен с A-записью на этот сервер.${NC}"
    selfmask_show_requirements

    local _domain=""
    while true; do
        echo -en "  ${BOLD}Ваш домен:${NC} "
        read -r _domain
        _domain=$(echo "$_domain" | tr '[:upper:]' '[:lower:]')
        if validate_domain "$_domain"; then
            SELFMASK_DOMAIN="$_domain"
            break
        fi
        log_error "Некорректный домен"
    done

    local _email_default="admin@${SELFMASK_DOMAIN}"
    echo -en "  ${BOLD}Email для Let's Encrypt [${_email_default}]:${NC} "
    local _email
    read -r _email
    SELFMASK_CERT_EMAIL="${_email:-$_email_default}"

    echo ""
    log_info "Проверяем DNS..."
    local _server_ip _resolved_ip
    _server_ip=$(get_public_ip)
    _resolved_ip=$(getent ahostsv4 "$SELFMASK_DOMAIN" 2>/dev/null | awk '{print $1; exit}')
    [ -n "$_server_ip" ] && log_info "IP сервера: ${_server_ip}"
    if [ -n "$_resolved_ip" ]; then
        log_info "A-запись ${SELFMASK_DOMAIN}: ${_resolved_ip}"
        if [ -n "$_server_ip" ] && [ "$_server_ip" != "$_resolved_ip" ]; then
            log_warn "A-запись домена не совпадает с IP сервера"
            echo -en "  ${BOLD}Продолжить всё равно? [y/N]:${NC} "
            local _dns_yn
            read -r _dns_yn
            [[ "$_dns_yn" =~ ^[yY]$ ]] || return 1
        fi
    else
        log_warn "Не удалось определить A-запись домена"
        echo -en "  ${BOLD}Продолжить всё равно? [y/N]:${NC} "
        local _dns_yn
        read -r _dns_yn
        [[ "$_dns_yn" =~ ^[yY]$ ]] || return 1
    fi

    echo ""
    draw_header "ШАБЛОН САЙТА"
    echo ""
    echo -e "  ${DIM}[1]${NC} Простая заглушка ${DIM}(«Сайт временно недоступен»)${NC}"
    echo -e "  ${DIM}[2]${NC} Файловый менеджер ${DIM}(форма входа с логином/паролем)${NC}"
    echo -e "  ${DIM}[3]${NC} Cat Runner ${DIM}(мини-игра: кот прыгает через кактусы)${NC}"
    echo -e "  ${CYAN}[4]${NC} Указать свой URL ${DIM}(прямая ссылка на index.html)${NC}"
    echo ""

    local _tpl
    _tpl=$(read_choice "выбор" "1")
    case "$_tpl" in
        2)
            SELFMASK_SITE_SOURCE="filemanager"
            log_info "Выбран шаблон: Файловый менеджер"
            ;;
        3)
            SELFMASK_SITE_SOURCE="catrunner"
            log_info "Выбран шаблон: Cat Runner"
            ;;
        4)
            echo -en "  ${BOLD}URL файла index.html:${NC} "
            local _custom_url
            read -r _custom_url
            if [[ "$_custom_url" =~ ^https?:// ]]; then
                SELFMASK_SITE_SOURCE="$_custom_url"
                log_info "Пользовательский шаблон: ${_custom_url}"
            else
                log_error "Нужен URL вида http(s)://..."
                return 1
            fi
            ;;
        *)
            SELFMASK_SITE_SOURCE="stub"
            log_info "Выбрана простая заглушка"
            ;;
    esac

    echo ""
    echo -en "  ${BOLD}Локальный backend-порт nginx [${SELFMASK_NGINX_BACKEND_PORT:-8444}]:${NC} "
    local _bp
    read -r _bp
    if [ -n "$_bp" ]; then
        validate_port "$_bp" || { log_error "Некорректный порт"; return 1; }
        SELFMASK_NGINX_BACKEND_PORT="$_bp"
    fi

    echo ""
    echo -e "  ${BOLD}Итоговые параметры:${NC}"
    echo -e "    Домен:     ${SELFMASK_DOMAIN}"
    echo -e "    Email:     ${SELFMASK_CERT_EMAIL}"
    local _src_display
    case "${SELFMASK_SITE_SOURCE:-stub}" in
        stub)        _src_display="Простая заглушка" ;;
        filemanager) _src_display="Файловый менеджер" ;;
        catrunner)   _src_display="Cat Runner" ;;
        *)           _src_display="${SELFMASK_SITE_SOURCE}" ;;
    esac
    echo -e "    Сайт:      ${_src_display}"
    echo -e "    Каталог:   ${SELFMASK_SITE_DIR}"
    echo -e "    Backend:   127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT}"
    echo -e "    TLS:       ${SELFMASK_TLS_PROTOCOLS:-TLSv1.3}"
    echo ""

    echo -en "  ${BOLD}Продолжить настройку? [Y/n]:${NC} "
    local _yn
    read -r _yn
    [[ "$_yn" =~ ^[nN]$ ]] && return 1

    return 0
}

_selfmask_install_deps() {
    log_info "Установка зависимостей..."

    local _missing=()

    # certbot
    command -v certbot &>/dev/null || _missing+=("certbot")

    # runtime-зависимости для PQ nginx
    dpkg -s libpcre3 &>/dev/null 2>&1 || _missing+=("libpcre3")
    dpkg -s zlib1g &>/dev/null 2>&1 || _missing+=("zlib1g")
    dpkg -s ca-certificates &>/dev/null 2>&1 || _missing+=("ca-certificates")

    if [ ${#_missing[@]} -gt 0 ]; then
        _wait_apt
        apt-get update -qq || true
        apt-get install -y -qq "${_missing[@]}" || {
            log_error "Не удалось установить зависимости: ${_missing[*]}"
            return 1
        }
    fi

    log_success "Зависимости установлены"
}

_selfmask_install_pq_nginx() {
    local _prefix="${SELFMASK_PQ_PREFIX}"

    if [ -x "$(_selfmask_pq_nginx_bin)" ] && [ -x "$(_selfmask_pq_openssl_bin)" ]; then
        local _ver
        _ver=$("$(_selfmask_pq_openssl_bin)" version 2>/dev/null | awk '{print $2}')
        log_success "PQ nginx уже установлен (OpenSSL ${_ver:-?})"
        return 0
    fi

    log_info "Скачивание PQ nginx (OpenSSL ${SELFMASK_PQ_OPENSSL_VERSION} + nginx ${SELFMASK_PQ_NGINX_VERSION})..."

    local _arch
    case "$(uname -m)" in
        x86_64|amd64) _arch="amd64" ;;
        aarch64|arm64) _arch="arm64" ;;
        *)
            log_error "Архитектура $(uname -m) не поддерживается"
            return 1
            ;;
    esac

    local _archive="mtproxyl-pq-nginx-${SELFMASK_PQ_NGINX_VERSION}-openssl${SELFMASK_PQ_OPENSSL_VERSION}-linux-${_arch}.tar.gz"
    local _url="https://github.com/${GITHUB_REPO}/releases/download/${SELFMASK_PQ_RELEASE_TAG}/${_archive}"
    local _tmp="/tmp/${_archive}"

    if ! curl -fsSL --max-time 180 "$_url" -o "$_tmp" 2>/dev/null; then
        log_error "Не удалось скачать PQ nginx"
        log_info "Проверьте Release asset: ${_url}"
        return 1
    fi

    rm -rf "$_prefix" /opt/opt/mtproxyl-nginx
    tar xzf "$_tmp" -C / || {
        log_error "Не удалось распаковать PQ nginx"
        rm -f "$_tmp"
        return 1
    }
    rm -f "$_tmp"

    # Обратная совместимость: если архив всё же был распакован в /opt/opt
    if [ ! -d "$_prefix" ] && [ -d "/opt/opt/mtproxyl-nginx" ]; then
        mkdir -p /opt
        mv /opt/opt/mtproxyl-nginx /opt/mtproxyl-nginx 2>/dev/null || true
        rmdir /opt/opt 2>/dev/null || true
    fi

    mkdir -p /var/log/mtproxyl-nginx
    mkdir -p /var/lib/mtproxyl-nginx/body
    mkdir -p /var/lib/mtproxyl-nginx/proxy
    mkdir -p /var/lib/mtproxyl-nginx/fastcgi
    mkdir -p /var/lock
    mkdir -p "${_prefix}/logs"
    mkdir -p "${_prefix}/conf"

    if [ ! -x "$(_selfmask_pq_nginx_bin)" ]; then
        log_error "После распаковки nginx-pq не найден"
        log_info "Ожидался путь: $(_selfmask_pq_nginx_bin)"
        return 1
    fi

    if [ ! -x "$(_selfmask_pq_openssl_bin)" ]; then
        log_error "После распаковки openssl-pq не найден"
        return 1
    fi

    local _ver
    _ver=$("$(_selfmask_pq_openssl_bin)" version 2>/dev/null | awk '{print $2}')
    log_success "PQ nginx установлен (OpenSSL ${_ver:-?})"
}

_selfmask_install_pq_service() {
    cat > "/etc/systemd/system/${SELFMASK_PQ_SERVICE}" << EOF
[Unit]
Description=MTProxyL PQ nginx for selfmask
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=$(_selfmask_pq_nginx_bin) -t -c $(_selfmask_pq_conf)
ExecStart=$(_selfmask_pq_nginx_bin) -c $(_selfmask_pq_conf) -g 'daemon off;'
ExecReload=/bin/kill -HUP \$MAINPID
ExecStop=/bin/kill -QUIT \$MAINPID
Restart=on-failure
RestartSec=3
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SELFMASK_PQ_SERVICE}" &>/dev/null || true
}

_selfmask_deploy_site() {
    log_info "Развёртывание сайта-маски..."

    mkdir -p "$SELFMASK_SITE_DIR"

    local _src="${SELFMASK_SITE_SOURCE:-stub}"
    local _templates_base="${GITHUB_RAW}/templates_html"

    case "$_src" in
        stub)
            _selfmask_download_template "${_templates_base}/stub.html" || _selfmask_fallback_stub
            ;;
        filemanager)
            _selfmask_download_template "${_templates_base}/filemanager.html" || _selfmask_fallback_stub
            ;;
        catrunner)
            _selfmask_download_template "${_templates_base}/catrunner.html" || _selfmask_fallback_stub
            ;;
        http*) 
            _selfmask_download_template "$_src" || _selfmask_fallback_stub
            ;;
        *)
            _selfmask_fallback_stub
            ;;
    esac

    chown -R www-data:www-data "$SELFMASK_SITE_DIR" 2>/dev/null || true
    chmod -R 755 "$SELFMASK_SITE_DIR" 2>/dev/null || true
}

_selfmask_download_template() {
    local _url="$1"
    log_info "Скачивание шаблона: ${_url}"
    if curl -fsSL --max-time 15 "$_url" -o "${SELFMASK_SITE_DIR}/index.html" 2>/dev/null; then
        log_success "Шаблон установлен"
        return 0
    else
        log_warn "Не удалось скачать шаблон"
        return 1
    fi
}

_selfmask_fallback_stub() {
    log_info "Создаём встроенную заглушку..."
    cat > "${SELFMASK_SITE_DIR}/index.html" << 'HTML_EOF'
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Добро пожаловать</title>
<style>
  body{font-family:system-ui,-apple-system,sans-serif;max-width:680px;margin:80px auto;padding:0 20px;color:#333;background:#fafafa}
  h1{font-size:1.6rem;color:#111}
  p{color:#666;line-height:1.6}
  .footer{margin-top:60px;font-size:.85rem;color:#aaa}
</style>
</head>
<body>
  <h1>Сайт временно недоступен</h1>
  <p>Ведутся технические работы. Пожалуйста, зайдите позже.</p>
  <p class="footer">&copy; 2026</p>
</body>
</html>
HTML_EOF
    log_success "Встроенная заглушка создана"
}

_selfmask_open_public_ports() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow 80/tcp &>/dev/null || true
        ufw allow 443/tcp &>/dev/null || true
        log_info "UFW: открыты 80 и 443"
    elif command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=80/tcp &>/dev/null || true
        firewall-cmd --permanent --add-port=443/tcp &>/dev/null || true
        firewall-cmd --reload &>/dev/null || true
        log_info "firewalld: открыты 80 и 443"
    elif command -v iptables &>/dev/null; then
        iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT
        iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT
        log_info "iptables: открыты 80 и 443"
    fi
}

_selfmask_obtain_cert() {
    log_info "Получение сертификата Let's Encrypt..."

    local _cert_dir="/etc/letsencrypt/live/${SELFMASK_DOMAIN}"
    if [ -f "${_cert_dir}/fullchain.pem" ]; then
        log_success "Сертификат уже существует"
        return 0
    fi

    mkdir -p "${SELFMASK_SITE_DIR}/.well-known/acme-challenge"
    mkdir -p "${SELFMASK_PQ_PREFIX}/conf"

    cat > "$(_selfmask_pq_conf)" << EOF
worker_processes auto;

events {
    worker_connections 1024;
}

http {
    server {
        listen 80;
        server_name ${SELFMASK_DOMAIN};
        root ${SELFMASK_SITE_DIR};

        location /.well-known/acme-challenge/ {
            root ${SELFMASK_SITE_DIR};
            allow all;
        }

        location / {
            return 200 'ok';
            add_header Content-Type text/plain;
        }
    }
}
EOF

    _selfmask_open_public_ports
    _selfmask_install_pq_service

    local _test_out=""
    _test_out=$("$(_selfmask_pq_nginx_bin)" -t -c "$(_selfmask_pq_conf)" 2>&1) || {
        log_error "Ошибка временного конфига PQ nginx для ACME"
        echo "$_test_out" | sed 's/^/    /'
        return 1
    }
    
    systemctl restart "${SELFMASK_PQ_SERVICE}" &>/dev/null || {
        log_error "Не удалось запустить PQ nginx"
        return 1
    }

    if certbot certonly --webroot -w "$SELFMASK_SITE_DIR" \
        -d "$SELFMASK_DOMAIN" \
        --non-interactive --agree-tos \
        -m "${SELFMASK_CERT_EMAIL}" \
        --cert-name "$SELFMASK_DOMAIN" &>/dev/null; then
        log_success "Сертификат получен"
    else
        log_error "Не удалось получить сертификат"
        log_info "Проверьте DNS домена и доступность порта 80 извне"
        return 1
    fi
}

_selfmask_configure_nginx() {
    log_info "Настройка PQ nginx..."

    local _cert_dir="/etc/letsencrypt/live/${SELFMASK_DOMAIN}"
    [ -f "${_cert_dir}/fullchain.pem" ] || { log_error "Сертификат не найден"; return 1; }

    mkdir -p "${SELFMASK_PQ_PREFIX}/conf"

    cat > "$(_selfmask_pq_conf)" << EOF
worker_processes auto;

events {
    worker_connections 1024;
}

http {
    server {
        listen 80 default_server;
        server_name _;
        return 444;
    }

    server {
        listen 80;
        server_name ${SELFMASK_DOMAIN};
        root ${SELFMASK_SITE_DIR};

        location /.well-known/acme-challenge/ {
            root ${SELFMASK_SITE_DIR};
            allow all;
        }

        location / {
            return 301 https://${SELFMASK_DOMAIN}\$request_uri;
        }
    }

    server {
        listen 127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT} ssl default_server;
        server_name _;

        ssl_protocols TLSv1.3;
        ssl_ecdh_curve X25519MLKEM768:X25519:prime256v1;
        ssl_prefer_server_ciphers on;

        ssl_certificate     ${_cert_dir}/fullchain.pem;
        ssl_certificate_key ${_cert_dir}/privkey.pem;

        return 444;
    }

    server {
        listen 127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT} ssl;
        server_name ${SELFMASK_DOMAIN};
        server_tokens off;

        ssl_protocols TLSv1.3;
        ssl_ecdh_curve X25519MLKEM768:X25519:prime256v1;
        ssl_prefer_server_ciphers on;

        ssl_certificate     ${_cert_dir}/fullchain.pem;
        ssl_certificate_key ${_cert_dir}/privkey.pem;

        root ${SELFMASK_SITE_DIR};
        index index.html index.htm;

        add_header X-Content-Type-Options nosniff always;
        add_header X-Frame-Options SAMEORIGIN always;
        add_header Referrer-Policy no-referrer always;

        location ~* "(wget|curl|chmod|/tmp/|eval\\(|base64)" {
            return 403;
        }

        location / {
            try_files \$uri \$uri/ =404;
        }
    }
}
EOF

    local _test_out=""
    _test_out=$("$(_selfmask_pq_nginx_bin)" -t -c "$(_selfmask_pq_conf)" 2>&1) || {
        log_error "Ошибка итогового конфига PQ nginx"
        echo "$_test_out" | sed 's/^/    /'
        return 1
    }

    systemctl restart "${SELFMASK_PQ_SERVICE}" &>/dev/null || {
        log_error "Не удалось перезапустить PQ nginx"
        return 1
    }

    log_success "PQ nginx настроен"
}

_selfmask_apply_mtproxyl_settings() {
    log_info "Применение selfmask-настроек в MTProxyL..."

    SELFMASK_ENABLED="true"

    PROXY_DOMAIN="${SELFMASK_DOMAIN}"
    MASKING_ENABLED="true"
    MASKING_HOST="127.0.0.1"
    MASKING_PORT="${SELFMASK_NGINX_BACKEND_PORT}"
    UNKNOWN_SNI_ACTION="mask"

    auto_set_fake_cert_len "${SELFMASK_DOMAIN}" 2>/dev/null || \
        log_warn "Не удалось определить fake_cert_len для '${SELFMASK_DOMAIN}', оставляем ${FAKE_CERT_LEN:-2048}"

    save_settings
    log_success "Selfmask-настройки сохранены"

    if is_proxy_running; then
        log_info "Перезапуск прокси..."
        load_secrets
        restart_proxy_container || true
    else
        log_info "Прокси не запущен — запустите позже командой mtproxyl start"
    fi
}

_selfmask_setup_renewal() {
    log_info "Настройка автопродления сертификата..."

    if systemctl is-enabled certbot.timer &>/dev/null 2>&1; then
        log_success "certbot.timer уже активен"
        return 0
    fi

    if [ -f /etc/cron.d/certbot ]; then
        log_success "Системный cron certbot уже настроен"
        return 0
    fi

    local _cron_line="0 3 * * * certbot renew --quiet --deploy-hook 'systemctl reload ${SELFMASK_PQ_SERVICE}'"
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "$_cron_line") | crontab -
        log_success "Добавлен cron для автопродления"
    else
        log_info "Cron автопродления уже существует"
    fi
}

selfmask_verify() {
    echo ""
    draw_header "ПРОВЕРКА SELFMASK"
    echo ""

    local _ok=true

    [ -x "$(_selfmask_pq_nginx_bin)" ] && log_success "PQ nginx установлен" || { log_error "PQ nginx не установлен"; _ok=false; }
    [ -x "$(_selfmask_pq_openssl_bin)" ] && log_success "PQ openssl установлен" || { log_error "PQ openssl не установлен"; _ok=false; }
    command -v certbot &>/dev/null && log_success "certbot установлен" || { log_error "certbot не установлен"; _ok=false; }

    if [ -f "/etc/letsencrypt/live/${SELFMASK_DOMAIN}/fullchain.pem" ]; then
        log_success "Сертификат найден"
    else
        log_warn "Сертификат не найден"
        _ok=false
    fi

    if systemctl is-active "${SELFMASK_PQ_SERVICE}" &>/dev/null; then
        log_success "PQ nginx активен"
    else
        log_warn "PQ nginx не запущен"
        _ok=false
    fi

    local _site_conf="$(_selfmask_pq_conf)"
    [ -f "$_site_conf" ] && log_success "Конфиг nginx найден" || { log_warn "Конфиг nginx не найден"; _ok=false; }

    local _http_code=""
    if [ -n "${SELFMASK_DOMAIN:-}" ]; then
        _http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
            --resolve "${SELFMASK_DOMAIN}:${SELFMASK_NGINX_BACKEND_PORT}:127.0.0.1" \
            "https://${SELFMASK_DOMAIN}:${SELFMASK_NGINX_BACKEND_PORT}/" 2>/dev/null || true)
    fi

    if [ "$_http_code" = "200" ] || [ "$_http_code" = "403" ] || [ "$_http_code" = "404" ]; then
        log_success "Backend nginx отвечает (HTTP ${_http_code})"
    else
        log_warn "Backend nginx не отвечает как ожидалось (HTTP ${_http_code:-?})"
    fi

    if [ -n "${SELFMASK_DOMAIN:-}" ] && [ -x "$(_selfmask_pq_openssl_bin)" ]; then
        local _pq_out _pq_line
        _pq_out=$("$(_selfmask_pq_openssl_bin)" s_client \
            -tls1_3 \
            -groups X25519MLKEM768 \
            -connect "127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT}" \
            -servername "${SELFMASK_DOMAIN}" </dev/null 2>&1 || true)

        _pq_line=$(echo "$_pq_out" | grep -iE "Server Temp Key|X25519MLKEM768|Negotiated group|group" | head -1 || true)

        if echo "$_pq_out" | grep -q "X25519MLKEM768"; then
            log_success "PQ handshake активен"
            [ -n "$_pq_line" ] && log_info "${_pq_line}"
        else
            log_warn "PQ handshake не подтверждён"
            [ -n "$_pq_line" ] && log_warn "${_pq_line}"
        fi
    fi   

    if [ "${SELFMASK_ENABLED:-false}" = "true" ] && \
       [ "${MASKING_HOST:-}" = "127.0.0.1" ] && \
       [ "${MASKING_PORT:-}" = "${SELFMASK_NGINX_BACKEND_PORT}" ] && \
       [ "${PROXY_DOMAIN:-}" = "${SELFMASK_DOMAIN:-}" ]; then
        log_success "Настройки MTProxyL для selfmask применены"
    else
        log_warn "Настройки MTProxyL не совпадают с selfmask"
        _ok=false
    fi

    echo ""
    if $_ok; then
        log_success "Проверка selfmask завершена успешно"
    else
        log_warn "Selfmask настроен не полностью — проверьте предупреждения выше"
    fi

    selfmask_show_requirements
}

selfmask_setup() {
    check_root

    if ! selfmask_supported_os; then
        log_error "Selfmask пока поддерживается только на Debian/Ubuntu"
        return 1
    fi

    if [ "${SELFMASK_ENABLED:-false}" = "true" ]; then
        echo ""
        log_warn "Selfmask уже включён для домена: ${SELFMASK_DOMAIN:-?}"
        echo -en "  ${BOLD}Переустановить / обновить настройку? [y/N]:${NC} "
        local _re
        read -r _re
        [[ "$_re" =~ ^[yY]$ ]] || return 0
    fi

    _selfmask_collect_params       || return 1
    _selfmask_install_deps         || return 1
    _selfmask_install_pq_nginx     || return 1
    _selfmask_deploy_site          || return 1
    _selfmask_obtain_cert          || return 1
    _selfmask_configure_nginx      || return 1
    _selfmask_apply_mtproxyl_settings || return 1
    _selfmask_setup_renewal        || true
    selfmask_verify

    echo ""
    log_success "Selfmask настроен"
    echo -e "  ${BOLD}Домен:${NC}   https://${SELFMASK_DOMAIN}"
    echo -e "  ${BOLD}Сайт:${NC}    ${SELFMASK_SITE_DIR}"
    echo -e "  ${BOLD}Схема:${NC}   telemt :443 → mask → nginx 127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT}"
    echo ""
}

selfmask_disable() {
    check_root

    echo ""
    echo -e "  ${YELLOW}${BOLD}Отключение Selfmask${NC}"
    echo -e "  ${DIM}Будет отключён nginx selfmask и MTProxyL перестанет использовать локальный mask backend.${NC}"
    echo -e "  ${DIM}Каталог сайта и сертификаты удаляться не будут.${NC}"
    echo ""
    echo -en "  ${BOLD}Продолжить? [y/N]:${NC} "
    local _yn
    read -r _yn
    [[ "$_yn" =~ ^[yY]$ ]] || { log_info "Отменено"; return 0; }

    systemctl disable --now "${SELFMASK_PQ_SERVICE}" &>/dev/null || true
    rm -f "/etc/systemd/system/${SELFMASK_PQ_SERVICE}" 2>/dev/null || true
    systemctl daemon-reload &>/dev/null || true
    rm -f "$(_selfmask_pq_conf)" 2>/dev/null || true

    SELFMASK_ENABLED="false"

    if [ "${MASKING_HOST:-}" = "127.0.0.1" ] && [ "${MASKING_PORT:-}" = "${SELFMASK_NGINX_BACKEND_PORT}" ]; then
        MASKING_ENABLED="true"
        MASKING_HOST=""
        MASKING_PORT="443"
        log_info "Selfmask отключён — маскировка возвращена в обычный режим"
        log_info "Теперь backend по умолчанию: ${PROXY_DOMAIN}:443"
        log_warn "Проверьте ссылки после отключения selfmask: mtproxyl secret link"
    fi

    save_settings

    if is_proxy_running; then
        load_secrets
        restart_proxy_container || true
    fi

    log_success "Selfmask отключён"
}

handle_selfmask_command() {
    local subcmd="${1:-status}"
    shift 2>/dev/null || true

    case "$subcmd" in
        status)  selfmask_show_status ;;
        setup)   selfmask_setup ;;
        verify)  selfmask_verify ;;
        disable) selfmask_disable ;;
        menu)    tui_selfmask_menu ;;
        *)
            echo -e "  ${BOLD}Selfmask:${NC}"
            echo -e "    ${GREEN}selfmask status${NC}   Статус"
            echo -e "    ${GREEN}selfmask setup${NC}    Настроить / переустановить"
            echo -e "    ${GREEN}selfmask verify${NC}   Проверка"
            echo -e "    ${GREEN}selfmask disable${NC}  Отключить"
            echo -e "    ${GREEN}selfmask menu${NC}     Открыть меню"
            ;;
    esac
}
