#!/bin/bash

# MTProxyL — меню WEB Proxy

_tui_web_layout_menu() {
    echo ""
    echo -e "  ${BOLD}Раскладка портов${NC}"
    echo ""
    echo -e "  ${CYAN}[1]${NC}  shared — WEB и обычный прокси на одном порту"
    echo -e "       ${DIM}$(web_frontend_has_haproxy && echo 'HAProxy' || echo 'nginx') разбирает SNI. Домен WEB должен отличаться от домена${NC}"
    echo -e "       ${DIM}маскировки.${NC}"
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
            if web_uses_managed_nginx; then
                local _p; read_line _p "  ${BOLD}Публичный порт WEB [${WEB_PUBLIC_PORT:-443}]:${NC} "
                [ -n "$_p" ] && web_set_param WEB_PUBLIC_PORT "$_p"
            fi
            # Порт прокси менять здесь нельзя: за ним тянутся ссылки, гео и фиксы.
            if [ "${PROXY_PORT:-443}" = "$(web_public_port)" ]; then
                echo ""
                log_warn "У прокси и WEB сейчас один порт ${PROXY_PORT}"
                log_info "Переведите прокси на другой: mtproxyl settings set PROXY_PORT <порт>"
            fi ;;
        *) return 0 ;;
    esac
}

_tui_web_frontend_menu() {
    echo ""
    echo -e "  ${BOLD}Frontend WEB Proxy${NC}"
    echo ""
    echo -e "  ${CYAN}[1]${NC}  nginx MTProxyL  ${DIM}сертификат и конфиг управляются автоматически${NC}"
    echo -e "  ${CYAN}[2]${NC}  внешний HAProxy ${DIM}уже установлен на этой машине${NC}"
    echo -e "  ${CYAN}[3]${NC}  HAProxy → nginx MTProxyL ${DIM}публичный порт у HAProxy, TLS и заглушка у нас${NC}"
    echo ""
    echo -e "  ${DIM}[0]${NC}  Отмена"
    echo ""
    local _cur=1
    web_frontend_is_haproxy && _cur=2
    web_frontend_is_haproxy_nginx && _cur=3
    local _c; _c=$(read_choice "выбор" "$_cur")
    case "$_c" in
        1) web_set_param WEB_FRONTEND nginx ;;
        3)
            web_set_param WEB_FRONTEND haproxy-nginx || return 0
            echo ""
            log_info "HAProxy остаётся вашим: фрагмент — mtproxyl web haproxy-config"
            log_info "Сертификат выпускает и продлевает MTProxyL, PEM для HAProxy не нужен"
            ;;
        2)
            web_set_param WEB_FRONTEND haproxy || return 0
            echo ""
            local _cert; read_line _cert "  ${BOLD}PEM сертификат + ключ [$(web_haproxy_cert)]:${NC} "
            [ -n "$_cert" ] && web_set_param WEB_HAPROXY_CERT "$_cert"
            echo ""
            log_info "MTProxyL не меняет HAProxy. Фрагмент: mtproxyl web haproxy-config"
            [ "${SELFMASK_ENABLED:-false}" = "true" ] \
                && log_warn "Перед включением внешнего HAProxy отключите Selfmask"
            ;;
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

_tui_web_decoy_menu() {
    echo ""
    echo -e "  ${BOLD}Сайт-заглушка WEB${NC}"
    echo ""
    echo -e "  ${CYAN}[1]${NC}  Выключить ${DIM}— пустой ответ, по умолчанию${NC}"
    echo -e "  ${CYAN}[2]${NC}  Статический сайт или шаблон"
    echo -e "  ${CYAN}[3]${NC}  Приватный HTTP-origin"
    echo ""
    echo -e "  ${DIM}[0]${NC}  Отмена"
    local _c; _c=$(read_choice "выбор" "0")
    case "$_c" in
        1) web_set_param WEB_DECOY_MODE empty ;;
        2)
            web_set_param WEB_DECOY_MODE static_directory || return 0
            installer_pick_web_site || return 0
            web_set_param WEB_DECOY_SOURCE "$SELFMASK_SITE_SOURCE"
            ;;
        3)
            local _upstream; read_line _upstream "  ${BOLD}HTTP-origin [${WEB_DECOY_UPSTREAM:-http://127.0.0.1:18081}]:${NC} "
            [ -z "$_upstream" ] && _upstream="${WEB_DECOY_UPSTREAM:-http://127.0.0.1:18081}"
            web_set_param WEB_DECOY_UPSTREAM "$_upstream" || return 0
            web_set_param WEB_DECOY_MODE http_upstream
            ;;
    esac
}

