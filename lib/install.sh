#!/bin/bash
# MTProxyL — мастер установки + деинсталлятор

run_installer() {
    show_banner

    echo -e "  ${BRIGHT_GREEN}Добро пожаловать в MTProxyL — менеджер Telegram MTProto прокси${NC}"
    echo -e "  ${DIM}by LiafanX${NC}"
    echo ""

    check_root

    # Проверка на повторную установку
    if [ -f "${INSTALL_DIR}/mtproxyl.sh" ] && [ -f "$SETTINGS_FILE" ]; then
        echo -e "  ${YELLOW}MTProxyL уже установлен.${NC}"
        echo ""
        echo -e "  ${DIM}[1]${NC} Открыть меню"
        echo -e "  ${DIM}[2]${NC} Переустановить"
        echo -e "  ${DIM}[3]${NC} Удалить"
        echo -e "  ${DIM}[0]${NC} Выход"
        local choice; choice=$(read_choice "выбор" "1")
        case "$choice" in
            1) load_settings; load_secrets; show_main_menu; return ;;
            2) ;;
            3) uninstall; return ;;
            *) exit 0 ;;
        esac
    fi

    draw_header "УСТАНОВКА"
    echo ""

    # Зависимости
    log_info "Проверка зависимостей..."
    local missing=()
    command -v curl &>/dev/null || missing+=("curl")
    command -v awk &>/dev/null || missing+=("awk")
    command -v openssl &>/dev/null || missing+=("openssl")
    if [ ${#missing[@]} -gt 0 ]; then
        log_info "Установка: ${missing[*]}"
        _wait_apt
        local os; os=$(detect_os)
        case "$os" in
            debian) apt-get update -qq && apt-get install -y -qq "${missing[@]}" ;;
            rhel)   yum install -y -q "${missing[@]}" ;;
            alpine) apk add --no-cache "${missing[@]}" ;;
        esac
    fi
    log_success "Зависимости в порядке"

    # Docker
    install_docker || exit 1
    wait_for_docker || exit 1

    echo ""
    draw_header "НАСТРОЙКА ПРОКСИ"
    echo ""

    # Порт
    echo -e "  ${BOLD}Порт прокси${NC} ${DIM}(по умолчанию: 443)${NC}"
    echo -en "  ${DIM}Порт [443]:${NC} "
    local port_input; read -r port_input
    [ -n "$port_input" ] && validate_port "$port_input" && PROXY_PORT="$port_input"

    # Metrics port — автоматически выбираем свободный
    echo ""
    local _metrics_default
    _metrics_default=$(find_free_metrics_port 9090 9199) || _metrics_default=9090
    PROXY_METRICS_PORT="${_metrics_default}"
    if ! is_port_available "$PROXY_METRICS_PORT" 2>/dev/null; then
        _metrics_default=9090
        PROXY_METRICS_PORT=9090
    fi
    echo -e "  ${BOLD}Порт метрик (Prometheus endpoint, только localhost)${NC}"
    if is_port_available "$PROXY_METRICS_PORT" 2>/dev/null; then
        echo -e "  ${DIM}Автоматически выбран свободный порт: ${PROXY_METRICS_PORT}${NC}"
    else
        echo -e "  ${YELLOW}Порт ${PROXY_METRICS_PORT} занят, рекомендуем выбрать другой${NC}"
    fi
    echo -en "  ${BOLD}Оставить порт метрик ${PROXY_METRICS_PORT}? [Y/n]:${NC} "
    local metrics_keep; read -r metrics_keep
    if [[ "$metrics_keep" =~ ^[nN]$ ]]; then
        while true; do
            echo -en "  ${BOLD}Введите порт метрик [${PROXY_METRICS_PORT}]:${NC} "
            local metrics_input; read -r metrics_input
            [ -z "$metrics_input" ] && break
            if validate_port "$metrics_input"; then
                if is_port_available "$metrics_input"; then
                    PROXY_METRICS_PORT="$metrics_input"
                    log_success "Порт метрик: ${PROXY_METRICS_PORT}"
                    break
                else
                    log_error "Порт ${metrics_input} уже занят, попробуйте другой"
                fi
            else
                log_error "Некорректный порт"
            fi
        done
    fi

    # IP
    echo ""
    local _det_ip; _det_ip=$(CUSTOM_IP="" get_public_ip)
    echo -e "  ${BOLD}IP или домен для ссылок${NC}"
    echo -en "  ${DIM}Определён: ${_det_ip:-?} — Свой IP/домен или Enter [${_det_ip:-авто}]:${NC} "
    local ip_input; read -r ip_input
    [ -n "$ip_input" ] && CUSTOM_IP="$ip_input"

    # Домен
    echo ""
    echo -e "  ${BOLD}FakeTLS домен${NC}"
    echo -e "  ${DIM}[1] cloudflare.com  [2] google.com  [3] microsoft.com  [4] Свой${NC}"
    local d; d=$(read_choice "выбор" "1")
    case "$d" in
        2) PROXY_DOMAIN="google.com" ;;
        3) PROXY_DOMAIN="microsoft.com" ;;
        4) echo -en "  Домен: "; local cd; read -r cd
           [ -n "$cd" ] && validate_domain "$cd" && PROXY_DOMAIN="$cd" ;;
        *) PROXY_DOMAIN="cloudflare.com" ;;
    esac

    # Маскировка
    echo ""
    echo -e "  ${BOLD}Маскировка трафика${NC}"
    echo -en "  ${DIM}Включить? [Y/n]:${NC} "
    local mask_input; read -r mask_input
    [[ "$mask_input" =~ ^[nN] ]] && MASKING_ENABLED="false" || MASKING_ENABLED="true"

    # Ресурсы
    echo ""
    echo -e "  ${BOLD}Ресурсы${NC}"
    echo -en "  ${DIM}CPU (напр. 1 (1 ядро)) [Enter без ограничений]:${NC} "; local cpu; read -r cpu
    [ -n "$cpu" ] && PROXY_CPUS="$cpu"
    echo -en "  ${DIM}RAM (напр. 256m, 1g) [Enter без ограничений]:${NC} "; local mem; read -r mem
    [ -n "$mem" ] && PROXY_MEMORY="$mem"

    # Первый секрет
    echo ""
    draw_header "СЕКРЕТ"
    echo ""
    echo -en "  ${DIM}Метка (имя пользователя) [по умолчанию default]:${NC} "
    local first_label; read -r first_label
    [ -z "$first_label" ] && first_label="default"
    [[ "$first_label" =~ ^[a-zA-Z0-9_-]+$ ]] || first_label="default"

    local first_secret; first_secret=$(generate_secret)
    SECRETS_LABELS=("$first_label")
    SECRETS_KEYS=("$first_secret")
    SECRETS_CREATED+=("$(date +%s)")
    SECRETS_ENABLED=("true")
    SECRETS_MAX_CONNS=("0"); SECRETS_MAX_IPS=("0")
    SECRETS_QUOTA=("0"); SECRETS_EXPIRES=("0"); SECRETS_NOTES=("")

    # Сохранение
    mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$STATS_DIR" "$BACKUP_DIR"
    chmod 700 "$CONFIG_DIR" "$INSTALL_DIR"
    save_settings
    save_secrets

    # Копирование скрипта
    # Главный скрипт уже скачан корневым install.sh, здесь только обновляем симлинк
    ln -sf "${INSTALL_DIR}/mtproxyl.sh" /usr/local/bin/mtproxyl

    # Запуск
    echo ""
    draw_header "ЗАПУСК ПРОКСИ"
    echo ""
    run_proxy_container || {
        log_error "Не удалось запустить прокси"
        echo -e "  ${DIM}Проверьте: docker logs mtproxyl${NC}"
    }

    # Автозапуск
    if command -v systemctl &>/dev/null; then
        cat > /etc/systemd/system/mtproxyl.service << 'SVC_EOF'
