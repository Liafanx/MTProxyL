#!/bin/bash
# MTProxyL — интерактивные меню (TUI)

show_banner() {
    echo -e "${BRIGHT_CYAN}"
    cat << 'BANNER'

    ███╗   ███╗████████╗██████╗ ██████╗  ██████╗
    ████╗ ████║╚══██╔══╝██╔══██╗██╔══██╗██╔═══██╗
    ██╔████╔██║   ██║   ██████╔╝██████╔╝██║   ██║
    ██║╚██╔╝██║   ██║   ██╔═══╝ ██╔══██╗██║   ██║
    ██║ ╚═╝ ██║   ██║   ██║     ██║  ██║╚██████╔╝
    ╚═╝     ╚═╝   ╚═╝   ╚═╝     ╚═╝  ╚═╝ ╚═════╝
BANNER
    echo -e "    ${BOLD}MTProxyL v${VERSION}${NC} ${DIM}by LiafanX${NC}"
    echo -e "${NC}"
}

show_main_menu() {
    while true; do
        clear 2>/dev/null || printf '\033[2J\033[H'
        show_banner

        # Статус-панель
        local _running=false
        if is_proxy_running; then _running=true; fi

        local status_str uptime_str t_in t_out conns
        if [ "$_running" = "true" ]; then
            status_str=$(draw_status running)
            local up_secs; up_secs=$(get_proxy_uptime)
            uptime_str=$(format_duration "$up_secs")
            read -r t_in t_out conns <<< "$(get_proxy_stats)"
        else
            status_str=$(draw_status stopped)
            uptime_str="—"; t_in=0; t_out=0; conns=0
        fi

        local active=0 disabled=0 i
        for i in "${!SECRETS_ENABLED[@]}"; do
            [ "${SECRETS_ENABLED[$i]}" = "true" ] && active=$((active+1)) || disabled=$((disabled+1))
        done

        echo -e "  ${BOLD}Движок:${NC}      telemt v$(get_telemt_version)  ${BOLD}Статус:${NC} ${status_str}"
        echo -e "  ${BOLD}Порт:${NC}        ${PROXY_PORT}            ${BOLD}Работает:${NC} ${uptime_str}"
        echo -e "  ${BOLD}Домен:${NC}       ${PROXY_DOMAIN}"
        echo -e "  ${BOLD}Трафик:${NC}      ${SYM_DOWN} $(format_bytes "$t_in")  ${SYM_UP} $(format_bytes "$t_out")  ${BOLD}Соед.:${NC} ${conns}"
        echo -e "  ${BOLD}Секреты:${NC}     ${active} активных / ${disabled} выключенных"

        # NFT статус
        load_nft_settings 2>/dev/null
        local _nft_line; _nft_line=$(nft_status_line 2>/dev/null || echo "${DIM}—${NC}")
        local _ios1_line; _ios1_line=$(ios_fix_status_line 2>/dev/null || echo "${DIM}—${NC}")
        local _ios2_line; _ios2_line=$(ios2_fix_status_line 2>/dev/null || echo "${DIM}—${NC}")
        echo -e "  ${BOLD}NFT лимитер:${NC} ${_nft_line}"
        echo -e "  ${BOLD}iOS фикс v1:${NC} ${_ios1_line}"
        echo -e "  ${BOLD}iOS фикс v2:${NC} ${_ios2_line}"

        echo ""
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        echo ""
        echo -e "  ${BRIGHT_CYAN}[1]${NC}  Управление прокси"
        echo -e "  ${BRIGHT_CYAN}[2]${NC}  Управление секретами"
        echo -e "  ${BRIGHT_CYAN}[3]${NC}  Ссылки и QR"
        echo -e "  ${BRIGHT_CYAN}[4]${NC}  Настройки"
        echo -e "  ${BRIGHT_CYAN}[5]${NC}  Безопасность и маршрутизация"
        echo -e "  ${BRIGHT_CYAN}[6]${NC}  Логи и трафик"
        echo -e "  ${BRIGHT_CYAN}[7]${NC}  NFT лимитер и iOS фиксы"
        echo -e "  ${BRIGHT_CYAN}[8]${NC}  Движок Telemt"
        echo -e "  ${BRIGHT_CYAN}[9]${NC}  Бэкапы"
        echo -e "  ${BRIGHT_CYAN}[e]${NC}  Режим эксперта"
        echo -e "  ${BRIGHT_CYAN}[i]${NC}  Информация"
        echo ""
        echo -e "  ${BRIGHT_CYAN}[r]${NC}  Переустановить"        
        echo -e "  ${RED}[u]${NC}  Удаление"
        echo -e "  ${BRIGHT_CYAN}[0]${NC}  Выход"
        echo ""
        local choice; choice=$(read_choice "выбор" "0")

        case "$choice" in
            1) tui_proxy_menu ;;
            2) tui_secrets_menu ;;
            3) tui_links_menu ;;
            4) tui_settings_menu ;;
            5) tui_security_menu ;;
            6) tui_traffic_menu ;;
            7) tui_nft_menu ;;
            8) tui_engine_menu ;;
            9) tui_backup_menu ;;
            e|E) tui_expert_menu ;;
            i|I) show_server_info; press_any_key ;;
            r|R) run_installer ;;
            u|U) uninstall; exit 0 ;;
            0|q|Q) exit 0 ;;
        esac
    done
}

# ── Подменю: Прокси ──────────────────────────────────────────
tui_proxy_menu() {
    while true; do
        clear_screen
        draw_header "УПРАВЛЕНИЕ ПРОКСИ"
        echo ""
        local _st; is_proxy_running && _st="$(draw_status running)" || _st="$(draw_status stopped)"
        echo -e "  Статус: ${_st}"
        echo ""
        echo -e "  ${DIM}[1]${NC} Запустить"
        echo -e "  ${DIM}[2]${NC} Остановить"
        echo -e "  ${DIM}[3]${NC} Перезапустить"
        echo -e "  ${DIM}[4]${NC} Логи"
        echo -e "  ${DIM}[5]${NC} Диагностика"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) start_proxy_container || true; press_any_key ;;
            2) stop_proxy_container || true; press_any_key ;;
            3) restart_proxy_container || true; press_any_key ;;
            4) echo -e "  ${DIM}Ctrl+C для остановки...${NC}"; docker logs -f --tail 30 "$CONTAINER_NAME" 2>&1 || true; press_any_key ;;
            5) health_check || true; press_any_key ;;
            0|"") return ;;
        esac
    done
}

