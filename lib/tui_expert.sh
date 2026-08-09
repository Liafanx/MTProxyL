#!/bin/bash
# MTProxyL — подменю: режим супер эксперта (только меню).
# Механика в lib/config.sh (superexpert_*), обычный режим эксперта —
# в lib/expert_catalog.sh и lib/expert_mode.sh.

tui_superexpert_menu() {
    while true; do
        clear_screen
        draw_header "РЕЖИМ СУПЕР ЭКСПЕРТА"
        echo ""
        echo -e "  ${BOLD}Статус:${NC} $(superexpert_status_line)"
        if [ -f "$SUPEREXPERT_FILE" ]; then
            local _users; _users=$(_superexpert_users 2>/dev/null | grep -c . || echo 0)
            echo -e "  ${BOLD}Файл:${NC}   ${SUPEREXPERT_FILE}"
            echo -e "  ${BOLD}В нём:${NC}  пользователей: ${_users}, порт: $(_toml_get_string_in_section "server" "port" "$SUPEREXPERT_FILE" 2>/dev/null || echo '?')"
        else
            echo -e "  ${BOLD}Файл:${NC}   ${DIM}ещё не создан${NC}"
        fi
        echo ""
        superexpert_show_rules
        echo ""

        if [ "${SUPEREXPERT_ENABLED:-false}" = "true" ]; then
            echo -e "  ${DIM}[1]${NC} Выключить режим ${DIM}(файл сохраняется)${NC}"
        else
            echo -e "  ${DIM}[1]${NC} Включить режим"
        fi
        echo -e "  ${DIM}[2]${NC} Редактировать конфиг"
        echo -e "  ${DIM}[3]${NC} Показать конфиг"
        echo -e "  ${DIM}[4]${NC} Пересоздать файл из текущего конфига менеджера"
        echo -e "  ${DIM}[0]${NC} Назад"

        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1)
                if [ "${SUPEREXPERT_ENABLED:-false}" = "true" ]; then
                    superexpert_disable || true
                else
                    superexpert_enable || true
                fi
                press_any_key ;;
            2) superexpert_edit || true; press_any_key ;;
            3)
                if [ -f "$SUPEREXPERT_FILE" ]; then
                    echo ""; draw_header "КОНФИГ СУПЕР ЭКСПЕРТА"; echo ""
                    sed 's/^/  /' "$SUPEREXPERT_FILE"; echo ""
                else
                    log_error "Файл ${SUPEREXPERT_FILE} не найден"
                fi
                press_any_key ;;
            4) superexpert_recreate || true; press_any_key ;;
            0|"") return ;;
        esac
    done
}
