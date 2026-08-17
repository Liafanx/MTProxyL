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
    echo -e "  ${DIM}Проще так: свой telemt — берите C; готовы править чужой конфиг${NC}"
    echo -e "  ${DIM}руками — тоже C; иначе B, а если разведка не находит живых${NC}"
    echo -e "  ${DIM}эндпоинтов (wg режут по сигнатуре) — A.${NC}"
}

tui_warp_menu() {
    while true; do
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
            echo -e "  ${BOLD}Эндпоинт:${NC}  ${WARP_ENDPOINT:-${DIM}выбирается разведкой${NC}}"
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
        echo -e "  ${DIM}[0]${NC} Назад"
        echo ""

        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) _tui_warp_enable socks ;;
            2) _tui_warp_enable iface ;;
            3) _tui_warp_enable upstream ;;
            4) warp_disable; press_any_key ;;
            5) _tui_warp_location ;;
            6) warp_scan_show; press_any_key ;;
            7) _tui_warp_endpoint ;;
            8) _tui_warp_proto ;;
            9) warp_status; press_any_key ;;
            10) echo ""; _tui_warp_explain; press_any_key ;;
            11) warp_reapply; press_any_key ;;
            12) _warp_upstream_manual_hint; press_any_key ;;
            13)
                echo ""
                echo -en "  ${BOLD}Удалить warpscout, службы и правила? [y/N]:${NC} "
                local _yn; read_line _yn
                [[ "$_yn" =~ ^[yY] ]] && warp_remove
                press_any_key ;;
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
    warp_enable "$_mode"
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
        1) warp_set_location clear ;;
        2)
            echo ""
            echo -e "  ${DIM}Вводите через запятую, регистр не важен:${NC}"
            echo -e "  ${DIM}  страны двумя буквами — DE, NL, FI, SE, TR;${NC}"
            echo -e "  ${DIM}  узлы Cloudflare тремя, по коду аэропорта — FRA, AMS, HEL, ARN.${NC}"
            echo -e "  ${DIM}Можно смешивать: DE,AMS. Чем уже список, тем выше шанс,${NC}"
            echo -e "  ${DIM}что живых эндпоинтов не найдётся вовсе.${NC}"
            echo -en "  ${BOLD}Локация:${NC} "
            local _v; read_line _v
            [ -n "$_v" ] && warp_set_location "$_v"
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
    echo -en "  ${BOLD}Эндпоинт:${NC} "
    local _v; read_line _v
    [ -n "$_v" ] && warp_set_endpoint "$_v"
    press_any_key
}

_tui_warp_proto() {
    echo ""
    echo -e "  ${BOLD}Протокол туннеля (варианты A и C)${NC}"
    echo -e "  ${DIM}[1]${NC} awg ${DIM}— обфусцированный WireGuard, проходит чаще всего${NC}"
    echo -e "  ${DIM}[2]${NC} wg  ${DIM}— обычный WireGuard, быстрее, но заметнее${NC}"
    echo -e "  ${DIM}[3]${NC} masque ${DIM}— второй транспорт Cloudflare поверх QUIC${NC}"
    local _c; _c=$(read_choice "выбор" "0")
    case "$_c" in
        1) warp_set_proto awg ;;
        2) warp_set_proto wg ;;
        3) warp_set_proto masque ;;
        *) return 0 ;;
    esac
    press_any_key
}
