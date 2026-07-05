#!/bin/bash
# MTProxyL — Selfmask через локальный nginx + Let's Encrypt
# Важно: backend nginx для mask в будущем будет принудительно использовать TLSv1.2

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
    echo -e "  ${DIM}• Домен должен поддерживать постквантовый гибридный обмен ключами${NC}"
    echo -e "  ${DIM}  X25519MLKEM768 + классическую эллиптическую кривую.${NC}"
    echo -e "  ${DIM}• Проверка: отправьте домен боту ${CYAN}@Sni_checker_bot${NC}"
    echo -e "  ${DIM}• Если PQ не поддерживается и Peer Temp Key = X25519,${NC}"
    echo -e "  ${DIM}  iOS-клиенты с высокой вероятностью не смогут подключиться.${NC}"
    echo ""
    echo -e "  ${DIM}• Backend nginx для selfmask будет делаться на ${BOLD}TLS 1.2${NC}${DIM} — это важно для стабильной работы прокси.${NC}"
    echo ""
}

selfmask_show_status() {
    echo ""
    draw_header "SELFMASK"
    echo ""
    echo -e "  ${BOLD}Статус:${NC}        $(selfmask_status_line)"
    echo -e "  ${BOLD}Домен:${NC}         ${SELFMASK_DOMAIN:-${DIM}не задан${NC}}"
    echo -e "  ${BOLD}Источник сайта:${NC} ${SELFMASK_SITE_SOURCE:-stub}"
    echo -e "  ${BOLD}Web root:${NC}      ${SELFMASK_SITE_DIR:-/var/www/mtproxyl-selfmask}"
    echo -e "  ${BOLD}Backend:${NC}       127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT:-8444}"
    echo -e "  ${BOLD}TLS backend:${NC}   ${SELFMASK_TLS_PROTOCOLS:-TLSv1.2}"
    echo -e "  ${BOLD}Auto renew:${NC}    ${SELFMASK_AUTO_RENEW:-true}"
    echo ""

    if [ "${SELFMASK_ENABLED:-false}" = "true" ]; then
        local _site_conf="${SELFMASK_NGINX_CONF_DIR}/${SELFMASK_NGINX_SITE_NAME:-mtproxyl-selfmask}"
        [ -f "$_site_conf" ] && echo -e "  ${BOLD}Nginx conf:${NC}    ${_site_conf}" || echo -e "  ${BOLD}Nginx conf:${NC}    ${DIM}не найден${NC}"
        if [ -f "/etc/letsencrypt/live/${SELFMASK_DOMAIN}/fullchain.pem" ]; then
            echo -e "  ${BOLD}Сертификат:${NC}    ${GREEN}найден${NC}"
        else
            echo -e "  ${BOLD}Сертификат:${NC}    ${DIM}не найден${NC}"
        fi
        if systemctl is-active nginx &>/dev/null; then
            echo -e "  ${BOLD}Nginx:${NC}         ${GREEN}активен${NC}"
        else
            echo -e "  ${BOLD}Nginx:${NC}         ${DIM}не запущен${NC}"
        fi
    fi

    selfmask_show_requirements
}

selfmask_setup() {
    check_root

    if ! selfmask_supported_os; then
        log_error "Selfmask пока поддерживается только на Debian/Ubuntu"
        return 1
    fi

    echo ""
    log_info "Selfmask — модуль локального nginx + Let's Encrypt + local mask backend"
    log_info "Этап A: каркас уже подключён."
    log_info "На следующем этапе будет добавлен полный pipeline setup:"
    echo -e "    ${DIM}deps → site deploy → certbot → nginx config → MTProxyL settings → verify${NC}"

    selfmask_show_requirements
}

selfmask_verify() {
    echo ""
    draw_header "ПРОВЕРКА SELFMASK"
    echo ""
    if ! selfmask_supported_os; then
        log_error "Selfmask пока поддерживается только на Debian/Ubuntu"
        return 1
    fi

    if [ "${SELFMASK_ENABLED:-false}" != "true" ]; then
        log_warn "Selfmask не включён"
        return 1
    fi

    local _ok=true

    command -v nginx &>/dev/null && log_success "nginx установлен" || { log_error "nginx не установлен"; _ok=false; }
    command -v certbot &>/dev/null && log_success "certbot установлен" || { log_error "certbot не установлен"; _ok=false; }

    if [ -f "/etc/letsencrypt/live/${SELFMASK_DOMAIN}/fullchain.pem" ]; then
        log_success "Сертификат найден: ${SELFMASK_DOMAIN}"
    else
        log_warn "Сертификат не найден для ${SELFMASK_DOMAIN}"
    fi

    if systemctl is-active nginx &>/dev/null; then
        log_success "nginx активен"
    else
        log_warn "nginx не запущен"
    fi

    if $_ok; then
        log_success "Базовая проверка selfmask завершена"
    fi
}

selfmask_disable() {
    check_root
    echo ""
    log_warn "Полное отключение selfmask с удалением nginx/certbot-конфига будет добавлено на следующем этапе."
    log_info "Пока каркас только подключён."
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
            echo -e "    ${GREEN}selfmask setup${NC}    Настройка (каркас)"
            echo -e "    ${GREEN}selfmask verify${NC}   Проверка"
            echo -e "    ${GREEN}selfmask disable${NC}  Отключение"
            echo -e "    ${GREEN}selfmask menu${NC}     Открыть меню"
            ;;
    esac
}