[Unit]
Description=MTProxyL Telegram Proxy
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/mtproxyl start
ExecStop=/usr/local/bin/mtproxyl stop

[Install]
WantedBy=multi-user.target
SVC_EOF
        systemctl daemon-reload
        systemctl enable mtproxyl.service 2>/dev/null
        log_success "Автозапуск включён"
    fi

    # Итог
    show_install_summary

    echo ""
    echo -en "  ${DIM}Нажмите клавишу для входа в меню...${NC}"
    read -rsn1
    read -rn 256 -t 0.05 _ 2>/dev/null || true
    load_settings; load_secrets
    show_main_menu
}

show_install_summary() {
    echo ""
    local server_ip; server_ip=$(get_public_ip)

    echo -e "  ${BRIGHT_GREEN}${BOLD}УСТАНОВКА ЗАВЕРШЕНА${NC}"
    echo ""
    echo -e "  ${BOLD}Сервер:${NC} ${server_ip:-?}"
    echo -e "  ${BOLD}Порт:${NC}   ${PROXY_PORT}"
    echo -e "  ${BOLD}Домен:${NC} ${PROXY_DOMAIN}"
    echo -e "  ${BOLD}Движок:${NC} telemt (Rust)"
    echo ""

    if [ -n "$server_ip" ]; then
        echo -e "  ${BOLD}ССЫЛКИ${NC}"
        echo ""
        local i
        for i in "${!SECRETS_LABELS[@]}"; do
            [ "${SECRETS_ENABLED[$i]}" = "true" ] || continue
            local fs; fs=$(build_faketls_secret "${SECRETS_KEYS[$i]}")
            echo -e "  ${BRIGHT_GREEN}${SECRETS_LABELS[$i]}:${NC}"
            echo -e "  ${CYAN}tg://proxy?server=${server_ip}&port=${PROXY_PORT}&secret=${fs}${NC}"
            echo ""
        done
    fi

    echo -e "  ${BOLD}КОМАНДЫ${NC}"
    echo -e "  ${GREEN}mtproxyl${NC}              Меню управления"
    echo -e "  ${GREEN}mtproxyl status${NC}       Статус"
    echo -e "  ${GREEN}mtproxyl secret add${NC}   Добавить пользователя"
    echo -e "  ${GREEN}mtproxyl help${NC}         Справка"
    echo ""
    echo -e "  ${YELLOW}Фаервол: откройте TCP порт, если закрыт ${PROXY_PORT}${NC}"
    echo ""
}

