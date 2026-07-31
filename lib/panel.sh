#!/bin/bash
# MTProxyL — установка и управление веб-панелью MTProxyL-Panel
#
# Панель — отдельный компонент (Go + React, один бинарник), который ставится
# своим установщиком. Здесь только тонкая обёртка: MTProxyL не дублирует
# логику установки, а вызывает установщик панели и показывает её состояние.

PANEL_SERVICE="mtproxyl-panel"
PANEL_BINARY="/usr/local/bin/mtproxyl-panel"
PANEL_CONFIG_DIR="/etc/mtproxyl-panel"
PANEL_INSTALLER_URL="${GITHUB_RAW}/mtproxyl-panel/install.sh"

panel_installed() {
    [ -x "$PANEL_BINARY" ]
}

panel_version() {
    panel_installed || return 1
    # Подкоманда, не флаг: панель печатает "mtproxyl-panel <версия>".
    "$PANEL_BINARY" version 2>/dev/null | awk '{print $2}'
}

panel_status_line() {
    if ! panel_installed; then
        echo -e "${DIM}не установлена${NC}"
        return
    fi
    local _ver; _ver=$(panel_version)
    if systemctl is-active "$PANEL_SERVICE" &>/dev/null; then
        echo -e "${GREEN}работает${NC}${_ver:+ (v${_ver})}"
    else
        echo -e "${YELLOW}установлена, не запущена${NC}${_ver:+ (v${_ver})}"
    fi
}

# Адрес, по которому панель отвечает — читаем из её конфига, чтобы не гадать.
panel_listen_addr() {
    local _cfg="${PANEL_CONFIG_DIR}/config.toml"
    [ -f "$_cfg" ] || return 1
    grep -oE '^[[:space:]]*listen[[:space:]]*=[[:space:]]*"[^"]+"' "$_cfg" 2>/dev/null \
        | head -1 | sed 's/.*"\([^"]*\)".*/\1/'
}

panel_install() {
    check_root || return 1

    if panel_installed; then
        log_info "Панель уже установлена: $(panel_status_line)"
        echo ""
        echo -en "  ${BOLD}Запустить установщик повторно (обновление/перенастройка)? [y/N]:${NC} "
        local _yn; read_line _yn
        [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 0; }
    fi

    if [ "${MTPROXYL_MODE:-manager}" = "manager" ] && ! _own_install_exists; then
        log_warn "Свой telemt ещё не установлен"
        log_info "Панели нужен работающий движок с доступным API — сначала выполните установку"
        return 1
    fi

    echo ""
    log_info "Установщик панели спросит адрес API telemt, логин и пароль администратора"
    log_info "Интеграция с MTProxyL будет предложена автоматически"

    # В режиме реаниматора цель чужая, и её API может слушать не на порту по
    # умолчанию — подсказываем найденный, чтобы не подбирать вручную.
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        local _api_port; _api_port=$(_get_telemt_api_port 2>/dev/null)
        if [ -n "$_api_port" ]; then
            log_info "API обнаруженной цели: http://127.0.0.1:${_api_port}"
            if ! _telemt_api_enabled 2>/dev/null; then
                log_warn "API цели сейчас недоступен: $(_telemt_api_unavailable_reason 2>/dev/null)"
                log_warn "Без работающего API панель не сможет показывать данные"
            fi
        else
            log_warn "Не удалось определить порт API цели — уточните его в конфиге цели"
        fi
    fi
    echo ""

    # Установщик интерактивный, поэтому запускаем его с терминалом, а не
    # через пайп: curl | sh лишил бы его stdin и все ответы ушли бы в никуда.
    local _tmp; _tmp=$(_mktemp) || return 1
    if ! curl -fsSL "$PANEL_INSTALLER_URL" -o "$_tmp"; then
        log_error "Не удалось скачать установщик панели"
        log_info "URL: ${PANEL_INSTALLER_URL}"
        return 1
    fi
    chmod +x "$_tmp"

    # Первый заход — обычная установка из релиза.
    if sh "$_tmp" install; then
        _panel_install_report
        return 0
    fi

    # Установщик уже объяснил причину своим сообщением. Самая частая — релиза
    # панели ещё нет; в этом случае можно собрать её прямо из ветки.
    echo ""
    log_warn "Установка из релиза не удалась (причина выше)"
    if panel_installed; then
        return 1
    fi

    echo ""
    log_info "Панель можно собрать из исходников ветки ${GITHUB_BRANCH}"
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        log_info "Сборка пойдёт в Docker — тулчейн на сервере не останется"
    else
        log_warn "Docker недоступен: понадобятся Go 1.25+ и Node.js 20+ на сервере"
    fi
    log_info "Нужен git; сборка занимает несколько минут"
    echo -en "  ${BOLD}Собрать из исходников? [y/N]:${NC} "
    local _yn; read_line _yn
    [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 1; }

    sh "$_tmp" install "--from-source=${GITHUB_BRANCH}" \
        || { log_error "Сборка из исходников не удалась (причина выше)"; return 1; }
    _panel_install_report
}

