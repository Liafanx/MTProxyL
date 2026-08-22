#!/bin/bash
# MTProxyL — подменю: блокировка IP адресов

_tui_ipblock_state_label() {
    if [ "${IPBLOCK_ENABLED}" = "true" ]; then
        echo -e "${GREEN}включена${NC} ${DIM}(${IPBLOCK_ACTION}, $(ipblock_count))${NC}"
    else
        echo -e "${DIM}выключена${NC}"
    fi
}

tui_ipblock_menu() {
    while true; do
        clear_screen
        draw_header "БЛОКИРОВКА IP АДРЕСОВ"
        echo ""
        echo -e "  ${BOLD}Состояние:${NC} $(_tui_ipblock_state_label)"
        echo -e "  ${BOLD}Действие:${NC}  $(ipblock_action_title)"
        echo -e "  ${BOLD}Правила:${NC}   $(ipblock_rules_active && echo "применены" || echo "${DIM}нет${NC}")"
        echo -e "  ${BOLD}Отбито:${NC}    $(ipblock_hits_total) пакетов"
        echo ""
        if [ "${IPBLOCK_ENABLED}" = "true" ]; then
            echo -e "  ${DIM}[1]${NC} Выключить"
        else
            echo -e "  ${DIM}[1]${NC} Включить"
        fi
        echo -e "  ${DIM}[2]${NC} Что делать с адресом: drop / reject"
        echo -e "  ${DIM}[3]${NC} Показать список"
        echo -e "  ${DIM}[4]${NC} Добавить адрес или подсеть"
        echo -e "  ${DIM}[5]${NC} Удалить из списка"
        echo -e "  ${DIM}[6]${NC} Очистить список"
        echo -e "  ${DIM}[7]${NC} Переприменить правила"
        echo -e "  ${DIM}[8]${NC} Срабатывания по адресам"
        echo -e "  ${DIM}[9]${NC} Выгрузить список в файл"
        echo -e "  ${DIM}[10]${NC} Загрузить список из файла"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1)  if [ "${IPBLOCK_ENABLED}" = "true" ]; then ipblock_disable; else ipblock_enable; fi
                load_settings; press_any_key ;;
            2)  echo ""
                echo -e "  ${DIM}[1]${NC} ${RED}drop${NC}   — молча отбрасывать пакеты"
                echo -e "  ${DIM}[2]${NC} ${YELLOW}reject${NC} — отвечать отказом ICMP"
                local a; a=$(read_choice "выбор" "0")
                case "$a" in
                    1) ipblock_set_action drop ;;
                    2) ipblock_set_action reject ;;
                esac
                load_settings; press_any_key ;;
            3)  echo ""; ipblock_show_list; press_any_key ;;
            4)  echo ""
                echo -e "  ${DIM}Примеры: 203.0.113.7, 203.0.113.0/24, 2001:db8::/32${NC}"
                local e; e=$(read_choice "адрес или подсеть" "")
                if [ -n "$e" ]; then
                    local c; c=$(read_choice "комментарий (необязательно)" "")
                    ipblock_add "$e" "$c"
                fi
                load_settings; press_any_key ;;
            5)  echo ""; ipblock_show_list; echo ""
                local e; e=$(read_choice "что удалить" "")
                [ -n "$e" ] && ipblock_del "$e"
                load_settings; press_any_key ;;
            6)  echo ""
                local c; c=$(read_choice "удалить все записи? (yes/нет)" "нет")
                [[ "$c" =~ ^(y|Y|д|Д) ]] && ipblock_clear
                load_settings; press_any_key ;;
            7)  ipblock_apply && log_success "Правила переприменены"; press_any_key ;;
            8)  echo ""; ipblock_hits_show; press_any_key ;;
            9)  local f; f=$(read_choice "куда сохранить" "/root/mtproxyl-blocklist.txt")
                if [ -n "$f" ]; then ipblock_export > "$f" && log_success "Сохранено: ${f} ($(ipblock_count) записей)"; fi
                press_any_key ;;
            10) local f; f=$(read_choice "файл со списком" "")
                if [ -n "$f" ]; then
                    echo -e "  ${DIM}[1]${NC} заменить список   ${DIM}[2]${NC} добавить к текущему"
                    local m; m=$(read_choice "выбор" "1")
                    [ "$m" = "2" ] && ipblock_import "$f" append || ipblock_import "$f" replace
                fi
                load_settings; press_any_key ;;
            0|"") return ;;
        esac
    done
}
