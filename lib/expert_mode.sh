#!/bin/bash
# MTProxyL — интерактивный режим эксперта

EXPERT_OVERRIDES_FILE="${INSTALL_DIR}/expert.conf"

# ── Загрузка / сохранение overrides ──────────────────────────
load_expert_overrides() {
    [ -f "$EXPERT_OVERRIDES_FILE" ] || return 0
}

save_expert_override() {
    local section="$1" key="$2" value="$3"
    mkdir -p "$INSTALL_DIR"
    touch "$EXPERT_OVERRIDES_FILE"; chmod 600 "$EXPERT_OVERRIDES_FILE"
    local tmp; tmp=$(_mktemp) || return 1
    grep -v "^${section}|${key}|" "$EXPERT_OVERRIDES_FILE" > "$tmp" 2>/dev/null || true
    echo "${section}|${key}|${value}" >> "$tmp"
    mv "$tmp" "$EXPERT_OVERRIDES_FILE"; chmod 600 "$EXPERT_OVERRIDES_FILE"
}

delete_expert_override() {
    local section="$1" key="$2"
    [ -f "$EXPERT_OVERRIDES_FILE" ] || return 0
    local tmp; tmp=$(_mktemp) || return 1
    grep -v "^${section}|${key}|" "$EXPERT_OVERRIDES_FILE" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$EXPERT_OVERRIDES_FILE"; chmod 600 "$EXPERT_OVERRIDES_FILE"
}

clear_all_expert_overrides() {
    rm -f "$EXPERT_OVERRIDES_FILE"
}

get_expert_override_value() {
    local section="$1" key="$2"
    [ -f "$EXPERT_OVERRIDES_FILE" ] || return 0
    awk -F'|' -v s="$section" -v k="$key" '$1==s && $2==k {print $3; exit}' "$EXPERT_OVERRIDES_FILE" 2>/dev/null
}

