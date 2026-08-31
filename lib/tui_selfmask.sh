#!/bin/bash
# MTProxyL — подменю: selfmask 

tui_selfmask_menu() {
    while true; do
        clear_screen
        if [ "${SELFMASK_CERT_MODE:-letsencrypt}" = "selfsigned" ]; then
            draw_header "SELFMASK (PQ NGINX + САМОПОДПИСАННЫЙ CERT)"
        else
            draw_header "SELFMASK (PQ NGINX + LET'S ENCRYPT)"
        fi
        echo ""

        load_nft_settings 2>/dev/null

        echo -e "  ${BOLD}Статус:${NC}    $(selfmask_status_line 2>/dev/null || echo "${DIM}неизвестно${NC}")"
        echo -e "  ${BOLD}Домен:${NC}     ${SELFMASK_DOMAIN:-${DIM}не задан${NC}}"
        echo -e "  ${BOLD}Тип cert:${NC}  ${SELFMASK_CERT_MODE:-letsencrypt}"
        echo -e "  ${BOLD}Backend:${NC}   127.0.0.1:${SELFMASK_NGINX_BACKEND_PORT:-8444}"
        echo -e "  ${BOLD}TLS:${NC}       $(_selfmask_get_tls_info)"
        echo -e "  ${BOLD}PQ nginx:${NC}  $([ -x "$(_selfmask_pq_nginx_bin)" ] && echo -e "${GREEN}установлен${NC}" || echo -e "${DIM}не установлен${NC}")"
        echo -e "  ${BOLD}Свой conf:${NC}  $(nginx_custom_status_line)"

        if [ -n "${SELFMASK_DOMAIN:-}" ] && [ -f "$(_selfmask_cert_dir)/fullchain.pem" ]; then
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
        if [ "${SELFMASK_ENABLED:-false}" = "true" ]; then
            echo -e "  ${DIM}Заглушку поднял MTProxyL — поддержка PQ hybrid${NC}"
            echo -e "  ${DIM}(X25519MLKEM768) обеспечена самим backend'ом.${NC}"
        else
            echo -e "  ${DIM}Заглушку поднимает сам MTProxyL, поэтому PQ hybrid${NC}"
            echo -e "  ${DIM}(X25519MLKEM768) поддерживается гарантированно.${NC}"
        fi
        echo -e "  ${DIM}Чужой домен для FakeTLS можно проверить на PQ:${NC}"
        echo -e "  ${DIM}меню ${BOLD}Дополнения${NC}${DIM} → проверка домена, либо ${CYAN}@Sni_checker_bot${NC}${DIM}.${NC}"
        echo ""

        echo -e "  ${CYAN}[1]${NC}  Подробный статус и требования"
        echo -e "  ${CYAN}[2]${NC}  Настроить / переустановить selfmask"
        echo -e "  ${CYAN}[3]${NC}  Проверка selfmask (verify)"
        echo -e "  ${CYAN}[4]${NC}  Отключить selfmask"
        echo -e "  ${CYAN}[5]${NC}  Показать конфиг PQ nginx"
        echo -e "  ${CYAN}[6]${NC}  Пользовательский конфиг nginx"
        echo -e "  ${RED}[7]${NC}  Полностью удалить PQ nginx"
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
            6) tui_nginx_custom_menu ;;
            7) selfmask_remove_pq_nginx; press_any_key ;;
            0|"") return ;;
        esac
    done
}

tui_nginx_custom_menu() {
    while true; do
        clear_screen
        draw_header "ПОЛЬЗОВАТЕЛЬСКИЙ КОНФИГ NGINX"
        echo ""
        echo -e "  ${BOLD}Статус:${NC} $(nginx_custom_status_line)"
        echo -e "  ${BOLD}Файл:${NC}   ${NGINX_CUSTOM_FILE}"
        echo ""
        echo -e "  ${DIM}При включённом режиме MTProxyL не перезаписывает этот файл.${NC}"
        echo -e "  ${DIM}Изменения настроек nginx нужно переносить в него вручную.${NC}"
        echo ""
        if nginx_custom_active; then
            echo -e "  ${CYAN}[1]${NC}  Выключить режим"
        else
            echo -e "  ${CYAN}[1]${NC}  Включить режим"
        fi
        echo -e "  ${CYAN}[2]${NC}  Редактировать"
        echo -e "  ${CYAN}[3]${NC}  Показать конфиг"
        echo -e "  ${CYAN}[4]${NC}  Проверить nginx -t"
        echo ""
        echo -e "  ${DIM}[0]${NC}  Назад"
        echo ""

        local _choice; _choice=$(read_choice "выбор" "0")
        case "$_choice" in
            1)
                if nginx_custom_active; then
                    nginx_custom_disable
                else
                    nginx_custom_enable
                fi
                press_any_key
                ;;
            2) nginx_custom_edit; press_any_key ;;
            3)
                echo ""
                draw_header "ПОЛЬЗОВАТЕЛЬСКИЙ NGINX.CONF"
                echo ""
                nginx_custom_show | sed 's/^/  /'
                press_any_key
                ;;
            4) nginx_custom_test; press_any_key ;;
            0|"") return ;;
        esac
    done
}
