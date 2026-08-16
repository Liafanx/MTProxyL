#!/bin/bash
# MTProxyL — подменю: телеграм-бот

tui_tgbot_menu() {
    while true; do
        clear_screen
        draw_header "ТЕЛЕГРАМ БОТ"
        echo ""

        if ! tgbot_installed; then
            echo -e "  ${BOLD}Состояние:${NC} ${DIM}не установлен${NC}"
            echo ""
            echo -e "  ${DIM}Бот управляет прокси кнопками в Telegram: пользователи, ссылки${NC}"
            echo -e "  ${DIM}с QR-кодами, трафик, доступность из России, бэкапы и${NC}"
            echo -e "  ${DIM}уведомления, когда что-то пошло не так.${NC}"
            echo ""
            echo -e "  ${DIM}Ставится в ${TGBOT_DIR} на python в venv, работает от${NC}"
            echo -e "  ${DIM}отдельного пользователя без прав — к MTProxyL ходит через${NC}"
            echo -e "  ${DIM}sudo по списку разрешённых команд.${NC}"
            echo ""
            echo -e "  ${GREEN}[1]${NC}  Установить бота"
            echo ""
            echo -e "  ${DIM}[0]${NC}  Назад"
            echo ""
            local c; c=$(read_choice "выбор" "0")
            case "$c" in
                1) tgbot_install; press_any_key ;;
                0|"") return ;;
            esac
            continue
        fi

        echo -e "  ${BOLD}Состояние:${NC}   $(tgbot_status_line)"
        echo -e "  ${BOLD}Каталог:${NC}     ${TGBOT_DIR}"
        local _admins; _admins=$(_tgbot_admins | tr '\n' ' ')
        echo -e "  ${BOLD}Админы:${NC}      ${_admins:-${DIM}никого — бот никого не пустит${NC}}"
        _tui_tgbot_notify_lines
        echo ""

        echo -e "  ${CYAN}[1]${NC}  $(tgbot_service_active && echo "Перезапустить" || echo "Запустить") бота"
        echo -e "  ${CYAN}[2]${NC}  Остановить"
        echo -e "  ${CYAN}[3]${NC}  Токен и администратор заново"
        echo -e "  ${CYAN}[4]${NC}  Администраторы: добавить / убрать"
        echo -e "  ${CYAN}[5]${NC}  Уведомления и таймеры"
        echo -e "  ${CYAN}[6]${NC}  Автобэкап в телеграм"
        echo -e "  ${CYAN}[7]${NC}  Прокси для Telegram: $(_tui_tgbot_proxy_line)"
        echo -e "  ${CYAN}[8]${NC}  Журнал службы"
        echo -e "  ${CYAN}[9]${NC}  Обновить код бота"
        echo -e "  ${CYAN}[10]${NC} Переустановить"
        echo -e "  ${RED}[11]${NC} Удалить бота"
        echo ""
        echo -e "  ${DIM}[0]${NC}  Назад"
        echo ""

        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1)
                if tgbot_service_active; then
                    systemctl restart "$TGBOT_SERVICE" && log_success "Перезапущен"
                else
                    systemctl start "$TGBOT_SERVICE" && log_success "Запущен"
                fi
                sleep 2
                tgbot_service_active || journalctl -u "$TGBOT_SERVICE" -n 10 --no-pager | sed 's/^/    /'
                press_any_key ;;
            2)  systemctl stop "$TGBOT_SERVICE" && log_success "Остановлен"; press_any_key ;;
            3)  tgbot_setup; press_any_key ;;
            4)  _tui_tgbot_admins; press_any_key ;;
            5)  _tui_tgbot_notify ;;
            6)  _tui_tgbot_autobackup ;;
            7)  _tui_tgbot_proxy; press_any_key ;;
            8)  journalctl -u "$TGBOT_SERVICE" -n 60 --no-pager; press_any_key ;;
            9)  tgbot_update_sources && log_success "Код обновлён, бот перезапущен"; press_any_key ;;
            10) tgbot_install; press_any_key ;;
            11) tgbot_uninstall; press_any_key; return ;;
            0|"") return ;;
        esac
    done
}

# ── Конфиг бота из меню ───────────────────────────────────────
# Тот же config.json, что правит и сам бот: у файла один формат и одни
# значения по умолчанию, поэтому читаем и пишем его через jq.

_tgbot_cfg_get() {
    local _path="$1" _default="$2"
    command -v jq &>/dev/null || { echo "$_default"; return 0; }
    [ -s "$TGBOT_CONFIG" ] || { echo "$_default"; return 0; }
    local _v; _v=$(jq -r "${_path} // empty" "$TGBOT_CONFIG" 2>/dev/null)
    echo "${_v:-$_default}"
}

