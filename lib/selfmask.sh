#!/bin/bash
# MTProxyL — Selfmask через локальный nginx + Let's Encrypt
# Важно: backend nginx для mask работает на TLS 1.2

SELFMASK_NGINX_CONF_DIR="/etc/nginx/sites-available"
SELFMASK_NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"

selfmask_supported_os() {
    [ "$(detect_os)" = "debian" ]
}

selfmask_status_line() {
    if [ "${SELFMASK_ENABLED:-false}" = "true" ]; then
        echo -e "${GREEN}включён${NC} (${SELFMASK_DOMAIN:-?} → 127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT:-8444}, ${SELFMASK_TLS_PROTOCOLS:-TLSv1.2})"
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
    echo -e "  ${DIM}• Внутренний backend nginx для selfmask будет работать на ${BOLD}TLS 1.2${NC}${DIM}.${NC}"
    echo ""
}

selfmask_show_status() {
    echo ""
    draw_header "SELFMASK"
    echo ""
    echo -e "  ${BOLD}Статус:${NC}         $(selfmask_status_line)"
    echo -e "  ${BOLD}Домен:${NC}          ${SELFMASK_DOMAIN:-${DIM}не задан${NC}}"
    echo -e "  ${BOLD}Источник сайта:${NC} ${SELFMASK_SITE_SOURCE:-stub}"
    echo -e "  ${BOLD}Каталог сайта:${NC}  ${SELFMASK_SITE_DIR:-/var/www/mtproxyl-selfmask}"
    echo -e "  ${BOLD}Backend:${NC}        127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT:-8444}"
    echo -e "  ${BOLD}TLS backend:${NC}    ${SELFMASK_TLS_PROTOCOLS:-TLSv1.2}"
    echo -e "  ${BOLD}Продление cert:${NC} ${SELFMASK_AUTO_RENEW:-true}"
    echo ""

    local _site_conf="${SELFMASK_NGINX_CONF_DIR}/${SELFMASK_NGINX_SITE_NAME:-mtproxyl-selfmask}"
    [ -f "$_site_conf" ] && echo -e "  ${BOLD}Nginx conf:${NC}     ${_site_conf}" || echo -e "  ${BOLD}Nginx conf:${NC}     ${DIM}не найден${NC}"

    if [ -n "${SELFMASK_DOMAIN:-}" ] && [ -f "/etc/letsencrypt/live/${SELFMASK_DOMAIN}/fullchain.pem" ]; then
        echo -e "  ${BOLD}Сертификат:${NC}     ${GREEN}найден${NC}"
    else
        echo -e "  ${BOLD}Сертификат:${NC}     ${DIM}не найден${NC}"
    fi

    if systemctl is-active nginx &>/dev/null; then
        echo -e "  ${BOLD}Nginx:${NC}          ${GREEN}активен${NC}"
    else
        echo -e "  ${BOLD}Nginx:${NC}          ${DIM}не запущен${NC}"
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
    echo -e "  ${GREEN}[1]${NC} Market-Terminal-Template"
    echo -e "      ${DIM}https://github.com/vaalaav/Market-Terminal-Template${NC}"
    echo -e "  ${GREEN}[2]${NC} kotorunner"
    echo -e "      ${DIM}https://github.com/vaalaav/kotorunner${NC}"
    echo -e "  ${CYAN}[3]${NC} Указать свой git-репозиторий"
    echo -e "  ${DIM}[4]${NC} Простая HTML-заглушка"
    echo ""

    local _tpl
    _tpl=$(read_choice "выбор" "4")
    case "$_tpl" in
        1)
            SELFMASK_SITE_SOURCE="https://github.com/vaalaav/Market-Terminal-Template.git"
            ;;
        2)
            SELFMASK_SITE_SOURCE="https://github.com/vaalaav/kotorunner.git"
            ;;
        3)
            echo -en "  ${BOLD}URL git-репозитория:${NC} "
            local _repo
            read -r _repo
            [[ "$_repo" =~ ^https?:// ]] || { log_error "Нужен URL вида http(s)://..."; return 1; }
            SELFMASK_SITE_SOURCE="$_repo"
            ;;
        *)
            SELFMASK_SITE_SOURCE="stub"
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
    echo -e "    Сайт:      ${SELFMASK_SITE_SOURCE}"
    echo -e "    Каталог:   ${SELFMASK_SITE_DIR}"
    echo -e "    Backend:   127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT}"
    echo -e "    TLS:       ${SELFMASK_TLS_PROTOCOLS:-TLSv1.2}"
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
    command -v nginx &>/dev/null || _missing+=("nginx")
    command -v certbot &>/dev/null || _missing+=("certbot" "python3-certbot-nginx")
    command -v git &>/dev/null || _missing+=("git")
    command -v rsync &>/dev/null || _missing+=("rsync")

    if command -v certbot &>/dev/null; then
        dpkg -s python3-certbot-nginx &>/dev/null 2>&1 || _missing+=("python3-certbot-nginx")
    fi

    if [ ${#_missing[@]} -gt 0 ]; then
        _wait_apt
        apt-get update -qq || true
        apt-get install -y -qq "${_missing[@]}" || {
            log_error "Не удалось установить зависимости: ${_missing[*]}"
            return 1
        }
    fi

    systemctl enable nginx &>/dev/null || true
    systemctl start nginx &>/dev/null || true

    log_success "Зависимости установлены"
}

_selfmask_install_pq_nginx() {
    local _prefix="/opt/mtproxyl-nginx"
    
    if [ -x "${_prefix}/sbin/nginx" ]; then
        local _ver
        _ver=$("${_prefix}/sbin/nginx" -V 2>&1 | grep -oP 'openssl/\K[0-9.]+' || echo "?")
        log_success "PQ nginx уже установлен (OpenSSL ${_ver})"
        return 0
    fi
    
    log_info "Скачивание PQ nginx (OpenSSL 3.5 + X25519MLKEM768)..."
    
    local _arch
    case "$(uname -m)" in
        x86_64|amd64) _arch="amd64" ;;
        aarch64|arm64) _arch="arm64" ;;
        *) log_error "Архитектура $(uname -m) не поддерживается"; return 1 ;;
    esac
    
    local _release_tag="pq-nginx-1.27.4-openssl3.5.0"
    local _archive="mtproxyl-pq-nginx-1.27.4-openssl3.5.0-linux-${_arch}.tar.gz"
    local _url="https://github.com/${GITHUB_REPO}/releases/download/${_release_tag}/${_archive}"
    local _tmp="/tmp/${_archive}"
    
    if curl -fsSL --max-time 120 "$_url" -o "$_tmp" 2>/dev/null; then
        sudo tar xzf "$_tmp" -C /opt/ || { log_error "Не удалось распаковать PQ nginx"; rm -f "$_tmp"; return 1; }
        rm -f "$_tmp"
        
        mkdir -p /var/log/mtproxyl-nginx /var/lib/mtproxyl-nginx/body /var/lib/mtproxyl-nginx/proxy /var/lib/mtproxyl-nginx/fastcgi
        
        log_success "PQ nginx установлен: ${_prefix}/sbin/nginx"
        "${_prefix}/sbin/nginx" -V 2>&1 | grep -i openssl | sed 's/^/  /'
    else
        log_error "Не удалось скачать PQ nginx"
        log_info "URL: ${_url}"
        return 1
    fi
}