# ── Подменю: Секреты ─────────────────────────────────────────
tui_secrets_menu() {
    while true; do
        clear_screen
        secret_list
        echo -e "  ${DIM}[1]${NC} Добавить секрет"
        echo -e "  ${DIM}[2]${NC} Удалить секрет"
        echo -e "  ${DIM}[3]${NC} Обновить ключ (ротация)"
        echo -e "  ${DIM}[4]${NC} Включить/выключить"
        echo -e "  ${DIM}[5]${NC} Установить лимиты"
        echo -e "  ${DIM}[6]${NC} Клонировать"
        echo -e "  ${DIM}[7]${NC} Переименовать"
        echo -e "  ${DIM}[8]${NC} Полная информация о секрете"
        echo -e "  ${DIM}[9]${NC} Ссылка / QR-код"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1)
                echo -en "  ${BOLD}Метка:${NC} "; local l; read -r l
                [ -n "$l" ] && { secret_add "$l" || true; }
                press_any_key ;;
            2)
                echo -en "  ${BOLD}Метка или #:${NC} "; local l; read -r l
                if [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -ge 1 ] && [ "$l" -le "${#SECRETS_LABELS[@]}" ]; then
                    l="${SECRETS_LABELS[$((l - 1))]}"
                fi
                [ -n "$l" ] && { secret_remove "$l" || true; }
                press_any_key ;;
            3)
                echo -en "  ${BOLD}Метка или #:${NC} "; local l; read -r l
                if [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -ge 1 ] && [ "$l" -le "${#SECRETS_LABELS[@]}" ]; then
                    l="${SECRETS_LABELS[$((l - 1))]}"
                fi
                [ -n "$l" ] && { secret_rotate "$l" || true; }
                press_any_key ;;
            4)
                echo -en "  ${BOLD}Метка или #:${NC} "; local l; read -r l
                if [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -ge 1 ] && [ "$l" -le "${#SECRETS_LABELS[@]}" ]; then
                    l="${SECRETS_LABELS[$((l - 1))]}"
                fi
                [ -n "$l" ] && { secret_toggle "$l" || true; }
                press_any_key ;;
            5)
                secret_show_limits
                echo ""
                echo -en "  ${BOLD}Метка или #:${NC} "; local l; read -r l
                if [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -ge 1 ] && [ "$l" -le "${#SECRETS_LABELS[@]}" ]; then
                    l="${SECRETS_LABELS[$((l - 1))]}"
                fi
                if [ -n "$l" ]; then
                    echo -en "  ${BOLD}Макс. TCP соединений (0=∞):${NC} "; local mc; read -r mc
                    echo -en "  ${BOLD}Макс. уникальных IP (0=∞):${NC} "; local mi; read -r mi
                    echo -en "  ${BOLD}Квота трафика (напр. 5G, 500M, 0=∞):${NC} "; local dq; read -r dq
                    echo -en "  ${BOLD}Срок действия (YYYY-MM-DD, 0=бессрочно):${NC} "; local ex; read -r ex
                    secret_set_limits "$l" "${mc:-0}" "${mi:-0}" "${dq:-0}" "${ex:-0}" || true
                fi
                press_any_key ;;
            6)
                echo -en "  ${BOLD}Источник:${NC} "; local s; read -r s
                if [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" -ge 1 ] && [ "$s" -le "${#SECRETS_LABELS[@]}" ]; then
                    s="${SECRETS_LABELS[$((s - 1))]}"
                fi
                echo -en "  ${BOLD}Новая метка:${NC} "; local n; read -r n
                [ -n "$s" ] && [ -n "$n" ] && { secret_clone "$s" "$n" || true; }
                press_any_key ;;
            7)
                echo -en "  ${BOLD}Старая:${NC} "; local o; read -r o
                if [[ "$o" =~ ^[0-9]+$ ]] && [ "$o" -ge 1 ] && [ "$o" -le "${#SECRETS_LABELS[@]}" ]; then
                    o="${SECRETS_LABELS[$((o - 1))]}"
                fi
                echo -en "  ${BOLD}Новая:${NC} "; local n; read -r n
                [ -n "$o" ] && [ -n "$n" ] && { secret_rename "$o" "$n" || true; }
                press_any_key ;;
            8)
                echo -en "  ${BOLD}Метка или #:${NC} "; local l; read -r l
                if [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -ge 1 ] && [ "$l" -le "${#SECRETS_LABELS[@]}" ]; then
                    l="${SECRETS_LABELS[$((l - 1))]}"
                fi
                [ -n "$l" ] && { secret_show_limits "$l" || true; }
                press_any_key ;;
            9)
                echo -en "  ${BOLD}Метка или #:${NC} "; local l; read -r l
                if [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -ge 1 ] && [ "$l" -le "${#SECRETS_LABELS[@]}" ]; then
                    l="${SECRETS_LABELS[$((l - 1))]}"
                fi
                if [ -n "$l" ]; then
                    local link; link=$(get_proxy_link "$l") || true
                    if [ -n "$link" ]; then
                        echo -e "  ${CYAN}${link}${NC}"
                        if command -v qrencode &>/dev/null; then
                            echo ""; qrencode -t ANSIUTF8 "$link" | sed 's/^/  /'
                        fi
                    fi
                fi
                press_any_key ;;
            0|"") return ;;
        esac
    done
}

