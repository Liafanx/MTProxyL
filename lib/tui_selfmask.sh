#!/bin/bash
# MTProxyL — подменю: selfmask

tui_selfmask_menu() {
    while true; do
        clear_screen
        draw_header "SELFMASK (PQ NGINX + LET'S ENCRYPT)"
        echo ""

        load_nft_settings 2>/dev/null

        echo -e "  ${BOLD}Статус:${NC}    $(selfmask_status_line 2>/dev/null || echo "${DIM}неизвестно${NC}")"
        echo -e "  ${BOLD}Домен:${NC}     ${SELFMASK_DOMAIN:-${DIM}не задан${NC}}"
        echo -e "  ${BOLD}Backend:${NC}   127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT:-8444}"
        echo -e "  ${BOLD}TLS:${NC}       TLSv1.3 (X25519MLKEM768)"
        echo -e "  ${BOLD}PQ nginx:${NC}  $([ -x "$(_selfmask_pq_nginx_bin)" ] && echo -e "${GREEN}установлен${NC}" || echo -e "${DIM}не установлен${NC}")"

        if [ -n "${SELFMASK_DOMAIN:-}" ] && [ -f "/etc/letsencrypt/live/${SELFMASK_DOMAIN}/fullchain.pem" ]; then
            echo -e "  ${BOLD}Сертификат:${NC} ${GREEN}найден${NC}"
        else
            echo -e "  ${BOLD}Сертификат:${NC} ${DIM}не найден${NC}"
        fi

        if systemctl is-active "${SELFMASK_PQ_SERVICE}" &>/dev/null; then
            echo -e "  ${BOLD}Служба:${NC}    ${GREEN}активна${NC}"
        else
            echo -e "  ${BOLD}Служба:${NC}    ${DIM}не запущена${NC}"
        fi

        echo ""
        echo -e "  ${YELLOW}${BOLD}Важно:${NC}"
        echo -e "  ${DIM}Домен для selfmask должен поддерживать PQ hybrid (X25519MLKEM768).${NC}"
        echo -e "  ${DIM}Проверка: отправьте домен боту ${CYAN}@Sni_checker_bot${NC}"
        echo -e "  ${DIM}🟢 X25519MLKEM768 — подходит${NC}"
        echo -e "  ${DIM}🔴 PQ не поддерживается + X25519 — iOS не подключится${NC}"
        echo ""

        echo -e "  ${CYAN}[1]${NC}  Подробный статус и требования"
        echo -e "  ${CYAN}[2]${NC}  Настроить / переустановить selfmask"
        echo -e "  ${CYAN}[3]${NC}  Проверка selfmask (verify)"
        echo -e "  ${CYAN}[4]${NC}  Отключить selfmask"
        echo -e "  ${CYAN}[5]${NC}  Показать конфиг PQ nginx"
        echo ""
        echo -e "  ${DIM}[0]${NC}  Назад"
        echo ""

        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) selfmask_show_status; press_any_key ;;
            2) selfmask_setup; press_any_key ;;
            3) selfmask_verify; press_any_key ;;
            4) selfmask_disable; press_any_key ;;
            5)
                local _conf="$(_selfmask_pq_conf)"
                if [ -f "$_conf" ]; then
                    echo ""
                    draw_header "КОНФИГ PQ NGINX"
                    echo ""
                    sed 's/^/  /' "$_conf"
                else
                    log_warn "Конфиг не найден: ${_conf}"
                fi
                press_any_key
                ;;
            0|"") return ;;
        esac
    done
}