_selfmask_deploy_site() {
    log_info "Развёртывание сайта-маски..."

    mkdir -p "$SELFMASK_SITE_DIR"

    if [ "${SELFMASK_SITE_SOURCE:-stub}" = "stub" ]; then
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
        log_success "Создана HTML-заглушка"
    else
        local _tmp
        _tmp=$(mktemp -d) || return 1
        log_info "Клонирование шаблона: ${SELFMASK_SITE_SOURCE}"
        if git clone --depth 1 "${SELFMASK_SITE_SOURCE}" "${_tmp}/repo" &>/dev/null; then
            find "$SELFMASK_SITE_DIR" -mindepth 1 -maxdepth 1 ! -name '.well-known' -exec rm -rf {} + 2>/dev/null || true
            if command -v rsync &>/dev/null; then
                rsync -a --exclude='.git' "${_tmp}/repo/" "${SELFMASK_SITE_DIR}/" &>/dev/null || true
            else
                find "${_tmp}/repo" -mindepth 1 -maxdepth 1 ! -name '.git' -exec cp -a {} "${SELFMASK_SITE_DIR}/" \;
            fi
            log_success "Шаблон сайта развернут"
        else
            log_warn "Не удалось скачать шаблон, создаём HTML-заглушку"
            cat > "${SELFMASK_SITE_DIR}/index.html" << 'HTML_EOF'
<!doctype html>
<html lang="ru">
<head><meta charset="utf-8"><title>Добро пожаловать</title></head>
<body><h1>Сайт временно недоступен</h1></body>
</html>
HTML_EOF
        fi
        rm -rf "$_tmp"
    fi

    chown -R www-data:www-data "$SELFMASK_SITE_DIR" 2>/dev/null || true
    chmod -R 755 "$SELFMASK_SITE_DIR" 2>/dev/null || true
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

    local _temp_conf="${SELFMASK_NGINX_CONF_DIR}/${SELFMASK_NGINX_SITE_NAME}-acme"
    cat > "$_temp_conf" << EOF
server {
    listen 80;
    server_name ${SELFMASK_DOMAIN};
    root ${SELFMASK_SITE_DIR};

    location /.well-known/acme-challenge/ {
        allow all;
    }

    location / {
        return 200 'ok';
        add_header Content-Type text/plain;
    }
}
EOF

    ln -sf "$_temp_conf" "${SELFMASK_NGINX_ENABLED_DIR}/$(basename "$_temp_conf")"
    rm -f "${SELFMASK_NGINX_ENABLED_DIR}/default" 2>/dev/null || true

    nginx -t &>/dev/null || {
        log_error "Ошибка временного nginx-конфига для ACME"
        rm -f "$_temp_conf" "${SELFMASK_NGINX_ENABLED_DIR}/$(basename "$_temp_conf")"
        return 1
    }

    systemctl restart nginx &>/dev/null || {
        log_error "Не удалось перезапустить nginx перед выдачей сертификата"
        return 1
    }

    _selfmask_open_public_ports

    if certbot certonly --webroot -w "$SELFMASK_SITE_DIR" \
        -d "$SELFMASK_DOMAIN" \
        --non-interactive --agree-tos \
        -m "${SELFMASK_CERT_EMAIL}" \
        --cert-name "$SELFMASK_DOMAIN" &>/dev/null; then
        log_success "Сертификат получен"
    else
        log_error "Не удалось получить сертификат"
        log_info "Проверьте DNS домена и доступность порта 80 извне"
        rm -f "$_temp_conf" "${SELFMASK_NGINX_ENABLED_DIR}/$(basename "$_temp_conf")"
        return 1
    fi

    rm -f "${SELFMASK_NGINX_ENABLED_DIR}/$(basename "$_temp_conf")"
    rm -f "$_temp_conf"
}