_panel_install_report() {
    echo ""
    if panel_installed; then
        log_success "Панель установлена"
        local _addr; _addr=$(panel_listen_addr)
        [ -n "$_addr" ] && log_info "Адрес: http://${_addr#0.0.0.0}"
    fi
}

panel_uninstall() {
    check_root || return 1
    panel_installed || { log_info "Панель не установлена"; return 0; }

    echo ""
    log_warn "Панель, её конфиг и права sudo будут удалены"
    echo -en "  ${BOLD}Продолжить? [y/N]:${NC} "
    local _yn; read_line _yn
    [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 0; }

    local _tmp; _tmp=$(_mktemp) || return 1
    if curl -fsSL "$PANEL_INSTALLER_URL" -o "$_tmp"; then
        chmod +x "$_tmp"
        sh "$_tmp" uninstall || log_warn "Установщик вернул ошибку при удалении"
    else
        log_warn "Установщик недоступен, удаляем вручную"
        systemctl disable --now "$PANEL_SERVICE" &>/dev/null || true
        rm -f "$PANEL_BINARY" "/etc/systemd/system/${PANEL_SERVICE}.service"
        rm -f "/etc/sudoers.d/${PANEL_SERVICE}" "/etc/sudoers.d/${PANEL_SERVICE}-mtproxyl"
        systemctl daemon-reload &>/dev/null || true
    fi
    log_success "Панель удалена"
}

panel_restart() {
    check_root || return 1
    panel_installed || { log_error "Панель не установлена"; return 1; }
    systemctl restart "$PANEL_SERVICE" \
        && log_success "Панель перезапущена" \
        || log_error "Не удалось перезапустить панель"
}

panel_show_status() {
    echo ""
    draw_header "MTPROXYL-PANEL"
    echo ""
    echo -e "  ${BOLD}Состояние:${NC} $(panel_status_line)"
    if panel_installed; then
        local _addr; _addr=$(panel_listen_addr)
        [ -n "$_addr" ] && echo -e "  ${BOLD}Адрес:${NC}     http://${_addr#0.0.0.0}"
        echo -e "  ${BOLD}Бинарник:${NC}  ${PANEL_BINARY}"
        echo -e "  ${BOLD}Конфиг:${NC}    ${PANEL_CONFIG_DIR}/config.toml"
        echo -e "  ${BOLD}Логи:${NC}      journalctl -u ${PANEL_SERVICE} -f"
    else
        echo ""
        echo -e "  ${DIM}Установка: mtproxyl panel install${NC}"
    fi
    echo ""
}

handle_panel_command() {
    case "${1:-status}" in
        install)   panel_install ;;
        uninstall) panel_uninstall ;;
        restart)   panel_restart ;;
        status)    panel_show_status ;;
        *)
            echo -e "  ${BOLD}MTProxyL-Panel (веб-панель):${NC}"
            echo -e "    ${GREEN}panel status${NC}     Состояние"
            echo -e "    ${GREEN}panel install${NC}    Установить / переустановить"
            echo -e "    ${GREEN}panel restart${NC}    Перезапустить"
            echo -e "    ${GREEN}panel uninstall${NC}  Удалить"
            ;;
    esac
}

# ── Подменю панели ───────────────────────────────────────────────────────────
tui_panel_menu() {
    while true; do
        clear_screen
        panel_show_status

        if panel_installed; then
            echo -e "  ${CYAN}[1]${NC}  Перезапустить"
            echo -e "  ${CYAN}[2]${NC}  Переустановить / перенастроить"
            echo -e "  ${CYAN}[3]${NC}  Показать логи"
            echo -e "  ${CYAN}[4]${NC}  Удалить"
        else
            echo -e "  ${CYAN}[1]${NC}  Установить"
            echo ""
            echo -e "  ${DIM}Панель даёт веб-интерфейс: пользователи, трафик, режим,${NC}"
            echo -e "  ${DIM}Selfmask, лимитер, бэкапы — всё то же, что и в этом меню.${NC}"
        fi
        echo ""
        echo -e "  ${DIM}[0]${NC}  Назад"
        echo ""

        local choice; choice=$(read_choice "выбор" "0")
        if panel_installed; then
            case "$choice" in
                1) panel_restart; press_any_key ;;
                2) panel_install; press_any_key ;;
                3) journalctl -u "$PANEL_SERVICE" -n 50 --no-pager; press_any_key ;;
                4) panel_uninstall; press_any_key ;;
                0|"") return ;;
            esac
        else
            case "$choice" in
                1) panel_install; press_any_key ;;
                0|"") return ;;
            esac
        fi
    done
}
