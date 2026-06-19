#!/bin/bash
# MTProxyL — подменю: секреты (полное)

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
        echo -e "  ${DIM}[8]${NC} Полная информация"
        echo -e "  ${DIM}[9]${NC} Ссылка / QR-код"
        echo -e "  ${DIM}[k]${NC} Изменить ключ на свой"
        echo -e "  ${DIM}[x]${NC} Экспорт секретов"
        echo -e "  ${DIM}[m]${NC} Импорт секретов"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1)
                echo -en "  ${BOLD}Метка:${NC} "; local l; read -r l
                [ -n "$l" ] && { secret_add "$l" || true; }; press_any_key ;;
            2)
                echo -en "  ${BOLD}Метка или #:${NC} "; local l; read -r l
                if [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -ge 1 ] && [ "$l" -le "${#SECRETS_LABELS[@]}" ]; then
                    l="${SECRETS_LABELS[$((l - 1))]}"; fi
                [ -n "$l" ] && { secret_remove "$l" || true; }; press_any_key ;;
            3)
                echo -en "  ${BOLD}Метка или #:${NC} "; local l; read -r l
                if [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -ge 1 ] && [ "$l" -le "${#SECRETS_LABELS[@]}" ]; then
                    l="${SECRETS_LABELS[$((l - 1))]}"; fi
                [ -n "$l" ] && { secret_rotate "$l" || true; }; press_any_key ;;
            4)
                echo -en "  ${BOLD}Метка или #:${NC} "; local l; read -r l
                if [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -ge 1 ] && [ "$l" -le "${#SECRETS_LABELS[@]}" ]; then
                    l="${SECRETS_LABELS[$((l - 1))]}"; fi
                [ -n "$l" ] && { secret_toggle "$l" || true; }; press_any_key ;;
            5)
                secret_show_limits; echo ""
                echo -en "  ${BOLD}Метка или #:${NC} "; local l; read -r l
                if [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -ge 1 ] && [ "$l" -le "${#SECRETS_LABELS[@]}" ]; then
                    l="${SECRETS_LABELS[$((l - 1))]}"; fi
                if [ -n "$l" ]; then
                    echo -en "  ${BOLD}Макс. соединений (0=∞):${NC} "; local mc; read -r mc
                    echo -en "  ${BOLD}Макс. IP (0=∞):${NC} "; local mi; read -r mi
                    echo -en "  ${BOLD}Квота (напр. 5G, 0=∞):${NC} "; local dq; read -r dq
                    echo -en "  ${BOLD}Срок (YYYY-MM-DD, 0=нет):${NC} "; local ex; read -r ex
                    secret_set_limits "$l" "${mc:-0}" "${mi:-0}" "${dq:-0}" "${ex:-0}" || true
                fi; press_any_key ;;
            6)
                echo -en "  ${BOLD}Источник:${NC} "; local s; read -r s
                if [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" -ge 1 ] && [ "$s" -le "${#SECRETS_LABELS[@]}" ]; then
                    s="${SECRETS_LABELS[$((s - 1))]}"; fi
                echo -en "  ${BOLD}Новая метка:${NC} "; local n; read -r n
                [ -n "$s" ] && [ -n "$n" ] && { secret_clone "$s" "$n" || true; }; press_any_key ;;
            7)
                echo -en "  ${BOLD}Старая:${NC} "; local o; read -r o
                if [[ "$o" =~ ^[0-9]+$ ]] && [ "$o" -ge 1 ] && [ "$o" -le "${#SECRETS_LABELS[@]}" ]; then
                    o="${SECRETS_LABELS[$((o - 1))]}"; fi
                echo -en "  ${BOLD}Новая:${NC} "; local n; read -r n
                [ -n "$o" ] && [ -n "$n" ] && { secret_rename "$o" "$n" || true; }; press_any_key ;;
            8)
                echo -en "  ${BOLD}Метка или #:${NC} "; local l; read -r l
                if [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -ge 1 ] && [ "$l" -le "${#SECRETS_LABELS[@]}" ]; then
                    l="${SECRETS_LABELS[$((l - 1))]}"; fi
                [ -n "$l" ] && { secret_show_limits "$l" || true; }; press_any_key ;;
            9)
                echo -en "  ${BOLD}Метка или #:${NC} "; local l; read -r l
                if [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -ge 1 ] && [ "$l" -le "${#SECRETS_LABELS[@]}" ]; then
                    l="${SECRETS_LABELS[$((l - 1))]}"; fi
                if [ -n "$l" ]; then
                    local link; link=$(get_proxy_link "$l") || true
                    if [ -n "$link" ]; then
                        echo -e "  ${CYAN}${link}${NC}"
                        command -v qrencode &>/dev/null && { echo ""; qrencode -t ANSIUTF8 "$link" | sed 's/^/  /'; }
                    fi
                fi; press_any_key ;;
            k|K)
                echo -en "  ${BOLD}Метка или #:${NC} "; local l; read -r l
                if [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -ge 1 ] && [ "$l" -le "${#SECRETS_LABELS[@]}" ]; then
                    l="${SECRETS_LABELS[$((l - 1))]}"; fi
                if [ -n "$l" ]; then
                    local idx=-1 ii
                    for ii in "${!SECRETS_LABELS[@]}"; do [ "${SECRETS_LABELS[$ii]}" = "$l" ] && { idx=$ii; break; }; done
                    if [ $idx -ge 0 ]; then
                        echo -e "  ${DIM}Текущий: ${SECRETS_KEYS[$idx]}${NC}"
                        echo -en "  ${BOLD}Новый ключ (32 hex):${NC} "; local nk; read -r nk
                        if [[ "$nk" =~ ^[0-9a-fA-F]{32}$ ]]; then
                            SECRETS_KEYS[$idx]="$nk"
                            save_secrets; reload_proxy_config 2>/dev/null || true
                            log_success "Ключ для '${l}' изменён"
                        elif [ -n "$nk" ]; then log_error "Ключ должен быть ровно 32 hex-символа"; fi
                    else log_error "Секрет '${l}' не найден"; fi
                fi; press_any_key ;;
            x|X)
                local exp_file="/tmp/mtproxyl-secrets-$(date +%Y%m%d).csv"
                echo "# label|key|enabled|max_conns|max_ips|quota|expires|notes" > "$exp_file"
                local ii; for ii in "${!SECRETS_LABELS[@]}"; do
                    echo "${SECRETS_LABELS[$ii]}|${SECRETS_KEYS[$ii]}|${SECRETS_ENABLED[$ii]}|${SECRETS_MAX_CONNS[$ii]:-0}|${SECRETS_MAX_IPS[$ii]:-0}|${SECRETS_QUOTA[$ii]:-0}|${SECRETS_EXPIRES[$ii]:-0}|${SECRETS_NOTES[$ii]:-}" >> "$exp_file"
                done
                log_success "Экспортировано в ${exp_file}"; press_any_key ;;
            m|M)
                echo -en "  ${BOLD}Файл для импорта:${NC} "; local f; read -r f
                if [ -f "$f" ]; then
                    local added=0 skipped=0
                    while IFS='|' read -r _l _k _e _mc _mi _q _ex _n; do
                        [[ "$_l" =~ ^# ]] || [ -z "$_l" ] && continue
                        local exists=false ii
                        for ii in "${!SECRETS_LABELS[@]}"; do [ "${SECRETS_LABELS[$ii]}" = "$_l" ] && { exists=true; break; }; done
                        if $exists; then skipped=$((skipped+1)); continue; fi
                        [[ "$_l" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
                        [[ "$_k" =~ ^[a-fA-F0-9]{32}$ ]] || continue
                        SECRETS_LABELS+=("$_l"); SECRETS_KEYS+=("$_k")
                        SECRETS_CREATED+=("$(date +%s)"); SECRETS_ENABLED+=("${_e:-true}")
                        SECRETS_MAX_CONNS+=("${_mc:-0}"); SECRETS_MAX_IPS+=("${_mi:-0}")
                        SECRETS_QUOTA+=("${_q:-0}"); SECRETS_EXPIRES+=("${_ex:-0}")
                        SECRETS_NOTES+=("${_n:-}"); added=$((added+1))
                    done < "$f"
                    [ $added -gt 0 ] && { save_secrets; reload_proxy_config 2>/dev/null || true; }
                    log_success "Импортировано: ${added}, пропущено: ${skipped}"
                else log_error "Файл не найден"; fi; press_any_key ;;
            0|"") return ;;
        esac
    done
}
