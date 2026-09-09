#!/bin/bash
# MTProxyL — подменю: маршрут до Telegram через Cloudflare WARP

_tui_warp_state_label() {
    if [ "${WARP_ENABLED:-false}" != "true" ]; then
        echo -e "${DIM}выключен${NC}"
        return 0
    fi
    local _variant; _variant=$(_warp_variant_letter)
    if warp_route_ready >/dev/null 2>&1; then
        echo -e "${GREEN}вариант ${_variant}${NC}"
    else
        echo -e "${YELLOW}вариант ${_variant}, не запущен${NC}"
    fi
}

# Объяснение висит в меню: от выбора зависит, встанет ли это вообще.
_tui_warp_explain() {
    echo -e "  ${BOLD}Вариант A — SOCKS5 warpscout + redsocks${NC} ${DIM}(по умолчанию)${NC}"
    echo -e "    ${DIM}Туннель поднимает сам warpscout, ядро ни при чём. Умеет awg и${NC}"
    echo -e "    ${DIM}masque — обфускацию, которая проходит там, где обычный${NC}"
    echo -e "    ${DIM}WireGuard режут по сигнатуре рукопожатия.${NC}"
    echo -e "    ${DIM}Подводные камни: туннель один, без запасного узла — при${NC}"
    echo -e "    ${DIM}обрыве службу поднимает systemd и заново ищет эндпоинт${NC}"
    echo -e "    ${DIM}(это минута-другая); в тракте лишний процесс redsocks;${NC}"
    echo -e "    ${DIM}заворачивается только TCP.${NC}"
    echo ""
    echo -e "  ${BOLD}Вариант B — интерфейс WireGuard + policy routing${NC}"
    echo -e "    ${DIM}Обычный wg-туннель в ядре, маршрут выбирается по метке.${NC}"
    echo -e "    ${DIM}Переподключается сам, лишних процессов нет, MTU честный.${NC}"
    echo -e "    ${DIM}Подводные камни: только чистый WireGuard — там, где его${NC}"
    echo -e "    ${DIM}блокируют по сигнатуре, рукопожатия не будет вовсе;${NC}"
    echo -e "    ${DIM}нужен модуль ядра wireguard и пакет wireguard-tools.${NC}"
    echo ""
    echo ""
    echo -e "  ${BOLD}Вариант C — socks5-upstream в конфиге движка${NC}"
    echo -e "    ${DIM}Правил в ядре нет вовсе: туннель поднимает warpscout, а telemt${NC}"
    echo -e "    ${DIM}сам ходит через него по своему конфигу. Самый простой путь,${NC}"
    echo -e "    ${DIM}если движок наш.${NC}"
    echo -e "    ${DIM}Подводные камни: через socks уходит весь исходящий трафик${NC}"
    echo -e "    ${DIM}движка, и локальный mask-бэкенд приходится возвращать на прямой${NC}"
    echo -e "    ${DIM}маршрут отдельной областью. В режиме менеджера MTProxyL делает${NC}"
    echo -e "    ${DIM}это сам, у чужой цели — печатает, что дописать в её конфиг.${NC}"
    echo ""
    echo -e "  ${YELLOW}Цена процессора.${NC} ${DIM}В A и C шифрует не ядро, а warpscout в${NC}"
    echo -e "    ${DIM}пользовательском пространстве, и через него идёт весь трафик${NC}"
    echo -e "    ${DIM}прокси. Замер на Xeon E5-2699 v4: 100 МБ за 2,8 с (300 Мбит/с)${NC}"
    echo -e "    ${DIM}стоили 3,8 с процессорного времени — 1,35 ядра. Тот же файл${NC}"
    echo -e "    ${DIM}напрямую: 0,55 с и 0,26 с CPU. Грубо — около половины ядра${NC}"
    echo -e "    ${DIM}на каждые 100 Мбит/с. В B шифрует ядро, и этой платы нет.${NC}"
    echo ""
    echo -e "  ${DIM}Проще так: нагруженный сервер и wg проходит — берите B. Свой${NC}"
    echo -e "  ${DIM}telemt и трафика немного — C; готовы править чужой конфиг${NC}"
    echo -e "  ${DIM}руками — тоже C; если разведка не находит живых эндпоинтов${NC}"
    echo -e "  ${DIM}(wg режут по сигнатуре) — A.${NC}"
}

_tui_warp_scan_pick() {
    handle_warp_command scan "${1:-$(_warp_mode)}" || return 1
    local _n _ep
    jq -r '.nodes | to_entries[] | "  [\(.key+1)] \(.value.node) \(.value.endpoint) — \(.value.tunnel_ping // .value.ping)"' "$(_warp_scan_file)"
    echo "  [0] Назад без выбора. Первый адрес рекомендован по результатам разведки."
    _n=$(read_choice "выбор" "0")
    [[ "$_n" =~ ^[0-9]{1,4}$ ]] && [ "$((10#$_n))" -gt 0 ] || return 1
    _ep=$(jq -r --argjson n "$((10#$_n - 1))" '.nodes[$n].endpoint // empty' "$(_warp_scan_file)")
    [ -n "$_ep" ] || return 1
    handle_warp_command endpoint "$_ep"
}