_selfmask_configure_nginx() {
    log_info "Настройка nginx..."

    local _conf="${SELFMASK_NGINX_CONF_DIR}/${SELFMASK_NGINX_SITE_NAME}"
    local _cert_dir="/etc/letsencrypt/live/${SELFMASK_DOMAIN}"
    [ -f "${_cert_dir}/fullchain.pem" ] || { log_error "Сертификат не найден"; return 1; }

    cat > "$_conf" << EOF
# MTProxyL selfmask
# Домен: ${SELFMASK_DOMAIN}
# Схема: telemt :443 → mask → nginx 127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT}

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

    ssl_protocols ${SELFMASK_TLS_PROTOCOLS};
    ssl_certificate     ${_cert_dir}/fullchain.pem;
    ssl_certificate_key ${_cert_dir}/privkey.pem;

    return 444;
}

server {
    listen 127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT} ssl;
    server_name ${SELFMASK_DOMAIN};
    server_tokens off;

    ssl_protocols ${SELFMASK_TLS_PROTOCOLS};
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
EOF

    ln -sf "$_conf" "${SELFMASK_NGINX_ENABLED_DIR}/${SELFMASK_NGINX_SITE_NAME}"
    rm -f "${SELFMASK_NGINX_ENABLED_DIR}/default" 2>/dev/null || true
    rm -f "${SELFMASK_NGINX_ENABLED_DIR}/${SELFMASK_NGINX_SITE_NAME}-acme" 2>/dev/null || true

    nginx -t &>/dev/null || {
        log_error "Ошибка итогового nginx-конфига"
        return 1
    }

    systemctl restart nginx &>/dev/null || {
        log_error "Не удалось перезапустить nginx"
        return 1
    }

    log_success "Nginx настроен"
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

    local _cron_line="0 3 * * * certbot renew --quiet --deploy-hook 'systemctl reload nginx'"
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

    command -v nginx &>/dev/null && log_success "nginx установлен" || { log_error "nginx не установлен"; _ok=false; }
    command -v certbot &>/dev/null && log_success "certbot установлен" || { log_error "certbot не установлен"; _ok=false; }

    if [ -f "/etc/letsencrypt/live/${SELFMASK_DOMAIN}/fullchain.pem" ]; then
        log_success "Сертификат найден"
    else
        log_warn "Сертификат не найден"
        _ok=false
    fi

    if systemctl is-active nginx &>/dev/null; then
        log_success "nginx активен"
    else
        log_warn "nginx не запущен"
        _ok=false
    fi

    local _site_conf="${SELFMASK_NGINX_CONF_DIR}/${SELFMASK_NGINX_SITE_NAME:-mtproxyl-selfmask}"
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

    rm -f "${SELFMASK_NGINX_ENABLED_DIR}/${SELFMASK_NGINX_SITE_NAME}" 2>/dev/null || true
    rm -f "${SELFMASK_NGINX_CONF_DIR}/${SELFMASK_NGINX_SITE_NAME}" 2>/dev/null || true
    nginx -t &>/dev/null && systemctl reload nginx &>/dev/null || true

    SELFMASK_ENABLED="false"

    if [ "${MASKING_HOST:-}" = "127.0.0.1" ] && [ "${MASKING_PORT:-}" = "${SELFMASK_NGINX_BACKEND_PORT}" ]; then
        MASKING_ENABLED="false"
        MASKING_HOST=""
        MASKING_PORT="443"
        log_warn "Маскировка переведена в выключенное состояние, чтобы избежать зацикливания на localhost"
        log_warn "После отключения selfmask проверьте ссылки: mtproxyl secret link"
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
