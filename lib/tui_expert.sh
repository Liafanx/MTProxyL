#!/bin/bash
# MTProxyL — подменю: режим эксперта

tui_expert_menu() {
    while true; do
        clear_screen
        draw_header "РЕЖИМ ЭКСПЕРТА"
        echo ""
        echo -e "  ${YELLOW}Прямое управление параметрами config.toml${NC}"
        echo -e "  ${DIM}Параметры применяются поверх сгенерированного конфига${NC}"
        echo ""
        expert_list 2>/dev/null
        echo -e "  ${DIM}[1]${NC} Добавить параметр"
        echo -e "  ${DIM}[2]${NC} Удалить параметр"
        echo -e "  ${DIM}[3]${NC} Очистить все"
        echo -e "  ${DIM}[4]${NC} Открыть config.toml в редакторе"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) echo -en "  ${BOLD}Секция:${NC} "; local s; read -r s
               echo -en "  ${BOLD}Ключ:${NC} "; local k; read -r k
               echo -en "  ${BOLD}Значение:${NC} "; local v; read -r v
               [ -n "$s" ] && [ -n "$k" ] && [ -n "$v" ] && { expert_set "$s" "$k" "$v"; reload_proxy_config 2>/dev/null || true; }
               press_any_key ;;
            2) echo -en "  ${BOLD}Ключ (или 'all'):${NC} "; local k; read -r k
               [ -n "$k" ] && { expert_clear "$k"; reload_proxy_config 2>/dev/null || true; }; press_any_key ;;
            3) expert_clear "all"; reload_proxy_config 2>/dev/null || true; press_any_key ;;
            4) handle_expert_command edit; press_any_key ;;
            0|"") return ;;
        esac
    done
}