tui_warp_menu() {
    while true; do
        load_settings
        clear_screen
        draw_header "TELEGRAM ЧЕРЕЗ WARP"
        echo ""
        echo -e "  ${DIM}В туннель уходят только подсети Telegram. Клиенты приходят${NC}"
        echo -e "  ${DIM}на сервер как раньше — их путь не меняется.${NC}"
        echo ""

        if [ "${WARP_ENABLED:-false}" = "true" ]; then
            local _variant="A — SOCKS5 + redsocks"
            [ "$(_warp_mode)" = "iface" ] && _variant="B — интерфейс ${WARP_IFACE}"
            [ "$(_warp_mode)" = "upstream" ] && _variant="C — socks5-upstream движка"
            echo -e "  ${BOLD}Состояние:${NC} $(_tui_warp_state_label) ${DIM}(${_variant})${NC}"
            echo -e "  ${BOLD}Рабочий адрес:${NC} $(_warp_active_endpoint)"
            echo -e "  ${BOLD}Закреплённый:${NC} ${WARP_ENDPOINT:-${DIM}автовыбор${NC}}"
            local _exit; _exit=$(warp_exit_info 2>/dev/null)
            if [ -n "$_exit" ]; then
                local _ip _loc _colo; IFS='|' read -r _ip _loc _colo <<< "$_exit"
                echo -e "  ${BOLD}Выход:${NC}     ${_ip}, ${_loc} ${DIM}(узел ${_colo})${NC}"
                echo -e "  ${BOLD}Уведено:${NC}   $(warp_matched_packets) пакетов до Telegram"
            fi
        else
            echo -e "  ${BOLD}Состояние:${NC} ${DIM}выключен, трафик до Telegram идёт напрямую${NC}"
        fi
        echo ""

        echo -e "  ${DIM}[1]${NC} Включить вариант A ${DIM}(SOCKS5 + redsocks, обфускация)${NC}"
        echo -e "  ${DIM}[2]${NC} Включить вариант B ${DIM}(интерфейс WireGuard)${NC}"
        echo -e "  ${DIM}[3]${NC} Включить вариант C ${DIM}(socks5-upstream движка, без правил)${NC}"
        echo -e "  ${DIM}[4]${NC} Выключить"
        echo ""
        echo -e "  ${DIM}[5]${NC} Локация выхода: ${WARP_LOCATION:-лучший по задержке}"
        echo -e "  ${DIM}[6]${NC} Разведка эндпоинтов"
        echo -e "  ${DIM}[7]${NC} Эндпоинт: ${WARP_ENDPOINT:-выбирается разведкой}"
        echo -e "  ${DIM}[8]${NC} Протокол вариантов A и C: ${WARP_PROTO:-awg}"
        echo -e "  ${DIM}[9]${NC} Подробное состояние"
        echo -e "  ${DIM}[10]${NC} Чем отличаются варианты"
        echo -e "  ${DIM}[11]${NC} Переприменить правила"
        echo -e "  ${DIM}[12]${NC} Что дописать в конфиг чужой цели (вариант C)"
        echo -e "  ${DIM}[13]${NC} Удалить warpscout и службы"
        echo -e "  ${DIM}[14]${NC} Применить сохранённый выбор"
        echo -e "  ${DIM}[15]${NC} Восстановить туннель"
        echo -e "  ${DIM}[16]${NC} Автовосстановление: ${WARP_WATCHDOG_ENABLED:-true}"
        echo -e "  ${DIM}[17]${NC} Обновить warpscout"
        echo -e "  ${DIM}[0]${NC} Назад"
        echo ""

        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) _tui_warp_enable socks ;;
            2) _tui_warp_enable iface ;;
            3) _tui_warp_enable upstream ;;
            4) handle_warp_command off; press_any_key ;;
            5) _tui_warp_location ;;
            6) _tui_warp_scan_pick; press_any_key ;;
            7) _tui_warp_endpoint ;;
            8) _tui_warp_proto ;;
            9) warp_status; press_any_key ;;
            10) echo ""; _tui_warp_explain; press_any_key ;;
            11) handle_warp_command reapply; press_any_key ;;
            12) _warp_upstream_manual_hint; press_any_key ;;
            13)
                echo ""
                local _yn; read_line _yn "  ${BOLD}Удалить warpscout, службы и правила? [y/N]:${NC} "
                [[ "$_yn" =~ ^[yY] ]] && handle_warp_command remove
                press_any_key ;;
            14) handle_warp_command apply; press_any_key ;;
            15) handle_warp_command recover; press_any_key ;;
            16)
                if [ "${WARP_WATCHDOG_ENABLED:-true}" = true ]; then
                    handle_warp_command watchdog off
                else
                    handle_warp_command watchdog on
                fi
                press_any_key ;;
            17) handle_warp_command install; press_any_key ;;
            0|"") return ;;
        esac
    done
}

