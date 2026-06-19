#!/bin/bash
# MTProxyL — бэкапы, восстановление, миграция

create_backup() {
    mkdir -p "$BACKUP_DIR"
    local ts; ts=$(date '+%Y%m%d-%H%M%S')
    local backup_file="${BACKUP_DIR}/mtproxyl-${ts}.tar.gz"

    local meta_tmp; meta_tmp=$(_mktemp) || return 1
    echo "version=${VERSION}" > "$meta_tmp"
    echo "date=$(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "$meta_tmp"
    echo "hostname=$(hostname 2>/dev/null || echo unknown)" >> "$meta_tmp"
    cp "$meta_tmp" "${INSTALL_DIR}/backup_meta.txt"
    rm -f "$meta_tmp"

    local files=()
    for f in settings.conf secrets.conf upstreams.conf nft-rules.conf expert.conf tunings.conf backup_meta.txt; do
        [ -f "${INSTALL_DIR}/$f" ] && files+=("$f")
    done
    [ -d "$STATS_DIR" ] && files+=("relay_stats")

    tar czf "$backup_file" -C "$INSTALL_DIR" --exclude='*.lock' "${files[@]}" 2>/dev/null
    chmod 600 "$backup_file"
    rm -f "${INSTALL_DIR}/backup_meta.txt"

    log_success "Бэкап создан: ${backup_file}"
    echo "$backup_file"
}

restore_backup() {
    local backup_file="$1"
    [ -z "$backup_file" ] && { log_error "Использование: mtproxyl restore <файл>"; return 1; }
    [ ! -f "$backup_file" ] && { log_error "Файл не найден: ${backup_file}"; return 1; }

    if ! tar tzf "$backup_file" 2>/dev/null | grep -q "settings.conf"; then
        log_error "Некорректный бэкап (нет settings.conf)"
        return 1
    fi

    local meta; meta=$(tar xzf "$backup_file" -O backup_meta.txt 2>/dev/null)
    if [ -n "$meta" ]; then
        echo ""
        echo -e "  ${BOLD}Информация о бэкапе:${NC}"
        echo "$meta" | while IFS='=' read -r k v; do echo -e "    ${k}: ${v}"; done
        echo ""
    fi

    echo -en "  ${YELLOW}Текущая конфигурация будет перезаписана. Продолжить? [y/N]:${NC} "
    local confirm; read -r confirm
    [[ "$confirm" =~ ^[yY] ]] || { log_info "Отменено"; return 0; }

    # Бэкап текущего состояния перед восстановлением
    log_info "Сохранение текущего состояния..."
    log_info "(создаётся бэкап текущих настроек на случай отката)"
    create_backup &>/dev/null

    # Распаковка
    tar xzf "$backup_file" -C "$INSTALL_DIR" --exclude='backup_meta.txt' 2>/dev/null
    chmod 600 "${SETTINGS_FILE}" 2>/dev/null
    chmod 600 "${SECRETS_FILE}" 2>/dev/null

    # Перезагрузка настроек в память
    load_settings
    load_secrets
    load_nft_settings 2>/dev/null

    log_success "Восстановлено из: $(basename "$backup_file")"
    echo ""
    echo -e "  ${BOLD}Восстановленные параметры:${NC}"
    echo -e "    Порт:   ${PROXY_PORT}"
    echo -e "    Домен:  ${PROXY_DOMAIN}"
    echo -e "    Секретов: ${#SECRETS_LABELS[@]}"
    echo ""

    # Предложение перезапуска
    if is_proxy_running; then
        echo -en "  ${BOLD}Перезапустить прокси для применения? [Y/n]:${NC} "
        local yn; read -r yn
        if [[ ! "$yn" =~ ^[nN]$ ]]; then
            restart_proxy_container || true
        else
            log_info "Выполните 'mtproxyl restart' для применения"
        fi
    else
        log_info "Прокси не запущен. Выполните 'mtproxyl start' для запуска с новыми настройками"
    fi
}

list_backups() {
    mkdir -p "$BACKUP_DIR"
    local files; files=$(ls -1t "${BACKUP_DIR}"/mtproxyl-*.tar.gz 2>/dev/null) || true
    if [ -z "$files" ]; then
        log_info "Нет бэкапов в ${BACKUP_DIR}"
        return
    fi
    echo ""
    draw_header "БЭКАПЫ"
    echo ""
    echo "$files" | while read -r f; do
        local size; size=$(du -h "$f" 2>/dev/null | awk '{print $1}')
        echo -e "  ${BOLD}$(basename "$f")${NC}  ${DIM}(${size})${NC}"
    done
    echo ""
}