# ── Подменю: Ссылки ──────────────────────────────────────────
tui_links_menu() {
    clear_screen
    draw_header "ССЫЛКИ И QR-КОДЫ"

    local server_ip; server_ip=$(get_public_ip)
    [ -z "$server_ip" ] && { log_error "Не удалось определить IP"; press_any_key; return; }

    local i
    for i in "${!SECRETS_LABELS[@]}"; do
        [ "${SECRETS_ENABLED[$i]}" = "true" ] || continue
        local fs; fs=$(build_faketls_secret "${SECRETS_KEYS[$i]}")
        local tg_link="tg://proxy?server=${server_ip}&port=${PROXY_PORT}&secret=${fs}"
        local web_link="https://t.me/proxy?server=${server_ip}&port=${PROXY_PORT}&secret=${fs}"

        echo ""
        echo -e "  ${BRIGHT_GREEN}${BOLD}${SECRETS_LABELS[$i]}${NC}"
        echo -e "  ${DIM}$(_repeat '─' 40)${NC}"
        echo -e "  ${BOLD}TG:${NC}  ${CYAN}${tg_link}${NC}"
        echo -e "  ${BOLD}Веб:${NC} ${CYAN}${web_link}${NC}"

        if command -v qrencode &>/dev/null; then
            echo ""
            qrencode -t ANSIUTF8 "$web_link" 2>/dev/null | sed 's/^/  /'
        fi
    done
    press_any_key
}

# ── Подменю: Настройки ───────────────────────────────────────
tui_settings_menu() {
    while true; do
        clear_screen
        draw_header "НАСТРОЙКИ"
        echo ""
        echo -e "  ${BOLD}Порт:${NC}        ${PROXY_PORT}"
        echo -e "  ${BOLD}IP:${NC}          ${CUSTOM_IP:-$(get_public_ip 2>/dev/null) ${DIM}(авто)${NC}}"
        echo -e "  ${BOLD}Домен:${NC}       ${PROXY_DOMAIN}"
        echo -e "  ${BOLD}CPU:${NC}         ${PROXY_CPUS:-без ограничений}"
        echo -e "  ${BOLD}Память:${NC}      ${PROXY_MEMORY:-без ограничений}"
        echo -e "  ${BOLD}Маскировка:${NC}  ${MASKING_ENABLED}$([ "$MASKING_ENABLED" = "true" ] && echo " → ${MASKING_HOST:-${PROXY_DOMAIN}}:${MASKING_PORT:-443}")"
        echo -e "  ${BOLD}Рекл. метка:${NC} ${AD_TAG:-${DIM}не задана${NC}}"
        echo -e "  ${BOLD}SNI-полит.:${NC}  ${UNKNOWN_SNI_ACTION}"
        echo -e "  ${BOLD}PROXY proto:${NC} ${PROXY_PROTOCOL}"
        echo -e "  ${BOLD}Движок:${NC}      telemt v$(get_telemt_version)"
        echo ""
        echo -e "  ${DIM}[1]${NC} Изменить порт"
        echo -e "  ${DIM}[2]${NC} Изменить IP"
        echo -e "  ${DIM}[3]${NC} Изменить домен"
        echo -e "  ${DIM}[4]${NC} Ресурсы (CPU/RAM)"
        echo -e "  ${DIM}[5]${NC} Маскировка вкл/выкл"
        echo -e "  ${DIM}[m]${NC} Mask backend (хост:порт)"
        echo -e "  ${DIM}[6]${NC} Рекламная метка"
        echo -e "  ${DIM}[7]${NC} SNI-политика [${UNKNOWN_SNI_ACTION}]"
        echo -e "  ${DIM}[8]${NC} PROXY protocol вкл/выкл"
        echo -e "  ${DIM}[9]${NC} Управление движком"
        echo -e "  ${DIM}[v]${NC} Просмотр конфига"
        echo -e "  ${DIM}[t]${NC} Тюнинг движка (tune)"
        echo -e "  ${DIM}[u]${NC} Пользовательские URL Telegram"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1)
                echo -en "  ${BOLD}Новый порт:${NC} "; local p; read -r p
                if validate_port "$p"; then
                    PROXY_PORT="$p"; save_settings; log_success "Порт: ${p}"
                    is_proxy_running && { load_secrets; restart_proxy_container || true; }
                elif [ -n "$p" ]; then log_error "Некорректный порт"; fi
                press_any_key ;;
            2)
                echo -en "  ${BOLD}IP [${CUSTOM_IP:-авто}]:${NC} "; local ip; read -r ip
                case "$ip" in
                    auto|clear) CUSTOM_IP=""; save_settings; log_success "IP: авто" ;;
                    "") ;;
                    *) CUSTOM_IP="$ip"; save_settings; log_success "IP: ${ip}" ;;
                esac
                press_any_key ;;
            3)
                echo -e "  ${DIM}[1] cloudflare.com  [2] google.com  [3] microsoft.com  [4] Свой${NC}"
                local d; d=$(read_choice "выбор" "1")
                case "$d" in
                    2) PROXY_DOMAIN="www.google.com" ;;
                    3) PROXY_DOMAIN="www.microsoft.com" ;;
                    4) echo -en "  Домен: "; local cd; read -r cd
                       [ -n "$cd" ] && validate_domain "$cd" && PROXY_DOMAIN="$cd" || log_error "Некорректный домен" ;;
                    *) PROXY_DOMAIN="cloudflare.com" ;;
                esac
                save_settings; log_success "Домен: ${PROXY_DOMAIN}"
                is_proxy_running && { load_secrets; restart_proxy_container || true; }
                press_any_key ;;
            4)
                echo -en "  ${BOLD}CPU [${PROXY_CPUS:-∞}]:${NC} "; local c; read -r c
                [ -n "$c" ] && PROXY_CPUS="$c"
                echo -en "  ${BOLD}RAM (напр. 256m, 1g) [${PROXY_MEMORY:-∞}]:${NC} "; local m; read -r m
                [ -n "$m" ] && PROXY_MEMORY="$m"
                save_settings; log_success "Ресурсы обновлены"
                press_any_key ;;
            5)
                [ "$MASKING_ENABLED" = "true" ] && MASKING_ENABLED="false" || MASKING_ENABLED="true"
                save_settings; log_success "Маскировка: ${MASKING_ENABLED}"
                is_proxy_running && { load_secrets; restart_proxy_container || true; }
                press_any_key ;;
            m|M)
                echo -e "  ${DIM}Текущий: ${MASKING_HOST:-${PROXY_DOMAIN}}:${MASKING_PORT:-443}${NC}"
                echo -en "  ${BOLD}Хост:${NC} "; local mh; read -r mh
                echo -en "  ${BOLD}Порт [${MASKING_PORT:-443}]:${NC} "; local mp; read -r mp
                [ -n "$mh" ] && MASKING_HOST="$mh"
                [ -n "$mp" ] && [[ "$mp" =~ ^[0-9]+$ ]] && MASKING_PORT="$mp"
                save_settings; log_success "Mask backend: ${MASKING_HOST:-${PROXY_DOMAIN}}:${MASKING_PORT:-443}"
                is_proxy_running && { load_secrets; restart_proxy_container || true; }
                press_any_key ;;
            6)
                echo -en "  ${BOLD}Рекл. метка (32 hex, 'remove'):${NC} "; local at; read -r at
                if [ "$at" = "remove" ]; then AD_TAG=""; log_success "Метка удалена"
                elif [[ "$at" =~ ^[0-9a-fA-F]{32}$ ]]; then AD_TAG="$at"; log_success "Метка установлена"
                elif [ -n "$at" ]; then log_error "Нужно 32 hex-символа"; fi
                save_settings; load_secrets; reload_proxy_config 2>/dev/null || true
                press_any_key ;;
            7)
                echo -e "  ${DIM}[1] Mask (перенаправлять)  [2] Drop (закрывать)${NC}"
                local sc; sc=$(read_choice "выбор" "1")
                case "$sc" in 2) UNKNOWN_SNI_ACTION="drop" ;; *) UNKNOWN_SNI_ACTION="mask" ;; esac
                save_settings; reload_proxy_config 2>/dev/null || true
                log_success "SNI-политика: ${UNKNOWN_SNI_ACTION}"
                press_any_key ;;
            8)
                [ "$PROXY_PROTOCOL" = "true" ] && PROXY_PROTOCOL="false" || PROXY_PROTOCOL="true"
                if [ "$PROXY_PROTOCOL" = "true" ]; then
                    echo -en "  ${BOLD}Доверенные CIDR (через запятую):${NC} "; local cidrs; read -r cidrs
                    PROXY_PROTOCOL_TRUSTED_CIDRS="$cidrs"
                else PROXY_PROTOCOL_TRUSTED_CIDRS=""; fi
                save_settings; log_success "PROXY protocol: ${PROXY_PROTOCOL}"
                is_proxy_running && { load_secrets; restart_proxy_container || true; }
                press_any_key ;;
            9) tui_engine_menu ;;
            v|V) show_config; press_any_key ;;
            t|T)
                handle_tune_command list
                echo -e "  ${DIM}[1] Установить  [2] Очистить  [3] Очистить все  [0] Назад${NC}"
                local tc; tc=$(read_choice "выбор" "0")
                case "$tc" in
                    1) echo -en "  ${BOLD}Параметр:${NC} "; local tp; read -r tp
                       echo -en "  ${BOLD}Значение:${NC} "; local tv; read -r tv
                       [ -n "$tp" ] && [ -n "$tv" ] && handle_tune_command set "$tp" "$tv" ;;
                    2) echo -en "  ${BOLD}Параметр:${NC} "; local tp; read -r tp
                       [ -n "$tp" ] && handle_tune_command clear "$tp" ;;
                    3) handle_tune_command clear all ;;
                esac
                press_any_key ;;
            u|U)
                echo -e "  ${BOLD}Пользовательские URL Telegram${NC}"
                echo -e "  ${DIM}Для регионов где core.telegram.org заблокирован${NC}"
                echo ""
                echo -e "  proxy_secret_url:    ${PROXY_SECRET_URL:-${DIM}(по умолчанию)${NC}}"
                echo -e "  proxy_config_v4_url: ${PROXY_CONFIG_V4_URL:-${DIM}(по умолчанию)${NC}}"
                echo -e "  proxy_config_v6_url: ${PROXY_CONFIG_V6_URL:-${DIM}(по умолчанию)${NC}}"
                echo ""
                echo -e "  ${DIM}[1] Установить  [2] Очистить все  [0] Назад${NC}"
                local uc; uc=$(read_choice "выбор" "0")
                case "$uc" in
                    1)
                        echo -e "  ${DIM}[1] secret  [2] config-v4  [3] config-v6${NC}"
                        local uf; uf=$(read_choice "выбор" "1")
                        echo -en "  ${BOLD}URL:${NC} "; local uv; read -r uv
                        if [ -n "$uv" ] && [[ "$uv" =~ ^https?:// ]]; then
                            case "$uf" in
                                1) PROXY_SECRET_URL="$uv" ;;
                                2) PROXY_CONFIG_V4_URL="$uv" ;;
                                3) PROXY_CONFIG_V6_URL="$uv" ;;
                            esac
                            save_settings; log_success "URL установлен"
                            is_proxy_running && { load_secrets; restart_proxy_container || true; }
                        elif [ -n "$uv" ]; then log_error "URL должен начинаться с http:// или https://"; fi ;;
                    2) PROXY_SECRET_URL=""; PROXY_CONFIG_V4_URL=""; PROXY_CONFIG_V6_URL=""
                       save_settings; log_success "URL сброшены"
                       is_proxy_running && { load_secrets; restart_proxy_container || true; } ;;
                esac
                press_any_key ;;
            0|"") return ;;
        esac
    done
}

