#!/bin/bash

# MTProxyL — меню WEB Proxy

_tui_web_layout_menu() {
    echo ""
    echo -e "  ${BOLD}Раскладка портов${NC}"
    echo ""
    echo -e "  ${CYAN}[1]${NC}  shared — WEB и обычный прокси на одном порту"
    echo -e "       ${DIM}nginx разбирает SNI. Домен WEB должен отличаться от домена${NC}"
    echo -e "       ${DIM}маскировки, и нужен nginx со stream.${NC}"
    echo ""
    echo -e "  ${CYAN}[2]${NC}  split — у WEB свой порт"
    echo -e "       ${DIM}Движок остаётся на своём порту напрямую. stream не нужен,${NC}"
    echo -e "       ${DIM}домены могут совпадать, zapret2 и лимитер WEB не задевают.${NC}"
    echo ""
    echo -e "  ${DIM}[0]${NC}  Отмена"
    echo ""
    local _c; _c=$(read_choice "выбор" "0")
    case "$_c" in
        1) web_set_param WEB_LAYOUT shared ;;
        2)
            web_set_param WEB_LAYOUT split || return 0
            echo ""
            echo -en "  ${BOLD}Публичный порт WEB [${WEB_PUBLIC_PORT:-443}]:${NC} "
            local _p; read_line _p
            [ -n "$_p" ] && web_set_param WEB_PUBLIC_PORT "$_p"
            # Порт прокси менять здесь нельзя: за ним тянутся ссылки, гео и фиксы.
            if [ "${PROXY_PORT:-443}" = "$(web_public_port)" ]; then
                echo ""
                log_warn "У прокси и WEB сейчас один порт ${PROXY_PORT}"
                log_info "Переведите прокси на другой: mtproxyl settings set PROXY_PORT <порт>"
            fi ;;
        *) return 0 ;;
    esac
}

_tui_web_carrier_menu() {
    echo ""
    echo -e "  ${BOLD}Транспорт carrier${NC}"
    echo ""
    echo -e "  ${CYAN}[1]${NC}  websocket    ${DIM}по умолчанию, стабильный один сокет${NC}"
    echo -e "  ${CYAN}[2]${NC}  websocket-lanes ${DIM}отдельный сокет на каждый поток${NC}"
    echo -e "  ${CYAN}[3]${NC}  https-lanes  ${DIM}потоки не блокируют друг друга, нужен HTTP/2${NC}"
    echo -e "  ${CYAN}[4]${NC}  https        ${DIM}максимальная совместимость${NC}"
    echo ""
    echo -e "  ${DIM}[0]${NC}  Отмена"
    echo ""
    local _c; _c=$(read_choice "выбор" "0")
    case "$_c" in
        1) web_set_param WEB_CARRIER websocket ;;
        2) web_set_param WEB_CARRIER websocket-lanes ;;
        3) web_set_param WEB_CARRIER https-lanes ;;
        4) web_set_param WEB_CARRIER https ;;
        *) return 0 ;;
    esac
}

tui_web_menu() {
    while true; do
        clear_screen
        draw_header "WEB PROXY"
        load_secrets 2>/dev/null || true
        web_status_print

        echo -e "  ${CYAN}[1]${NC}  $(web_is_only_mode && echo "Применить заново" || { web_is_enabled && echo "Выключить" || echo "Включить"; })"
        echo -e "  ${CYAN}[2]${NC}  Режим  ${DIM}$(proxy_transport_mode_title)${NC}"
        if mtproto_is_enabled; then
            echo -e "  ${CYAN}[3]${NC}  Раскладка портов  ${DIM}${WEB_LAYOUT:-shared}${NC}"
        else
            echo -e "  ${DIM}[3]  Раскладка не нужна без обычного MTProto${NC}"
        fi
        echo -e "  ${CYAN}[4]${NC}  Транспорт carrier  ${DIM}${WEB_CARRIER:-websocket}${NC}"
        echo -e "  ${CYAN}[5]${NC}  Домен  ${DIM}$(web_domain 2>/dev/null || echo '—')${NC}"
        echo -e "  ${CYAN}[6]${NC}  Ссылки tg://webproxy"
        echo -e "  ${CYAN}[7]${NC}  Диагностика /web-status  ${DIM}$([ "${WEB_DEBUG:-false}" = "true" ] && echo "включена" || echo "выключена")${NC}"
        echo -e "  ${CYAN}[8]${NC}  Пользовательский конфиг nginx  ${DIM}$(nginx_custom_status_line)${NC}"
        echo ""
        echo -e "  ${DIM}[0]${NC}  Назад"
        echo ""
        local _c; _c=$(read_choice "выбор" "0")

        case "$_c" in
            1)
                if web_is_only_mode; then web_enable
                elif web_is_enabled; then web_disable
                else web_enable
                fi
                press_any_key ;;
            2)
                echo ""
                echo -e "  ${CYAN}[1]${NC} Только WEB"
                echo -e "  ${CYAN}[2]${NC} MTProto + WEB"
                local _m; _m=$(read_choice "выбор" "$([ "${PROXY_MODE:-mtproto}" = web ] && echo 1 || echo 2)")
                case "$_m" in 1) web_set_proxy_mode web ;; 2) web_set_proxy_mode combined ;; esac
                press_any_key ;;
            3) mtproto_is_enabled && _tui_web_layout_menu; press_any_key ;;
            4) _tui_web_carrier_menu; press_any_key ;;
            5)
                echo ""
                if [ "${SELFMASK_ENABLED:-false}" = "true" ]; then
                    echo -e "  ${DIM}Пусто — взять поддомен web.<домен Selfmask>${NC}"
                else
                    echo -e "  ${DIM}Без Selfmask нужен собственный домен с A-записью на сервер.${NC}"
                fi
                echo -en "  ${BOLD}Домен WEB [$(web_domain 2>/dev/null)]:${NC} "
                local _d; read_line _d
                web_set_param WEB_DOMAIN "$_d"
                press_any_key ;;
            6) web_links_print; press_any_key ;;
            7)
                if [ "${WEB_DEBUG:-false}" = "true" ]; then
                    web_set_param WEB_DEBUG false
                else
                    web_set_param WEB_DEBUG true
                    echo ""
                    log_info "Страница: http://127.0.0.1:${PROXY_API_PORT:-9091}/web-status"
                    log_info "Нужен заголовок Authorization из [server.api] конфига движка"
                fi
                press_any_key ;;
            8) tui_nginx_custom_menu ;;
            0|"") return 0 ;;
        esac
    done
}