uninstall() {
    clear_screen
    echo ""
    echo -e "  ${BRIGHT_RED}${BOLD}УДАЛЕНИЕ MTPROXYL${NC}"
    echo ""
    echo -e "  ${YELLOW}Будет удалено:${NC}"
    echo -e "  ${DIM}- Контейнер и Docker-образ MTProxyL${NC}"
    echo -e "  ${DIM}- Конфигурация и секреты${NC}"
    echo -e "  ${DIM}- Systemd-сервисы MTProxyL${NC}"
    echo -e "  ${DIM}- NFT правила и iOS фиксы${NC}"
    echo -e "  ${DIM}- /usr/local/bin/mtproxyl${NC}"
    echo ""
    echo -e "  ${GREEN}НЕ будет удалено:${NC}"
    echo -e "  ${DIM}- Docker (сам движок)${NC}"
    echo -e "  ${DIM}- Другие Docker-образы и контейнеры${NC}"
    echo -e "  ${DIM}- Глобальный Docker build cache${NC}"
    echo ""

    echo -en "  ${BOLD}Введите 'yes' для подтверждения:${NC} "
    local confirm; read -r confirm
    [ "$confirm" != "yes" ] && { log_info "Отменено"; return; }

    # Экспорт секретов
    echo -en "  ${BOLD}Сохранить секреты перед удалением? [y/N]:${NC} "
    local export_choice; read -r export_choice
    if [[ "$export_choice" =~ ^[yY] ]]; then
        local export_file="${HOME}/mtproxyl-secrets-backup.txt"
        cp "$SECRETS_FILE" "$export_file" 2>/dev/null || true
        chmod 600 "$export_file" 2>/dev/null || true
        log_success "Секреты сохранены: ${export_file}"
    fi

    # NFT очистка
    log_info "Удаление NFT правил..."
    load_nft_settings 2>/dev/null || true
    nft_full_cleanup 2>/dev/null || true

    # Systemd сервисы
    log_info "Удаление сервисов..."
    systemctl stop mtproxyl.service >/dev/null 2>&1 || true
    systemctl disable mtproxyl.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/mtproxyl.service
    systemctl daemon-reload >/dev/null 2>&1 || true

    # Гео-блокировка
    log_info "Удаление гео-блокировки..."
    geoblock_remove_all >/dev/null 2>&1 || true

    # Docker контейнер
    log_info "Удаление контейнера..."
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

    # Docker образы — только MTProxyL
    log_info "Удаление образов MTProxyL..."
    docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
        | grep "^${DOCKER_IMAGE_BASE}:" \
        | while IFS= read -r _img; do
            docker rmi "$_img" >/dev/null 2>&1 || true
        done

    # Образы из реестра (если были скачаны)
    docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
        | grep "^${REGISTRY_IMAGE}:" \
        | while IFS= read -r _img; do
            docker rmi "$_img" >/dev/null 2>&1 || true
        done

    # Файлы
    log_info "Удаление файлов..."
    rm -rf "$INSTALL_DIR"
    rm -f /usr/local/bin/mtproxyl

    echo ""
    log_success "MTProxyL полностью удалён"
    echo ""
}