backup_autoclean() {
    local days="${1:-${BACKUP_RETENTION_DAYS:-30}}"
    [[ "$days" =~ ^[0-9]+$ ]] || { log_error "Дни: положительное число"; return 1; }
    [ "$days" -le 0 ] && { log_info "Автоочистка отключена (0 = хранить всё)"; return 0; }
    [ -d "$BACKUP_DIR" ] || return 0

    local before after
    before=$(find "$BACKUP_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
    find "$BACKUP_DIR" -maxdepth 1 -type f -mtime "+${days}" -delete 2>/dev/null
    after=$(find "$BACKUP_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')

    local removed=$((before - after))
    log_success "Удалено ${removed} бэкапов старше ${days} дней (осталось ${after})"
}

# Зашифрованные бэкапы
backup_create_encrypted() {
    check_root
    command -v openssl &>/dev/null || { log_error "Требуется openssl"; return 1; }

    mkdir -p "$BACKUP_DIR"
    local ts; ts=$(date +%Y%m%d-%H%M%S)
    local plain="${BACKUP_DIR}/mtproxyl-${ts}.tar.gz"
    local enc="${plain}.enc"

    create_backup > /dev/null || { log_error "Ошибка создания бэкапа"; return 1; }
    # create_backup сохраняет файл и выводит путь — берём последний
    plain=$(ls -1t "${BACKUP_DIR}"/mtproxyl-*.tar.gz 2>/dev/null | head -1)
    [ -z "$plain" ] && { log_error "Бэкап не найден"; return 1; }
    enc="${plain}.enc"

    local pw1 pw2
    echo -en "  ${BOLD}Пароль шифрования:${NC} "; read -rs pw1; echo ""
    echo -en "  ${BOLD}Повторите пароль:${NC} "; read -rs pw2; echo ""
    [ "$pw1" != "$pw2" ] && { log_error "Пароли не совпадают"; rm -f "$plain"; return 1; }
    [ ${#pw1} -lt 8 ] && { log_error "Пароль: минимум 8 символов"; rm -f "$plain"; return 1; }

    local _rc=0
    MTPMXPW="$pw1" openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -in "$plain" -out "$enc" -pass env:MTPMXPW 2>/dev/null || _rc=1
    unset pw1 pw2 MTPMXPW
    if [ "$_rc" -eq 0 ]; then
        chmod 600 "$enc"; rm -f "$plain"
        log_success "Зашифрованный бэкап: ${enc}"
    else
        log_error "Шифрование не удалось"; rm -f "$plain" "$enc"; return 1
    fi
}

backup_restore_encrypted() {
    check_root
    local file="$1"
    [ -z "$file" ] && { log_error "Использование: backup restore-encrypted <файл>"; return 1; }
    [ -f "$file" ] || { log_error "Файл не найден: ${file}"; return 1; }
    command -v openssl &>/dev/null || { log_error "Требуется openssl"; return 1; }

    local pw
    echo -en "  ${BOLD}Пароль расшифровки:${NC} "; read -rs pw; echo ""
    local plain; plain=$(mktemp "${BACKUP_DIR}/.decrypt.XXXXXX.tar.gz")
    local _rc=0
    MTPMXPW="$pw" openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -in "$file" -out "$plain" -pass env:MTPMXPW 2>/dev/null || _rc=1
    unset pw MTPMXPW
    if [ "$_rc" -eq 0 ]; then
        restore_backup "$plain"
        rm -f "$plain"
    else
        log_error "Расшифровка не удалась (неверный пароль?)"; rm -f "$plain"; return 1
    fi
}

# Миграция
migrate_export() {
    local out="${1:-/tmp/mtproxyl-migrate-$(date +%Y%m%d-%H%M%S).tar.gz}"
    local tmp; tmp=$(mktemp -d) || { log_error "Не удалось создать временную директорию"; return 1; }
    local count=0
    for f in settings.conf secrets.conf upstreams.conf nft-rules.conf expert.conf tunings.conf; do
        [ -f "${INSTALL_DIR}/$f" ] && { cp "${INSTALL_DIR}/$f" "$tmp/" && count=$((count + 1)); }
    done
    echo "v${VERSION}" > "$tmp/MIGRATE_VERSION"
    tar -czf "$out" -C "$tmp" . 2>/dev/null && log_success "Экспортировано ${count} файлов в ${out}" || { log_error "Экспорт не удался"; rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"; chmod 600 "$out"
}

migrate_import() {
    check_root
    local file="$1"
    [ -z "$file" ] && { log_error "Использование: mtproxyl migrate import <файл>"; return 1; }
    [ -f "$file" ] || { log_error "Файл не найден: ${file}"; return 1; }

    local backup_before="${BACKUP_DIR}/pre-migrate-$(date +%s).tar.gz"
    mkdir -p "$BACKUP_DIR"
    migrate_export "$backup_before" 2>/dev/null
    log_info "Текущее состояние сохранено: ${backup_before}"

    local tmp; tmp=$(mktemp -d) || { log_error "Не удалось создать временную директорию"; return 1; }
    tar -xzf "$file" -C "$tmp" 2>/dev/null || { log_error "Некорректный архив"; rm -rf "$tmp"; return 1; }

    local restored=0 base
    for f in settings.conf secrets.conf upstreams.conf nft-rules.conf expert.conf tunings.conf; do
        [ -f "${tmp}/${f}" ] && { cp "${tmp}/${f}" "${INSTALL_DIR}/$f" && chmod 600 "${INSTALL_DIR}/$f" && restored=$((restored + 1)); }
    done

    rm -rf "$tmp"
    load_settings; load_secrets
    log_success "Импортировано ${restored} файлов из ${file}"

    if is_proxy_running; then
        restart_proxy_container
    else
        reload_proxy_config 2>/dev/null || true
    fi
}

handle_backup_command() {
    case "${1:-}" in
        --encrypt|encrypt) backup_create_encrypted ;;
        restore-encrypted) backup_restore_encrypted "$2" ;;
        autoclean)         backup_autoclean "${2:-${BACKUP_RETENTION_DAYS:-30}}" ;;
        *) create_backup ;;
    esac
}

handle_restore_command() {
    if [ "${1:-}" = "--encrypted" ] && [ -n "${2:-}" ]; then
        backup_restore_encrypted "$2"
    else
        restore_backup "$1"
    fi
}