# ── Подменю: Безопасность ────────────────────────────────────
tui_security_menu() {
    while true; do
        clear_screen
        draw_header "БЕЗОПАСНОСТЬ И МАРШРУТИЗАЦИЯ"
        echo ""
        echo -e "  ${DIM}[1]${NC} Гео-блокировка"
        echo -e "  ${DIM}[2]${NC} Upstream-маршруты"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) tui_geoblock_menu ;;
            2) tui_upstream_menu ;;
            0|"") return ;;
        esac
    done
}

# ── Подменю: Гео-блокировка ──────────────────────────────────
tui_geoblock_menu() {
    while true; do
        clear_screen
        draw_header "ГЕО-БЛОКИРОВКА"
        echo ""
        echo -e "  ${BOLD}Режим:${NC}   ${GEOBLOCK_MODE}"
        echo -e "  ${BOLD}Страны:${NC} ${BLOCKLIST_COUNTRIES:-${DIM}нет${NC}}"
        echo ""
        echo -e "  ${DIM}[1]${NC} Добавить страну"
        echo -e "  ${DIM}[2]${NC} Удалить страну"
        echo -e "  ${DIM}[3]${NC} Очистить все"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1)
                echo -e "  ${DIM}Коды: US DE NL FR GB SG JP CA AU KR CN RU IR${NC}"
                echo -en "  ${BOLD}Код страны:${NC} "; local cc; read -r cc
                [ -n "$cc" ] && handle_geoblock_command add "$cc"
                press_any_key ;;
            2)
                echo -en "  ${BOLD}Код страны:${NC} "; local cc; read -r cc
                [ -n "$cc" ] && handle_geoblock_command remove "$cc"
                press_any_key ;;
            3) handle_geoblock_command clear; press_any_key ;;
            0|"") return ;;
        esac
    done
}

