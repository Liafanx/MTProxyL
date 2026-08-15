#!/bin/bash
# MTProxyL — подменю: цель / режим (Manager ⇄ Reanimator)

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
        fi
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
                    echo -en "  ${BOLD}Включить режим «только оптимизация»? [y/N]:${NC} "
                    local _yn; read_line _yn
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
            0|"") return ;;
        esac
    done
}