# ── Валидация override-файла ──────────────────────────────────
validate_expert_file() {
    [ -f "$EXPERT_OVERRIDES_FILE" ] || return 0
    local _lineno=0 _errors=0
    while IFS='|' read -r _s _k _v; do
        _lineno=$((_lineno + 1))
        [[ "$_s" =~ ^[[:space:]]*# ]] && continue
        [[ "$_s" =~ ^[[:space:]]*$ ]] && continue
        [ -z "$_k" ] && { log_warn "Строка ${_lineno}: пустой ключ — пропускаем"; _errors=$((_errors + 1)); continue; }
        local _entry
        if _entry=$(_expert_find "$_s" "$_k"); then
            _expert_parse "$_entry"
            local _err
            _err=$(_expert_validate "$EXPERT_P_VALIDATOR" "$_v" 2>&1)
            if [ -n "$_err" ]; then
                log_warn "Строка ${_lineno}: [${_s}] ${_k} = '${_v}' — ${_err}"
                _errors=$((_errors + 1))
            fi
        else
            log_warn "Строка ${_lineno}: [${_s}] ${_k} — неизвестный параметр (применяется на ваш страх и риск)"
        fi
    done < "$EXPERT_OVERRIDES_FILE"
    return "$_errors"
}

# ── Применение expert overrides в config.toml ────────────────
_apply_expert_overrides() {
    local config_file="$1"
    [ -f "$EXPERT_OVERRIDES_FILE" ] || return 0
    [ -f "$config_file" ] || return 0

    local work_file="${config_file}.expert.$$"
    cp "$config_file" "$work_file" || return 1

    while IFS='|' read -r section key value; do
        [[ "$section" =~ ^[[:space:]]*# ]] && continue
        [[ "$section" =~ ^[[:space:]]*$ ]] && continue
        [ -z "$key" ] && continue

        # Форматирование значения по типу из каталога
        local fv
        local _entry=""
        if _entry=$(_expert_find "$section" "$key" 2>/dev/null); then
            _expert_parse "$_entry"
            case "$EXPERT_P_TYPE" in
                bool|u8|u16|u32|u64|usize|f32)
                    fv="$value"
                    ;;
                "string[]")
                    local oldIFS="$IFS"
                    IFS=','
                    read -ra _vals <<< "$value"
                    IFS="$oldIFS"

                    local _out="" _v
                    for _v in "${_vals[@]}"; do
                        _v="${_v#"${_v%%[![:space:]]*}"}"
                        _v="${_v%"${_v##*[![:space:]]}"}"
                        [ -z "$_v" ] && continue
                        [ -n "$_out" ] && _out+=", "
                        _out+="\"$_v\""
                    done
                    fv="[${_out}]"
                    ;;
                *)
                    if [[ "$value" =~ ^(true|false)$ ]]; then
                        fv="$value"
                    elif [[ "$value" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
                        fv="$value"
                    else
                        fv="\"$value\""
                    fi
                    ;;
            esac
        else
            # fallback для неизвестных параметров
            if [[ "$value" =~ ^(true|false)$ ]]; then
                fv="$value"
            elif [[ "$value" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
                fv="$value"
            else
                fv="\"$value\""
            fi
        fi

        local section_header="[$section]"

        # Заменить/добавить ключ строго внутри нужной секции
        awk -v sec="$section_header" -v key="$key" -v val="$fv" '
            BEGIN {
                insec = 0
                done = 0
            }

            /^\[/ {
                # если выходим из нужной секции и ключ ещё не вставлен — вставляем перед новой секцией
                if (insec && !done) {
                    print key " = " val
                    done = 1
                }
                insec = ($0 == sec)
                print
                next
            }

            {
                # если мы внутри нужной секции и нашли старый ключ — заменяем его
                if (insec && $1 == key && $2 == "=") {
                    if (!done) {
                        print key " = " val
                        done = 1
                    }
                    next
                }
                print
            }

            END {
                # если секции вообще не было или ключ не был вставлен
                if (!done) {
                    if (!insec) {
                        print ""
                        print sec
                    }
                    print key " = " val
                }
            }
        ' "$work_file" > "${work_file}.new" && mv "${work_file}.new" "$work_file"
    done < "$EXPERT_OVERRIDES_FILE"

    mv "$work_file" "$config_file"
}

# ── Показ карточки параметра ──────────────────────────────────
show_expert_param_card() {
    local section="$1" key="$2"
    local _entry; _entry=$(_expert_find "$section" "$key") || { log_error "Параметр не найден"; return 1; }
    _expert_parse "$_entry"

    local current_val; current_val=$(get_expert_override_value "$section" "$key")

    echo ""
    echo -e "  ${BOLD}Параметр:${NC}    ${section}.${key}"
    echo -e "  ${BOLD}Тип:${NC}         ${EXPERT_P_TYPE}"
    echo -e "  ${BOLD}По умолчанию:${NC} ${EXPERT_P_DEFAULT:-${DIM}(нет)${NC}}"
    echo -e "  ${BOLD}Hot-Reload:${NC}   ${EXPERT_P_HOT}"
    echo -e "  ${BOLD}Допустимо:${NC}   ${EXPERT_P_HINT}"
    echo -e "  ${BOLD}Описание:${NC}"
    echo -e "    ${DIM}${EXPERT_P_DESC}${NC}"
    echo ""
    if [ -n "$current_val" ]; then
        echo -e "  ${BOLD}Текущий override:${NC} ${GREEN}${current_val}${NC}"
    else
        echo -e "  ${BOLD}Текущий override:${NC} ${DIM}не задан (будет использован default)${NC}"
    fi
    echo ""
}

# ── Интерактивная установка параметра ────────────────────────
expert_set_interactive() {
    local section="$1" key="$2"
    local _entry; _entry=$(_expert_find "$section" "$key") || { log_error "Параметр не найден"; return 1; }
    _expert_parse "$_entry"

    show_expert_param_card "$section" "$key"

    local current_val; current_val=$(get_expert_override_value "$section" "$key")

    echo -en "  ${BOLD}Введите значение [${current_val:-${EXPERT_P_DEFAULT}}]:${NC} "
    local input; read -r input
    [ -z "$input" ] && { log_info "Отменено (значение не изменено)"; return 0; }

    # Валидация
    local _err
    _err=$(_expert_validate "$EXPERT_P_VALIDATOR" "$input" 2>&1)
    if [ -n "$_err" ]; then
        log_error "Некорректное значение: ${_err}"
        return 1
    fi

    save_expert_override "$section" "$key" "$input"
    log_success "Override сохранён: [${section}] ${key} = ${input}"

    if [ "${EXPERT_P_HOT}" = "✔" ]; then
        echo -e "  ${DIM}Hot-Reload: ✔ — можно применить через hot-reload${NC}"
    else
        echo -e "  ${YELLOW}Hot-Reload: ✘ — требуется перезапуск прокси${NC}"
    fi
}

# ── Показ активных overrides ──────────────────────────────────
show_expert_overrides() {
    if [ ! -f "$EXPERT_OVERRIDES_FILE" ] || [ ! -s "$EXPERT_OVERRIDES_FILE" ]; then
        log_info "Нет активных expert override"
        echo -e "  ${DIM}Выберите раздел и параметр для добавления${NC}"
        return
    fi

    echo ""
    draw_header "АКТИВНЫЕ EXPERT OVERRIDE"
    echo ""
    printf "  ${BOLD}%-4s %-24s %-24s %s${NC}\n" "#" "СЕКЦИЯ" "КЛЮЧ" "ЗНАЧЕНИЕ"
    echo -e "  ${DIM}$(_repeat '─' 72)${NC}"
    local _n=0
    while IFS='|' read -r _s _k _v; do
        [[ "$_s" =~ ^[[:space:]]*# ]] && continue
        [[ "$_s" =~ ^[[:space:]]*$ ]] && continue
        [ -z "$_k" ] && continue
        _n=$((_n + 1))

        local _entry; _entry=$(_expert_find "$_s" "$_k") || true
        local _hot=""
        if [ -n "$_entry" ]; then
            _expert_parse "$_entry"
            _hot="${EXPERT_P_HOT}"
        fi

        printf "  %-4s %-24s %-24s %s" "$_n" "$_s" "$_k" "$_v"
        [ "$_hot" = "✔" ] && echo -e " ${DIM}[hot-reload]${NC}" || echo ""
    done < "$EXPERT_OVERRIDES_FILE"
    echo ""
}

# ── Удаление override ─────────────────────────────────────────
expert_delete_interactive() {
    show_expert_overrides
    if [ ! -f "$EXPERT_OVERRIDES_FILE" ] || [ ! -s "$EXPERT_OVERRIDES_FILE" ]; then
        press_any_key; return; fi

    echo -en "  ${BOLD}Номер override для удаления (или 0 для отмены):${NC} "
    local _sel; read -r _sel
    [ "$_sel" = "0" ] || [ -z "$_sel" ] && { log_info "Отменено"; return; }

    local _n=0 _s="" _k=""
    while IFS='|' read -r __s __k __v; do
        [[ "$__s" =~ ^[[:space:]]*# ]] && continue
        [[ "$__s" =~ ^[[:space:]]*$ ]] && continue
        [ -z "$__k" ] && continue
        _n=$((_n + 1))
        if [ "$_n" = "$_sel" ]; then _s="$__s"; _k="$__k"; break; fi
    done < "$EXPERT_OVERRIDES_FILE"

    if [ -z "$_s" ] || [ -z "$_k" ]; then
        log_error "Некорректный номер"; return 1; fi

    delete_expert_override "$_s" "$_k"
    log_success "Override удалён: [${_s}] ${_k}"
}

# ── Меню выбора секции ────────────────────────────────────────
tui_expert_section_menu() {
    clear_screen
    draw_header "РЕЖИМ ЭКСПЕРТА — ВЫБОР РАЗДЕЛА"
    echo ""
    local _idx=0
    local -a _sec_map=()
    for _sec in "${_EXPERT_SECTIONS[@]}"; do
        _idx=$((_idx + 1))
        _sec_map+=("$_sec")
        printf "  ${CYAN}[%2s]${NC}  %s\n" "$_idx" "$_sec"
    done
    echo ""
    echo -e "  ${DIM}[0]${NC}  Назад"
    echo ""
    echo -en "  Выбор раздела: "
    local _sel; read -r _sel
    [ "$_sel" = "0" ] || [ -z "$_sel" ] && return

    if [[ "$_sel" =~ ^[0-9]+$ ]] && [ "$_sel" -ge 1 ] && [ "$_sel" -le "${#_sec_map[@]}" ]; then
        local _chosen_section="${_sec_map[$((_sel - 1))]}"
        tui_expert_key_menu "$_chosen_section"
    else
        log_error "Некорректный выбор"
    fi
}

# ── Меню выбора параметра ─────────────────────────────────────
tui_expert_key_menu() {
    local section="$1"
    while true; do
        clear_screen
        draw_header "РАЗДЕЛ: ${section}"
        echo ""

        local -a _keys=()
        while IFS= read -r _k; do
            _keys+=("$_k")
        done < <(_expert_keys_of_section "$section")

        if [ ${#_keys[@]} -eq 0 ]; then
            log_info "Нет параметров для раздела '$section'"
            press_any_key; return; fi

        local _idx=0
        for _k in "${_keys[@]}"; do
            _idx=$((_idx + 1))
            local _cv; _cv=$(get_expert_override_value "$section" "$_k")
            local _entry; _entry=$(_expert_find "$section" "$_k") || continue
            _expert_parse "$_entry"

            local _marker=""
            [ -n "$_cv" ] && _marker=" ${GREEN}= ${_cv}${NC}"

            printf "  ${CYAN}[%2s]${NC}  %-40s %b %b\n" \
                "$_idx" "${_k}" "${DIM}(${EXPERT_P_DEFAULT:-—})${NC}" "$_marker"
        done

        echo ""
        echo -e "  ${DIM}[0]${NC}  Назад"
        echo ""
        echo -en "  Выбор параметра: "
        local _sel; read -r _sel
        [ "$_sel" = "0" ] || [ -z "$_sel" ] && return

        if [[ "$_sel" =~ ^[0-9]+$ ]] && [ "$_sel" -ge 1 ] && [ "$_sel" -le "${#_keys[@]}" ]; then
            local _chosen_key="${_keys[$((_sel - 1))]}"
            expert_set_interactive "$section" "$_chosen_key"
            press_any_key
        else
            log_error "Некорректный выбор"
        fi
    done
}

# ── Главное меню режима эксперта ──────────────────────────────
tui_expert_menu() {
    while true; do
        clear_screen
        draw_header "РЕЖИМ ЭКСПЕРТА"
        echo ""
        echo -e "  ${YELLOW}⚠ Параметры применяются поверх всех остальных настроек MTProxyL.${NC}"
        echo -e "  ${YELLOW}  Не меняйте значения без понимания их назначения.${NC}"
        echo ""

        # Показать кол-во активных overrides
        local _count=0
        if [ -f "$EXPERT_OVERRIDES_FILE" ]; then
            _count=$(grep -c '^[^#]' "$EXPERT_OVERRIDES_FILE" 2>/dev/null || echo 0)
        fi
        echo -e "  ${BOLD}Активных override:${NC} ${_count}"
        echo ""
        echo -e "  ${CYAN}[1]${NC}  Выбрать раздел и параметр"
        echo -e "  ${CYAN}[2]${NC}  Показать активные override"
        echo -e "  ${CYAN}[3]${NC}  Удалить override"
        echo -e "  ${CYAN}[4]${NC}  Очистить все override"
        echo -e "  ${CYAN}[5]${NC}  Открыть expert.conf в nano"
        echo -e "  ${CYAN}[6]${NC}  Проверить expert.conf"
        echo -e "  ${CYAN}[7]${NC}  Применить override (hot-reload)"
        echo ""
        echo -e "  ${DIM}[0]${NC}  Назад"
        echo ""
        local choice; choice=$(read_choice "выбор" "0")

        case "$choice" in
            1) tui_expert_section_menu ;;
            2) show_expert_overrides; press_any_key ;;
            3) expert_delete_interactive; press_any_key ;;
            4)
                echo -en "  ${RED}Очистить все override? Введите 'yes':${NC} "
                local _c; read -r _c
                if [ "$_c" = "yes" ]; then
                    clear_all_expert_overrides
                    log_success "Все expert override удалены"
                else log_info "Отменено"; fi
                press_any_key ;;
            5)
                touch "$EXPERT_OVERRIDES_FILE"; chmod 600 "$EXPERT_OVERRIDES_FILE"
                log_warn "Формат: section|key|value"
                log_warn "Пример: censorship|fake_cert_len|4096"
                echo ""
                local editor="${EDITOR:-nano}"
                "$editor" "$EXPERT_OVERRIDES_FILE"
                echo ""
                log_info "Проверка файла..."
                validate_expert_file && log_success "Файл корректен" || log_warn "Обнаружены предупреждения"
                press_any_key ;;
            6)
                validate_expert_file
                if [ $? -eq 0 ]; then log_success "Файл корректен"
                else log_warn "Проверьте предупреждения выше"; fi
                press_any_key ;;
            7)
                log_info "Пересборка конфига с expert override..."
                generate_telemt_config && log_success "Конфиг обновлён" || log_error "Ошибка генерации конфига"
                if is_proxy_running; then
                    docker kill -s SIGHUP "$CONTAINER_NAME" &>/dev/null || true
                    log_success "Hot-reload отправлен контейнеру"
                else log_warn "Прокси не запущен — перезапустите вручную"; fi
                press_any_key ;;
            0|"") return ;;
        esac
    done
}
