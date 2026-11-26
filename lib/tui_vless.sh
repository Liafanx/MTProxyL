#!/bin/bash
# MTProxyL — подменю VLESS (Xray-core)

_tui_vless_state_label() {
    if [ "${VLESS_ENABLED:-false}" = true ]; then
        local _id="${VLESS_ACTIVE:-}" _row _name
        _row=$(_vless_link_row "$_id")
        if [ -n "$_row" ]; then
            _name=$(cut -d'|' -f2 <<< "$_row")
            echo -e "${GREEN}включён${NC} (${_name:-$_id})"
        else
            echo -e "${GREEN}включён${NC}"
        fi
    else
        echo -e "${DIM}выключен${NC}"
    fi
}

tui_vless_menu() {
    while true; do
        clear_screen
        draw_header "VLESS (XRAY)"
        echo ""
        vless_status
        echo -e "  ${DIM}[1]${NC} Включить весь трафик движка через VLESS"
        echo -e "  ${DIM}[2]${NC} Выключить"
        echo -e "  ${DIM}[3]${NC} Ссылки: добавить / список / активная"
        echo -e "  ${DIM}[4]${NC} Подписка: задать / обновить / отключить"
        echo -e "  ${DIM}[5]${NC} Проверить выход, Telegram и DC"
        echo -e "  ${DIM}[6]${NC} Обновить Xray-core"
        echo -e "  ${DIM}[7]${NC} Откатить Xray-core"
        echo -e "  ${DIM}[8]${NC} Перезапустить и переприменить"
        echo -e "  ${DIM}[0]${NC} Назад"
        echo ""
        local c; c=$(read_choice "выбор" "0")
        case "$c" in
            1) vless_on ;;
            2) vless_off ;;
            3) _tui_vless_links ;;
            4) _tui_vless_sub ;;
            5) vless_test ;;
            6) handle_vless_command update ;;
            7) handle_vless_command rollback ;;
            8) handle_vless_command recover ;;
            0|"") return ;;
        esac
        press_any_key
    done
}

_tui_vless_links() {
    while true; do
        clear_screen
        draw_header "VLESS: ССЫЛКИ"
        echo ""
        vless_link_list
        echo -e "  ${DIM}[1]${NC} Добавить ссылку vless://"
        echo -e "  ${DIM}[2]${NC} Сделать активной"
        echo -e "  ${DIM}[3]${NC} Удалить (один или несколько ID через пробел)"
        echo -e "  ${DIM}[0]${NC} Назад"
        echo ""
        local c; c=$(read_choice "выбор" "0")
        case "$c" in
            1)
                local u n
                read_line u "  Ссылка vless://: "
                [ -n "$u" ] || continue
                read_line n "  Имя (необязательно): "
                vless_link_add "$u" "$n" ;;
            2)
                local id; read_line id "  ID: "
                vless_link_use "$id" ;;
            3)
                local id
                read_line id "  ID (несколько через пробел): "
                [ -n "$id" ] || continue
                # shellcheck disable=SC2086
                vless_link_remove $id ;;
            0|"") return ;;
        esac
        press_any_key
    done
}

_tui_vless_sub() {
    clear_screen
    draw_header "VLESS: ПОДПИСКА"
    echo ""
    local u; u=$(_vless_sub_url)
    if [ -n "$u" ]; then
        echo -e "  Текущая: ${DIM}${u:0:48}…${NC}"
    else
        echo -e "  ${DIM}Подписка не задана${NC}"
    fi
    echo ""
    echo -e "  ${DIM}[1]${NC} Задать или заменить URL"
    echo -e "  ${DIM}[2]${NC} Обновить сейчас"
    echo -e "  ${DIM}[3]${NC} Отключить и удалить ссылки подписки"
    echo -e "  ${DIM}[0]${NC} Назад"
    echo ""
    local c; c=$(read_choice "выбор" "0")
    case "$c" in
        1) local url; read_line url "  https://: "; [ -n "$url" ] && vless_sub_set "$url" ;;
        2) vless_sub_refresh ;;
        3) vless_sub_off ;;
        *) return ;;
    esac
    press_any_key
}