# ── Подменю: Upstream ────────────────────────────────────────
tui_upstream_menu() {
    while true; do
        clear_screen
        upstream_list
        echo -e "  ${DIM}[1]${NC} Добавить"
        echo -e "  ${DIM}[2]${NC} Удалить"
        echo -e "  ${DIM}[3]${NC} Вкл/выкл"
        echo -e "  ${DIM}[4]${NC} Тест"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1)
                echo -en "  ${BOLD}Имя:${NC} "; local n; read -r n
                echo -e "  ${DIM}[1] SOCKS5  [2] SOCKS4  [3] Direct${NC}"
                local tc; read -rp "  > " tc
                local t; case "$tc" in 1) t="socks5" ;; 2) t="socks4" ;; *) t="direct" ;; esac
                local a="" us="" ps=""
                if [ "$t" != "direct" ]; then
                    echo -en "  ${BOLD}Адрес (host:port):${NC} "; read -r a
                    echo -en "  ${BOLD}Логин:${NC} "; read -r us
                    echo -en "  ${BOLD}Пароль:${NC} "; read -r ps
                fi
                echo -en "  ${BOLD}Вес [10]:${NC} "; local w; read -r w; w="${w:-10}"
                upstream_add "$n" "$t" "$a" "$us" "$ps" "$w" || true
                press_any_key ;;
            2) echo -en "  ${BOLD}Имя:${NC} "; local n; read -r n; [ -n "$n" ] && upstream_remove "$n" || true; press_any_key ;;
            3) echo -en "  ${BOLD}Имя:${NC} "; local n; read -r n; [ -n "$n" ] && upstream_toggle "$n" || true; press_any_key ;;
            4) echo -en "  ${BOLD}Имя:${NC} "; local n; read -r n; [ -n "$n" ] && upstream_test "$n" || true; press_any_key ;;
            0|"") return ;;
        esac
    done
}

# ── Подменю: Трафик ──────────────────────────────────────────
tui_traffic_menu() {
    clear_screen
    if ! is_proxy_running; then
        echo -e "  ${DIM}Прокси не запущен${NC}"; press_any_key; return
    fi
    show_traffic
    echo -e "  ${DIM}[1]${NC} Логи"
    echo -e "  ${DIM}[2]${NC} Метрики (авто)"
    echo -e "  ${DIM}[3]${NC} Соединения"
    echo -e "  ${DIM}[0]${NC} Назад"
    local choice; choice=$(read_choice "выбор" "0")
    case "$choice" in
        1) echo -e "  ${DIM}Ctrl+C...${NC}"; docker logs -f --tail 30 "$CONTAINER_NAME" 2>&1 || true ;;
        2) handle_metrics_command live 5 ;;
        3) show_connections; press_any_key ;;
    esac
}

# ── Подменю: NFT лимитер ─────────────────────────────────────
tui_nft_menu() {
    while true; do
        clear_screen
        draw_header "NFT ЛИМИТЕР И iOS ФИКСЫ"
        echo ""
        load_nft_settings 2>/dev/null
        echo -e "  ${BOLD}NFT лимитер:${NC} $(nft_status_line)"
        echo -e "  ${BOLD}iOS фикс v1:${NC} $(ios_fix_status_line)"
        echo -e "  ${BOLD}iOS фикс v2:${NC} $(ios2_fix_status_line)"
        echo ""
        echo -e "  ${DIM}Параметры: rate=${NFT_RATE} burst=${NFT_BURST} timeout=${NFT_METER_TIMEOUT}${NC}"
        [ -n "${NFT_SERVER_IP:-}" ] && echo -e "  ${DIM}IP: ${NFT_SERVER_IP}${NC}" || echo -e "  ${DIM}IP: все${NC}"
        echo ""
        echo -e "  ${CYAN}[1]${NC}  Применить NFT правила"
        echo -e "  ${CYAN}[2]${NC}  Удалить NFT правила"
        echo -e "  ${CYAN}[3]${NC}  Пресеты (жёсткий/средний/мягкий)"
        echo -e "  ${CYAN}[4]${NC}  Настройки NFT"
        echo -e "  ${CYAN}[5]${NC}  Счётчик дропов"
        echo -e "  ${CYAN}[6]${NC}  Установить службу"
        echo -e "  ${CYAN}[7]${NC}  Удалить службу"
        echo -e "  ${CYAN}[8]${NC}  Доп. правила"
        echo ""
        echo -e "  ${CYAN}[a]${NC}  iOS Fix v1 (TCP keepalive)"
        echo -e "  ${CYAN}[b]${NC}  iOS Fix v2 (MSS + redirect)"
        echo ""
        echo -e "  ${DIM}[0]${NC}  Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1)
                if [ -z "${PROXY_PORT:-}" ]; then log_error "Порт не задан"; press_any_key; continue; fi
                apply_nft_rules || true; press_any_key ;;
            2) remove_nft_rules || true; press_any_key ;;
            3)
                echo -e "  ${RED}[1]${NC} Жёсткий (1/s burst 1)  ${YELLOW}[2]${NC} Средний (1/s burst 3)  ${GREEN}[3]${NC} Мягкий (2/s burst 5)"
                local pc; pc=$(read_choice "выбор" "1")
                case "$pc" in 1) apply_nft_preset hard ;; 2) apply_nft_preset medium ;; 3) apply_nft_preset soft ;; esac
                echo -en "  ${BOLD}Применить сейчас? [Y/n]:${NC} "; local yn; read -r yn
                [[ ! "$yn" =~ ^[nN]$ ]] && apply_nft_rules || true
                press_any_key ;;
            4) tui_nft_settings ;;
            5) show_nft_drop_counter || true ;;
            6) install_nft_service || true; press_any_key ;;
            7) remove_nft_service || true; press_any_key ;;
            8) tui_nft_extra_menu ;;
            a|A) tui_ios1_menu ;;
            b|B) tui_ios2_menu ;;
            0|"") return ;;
        esac
    done
}

