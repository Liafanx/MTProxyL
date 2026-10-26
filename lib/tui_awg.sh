#!/bin/bash
# MTProxyL — меню: Telegram через свой сервер AmneziaWG (импорт конфига)

_tui_awg_state_label() {
    local _l; _l=$(awg_state_label 2>/dev/null)
    case "$_l" in
        "через "*)  echo -e "${GREEN}${_l}${NC}" ;;
        "не настроен"|"") echo -e "${DIM}не настроен${NC}" ;;
        *)          echo -e "${YELLOW}${_l}${NC}" ;;
    esac
}

# Выбор конфига: импортированные, найденные на сервере или путь вручную.
_tui_awg_pick() {
    _TUI_AWG_PICK=""
    local -a _items=() _labels=()
    local _n _f _info _ep _addr _obf _v6 _lvl
    while IFS= read -r _n; do
        [ -n "$_n" ] || continue
        IFS='|' read -r _ep _addr _obf _v6 _lvl < <(_awg_conf_info "$(_awg_store)/${_n}.conf")
        _items+=("$_n"); _labels+=("${_n}  ${DIM}импортирован, ${_ep}${NC}")
    done < <(_awg_list_names)
    echo -e "  ${DIM}Ищем конфиги в ${INSTALL_DIR:-/opt/mtproxyl}, /root, /etc/amnezia, /etc/wireguard...${NC}"
    while IFS= read -r _f; do
        [ -n "$_f" ] || continue
        _info=$(_awg_check_file "$_f") || continue
        IFS='|' read -r _ep _addr _obf _v6 _lvl <<< "$_info"
        _items+=("$_f"); _labels+=("${_f}  ${DIM}${_ep}$(_awg_kind "$_obf" "$_lvl")${NC}")
    done < <(_awg_scan_paths)
    echo ""
    local _i
    for _i in "${!_items[@]}"; do
        echo -e "  ${DIM}[$((_i + 1))]${NC} ${_labels[$_i]}"
    done
    [ ${#_items[@]} -eq 0 ] && echo -e "  ${DIM}Конфигов не найдено — укажите путь к файлу.${NC}"
    echo ""
    local _c; read_line _c "  ${BOLD}Номер или полный путь к конфигу (пусто — отмена):${NC} "
    _c="${_c#"${_c%%[![:space:]]*}"}"; _c="${_c%"${_c##*[![:space:]]}"}"
    [ -n "$_c" ] || return 1
    if [[ "$_c" =~ ^[0-9]+$ ]]; then
        [ "$_c" -ge 1 ] && [ "$_c" -le ${#_items[@]} ] || { log_error "Нет такого номера"; return 1; }
        _TUI_AWG_PICK="${_items[$((_c - 1))]}"
    else
        [ -f "$_c" ] || { log_error "Файл не найден: ${_c}"; return 1; }
        _awg_check_file "$_c" >/dev/null || { log_error "Конфиг не подходит: ${_AWG_FILE_ERR}"; return 1; }
        _TUI_AWG_PICK="$_c"
    fi
}

# Номера через пробел из импортированных — список имён в _TUI_AWG_NAMES.
_tui_awg_pick_many() {
    local _prompt="$1" _skip="${2:-}"
    _TUI_AWG_NAMES=()
    local -a _names=()
    mapfile -t _names < <(_awg_list_names | grep -vxF "${_skip:-//}")
    [ ${#_names[@]} -gt 0 ] || return 1
    local _i
    echo ""
    for _i in "${!_names[@]}"; do echo -e "  ${DIM}[$((_i + 1))]${NC} ${_names[$_i]}"; done
    local _c; read_line _c "  ${BOLD}${_prompt}${NC} "
    for _i in $_c; do
        [[ "$_i" =~ ^[0-9]+$ ]] && [ "$_i" -ge 1 ] && [ "$_i" -le ${#_names[@]} ] || { log_error "Нет номера ${_i}"; return 1; }
        _TUI_AWG_NAMES+=("${_names[$((_i - 1))]}")
    done
    [ ${#_TUI_AWG_NAMES[@]} -gt 0 ]
}

_tui_awg_enable() {
    _tui_awg_pick || return 0
    local -a _all=("$_TUI_AWG_PICK")
    local _primary="$_TUI_AWG_PICK"
    [[ "$_primary" == */* ]] && _primary=""
    echo -e "  ${DIM}Запасные выходы: при сбое основного дольше 3 минут движок перейдёт на следующий.${NC}"
    _tui_awg_pick_many "Запасные — номера через пробел (пусто — без запасных):" "$_primary" && _all+=("${_TUI_AWG_NAMES[@]}")
    echo ""
    echo -e "  ${DIM}MTU: пусто — из конфига; при зависании TLS через туннель попробуйте 1280.${NC}"
    local _mtu; read_line _mtu "  ${BOLD}MTU [из конфига]:${NC} "
    local -a _args=("${_all[@]}")
    [ -n "$_mtu" ] && _args+=(--mtu "$_mtu")
    awg_enable "${_args[@]}"
}

_tui_awg_remove() {
    local -a _names=()
    mapfile -t _names < <(_awg_list_names)
    [ ${#_names[@]} -gt 0 ] || { log_info "Импортированных конфигов нет"; return 0; }
    local _i
    for _i in "${!_names[@]}"; do echo -e "  ${DIM}[$((_i + 1))]${NC} ${_names[$_i]}"; done
    local _c; read_line _c "  ${BOLD}Какой удалить (пусто — отмена):${NC} "
    [[ "$_c" =~ ^[0-9]+$ ]] && [ "$_c" -ge 1 ] && [ "$_c" -le ${#_names[@]} ] || return 0
    awg_remove "${_names[$((_c - 1))]}"
}

tui_awg_menu() {
    while true; do
        clear_screen
        draw_header "TELEGRAM ЧЕРЕЗ СВОЙ AWG"
        echo ""
        echo -e "  ${DIM}Клиентский конфиг AmneziaWG или WireGuard от вашего сервера: через туннель${NC}"
        echo -e "  ${DIM}идут только подсети Telegram, SSH и остальной трафик — напрямую.${NC}"
        awg_status
        awg_load
        if [ "$AWG_ENABLED" = true ]; then
            echo -e "  ${DIM}[1]${NC} Сменить конфиг"
            echo -e "  ${DIM}[2]${NC} Проверить туннель"
            echo -e "  ${DIM}[3]${NC} Выключить — движок пойдёт к Telegram напрямую"
        else
            echo -e "  ${DIM}[1]${NC} Включить — выбрать конфиг"
        fi
        echo -e "  ${DIM}[4]${NC} Найти конфиги на сервере"
        echo -e "  ${DIM}[5]${NC} Удалить импортированный конфиг"
        [ "$(_awg_list_names | wc -l)" -gt 1 ] && echo -e "  ${DIM}[6]${NC} Порядок выходов — основной и запасные"
        echo -e "  ${DIM}[0]${NC} Назад"
        local _c; _c=$(read_choice "выбор" "0")
        case "$_c" in
            1) _tui_awg_enable; press_any_key ;;
            2) [ "$AWG_ENABLED" = true ] && { awg_check; press_any_key; } ;;
            3)
                [ "$AWG_ENABLED" = true ] || continue
                local _yn; read_line _yn "  ${BOLD}Выключить выход через AWG? [y/N]:${NC} "
                [[ "$_yn" =~ ^[yY] ]] && awg_disable
                press_any_key ;;
            4) awg_scan; press_any_key ;;
            5) _tui_awg_remove; press_any_key ;;
            6)
                echo -e "  ${DIM}Первый — основной, остальные — запасные по порядку.${NC}"
                _tui_awg_pick_many "Выходы по порядку — номера через пробел:" && awg_order "${_TUI_AWG_NAMES[@]}"
                press_any_key ;;
            0|"") return ;;
        esac
    done
}