_tui_warp_enable() {
    local _mode="$1"
    echo ""
    if [ "$_mode" = "iface" ]; then
        echo -e "  ${DIM}Вариант B работает только по чистому WireGuard. Если его режут${NC}"
        echo -e "  ${DIM}по сигнатуре, разведка не найдёт ни одного живого эндпоинта —${NC}"
        echo -e "  ${DIM}тогда берите вариант A.${NC}"
    elif [ "$_mode" = "upstream" ]; then
        echo -e "  ${DIM}Вариант C ничего не пишет в ядро: маршрут задаёт сам движок.${NC}"
        echo -e "  ${DIM}В режиме менеджера MTProxyL пропишет его сам; у чужой цели${NC}"
        echo -e "  ${DIM}поднимет туннель и покажет, что дописать в её конфиг.${NC}"
    else
        echo -e "  ${DIM}Вариант A поднимает туннель в самом warpscout: обфускация awg${NC}"
        echo -e "  ${DIM}проходит там, где обычный WireGuard блокируют.${NC}"
    fi
    echo -e "  ${DIM}Разведка занимает несколько минут — прерывать не нужно.${NC}"
    echo ""
    if [ -z "${WARP_ENDPOINT:-}" ]; then
        _tui_warp_scan_pick "$_mode" || { press_any_key; return; }
    fi
    handle_warp_command on "$_mode"
    press_any_key
}

_tui_warp_location() {
    echo ""
    echo -e "  ${BOLD}Где выходить в интернет${NC}"
    echo -e "  ${DIM}[1]${NC} Лучший по задержке ${DIM}(по умолчанию: берём самый быстрый живой)${NC}"
    echo -e "  ${DIM}[2]${NC} Конкретная локация"
    echo -e "  ${DIM}[0]${NC} Отмена"
    local _c; _c=$(read_choice "выбор" "0")
    case "$_c" in
        1) handle_warp_command settings keep clear clear ;;
        2)
            warp_scan_print 2>/dev/null || true
            echo ""
            echo -e "  ${DIM}Вводите через запятую, регистр не важен:${NC}"
            echo -e "  ${DIM}  страны двумя буквами — DE, NL, FI, SE, TR;${NC}"
            echo -e "  ${DIM}  узлы Cloudflare тремя, по коду аэропорта — FRA, AMS, HEL, ARN.${NC}"
            echo -e "  ${DIM}Можно смешивать: DE,AMS. Чем уже список, тем выше шанс,${NC}"
            echo -e "  ${DIM}что живых эндпоинтов не найдётся вовсе.${NC}"
            local _v; read_line _v "  ${BOLD}Локация:${NC} "
            [ -n "$_v" ] && handle_warp_command settings keep "$_v" clear
            ;;
        *) return 0 ;;
    esac
    press_any_key
}

_tui_warp_endpoint() {
    echo ""
    echo -e "  ${DIM}Закреплённый адрес избавляет от полной разведки при старте.${NC}"
    echo -e "  ${DIM}Если он замолчит, MTProxyL всё равно найдёт новый.${NC}"
    echo -e "  ${DIM}Формат: 188.114.98.58:2408, «clear» — выбирать разведкой.${NC}"
    local _v; read_line _v "  ${BOLD}Эндпоинт:${NC} "
    [ -n "$_v" ] && handle_warp_command endpoint "$_v"
    press_any_key
}

_tui_warp_proto() {
    echo ""
    echo -e "  ${BOLD}Протокол туннеля (варианты A и C)${NC}"
    echo -e "  ${DIM}[1]${NC} awg ${DIM}— обфусцированный WireGuard, проходит чаще всего${NC}"
    echo -e "  ${DIM}[2]${NC} wg  ${DIM}— обычный WireGuard, быстрее, но заметнее${NC}"
    echo -e "  ${DIM}[3]${NC} masque ${DIM}— второй транспорт Cloudflare поверх QUIC${NC}"
    echo -e "  ${DIM}[4]${NC} masque-h2 ${DIM}— транспорт Cloudflare поверх HTTP/2${NC}"
    local _c; _c=$(read_choice "выбор" "0")
    case "$_c" in
        1) handle_warp_command proto awg ;;
        2) handle_warp_command proto wg ;;
        3) handle_warp_command proto masque ;;
        4) handle_warp_command proto masque-h2 ;;
        *) return 0 ;;
    esac
    press_any_key
}