tui_nft_settings() {
    clear_screen
    draw_header "НАСТРОЙКИ NFT"
    echo ""
    echo -en "  ${BOLD}Rate [${NFT_RATE}]:${NC} "; local r; read -r r; [ -n "$r" ] && NFT_RATE="$r"
    echo -en "  ${BOLD}Burst [${NFT_BURST}]:${NC} "; local b; read -r b; [[ "$b" =~ ^[0-9]+$ ]] && NFT_BURST="$b"
    echo -en "  ${BOLD}Timeout [${NFT_METER_TIMEOUT}]:${NC} "; local t; read -r t; [ -n "$t" ] && NFT_METER_TIMEOUT="$t"
    echo -en "  ${BOLD}IP сервера [${NFT_SERVER_IP:-пусто}]:${NC} "; local ip; read -r ip
    case "$ip" in none|clear|-) NFT_SERVER_IP="" ;; "") ;; *) NFT_SERVER_IP="$ip" ;; esac
    save_nft_settings
    log_success "Настройки NFT обновлены"
    echo -en "  ${BOLD}Применить сейчас? [Y/n]:${NC} "; local yn; read -r yn
    [[ ! "$yn" =~ ^[nN]$ ]] && apply_nft_rules || true
    press_any_key
}

tui_nft_extra_menu() {
    clear_screen
    draw_header "ДОПОЛНИТЕЛЬНЫЕ ПРАВИЛА"
    echo ""
    if [ "$NFT_EXTRA_COUNT" -eq 0 ]; then
        echo -e "  ${DIM}Нет дополнительных правил${NC}"
    else
        local i; for i in $(seq 1 "$NFT_EXTRA_COUNT"); do
            echo -e "  ${DIM}[$i]${NC} порт=${NFT_EXTRA_PORT[$i]:-?} ip=${NFT_EXTRA_IP[$i]:-все} rate=${NFT_EXTRA_RATE[$i]:-?} burst=${NFT_EXTRA_BURST[$i]:-?}"
        done
    fi
    echo ""
    echo -e "  ${DIM}[a]${NC} Добавить  ${DIM}[d]${NC} Удалить  ${DIM}[0]${NC} Назад"
    local choice; choice=$(read_choice "выбор" "0")
    case "$choice" in
        a|A)
            echo -en "  Порт: "; local p; read -r p
            echo -en "  IP (пусто=все): "; local ip; read -r ip
            echo -en "  Rate [1/second]: "; local r; read -r r; r="${r:-1/second}"
            echo -en "  Burst [1]: "; local b; read -r b; b="${b:-1}"
            nft_extra_add "$p" "$ip" "$r" "$b" || true
            echo -en "  ${BOLD}Применить? [Y/n]:${NC} "; local yn; read -r yn
            [[ ! "$yn" =~ ^[nN]$ ]] && apply_nft_rules || true ;;
        d|D)
            echo -en "  Номер: "; local idx; read -r idx
            nft_extra_remove "$idx" || true
            echo -en "  ${BOLD}Применить? [Y/n]:${NC} "; local yn; read -r yn
            [[ ! "$yn" =~ ^[nN]$ ]] && apply_nft_rules || true ;;
    esac
    press_any_key
}

tui_ios1_menu() {
    clear_screen
    draw_header "iOS FIX v1 — TCP KEEPALIVE"
    echo ""
    echo -e "  Статус: $(ios_fix_status_line)"
    echo ""
    echo -e "  ${DIM}[1]${NC} Применить"
    echo -e "  ${DIM}[2]${NC} Откатить"
    echo -e "  ${DIM}[0]${NC} Назад"
    local choice; choice=$(read_choice "выбор" "0")
    case "$choice" in
        1) ios_fix_apply || true ;;
        2) ios_fix_remove || true ;;
    esac
    press_any_key
}

tui_ios2_menu() {
    clear_screen
    draw_header "iOS FIX v2 — MSS + REDIRECT"
    echo ""
    echo -e "  Статус: $(ios2_fix_status_line)"
    echo -e "  Порт iOS: ${IOS2_EXTERNAL_PORT}  MSS: ${IOS2_MSS}"
    echo ""
    echo -e "  ${DIM}[1]${NC} Применить"
    echo -e "  ${DIM}[2]${NC} Откатить"
    echo -e "  ${DIM}[3]${NC} Изменить порт [${IOS2_EXTERNAL_PORT}]"
    echo -e "  ${DIM}[4]${NC} Изменить MSS [${IOS2_MSS}]"
    echo -e "  ${DIM}[0]${NC} Назад"
    local choice; choice=$(read_choice "выбор" "0")
    case "$choice" in
        1) ios2_fix_apply || true ;;
        2) ios2_fix_remove || true ;;
        3) echo -en "  Порт: "; local p; read -r p
           [[ "$p" =~ ^[0-9]+$ ]] && { IOS2_EXTERNAL_PORT="$p"; save_nft_settings; log_success "Порт: $p"; } ;;
        4) echo -en "  MSS: "; local m; read -r m
           [[ "$m" =~ ^[0-9]+$ ]] && { IOS2_MSS="$m"; save_nft_settings; log_success "MSS: $m"; } ;;
    esac
    press_any_key
}

# ── Подменю: Движок ──────────────────────────────────────────
tui_engine_menu() {
    while true; do
        clear_screen
        draw_header "ДВИЖОК TELEMT"
        echo ""
        echo -e "  ${BOLD}Версия:${NC}    telemt v$(get_telemt_version)"
        echo -e "  ${BOLD}Закреплён:${NC} commit ${TELEMT_COMMIT}"
        echo ""
        echo -e "  ${DIM}[1]${NC} Список версий"
        echo -e "  ${DIM}[2]${NC} Обновить до версии"
        echo -e "  ${DIM}[3]${NC} Откатить"
        echo -e "  ${DIM}[4]${NC} Пересобрать"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) handle_engine_command list; press_any_key ;;
            2) handle_engine_command update; press_any_key ;;
            3) handle_engine_command rollback; press_any_key ;;
            4) build_telemt_image true; is_proxy_running && { load_secrets; restart_proxy_container || true; }; press_any_key ;;
            0|"") return ;;
        esac
    done
}