tui_web_menu() {
    while true; do
        clear_screen
        draw_header "WEB PROXY"
        load_secrets 2>/dev/null || true
        web_status_print

        echo -e "  ${CYAN}[1]${NC}  $(web_is_enabled && ! web_can_disable && echo "Применить заново" || { web_is_enabled && echo "Выключить" || echo "Включить"; })"
        echo -e "  ${CYAN}[2]${NC}  Режим  ${DIM}$(proxy_transport_mode_title)${NC}"
        if mtproto_is_enabled; then
            echo -e "  ${CYAN}[3]${NC}  Раскладка портов  ${DIM}${WEB_LAYOUT:-shared}${NC}"
        else
            echo -e "  ${DIM}[3]  Раскладка не нужна без обычного MTProto${NC}"
        fi
        echo -e "  ${CYAN}[4]${NC}  Транспорт carrier  ${DIM}${WEB_CARRIER:-websocket}${NC}"
        echo -e "  ${CYAN}[5]${NC}  Frontend  ${DIM}$(web_frontend_title)${NC}"
        echo -e "  ${CYAN}[6]${NC}  Домен  ${DIM}$(web_domain 2>/dev/null || echo '—')${NC}"
        echo -e "  ${CYAN}[7]${NC}  Ссылки tg://webproxy"
        echo -e "  ${CYAN}[8]${NC}  Диагностика /web-status  ${DIM}$([ "${WEB_DEBUG:-false}" = "true" ] && echo "включена" || echo "выключена")${NC}"
        if web_frontend_has_haproxy; then
            echo -e "  ${CYAN}[9]${NC}  Конфигурация HAProxy"
        else
            echo -e "  ${CYAN}[9]${NC}  Пользовательский конфиг nginx  ${DIM}$(nginx_custom_status_line)${NC}"
        fi
        local _decoy_label="выключена"
        case "${WEB_DECOY_MODE:-empty}" in
            static_directory) _decoy_label=$(_selfmask_template_label "${SELFMASK_SITE_SOURCE:-stub}") ;;
            http_upstream) _decoy_label="HTTP-origin" ;;
        esac
        echo -e "  ${CYAN}[10]${NC} Заглушка  ${DIM}${_decoy_label}${NC}"
        echo ""
        echo -e "  ${DIM}[0]${NC}  Назад"
        echo ""
        local _c; _c=$(read_choice "выбор" "0")

        case "$_c" in
            1)
                if web_is_enabled && ! web_can_disable; then web_enable
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
            5) _tui_web_frontend_menu; press_any_key ;;
            6)
                echo ""
                if [ "${SELFMASK_ENABLED:-false}" = "true" ]; then
                    echo -e "  ${DIM}Пусто — взять поддомен web.<домен Selfmask>${NC}"
                else
                    echo -e "  ${DIM}Без Selfmask нужен собственный домен с A-записью на сервер.${NC}"
                fi
                local _d; read_line _d "  ${BOLD}Домен WEB [$(web_domain 2>/dev/null)]:${NC} "
                web_set_param WEB_DOMAIN "$_d"
                press_any_key ;;
            7) web_links_print; press_any_key ;;
            8)
                if [ "${WEB_DEBUG:-false}" = "true" ]; then
                    web_set_param WEB_DEBUG false
                else
                    web_set_param WEB_DEBUG true
                    echo ""
                    log_info "Страница: http://127.0.0.1:${PROXY_API_PORT:-9091}/web-status"
                    log_info "Нужен заголовок Authorization из [server.api] конфига движка"
                fi
                press_any_key ;;
            9)
                if web_frontend_has_haproxy; then
                    echo ""
                    web_haproxy_config
                    press_any_key
                else
                    tui_nginx_custom_menu
                fi ;;
            10) _tui_web_decoy_menu; press_any_key ;;
            0|"") return 0 ;;
        esac
    done
}