_tgbot_cfg_set() {
    local _expr="$1"
    command -v jq &>/dev/null || { log_error "Нужен jq"; return 1; }
    local _tmp; _tmp=$(mktemp "${TGBOT_DIR}/.config.XXXXXX") || return 1
    if ! jq "$_expr" "$TGBOT_CONFIG" > "$_tmp" 2>/dev/null; then
        rm -f "$_tmp"
        log_error "Не удалось изменить настройку"
        return 1
    fi
    mv -f "$_tmp" "$TGBOT_CONFIG"
    chown "$TGBOT_USER":"$TGBOT_USER" "$TGBOT_CONFIG" 2>/dev/null || true
    chmod 600 "$TGBOT_CONFIG"
    return 0
}

_tgbot_flag() {
    [ "$(_tgbot_cfg_get ".notify.$1" "true")" = "true" ] \
        && echo -e "${GREEN}вкл${NC}" || echo -e "${DIM}выкл${NC}"
}

# Через что бот ходит в Telegram. Пусто в конфиге — напрямую.
_tui_tgbot_proxy_line() {
    local _p=""
    command -v jq &>/dev/null && [ -s "$TGBOT_CONFIG" ] && \
        _p=$(jq -r '.proxy // ""' "$TGBOT_CONFIG" 2>/dev/null)
    if [ -n "$_p" ] && [ "$_p" != "null" ]; then
        echo -e "${GREEN}${_p}${NC}"
    else
        echo -e "${DIM}напрямую${NC}"
    fi
}

# Локальный SOCKS5 на случай, когда серверы Telegram с хоста недоступны.
_tui_tgbot_proxy() {
    echo ""
    echo -e "  ${DIM}Бот пойдёт к Telegram через локальный SOCKS5. Поднимаете его вы —${NC}"
    echo -e "  ${DIM}MTProxyL прокси не ставит и за ним не следит.${NC}"
    echo -e "  ${DIM}Формат: socks5://[логин:пароль@]хост:порт, 'off' — напрямую.${NC}"
    echo -en "  ${BOLD}Прокси:${NC} "
    local _v; read_line _v
    [ -n "$_v" ] || return 0
    tgbot_set_param proxy "$_v" || return 1
    # Сессию бот создаёт на старте — без перезапуска настройка не применится.
    systemctl restart "$TGBOT_SERVICE" 2>/dev/null \
        && log_success "Бот перезапущен" \
        || log_warn "Перезапустите бота вручную, чтобы настройка применилась"
}

_tui_tgbot_notify_lines() {
    command -v jq &>/dev/null || return 0
    [ -s "$TGBOT_CONFIG" ] || return 0
    echo -e "  ${BOLD}Уведомления:${NC} доступность $(_tgbot_flag availability), DC $(_tgbot_flag dc)$([ "$(_dc_threshold)" -eq 0 ] && echo " ${DIM}(порог выключен)${NC}"), прокси $(_tgbot_flag proxy), лимиты $(_tgbot_flag limits), бэкапы $(_tgbot_flag backup)"
}

_tui_tgbot_notify() {
    while true; do
        clear_screen
        draw_header "УВЕДОМЛЕНИЯ БОТА"
        echo ""
        echo -e "  ${DIM}Бот пишет при смене состояния, а не на каждой проверке.${NC}"
        echo ""
        local _dc_thr; _dc_thr=$(_dc_threshold)
        local _dc_thr_line="ниже ${_dc_thr}%"
        [ "$_dc_thr" -eq 0 ] && _dc_thr_line="порог выключен"
        echo -e "  ${CYAN}[1]${NC}  Доступность ниже порога: $(_tgbot_flag availability)  ${DIM}(каждые $(_tgbot_cfg_get '.intervals.availability' 15) мин)${NC}"
        echo -e "  ${CYAN}[2]${NC}  Дата-центры Telegram, ${_dc_thr_line}: $(_tgbot_flag dc)  ${DIM}(каждые $(_tgbot_cfg_get '.intervals.dc' 15) мин)${NC}"
        echo -e "  ${CYAN}[3]${NC}  Прокси упал / поднялся: $(_tgbot_flag proxy)  ${DIM}(каждые $(_tgbot_cfg_get '.intervals.proxy' 5) мин)${NC}"
        echo -e "  ${CYAN}[4]${NC}  Лимиты пользователей: $(_tgbot_flag limits)  ${DIM}(каждые $(_tgbot_cfg_get '.intervals.limits' 60) мин)${NC}"
        echo -e "  ${CYAN}[5]${NC}  Итог автобэкапа: $(_tgbot_flag backup)"
        echo ""
        echo -e "  ${CYAN}[6]${NC}  Изменить период проверки"
        echo -e "  ${CYAN}[7]${NC}  Порог покрытия дата-центров: ${_dc_thr}%"
        echo -e "  ${DIM}[0]${NC}  Назад"
        echo ""
        local c; c=$(read_choice "выбор" "0")
        case "$c" in
            1) _tgbot_cfg_set '.notify.availability = (.notify.availability | not)' ;;
            2) _tgbot_cfg_set '.notify.dc = (.notify.dc | not)' ;;
            3) _tgbot_cfg_set '.notify.proxy = (.notify.proxy | not)' ;;
            4) _tgbot_cfg_set '.notify.limits = (.notify.limits | not)' ;;
            5) _tgbot_cfg_set '.notify.backup = (.notify.backup | not)' ;;
            6) _tui_tgbot_interval ;;
            7) _tui_tgbot_dc_threshold ;;
            0|"") return ;;
        esac
    done
}