# ── Подменю: Бэкапы ──────────────────────────────────────────
tui_backup_menu() {
    while true; do
        clear_screen
        draw_header "БЭКАПЫ И ОБНОВЛЕНИЯ"
        echo ""
        echo -e "  ${DIM}[1]${NC} Проверить обновления"
        echo -e "  ${DIM}[2]${NC} Создать бэкап"
        echo -e "  ${DIM}[3]${NC} Восстановить бэкап"
        echo -e "  ${DIM}[4]${NC} Список бэкапов"
        echo -e "  ${DIM}[5]${NC} Зашифрованный бэкап"
        echo -e "  ${DIM}[6]${NC} Восстановить зашифрованный"
        echo -e "  ${DIM}[7]${NC} Экспорт (миграция на другой сервер)"
        echo -e "  ${DIM}[8]${NC} Импорт (миграция с другого сервера)"
        echo -e "  ${DIM}[9]${NC} Автоочистка старых бэкапов"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) self_update || true; press_any_key ;;
            2) create_backup || true; press_any_key ;;
            3) list_backups; echo -en "  ${BOLD}Файл:${NC} "; local f; read -r f
               [ -n "$f" ] && restore_backup "$f" || true; press_any_key ;;
            4) list_backups; press_any_key ;;
            5) backup_create_encrypted || true; press_any_key ;;
            6) echo -en "  ${BOLD}Файл:${NC} "; local f; read -r f
               [ -n "$f" ] && backup_restore_encrypted "$f" || true; press_any_key ;;
            7) migrate_export || true; press_any_key ;;
            8) echo -en "  ${BOLD}Файл:${NC} "; local f; read -r f
               [ -n "$f" ] && migrate_import "$f" || true; press_any_key ;;
            9)
                echo -e "  ${DIM}Текущая политика: ${BACKUP_RETENTION_DAYS:-30} дней${NC}"
                echo -en "  ${BOLD}Удалить старше N дней [${BACKUP_RETENTION_DAYS:-30}]:${NC} "
                local d; read -r d; d="${d:-${BACKUP_RETENTION_DAYS:-30}}"
                backup_autoclean "$d" || true
                press_any_key ;;
            0|"") return ;;
        esac
    done
}
# ── Подменю: Режим эксперта ──────────────────────────────────
tui_expert_menu() {
    while true; do
        clear_screen
        draw_header "РЕЖИМ ЭКСПЕРТА"
        echo ""
        echo -e "  ${YELLOW}Прямое управление параметрами config.toml${NC}"
        echo -e "  ${DIM}Параметры применяются поверх сгенерированного конфига${NC}"
        echo ""
        expert_list 2>/dev/null
        echo -e "  ${DIM}[1]${NC} Добавить параметр"
        echo -e "  ${DIM}[2]${NC} Удалить параметр"
        echo -e "  ${DIM}[3]${NC} Очистить все"
        echo -e "  ${DIM}[4]${NC} Открыть config.toml в редакторе"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1)
                echo -en "  ${BOLD}Секция (напр. censorship, server, general):${NC} "; local s; read -r s
                echo -en "  ${BOLD}Ключ:${NC} "; local k; read -r k
                echo -en "  ${BOLD}Значение:${NC} "; local v; read -r v
                [ -n "$s" ] && [ -n "$k" ] && [ -n "$v" ] && { expert_set "$s" "$k" "$v"; reload_proxy_config 2>/dev/null || true; }
                press_any_key ;;
            2)
                echo -en "  ${BOLD}Ключ (или 'all'):${NC} "; local k; read -r k
                [ -n "$k" ] && { expert_clear "$k"; reload_proxy_config 2>/dev/null || true; }
                press_any_key ;;
            3) expert_clear "all"; reload_proxy_config 2>/dev/null || true; press_any_key ;;
            4) handle_expert_command edit; press_any_key ;;
            0|"") return ;;
        esac
    done
}

# ── Диагностика ──────────────────────────────────────────────
health_check() {
    echo ""
    draw_header "ДИАГНОСТИКА"
    echo ""

    if command -v docker &>/dev/null; then
        echo -e "  ${GREEN}${SYM_CHECK}${NC} Docker установлен"
    else
        echo -e "  ${RED}${SYM_CROSS}${NC} Docker не установлен"
    fi

    if is_proxy_running; then
        echo -e "  ${GREEN}${SYM_CHECK}${NC} Контейнер запущен"
    else
        echo -e "  ${RED}${SYM_CROSS}${NC} Контейнер не запущен"
    fi

    if curl -s --max-time 2 "http://127.0.0.1:${PROXY_METRICS_PORT}/metrics" &>/dev/null; then
        echo -e "  ${GREEN}${SYM_CHECK}${NC} Метрики доступны"
    else
        echo -e "  ${RED}${SYM_CROSS}${NC} Метрики недоступны"
    fi

    if [ -f "${CONFIG_DIR}/config.toml" ]; then
        echo -e "  ${GREEN}${SYM_CHECK}${NC} Конфиг существует"
    else
        echo -e "  ${RED}${SYM_CROSS}${NC} Конфиг не найден"
    fi

    local active=0 i
    for i in "${!SECRETS_ENABLED[@]}"; do [ "${SECRETS_ENABLED[$i]}" = "true" ] && active=$((active+1)); done
    if [ $active -gt 0 ]; then
        echo -e "  ${GREEN}${SYM_CHECK}${NC} ${active} активных секретов"
    else
        echo -e "  ${RED}${SYM_CROSS}${NC} Нет активных секретов"
    fi
    echo ""
}

show_server_info() {
    echo ""
    draw_header "ИНФОРМАЦИЯ О СЕРВЕРЕ"
    echo ""
    local os_name="unknown" kernel arch
    [ -f /etc/os-release ] && os_name=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-$ID}")
    kernel=$(uname -r 2>/dev/null || echo "?")
    arch=$(uname -m 2>/dev/null || echo "?")

    echo -e "  ${BOLD}Система${NC}"
    echo -e "    ОС:           ${os_name}"
    echo -e "    Ядро:         ${kernel}"
    echo -e "    Архитектура:  ${arch}"
    echo ""
    echo -e "  ${BOLD}Прокси${NC}"
    echo -e "    Скрипт:       v${VERSION}"
    echo -e "    Движок:       telemt v$(get_telemt_version)"
    echo -e "    Домен:        ${PROXY_DOMAIN}"
    echo -e "    Порт:         ${PROXY_PORT}"
    echo -e "    Маскировка:   ${MASKING_ENABLED}"
    echo ""
}

