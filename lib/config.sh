#!/bin/bash
# MTProxyL — генерация config.toml + режим эксперта

EXPERT_FILE="${INSTALL_DIR}/expert.conf"

# Загрузка expert overrides
load_expert_overrides() {
    [ -f "$EXPERT_FILE" ] || return 0
    # Формат: SECTION|KEY|VALUE
    # Например: censorship|mask_relay_max_bytes|5242880
}

# Сохранить expert override
expert_set() {
    local section="$1" key="$2" value="$3"
    [ -z "$section" ] || [ -z "$key" ] || [ -z "$value" ] && {
        log_error "Использование: expert set <секция> <ключ> <значение>"
        return 1
    }

    mkdir -p "$INSTALL_DIR"
    touch "$EXPERT_FILE"; chmod 600 "$EXPERT_FILE"

    # Удаляем старую запись если есть
    local tmp; tmp=$(_mktemp) || return 1
    grep -v "^${section}|${key}|" "$EXPERT_FILE" > "$tmp" 2>/dev/null || true
    echo "${section}|${key}|${value}" >> "$tmp"
    mv "$tmp" "$EXPERT_FILE"
    chmod 600 "$EXPERT_FILE"

    log_success "Режим эксперта: [${section}] ${key} = ${value}"
}

# Удалить expert override
expert_clear() {
    local key="$1"
    [ -z "$key" ] && { log_error "Укажите ключ или 'all'"; return 1; }
    [ ! -f "$EXPERT_FILE" ] && { log_info "Нет пользовательских параметров"; return 0; }

    if [ "$key" = "all" ]; then
        rm -f "$EXPERT_FILE"
        log_success "Все пользовательские параметры удалены"
    else
        local tmp; tmp=$(_mktemp) || return 1
        grep -v "|${key}|" "$EXPERT_FILE" > "$tmp" 2>/dev/null || true
        mv "$tmp" "$EXPERT_FILE"
        log_success "Параметр ${key} удалён"
    fi
}

# Показать все expert overrides
expert_list() {
    if [ ! -f "$EXPERT_FILE" ] || [ ! -s "$EXPERT_FILE" ]; then
        log_info "Нет пользовательских параметров (режим эксперта)"
        echo -e "  ${DIM}Используйте: mtproxyl expert set <секция> <ключ> <значение>${NC}"
        return
    fi

    echo ""
    draw_header "РЕЖИМ ЭКСПЕРТА — ПОЛЬЗОВАТЕЛЬСКИЕ ПАРАМЕТРЫ"
    echo ""
    printf "  ${BOLD}%-20s %-30s %s${NC}\n" "СЕКЦИЯ" "КЛЮЧ" "ЗНАЧЕНИЕ"
    echo -e "  ${DIM}$(_repeat '─' 65)${NC}"

    while IFS='|' read -r section key value; do
        [ -z "$section" ] && continue
        printf "  %-20s %-30s %s\n" "[$section]" "$key" "$value"
    done < "$EXPERT_FILE"
    echo ""
}

# Применить expert overrides к config.toml
_apply_expert_overrides() {
    local config_file="$1"
    [ -f "$EXPERT_FILE" ] || return 0
    [ -f "$config_file" ] || return 0

    while IFS='|' read -r section key value; do
        [ -z "$section" ] || [ -z "$key" ] && continue

        # Определить формат значения
        local formatted_value
        if [[ "$value" =~ ^(true|false)$ ]]; then
            formatted_value="$value"
        elif [[ "$value" =~ ^[0-9]+$ ]]; then
            formatted_value="$value"
        elif [[ "$value" =~ ^[0-9]+\.[0-9]+$ ]]; then
            formatted_value="$value"
        else
            formatted_value="\"$value\""
        fi

        # Заменить существующий ключ или добавить после секции
        if grep -qE "^${key}[[:space:]]*=" "$config_file"; then
            sed -i "s/^${key}[[:space:]]*=.*/${key} = ${formatted_value}/" "$config_file"
        elif grep -qE "^\\[${section}\\]" "$config_file"; then
            sed -i "/^\\[${section}\\]/a ${key} = ${formatted_value}" "$config_file"
        else
            # Секции нет — добавляем в конец
            echo "" >> "$config_file"
            echo "[${section}]" >> "$config_file"
            echo "${key} = ${formatted_value}" >> "$config_file"
        fi
    done < "$EXPERT_FILE"
}

# Генерация config.toml (основная функция — портирована из MTProxyMax)
generate_telemt_config() {
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"

    # ... (здесь будет основная генерация как в MTProxyMax,
    #      но в конце вызывается _apply_expert_overrides)

    local tmp; tmp=$(_mktemp "$CONFIG_DIR") || return 1

    # === Генерация базового config.toml ===
    # (весь код генерации из MTProxyMax переносится сюда)

    # === Применяем engine tuning ===
    # (код из MTProxyMax для _TUNE_FILE)

    # === Применяем expert overrides ===
    _apply_expert_overrides "$tmp"

    chmod 644 "$tmp"
    cp "$tmp" "${CONFIG_DIR}/config.toml" && rm -f "$tmp"
}

# CLI handler для expert
handle_expert_command() {
    local subcmd="${1:-list}"
    shift 2>/dev/null || true

    case "$subcmd" in
        list)    expert_list ;;
        set)     check_root; expert_set "$1" "$2" "$3" ;;
        clear)   check_root; expert_clear "$1" ;;
        edit)
            check_root
            local config="${CONFIG_DIR}/config.toml"
            if [ -f "$config" ]; then
                local editor="${EDITOR:-nano}"
                log_info "Открытие ${config} в ${editor}..."
                log_warn "Изменения будут перезаписаны при следующей генерации конфига!"
                log_info "Для постоянных изменений используйте: mtproxyl expert set <секция> <ключ> <значение>"
                echo ""
                "$editor" "$config"
            else
                log_error "Конфиг не найден — запустите прокси хотя бы раз"
            fi
            ;;
        *)
            echo -e "  ${BOLD}Режим эксперта — прямое редактирование config.toml${NC}"
            echo ""
            echo -e "  ${GREEN}expert list${NC}                          Показать пользовательские параметры"
            echo -e "  ${GREEN}expert set${NC} <секция> <ключ> <значение>  Добавить параметр"
            echo -e "  ${GREEN}expert clear${NC} <ключ|all>               Удалить параметр"
            echo -e "  ${GREEN}expert edit${NC}                          Открыть config.toml в редакторе"
            echo ""
            echo -e "  ${DIM}Пример:${NC}"
            echo -e "  ${CYAN}mtproxyl expert set censorship mask_relay_max_bytes 5242880${NC}"
            echo -e "  ${CYAN}mtproxyl expert set general rst_on_close errors${NC}"
            echo -e "  ${CYAN}mtproxyl expert set server client_mss tspu${NC}"
            ;;
    esac
}
