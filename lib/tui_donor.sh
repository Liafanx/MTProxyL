#!/bin/bash
# MTProxyL — меню: туннель AWG до сервера-донора

_tui_donor_state_label() {
    local _l; _l=$(donor_state_label 2>/dev/null)
    case "$_l" in
        "через "*)  echo -e "${GREEN}${_l}${NC}" ;;
        "не настроен"|"") echo -e "${DIM}не настроен${NC}" ;;
        *)          echo -e "${YELLOW}${_l}${NC}" ;;
    esac
}

_tui_donor_auto() {
    echo ""
    echo -e "  ${DIM}Нужен сервер, откуда Telegram открывается: Debian или Ubuntu на KVM,${NC}"
    echo -e "  ${DIM}вход root по паролю или ключу. Пароль нужен только на время настройки.${NC}"
    echo ""
    local _host _port _user _awg
    read_line _host "  ${BOLD}IP или домен донора:${NC} "
    _host="${_host// /}"
    [ -n "$_host" ] || return 0
    _donor_valid_host "$_host" || { log_error "Нужен IPv4-адрес или домен"; return 1; }
    read_line _port "  ${BOLD}Порт SSH [22]:${NC} "
    read_line _user "  ${BOLD}Пользователь [root]:${NC} "
    read_line _awg "  ${BOLD}UDP-порт туннеля на доноре [случайный]:${NC} "
    local -a _args=("$_host" --ssh-port "${_port:-22}" --user "${_user:-root}")
    [ -n "$_awg" ] && _args+=(--awg-port "$_awg")
    donor_setup "${_args[@]}"
}

_tui_donor_manual() {
    echo ""
    echo -e "  ${DIM}Скрипт настройки донора будет сохранён в файл — его запускают на доноре${NC}"
    echo -e "  ${DIM}от root сами. Пароль донора сюда вводить не нужно.${NC}"
    echo ""
    local _host _awg
    read_line _host "  ${BOLD}IP или домен донора:${NC} "
    _host="${_host// /}"
    [ -n "$_host" ] || return 0
    read_line _awg "  ${BOLD}UDP-порт туннеля на доноре [случайный]:${NC} "
    donor_manual "$_host" "$_awg" || return 1
    _tui_donor_finish
}

_tui_donor_finish() {
    echo ""
    local _key
    read_line _key "  ${BOLD}Публичный ключ донора (Enter — ввести позже):${NC} "
    _key="${_key// /}"
    [ -n "$_key" ] || { log_info "Позже: пункт «Ввести ключ донора» или mtproxyl donor finish <ключ>"; return 0; }
    donor_finish "$_key"
}

_tui_donor_remove() {
    echo ""
    log_warn "Туннель будет удалён, движок вернётся на прямые маршруты"
    local _yn _remote=()
    read_line _yn "  ${BOLD}Удалить и на доноре ${DONOR_HOST}? Понадобится пароль [Y/n]:${NC} "
    [[ "$_yn" =~ ^[nN] ]] || _remote=(--remote)
    read_line _yn "  ${BOLD}Удалить туннель? [y/N]:${NC} "
    [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 0; }
    donor_remove "${_remote[@]}"
}

tui_donor_menu() {
    while true; do
        clear_screen
        draw_header "ТУННЕЛЬ AWG ДО СЕРВЕРА-ДОНОРА"
        echo ""
        echo -e "  ${DIM}Для серверов, откуда не открываются Telegram или его дата-центры.${NC}"
        echo -e "  ${DIM}Движок выходит к Telegram через второй сервер — донор — по туннелю${NC}"
        echo -e "  ${DIM}AmneziaWG. Адрес выхода один, поэтому middle proxy (ME) работает.${NC}"
        donor_status
        donor_load
        local _ready=false _pending=false
        [ "$DONOR_STAGE" = ready ] && donor_configured && _ready=true
        [ "$DONOR_STAGE" = pending ] && _pending=true
        echo -e "  ${DIM}[1]${NC} Настроить автоматически — адрес, логин и пароль донора"
        echo -e "  ${DIM}[2]${NC} Ручная настройка — скрипт для донора и инструкция"
        if [ "$_ready" = true ]; then
            echo -e "  ${DIM}[3]${NC} Проверить туннель"
            if [ "$DONOR_ENABLED" = true ]; then
                echo -e "  ${DIM}[4]${NC} Выключить — движок пойдёт к Telegram напрямую"
            else
                echo -e "  ${DIM}[4]${NC} Включить — движок пойдёт через донор"
            fi
        fi
        [ "$_pending" = true ] && echo -e "  ${DIM}[5]${NC} Ввести ключ донора — завершить ручную настройку"
        if donor_configured; then
            echo -e "  ${DIM}[6]${NC} Удалить туннель"
            echo -e "  ${DIM}[7]${NC} Сменить адрес донора — IP или домен, без перенастройки"
        fi
        echo -e "  ${DIM}[0]${NC} Назад"
        local _c; _c=$(read_choice "выбор" "0")
        case "$_c" in
            1) _tui_donor_auto; press_any_key ;;
            2) _tui_donor_manual; press_any_key ;;
            3) [ "$_ready" = true ] && { donor_check; press_any_key; } ;;
            4)
                [ "$_ready" = true ] || continue
                if [ "$DONOR_ENABLED" = true ]; then
                    local _yn; read_line _yn "  ${BOLD}Выключить туннель и вернуть прямые маршруты? [y/N]:${NC} "
                    [[ "$_yn" =~ ^[yY] ]] && donor_disable
                else
                    donor_enable
                fi
                press_any_key ;;
            5) [ "$_pending" = true ] && { _tui_donor_finish; press_any_key; } ;;
            6) donor_configured && { _tui_donor_remove; press_any_key; } ;;
            7)
                donor_configured || continue
                echo ""
                echo -e "  ${DIM}С доменом туннель сам переходит на новый адрес из A-записи.${NC}"
                local _nh; read_line _nh "  ${BOLD}Новый IP или домен [${DONOR_HOST}]:${NC} "
                _nh="${_nh// /}"
                [ -n "$_nh" ] && donor_set_host "$_nh"
                press_any_key ;;
            0|"") return ;;
        esac
    done
}
