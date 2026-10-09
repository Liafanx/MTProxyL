#!/bin/bash
# MTProxyL — подменю: цель / режим (Manager ⇄ Reanimator)

# Версия telemt цели: меняется только бинарник, конфиг цели остаётся.
_tui_target_engine() {
    clear_screen
    draw_header "ВЕРСИЯ TELEMT ЦЕЛИ"
    echo ""
    target_engine_status
    echo ""
    if [ -n "$(target_engine_unsupported_reason)" ]; then
        press_any_key
        return
    fi
    echo -e "  ${DIM}Меняется только бинарник, конфиг цели не трогается. Если новая версия${NC}"
    echo -e "  ${DIM}не поднимется с этим конфигом, прежняя вернётся сама.${NC}"
    echo ""
    echo -e "  ${DIM}[1]${NC} Поставить версию из списка"
    echo -e "  ${DIM}[2]${NC} Откатить на предыдущую"
    echo -e "  ${DIM}[0]${NC} Назад"
    local _c; _c=$(read_choice "выбор" "0")
    case "$_c" in
        1) handle_engine_command update || true; press_any_key ;;
        2) handle_engine_command rollback || true; press_any_key ;;
    esac
}

tui_target_menu() {
    while true; do
        clear_screen
        draw_header "ЦЕЛЬ / РЕЖИМ"
        echo ""
        echo -e "  ${BOLD}Текущий режим:${NC} ${MTPROXYL_MODE:-manager}"
        if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
            echo -e "  ${BOLD}Цель:${NC}          ${DETECTED_MODE:-unknown}$([ -n "$DETECTED_CONTAINER" ] && echo " (${DETECTED_CONTAINER})")"
            echo -e "  ${BOLD}Конфиг цели:${NC}   ${DETECTED_CONFIG_PATH:-нет}"
            echo -e "  ${BOLD}Сеть Docker:${NC}   ${DETECTED_NETWORK_MODE:-?}"
        fi
        echo ""
        # Установка оригинального telemt — только в реаниматоре: в режиме
        # менеджера MTProxyL ставит и обслуживает свой движок сам.
        local _telemt_item="false"
        [ "${MTPROXYL_MODE:-manager}" = "reanimator" ] && _telemt_item="true"

        echo -e "  ${DIM}[1]${NC} Повторить обнаружение цели"
        if [ "${MTPROXYL_MODE:-manager}" = "manager" ]; then
            echo -e "  ${DIM}[2]${NC} Переключиться в Reanimator"
        else
            echo -e "  ${DIM}[2]${NC} Переключиться в Manager"
        fi
        if [ "$_telemt_item" = "true" ]; then
            echo -e "  ${DIM}[3]${NC} Установить / обновить telemt (официальный установщик)"
            echo -e "  ${DIM}[4]${NC} Удалить telemt (официальный установщик)"
            if [ "${TOOLS_ONLY:-false}" = "true" ]; then
                echo -e "  ${DIM}[5]${NC} Только оптимизация: ${GREEN}включена${NC} — вернуть работу с движком"
            else
                echo -e "  ${DIM}[5]${NC} Только оптимизация ${DIM}(без движка: фиксы, лимитер, оптимизация)${NC}"
            fi
            echo -e "  ${DIM}[6]${NC} Версия telemt: обновить или откатить ${DIM}(только бинарник)${NC}"
        fi
        [ "${MTPROXYL_MODE:-manager}" = "reanimator" ] && \
            echo -e "  ${DIM}[7]${NC} Порт REST API цели [$(api_port_current)] ${DIM}(через него работает панель)${NC}"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) run_target_detection; save_detect_settings; sync_port_from_target; press_any_key ;;
            2)
                if [ "${MTPROXYL_MODE:-manager}" = "manager" ]; then
                    switch_to_reanimator_mode
                else
                    switch_to_manager_mode
                fi
                press_any_key ;;
            5)
                [ "$_telemt_item" = "true" ] || continue
                if [ "${TOOLS_ONLY:-false}" = "true" ]; then
                    TOOLS_ONLY="false"; save_settings
                    log_success "Работа с движком включена обратно"
                    run_target_detection 2>/dev/null && save_detect_settings 2>/dev/null || true
                else
                    echo ""
                    echo -e "  ${DIM}Пользователи, ссылки и статистика движка уйдут из меню:${NC}"
                    echo -e "  ${DIM}их неоткуда брать. Останутся фиксы хоста — zapret2, лимитер,${NC}"
                    echo -e "  ${DIM}оптимизация By-MEKO, гео-блокировка, дополнения.${NC}"
                    local _yn; read_line _yn "  ${BOLD}Включить режим «только оптимизация»? [y/N]:${NC} "
                    if [[ "$_yn" =~ ^[yY] ]]; then
                        TOOLS_ONLY="true"; save_settings
                        log_success "Только оптимизация: движок больше не трогаем"
                    fi
                fi
                press_any_key ;;
            3)
                [ "$_telemt_item" = "true" ] || continue
                install_original_telemt || true
                press_any_key ;;
            4)
                [ "$_telemt_item" = "true" ] || continue
                uninstall_original_telemt || true
                press_any_key ;;
            6)
                [ "$_telemt_item" = "true" ] || continue
                _tui_target_engine ;;
            7)
                [ "${MTPROXYL_MODE:-manager}" = "reanimator" ] || continue
                local _ap; read_line _ap "  ${BOLD}Новый порт API [$(api_port_current)]:${NC} "
                [ -n "$_ap" ] && { api_port_set "$_ap" || true; }
                press_any_key ;;
            0|"") return ;;
        esac
    done
}
