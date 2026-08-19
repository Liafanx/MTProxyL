#!/bin/bash
# MTProxyL — главное меню

show_banner() {
    echo -e "${BRIGHT_CYAN}"
    cat << 'BANNER'

    ███╗   ███╗████████╗██████╗ ██████╗  ██████╗ ██╗  ██╗██╗   ██╗██╗
    ████╗ ████║╚══██╔══╝██╔══██╗██╔══██╗██╔═══██╗╚██╗██╔╝╚██╗ ██╔╝██║
    ██╔████╔██║   ██║   ██████╔╝██████╔╝██║   ██║ ╚███╔╝  ╚████╔╝ ██║
    ██║╚██╔╝██║   ██║   ██╔═══╝ ██╔══██╗██║   ██║ ██╔██╗   ╚██╔╝  ██║
    ██║ ╚═╝ ██║   ██║   ██║     ██║  ██║╚██████╔╝██╔╝ ██╗   ██║   ███████╗
    ╚═╝     ╚═╝   ╚═╝   ╚═╝     ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝   ╚═╝   ╚══════╝
BANNER
    echo -e "    ${BOLD}MTProxyL v${VERSION}${NC} ${DIM}by LiafanX${NC}"
    echo -e "${NC}"
}

show_main_menu() {
    while true; do
        clear 2>/dev/null || printf '\033[2J\033[H'
        show_banner

        local _running=false
        is_proxy_running && _running=true
        local _reanimator="false"
        [ "${MTPROXYL_MODE:-manager}" = "reanimator" ] && _reanimator="true"

        local status_str uptime_str t_in t_out conns uips="—"
        if [ "$_running" = "true" ]; then
            status_str=$(draw_status running)
            local up_secs; up_secs=$(get_proxy_uptime)
            uptime_str=$(format_duration "$up_secs")
            if [ "$_reanimator" != "true" ]; then
                flush_traffic_to_disk 2>/dev/null || true
                read -r t_in t_out conns <<< "$(get_persistent_stats)"
                # Уникальные IP считает только API движка: в метриках их нет.
                uips=$(_engine_unique_ips 2>/dev/null) || uips="—"
            fi
        else
            status_str=$(draw_status stopped)
            uptime_str="—"; t_in=0; t_out=0; conns=0
        fi

        local active=0 disabled=0 i _target_stats_ok="false"
        if [ "$_reanimator" = "true" ]; then
            fetch_target_stats && _target_stats_ok="true"
            conns="${TARGET_STATS_CONNS:-0}"
            active="${TARGET_STATS_ACTIVE:-0}"
            disabled="${TARGET_STATS_DISABLED:-0}"
        elif _superexpert_active; then
            # Пользователи заданы в конфиге супер эксперта, а не в secrets.conf
            active=$(_superexpert_users 2>/dev/null | grep -c . || echo 0)
        else
            for i in "${!SECRETS_ENABLED[@]}"; do
                [ "${SECRETS_ENABLED[$i]}" = "true" ] && active=$((active+1)) || disabled=$((disabled+1))
            done
        fi

        if [ "$_reanimator" = "true" ]; then
            if [ "${TOOLS_ONLY:-false}" = "true" ]; then
                echo -e "  ${BOLD}Режим:${NC}       ${BRIGHT_CYAN}Только оптимизация${NC}"
            else
                echo -e "  ${BOLD}Режим:${NC}       ${BRIGHT_CYAN}Reanimator${NC}  ${BOLD}Статус:${NC} ${status_str}"
            fi
            if [ "${TOOLS_ONLY:-false}" = "true" ]; then
                echo -e "  ${DIM}Движок не наш и не нужен: MTProxyL здесь — набор фиксов${NC}"
                echo -e "  ${DIM}для хоста (zapret2, лимитер, оптимизация, гео).${NC}"
            else
            echo -e "  ${BOLD}Цель:${NC}        ${DETECTED_MODE:-unknown}$([ -n "$DETECTED_CONTAINER" ] && echo " (${DETECTED_CONTAINER})")"
            echo -e "  ${BOLD}Конфиг цели:${NC} ${DETECTED_CONFIG_PATH:-${DIM}не найден${NC}}"
            if _no_telemt_target; then
                # Различаем «на сервере пусто» и «конфиг остался, а движка нет»:
                # во втором случае строка выше показывает путь к конфигу, и
                # сообщение «не найден» без уточнения выглядит противоречиво.
                if [ -n "${DETECTED_CONFIG_PATH:-}" ] && [ -f "${DETECTED_CONFIG_PATH}" ]; then
                    echo -e "  ${YELLOW}⚠ Конфиг остался, но самого telemt нет${NC}"
                    echo -e "  ${DIM}  Ни службы, ни контейнера, ни бинарника — чинить нечего${NC}"
                    echo -e "  ${DIM}  Поставить telemt заново: пункт «Установить telemt» ниже${NC}"
                    echo -e "  ${DIM}  Настройки из конфига установщик подхватит${NC}"
                else
                    echo -e "  ${YELLOW}⚠ telemt на сервере не найден — чинить нечего${NC}"
                    echo -e "  ${DIM}  Поставить оригинальный telemt: пункт «Установить telemt» ниже${NC}"
                    echo -e "  ${DIM}  Нужны только фиксы и оптимизация? Цель/режим → «Только оптимизация»${NC}"
                fi
            fi
            fi
        else
            echo -e "  ${BOLD}Движок:${NC}      telemt v$(get_telemt_version)  ${BOLD}Статус:${NC} ${status_str}"
            # Показываем только когда режим включён — выключенный не упоминаем
            if _superexpert_active; then
                echo -e "  ${YELLOW}${BOLD}Режим супер эксперта включён${NC} ${DIM}(конфиг: ${SUPEREXPERT_FILE})${NC}"
            elif [ "${SUPEREXPERT_ENABLED:-false}" = "true" ]; then
                echo -e "  ${RED}${BOLD}Режим супер эксперта включён, но файл не найден${NC}"
            fi
            # Контейнер есть, но не работает (например, порт занят и он
            # падает в цикле) — показываем причину, а не просто «ОСТАНОВЛЕН».
            if [ "$_running" != "true" ]; then
                local _prob; _prob=$(own_container_problem 2>/dev/null)
                [ -n "$_prob" ] && echo -e "  ${RED}Контейнер:${NC}   ${_prob}"
            fi
        fi
        if [ "$_reanimator" = "true" ] && [ "${TOOLS_ONLY:-false}" = "true" ]; then
            # Ни порта, ни домена, ни счётчиков у нас нет: движок чужой и
            # трогать его мы не собираемся. Показывать его домен-заглушку —
            # обманывать. Дальше сразу состояние фиксов.
            :
        else
        echo -e "  ${BOLD}Порт:${NC}        ${PROXY_PORT}            ${BOLD}Работает:${NC} ${uptime_str}"
        # Порт цели разошёлся с нашим — фиксы висят не на том порту
        if [ "$_reanimator" = "true" ] && [ -n "${DETECTED_PORT:-}" ] && [ "${DETECTED_PORT}" != "${PROXY_PORT}" ]; then
            echo -e "  ${YELLOW}⚠ Порт цели ${DETECTED_PORT}, а фиксы применяются к ${PROXY_PORT}${NC}"
            echo -e "  ${DIM}  Синхронизировать: Цель/режим → Повторить обнаружение${NC}"
        fi
        echo -e "  ${BOLD}Домен(SNI):${NC}  $(_current_sni_domain 2>/dev/null || echo "$PROXY_DOMAIN")"
        if [ "$_reanimator" = "true" ]; then
            if [ "$_target_stats_ok" = "true" ]; then
                echo -e "  ${BOLD}Трафик:${NC}      $(format_bytes "${TARGET_STATS_OCTETS:-0}")  ${BOLD}Соед.:${NC} ${conns}  ${BOLD}Уник. IP:${NC} ${TARGET_STATS_IPS:-0}"
                echo -e "  ${BOLD}Секреты:${NC}     ${active} активных / ${disabled} выключенных"
            else
                local _api_why; _api_why=$(_telemt_api_unavailable_reason 2>/dev/null)
                echo -e "  ${BOLD}Трафик:${NC}      ${DIM}н/д — ${_api_why:-API цели недоступен}${NC}"
                echo -e "  ${BOLD}Секреты:${NC}     ${DIM}н/д${NC}"
            fi
        elif _superexpert_active; then
            echo -e "  ${BOLD}Трафик:${NC}      ${SYM_DOWN} $(format_bytes "$t_in")  ${SYM_UP} $(format_bytes "$t_out")  ${BOLD}Соед.:${NC} ${conns}  ${BOLD}Уник. IP:${NC} ${uips}"
            echo -e "  ${BOLD}Секреты:${NC}     ${active} ${DIM}(из вашего конфига)${NC}"
        else
            echo -e "  ${BOLD}Трафик:${NC}      ${SYM_DOWN} $(format_bytes "$t_in")  ${SYM_UP} $(format_bytes "$t_out")  ${BOLD}Соед.:${NC} ${conns}  ${BOLD}Уник. IP:${NC} ${uips}"
            echo -e "  ${BOLD}Секреты:${NC}     ${active} активных / ${disabled} выключенных"
        fi
        fi

        load_nft_settings 2>/dev/null

        # Zapret2 — показываем первым
        echo -e "  ${BOLD}Zapret2 fix:${NC} $(zapret2_status 2>/dev/null || echo "${DIM}—${NC}")"

        # NFT limiter — скрываем если только zapret2 активен
        local _z_active="false" _l_active="false"
        nft list table ip "${ZAPRET2_NFT_TABLE:-MTProtoL}" &>/dev/null 2>&1 && _z_active="true"
        nft list table inet "${NFT_TABLE:-mtproxyl_limit}" &>/dev/null 2>&1 && _l_active="true"

        if [ "$_z_active" != "true" ] || [ "$_l_active" = "true" ]; then
            echo -e "  ${BOLD}NFT лимитер:${NC} $(nft_status_line 2>/dev/null || echo "${DIM}—${NC}")"
        fi

        # iOS фиксы — только если применены
        if [ "${IOS_FIX_ENABLED:-false}" = "true" ]; then
            echo -e "  ${BOLD}iOS фикс v1:${NC} $(ios_fix_status_line 2>/dev/null || echo "${DIM}—${NC}")"
        fi
        if [ "${IOS2_FIX_ENABLED:-false}" = "true" ]; then
            echo -e "  ${BOLD}iOS фикс v2:${NC} $(ios2_fix_status_line 2>/dev/null || echo "${DIM}—${NC}")"
        fi

        echo -e "  ${BOLD}MEKO оптим.:${NC} $(meko_opt_status 2>/dev/null || echo "${DIM}—${NC}")"
        echo -e "  ${BOLD}Selfmask:${NC}    $(selfmask_status_line 2>/dev/null || echo "${DIM}—${NC}")"
        # Только когда включён: на обычной установке строка была бы шумом.
        warp_menu_line 2>/dev/null || true

        if [ -n "$_UPDATE_AVAILABLE" ]; then
            echo ""
            echo -e "  ${YELLOW}${BOLD}⬆ Доступно обновление: v${VERSION} → v${_UPDATE_AVAILABLE}${NC}"
            echo -e "  ${DIM}  Обновить: меню обновлений → Проверить обновления${NC}"
        fi

        echo ""
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        echo ""
        # Пункты нумеруются подряд, только цифрами, 0 — выход. Набор
        # пунктов зависит от режима: в reanimator скрыто всё, что требует
        # владения конфигом/движком цели, поэтому нумерация своя.
        local choice
        if [ "$_reanimator" = "true" ] && [ "${TOOLS_ONLY:-false}" = "true" ]; then
            # Только то, что не требует движка. Пункты про пользователей,
            # ссылки и трафик цели здесь показывать нечем.
            echo -e "  ${BRIGHT_CYAN}[1]${NC}   NFT лимитер, Zapret2 и фиксы"
            echo -e "  ${BRIGHT_CYAN}[2]${NC}   Безопасность и маршрутизация"
            echo -e "  ${BRIGHT_CYAN}[3]${NC}   Дополнения (утилиты)"
            echo -e "  ${BRIGHT_CYAN}[4]${NC}   Обновление MTProxyL"
            echo -e "  ${BRIGHT_CYAN}[5]${NC}   Информация"
            echo -e "  ${BRIGHT_CYAN}[6]${NC}   Цель / режим — вернуться к работе с движком"
            echo ""
            echo -e "  ${BRIGHT_CYAN}[7]${NC}   Установка / переустановка"
            echo -e "  ${RED}[8]${NC}   Удаление"
            echo -e "  ${BRIGHT_CYAN}[0]${NC}   Выход"
            echo ""
            choice=$(read_choice "выбор" "0")
            case "$choice" in
                1) tui_nft_menu ;;
                2) tui_security_menu ;;
                3) tui_addons_menu ;;
                4) tui_backup_menu ;;
                5) show_server_info; press_any_key ;;
                6) tui_target_menu ;;
                7) run_installer ;;
                8) uninstall; exit 0 ;;
                0) exit 0 ;;
            esac
        elif [ "$_reanimator" = "true" ]; then
            # Цели на сервере нет — добавляем пункт установки оригинального
            # telemt: чинить пока нечего. Нумерация остаётся сплошной,
            # поэтому номера двух последних пунктов зависят от этого.
            local _n_telemt="__none__" _n_setup=13 _n_uninstall=14
            if _no_telemt_target; then
                _n_telemt=13; _n_setup=14; _n_uninstall=15
            fi
            echo -e "  ${BRIGHT_CYAN}[1]${NC}   Управление прокси"
            echo -e "  ${BRIGHT_CYAN}[2]${NC}   Пользователи цели"
            echo -e "  ${BRIGHT_CYAN}[3]${NC}   Ссылки на прокси"
            echo -e "  ${BRIGHT_CYAN}[4]${NC}   Безопасность и маршрутизация"
            echo -e "  ${BRIGHT_CYAN}[5]${NC}   Логи и трафик"
            echo -e "  ${BRIGHT_CYAN}[6]${NC}   NFT лимитер, Zapret2 и фиксы"
            echo -e "  ${BRIGHT_CYAN}[7]${NC}   Обновление MTProxyL"
            echo -e "  ${BRIGHT_CYAN}[8]${NC}   Телеграм бот  ${DIM}$(tgbot_status_line)${NC}"
            echo -e "  ${BRIGHT_CYAN}[9]${NC}   Дополнения (утилиты)"
            echo -e "  ${BRIGHT_CYAN}[10]${NC}  Цель / режим (Manager ⇄ Reanimator)"
            echo -e "  ${BRIGHT_CYAN}[11]${NC}  Редактировать конфиг цели"
            echo -e "  ${BRIGHT_CYAN}[12]${NC}  Информация"
            echo ""
            [ "$_n_telemt" != "__none__" ] && \
                echo -e "  ${GREEN}[${_n_telemt}]${NC}  Установить telemt (официальный установщик)"
            echo -e "  ${BRIGHT_CYAN}[${_n_setup}]${NC}  Установка / переустановка"
            echo -e "  ${RED}[${_n_uninstall}]${NC}  Удаление"
            echo -e "  ${BRIGHT_CYAN}[0]${NC}   Выход"
            echo ""
            choice=$(read_choice "выбор" "0")
            case "$choice" in
                1)  tui_proxy_menu ;;
                2)  tui_target_users_menu ;;
                3)  tui_links_menu ;;
                4)  tui_security_menu ;;
                5)  tui_traffic_menu ;;
                6)  tui_nft_menu ;;
                7)  tui_backup_menu ;;
                8)  tui_tgbot_menu ;;
                9)  tui_addons_menu ;;
                10) tui_target_menu ;;
                11) edit_target_config || true; press_any_key ;;
                12) show_server_info; press_any_key ;;
                "$_n_telemt")    install_original_telemt || true; press_any_key ;;
                "$_n_setup")     run_installer ;;
                "$_n_uninstall") uninstall; exit 0 ;;
                0)  exit 0 ;;
            esac
        else
            echo -e "  ${BRIGHT_CYAN}[1]${NC}   Управление прокси"
            echo -e "  ${BRIGHT_CYAN}[2]${NC}   Управление секретами (пользователями)"
            echo -e "  ${BRIGHT_CYAN}[3]${NC}   Ссылки на прокси"
            echo -e "  ${BRIGHT_CYAN}[4]${NC}   Настройки"
            echo -e "  ${BRIGHT_CYAN}[5]${NC}   Безопасность и маршрутизация"
            echo -e "  ${BRIGHT_CYAN}[6]${NC}   Логи и трафик"
            echo -e "  ${BRIGHT_CYAN}[7]${NC}   NFT лимитер, Zapret2 и фиксы"
            echo -e "  ${BRIGHT_CYAN}[8]${NC}   Движок Telemt"
            echo -e "  ${BRIGHT_CYAN}[9]${NC}   Обновление, бэкапы и миграция"
            echo -e "  ${BRIGHT_CYAN}[10]${NC}  Режим эксперта (override поверх config.toml)"
            echo -e "  ${BRIGHT_CYAN}[11]${NC}  Режим супер эксперта (свой config.toml)"
            echo -e "  ${BRIGHT_CYAN}[12]${NC}  Телеграм бот  ${DIM}$(tgbot_status_line)${NC}"
            echo -e "  ${BRIGHT_CYAN}[13]${NC}  Дополнения (утилиты)"
            echo -e "  ${BRIGHT_CYAN}[14]${NC}  Цель / режим (Manager ⇄ Reanimator)"
            echo -e "  ${BRIGHT_CYAN}[15]${NC}  Информация"
            echo ""
            echo -e "  ${BRIGHT_CYAN}[16]${NC}  Установка / переустановка"
            echo -e "  ${RED}[17]${NC}  Удаление"
            echo -e "  ${BRIGHT_CYAN}[0]${NC}   Выход"
            echo ""
            choice=$(read_choice "выбор" "0")
            case "$choice" in
                1)  tui_proxy_menu ;;
                2)  tui_secrets_menu ;;
                3)  tui_links_menu ;;
                4)  tui_settings_menu ;;
                5)  tui_security_menu ;;
                6)  tui_traffic_menu ;;
                7)  tui_nft_menu ;;
                8)  tui_engine_menu ;;
                9)  tui_backup_menu ;;
                10) tui_expert_menu ;;
                11) tui_superexpert_menu ;;
                12) tui_tgbot_menu ;;
                13) tui_addons_menu ;;
                14) tui_target_menu ;;
                15) show_server_info; press_any_key ;;
                16) run_installer ;;
                17) uninstall; exit 0 ;;
                0)  exit 0 ;;
            esac
        fi
    done
}