# Порог общий для бота, панели и CLI — он живёт в настройках MTProxyL, а не в
# конфиге бота, поэтому и меняется командой dc.
_tui_tgbot_dc_threshold() {
    echo ""
    echo -e "  ${DIM}Ниже этого покрытия бот пишет о просадке. 0 — не писать вовсе.${NC}"
    echo -en "  ${BOLD}Порог, %${NC} ${DIM}(сейчас $(_dc_threshold))${NC}: "
    local _v; read_line _v
    [ -n "$_v" ] || return 0
    dc_set_threshold "$_v" || true
    press_any_key
}

_tui_tgbot_interval() {
    echo ""
    echo -e "  ${BOLD}Какой период менять?${NC}"
    echo -e "    ${CYAN}[1]${NC} доступность   ${CYAN}[2]${NC} прокси   ${CYAN}[3]${NC} лимиты   ${CYAN}[4]${NC} дата-центры"
    local _what; _what=$(read_choice "выбор" "0")
    local _key
    case "$_what" in
        1) _key="availability" ;;
        2) _key="proxy" ;;
        3) _key="limits" ;;
        4) _key="dc" ;;
        *) return ;;
    esac
    echo -en "  ${BOLD}Минут${NC} ${DIM}(текущее $(_tgbot_cfg_get ".intervals.${_key}" 15))${NC}: "
    local _v; read_line _v
    [[ "$_v" =~ ^[0-9]+$ ]] && [ "$_v" -ge 1 ] && [ "$_v" -le 1440 ] || {
        log_error "Нужно число от 1 до 1440"
        press_any_key
        return 1
    }
    _tgbot_cfg_set ".intervals.${_key} = ${_v}" && log_success "Период: ${_v} мин"
}

_tui_tgbot_autobackup() {
    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
        log_warn "Бэкапы доступны только в режиме менеджера"
        press_any_key
        return 0
    fi
    while true; do
        clear_screen
        draw_header "АВТОБЭКАП В ТЕЛЕГРАМ"
        echo ""
        local _on _time _file
        _on=$(_tgbot_cfg_get '.autobackup.enabled' "false")
        _time=$(_tgbot_cfg_get '.autobackup.time' "05:30")
        _file=$(_tgbot_cfg_get '.autobackup.send_file' "true")
        echo -e "  ${BOLD}Автобэкап:${NC}   $([ "$_on" = "true" ] && echo -e "${GREEN}включён${NC}" || echo -e "${DIM}выключен${NC}")"
        echo -e "  ${BOLD}Время:${NC}       ${_time} ${DIM}(по времени сервера)${NC}"
        echo -e "  ${BOLD}Файл в чат:${NC}  $([ "$_file" = "true" ] && echo "да" || echo "нет")"
        echo ""
        echo -e "  ${CYAN}[1]${NC}  $([ "$_on" = "true" ] && echo "Выключить" || echo "Включить")"
        echo -e "  ${CYAN}[2]${NC}  Изменить время"
        echo -e "  ${CYAN}[3]${NC}  Присылать файл: $([ "$_file" = "true" ] && echo "да → нет" || echo "нет → да")"
        echo ""
        echo -e "  ${DIM}[0]${NC}  Назад"
        echo ""
        local c; c=$(read_choice "выбор" "0")
        case "$c" in
            1) _tgbot_cfg_set '.autobackup.enabled = (.autobackup.enabled | not)' ;;
            2)
                echo -en "  ${BOLD}Время в формате ЧЧ:ММ:${NC} "
                local _v; read_line _v
                if [[ "$_v" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                    _tgbot_cfg_set ".autobackup.time = \"${_v}\"" && log_success "Время: ${_v}"
                else
                    log_error "Формат ЧЧ:ММ, например 05:30"
                fi
                press_any_key ;;
            3) _tgbot_cfg_set '.autobackup.send_file = (.autobackup.send_file | not)' ;;
            0|"") return ;;
        esac
    done
}

_tui_tgbot_admins() {
    echo ""
    echo -e "  ${BOLD}Администраторы бота${NC}"
    local _list; _list=$(_tgbot_admins)
    if [ -n "$_list" ]; then
        echo "$_list" | sed 's/^/    /'
    else
        echo -e "    ${DIM}никого${NC}"
    fi
    echo ""
    echo -e "    ${CYAN}[1]${NC} Добавить   ${CYAN}[2]${NC} Убрать   ${DIM}[0]${NC} Назад"
    local c; c=$(read_choice "выбор" "0")
    case "$c" in
        1) tgbot_add_admin ;;
        2) tgbot_remove_admin ;;
    esac
}