# ── Автообновление ────────────────────────────────────────────
check_for_update() {
    local _remote_ver
    _remote_ver=$(curl -fsS --max-time 5 "${GITHUB_RAW}/version" 2>/dev/null | tr -d '[:space:]')
    [ -z "$_remote_ver" ] && return 0
    [ "$_remote_ver" = "$VERSION" ] && return 0

    echo ""
    echo -e "  ${YELLOW}${BOLD}Доступно обновление: v${VERSION} → v${_remote_ver}${NC}"
    echo -en "  ${BOLD}Обновить? [Y/n]:${NC} "
    local _yn; read -r _yn
    [[ "$_yn" =~ ^[nN] ]] && return 0

    self_update
}

self_update() {
    log_info "Скачивание обновления..."

    # Скачиваем главный скрипт
    local _tmp="/tmp/mtproxyl-update-$$.sh"
    if ! curl -fsS --max-time 30 "${GITHUB_RAW}/mtproxyl.sh" -o "$_tmp" 2>/dev/null; then
        log_error "Не удалось скачать обновление"
        rm -f "$_tmp"; return 1
    fi

    # Проверяем синтаксис
    if ! bash -n "$_tmp" 2>/dev/null; then
        log_error "Ошибка синтаксиса — обновление отменено"
        rm -f "$_tmp"; return 1
    fi

    # Проверяем что новая версия действительно новее
    local _new_ver
    _new_ver=$(grep -m1 '^VERSION="' "$_tmp" | cut -d'"' -f2)
    if [ -z "$_new_ver" ]; then
        log_error "Не удалось определить версию в скачанном файле"
        rm -f "$_tmp"; return 1
    fi
    if [ "$_new_ver" = "$VERSION" ]; then
        log_info "Версия уже актуальна (v${VERSION})"
        rm -f "$_tmp"; return 0
    fi

    # Бэкап
    cp "${INSTALL_DIR}/mtproxyl.sh" "${INSTALL_DIR}/mtproxyl.sh.backup-$(date +%s)" 2>/dev/null || true
    mv "$_tmp" "${INSTALL_DIR}/mtproxyl.sh"
    chmod +x "${INSTALL_DIR}/mtproxyl.sh"

    # Обновляем библиотеки
    log_info "Обновление библиотек..."
    local _lib_ok=true
    for lib in colors utils settings secrets config docker engine traffic geoblock upstream backup nft tui install; do
        if ! curl -fsS --max-time 15 "${GITHUB_RAW}/lib/${lib}.sh" -o "${LIB_DIR}/${lib}.sh" 2>/dev/null; then
            log_warn "Не удалось обновить lib/${lib}.sh"
            _lib_ok=false
        fi
    done

    if [ "$_lib_ok" = "true" ]; then
        log_success "Обновлено до v${_new_ver}"
    else
        log_warn "Обновлено до v${_new_ver}, но некоторые библиотеки не обновились"
    fi

    log_info "Перезапуск..."
    exec "${INSTALL_DIR}/mtproxyl.sh"
}

show_cli_help() {
    echo ""
    echo -e "  ${BRIGHT_CYAN}${BOLD}MTProxyL${NC} ${DIM}v${VERSION}${NC} — Менеджер Telegram MTProto прокси"
    echo ""
    echo -e "  ${BOLD}Использование:${NC} mtproxyl <команда> [параметры]"
    echo ""
    echo -e "  ${BOLD}Прокси:${NC}"
    echo -e "    ${GREEN}start${NC} / ${GREEN}stop${NC} / ${GREEN}restart${NC} / ${GREEN}status${NC}"
    echo ""
    echo -e "  ${BOLD}Секреты:${NC}"
    echo -e "    ${GREEN}secret${NC} add|remove|list|rotate|enable|disable|limits|link|qr|clone|rename"
    echo ""
    echo -e "  ${BOLD}Настройки:${NC}"
    echo -e "    ${GREEN}port${NC} / ${GREEN}ip${NC} / ${GREEN}domain${NC} / ${GREEN}mask-backend${NC} / ${GREEN}config${NC}"
    echo ""
    echo -e "  ${BOLD}Движок:${NC}"
    echo -e "    ${GREEN}engine${NC} status|list|update|rollback|rebuild"
    echo ""
    echo -e "  ${BOLD}Режим эксперта:${NC}"
    echo -e "    ${GREEN}expert${NC} list|set|clear|edit"
    echo ""
    echo -e "  ${BOLD}NFT лимитер:${NC}"
    echo -e "    ${GREEN}nft${NC} apply|remove|service|drop|preset|ios1|ios2|extra-add|extra-rm"
    echo ""
    echo -e "  ${BOLD}Безопасность:${NC}"
    echo -e "    ${GREEN}geoblock${NC} add|remove|list|clear"
    echo -e "    ${GREEN}upstream${NC} list|add|remove|enable|disable|test"
    echo -e "    ${GREEN}sni-policy${NC} [mask|drop]"
    echo ""
    echo -e "  ${BOLD}Мониторинг:${NC}"
    echo -e "    ${GREEN}traffic${NC} / ${GREEN}connections${NC} / ${GREEN}metrics${NC} [live] / ${GREEN}logs${NC} / ${GREEN}health${NC} / ${GREEN}info${NC}"
    echo ""
    echo -e "  ${BOLD}Бэкапы:${NC}"
    echo -e "    ${GREEN}backup${NC} [--encrypt] / ${GREEN}restore${NC} <файл>"
    echo ""
    echo -e "  ${BOLD}Система:${NC}"
    echo -e "    ${GREEN}install${NC} / ${GREEN}menu${NC} / ${GREEN}update${NC} / ${GREEN}uninstall${NC} / ${GREEN}version${NC} / ${GREEN}help${NC}"
    echo ""
}
