#!/bin/bash
# MTProxyL — подменю: секреты (полное)

# Пользователи цели в режиме реаниматора. Отдельное меню, а не ветка в
# tui_secrets_menu: там всё построено на SECRETS_* и нумерации по этому массиву,
# а здесь источник — [access.users] конфига цели, и выбирать приходится по метке.
tui_target_users_menu() {
    while true; do
        clear_screen
        target_users_list
        echo -e "  ${DIM}[1]${NC} Добавить пользователя"
        echo -e "  ${DIM}[2]${NC} Удалить"
        echo -e "  ${DIM}[3]${NC} Обновить ключ (ротация)"
        echo -e "  ${DIM}[4]${NC} Включить"
        echo -e "  ${DIM}[5]${NC} Выключить"
        echo -e "  ${DIM}[6]${NC} Лимиты"
        echo -e "  ${DIM}[7]${NC} Переименовать"
        echo -e "  ${DIM}[8]${NC} Ссылка для подключения"
        echo -e "  ${DIM}[9]${NC} Рекламная метка"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        local l
        case "$choice" in
            1)
                echo -en "  ${BOLD}Метка:${NC} "; read_line l
                [ -n "$l" ] && { target_user_add "$l" || true; }; press_any_key ;;
            2)
                echo -en "  ${BOLD}Метка:${NC} "; read_line l
                [ -n "$l" ] && { target_user_remove "$l" || true; }; press_any_key ;;
            3)
                echo -en "  ${BOLD}Метка:${NC} "; read_line l
                [ -n "$l" ] && { target_user_rotate "$l" || true; }; press_any_key ;;
            4)
                echo -en "  ${BOLD}Метка:${NC} "; read_line l
                [ -n "$l" ] && { target_user_toggle "$l" enable || true; }; press_any_key ;;
            5)
                echo -en "  ${BOLD}Метка:${NC} "; read_line l
                [ -n "$l" ] && { target_user_toggle "$l" disable || true; }; press_any_key ;;
            6)
                echo -en "  ${BOLD}Метка:${NC} "; read_line l
                if [ -n "$l" ]; then
                    target_user_show_limits "$l" || { press_any_key; continue; }
                    echo -e "  ${DIM}0 — снять ограничение${NC}"
                    echo -en "  ${BOLD}Макс. соединений:${NC} "; local mc; read_line mc
                    echo -en "  ${BOLD}Макс. уникальных IP:${NC} "; local mi; read_line mi
                    echo -en "  ${BOLD}Квота, байт:${NC} "; local mq; read_line mq
                    target_user_setlimits "$l" "${mc:-0}" "${mi:-0}" "${mq:-0}" || true
                fi
                press_any_key ;;
            7)
                echo -en "  ${BOLD}Текущая метка:${NC} "; read_line l
                if [ -n "$l" ]; then
                    echo -en "  ${BOLD}Новая метка:${NC} "; local nl; read_line nl
                    [ -n "$nl" ] && { target_user_rename "$l" "$nl" || true; }
                fi
                press_any_key ;;
            8)
                echo -en "  ${BOLD}Метка:${NC} "; read_line l
                if [ -n "$l" ]; then
                    local _link; _link=$(target_user_link "$l")
                    if [ -n "$_link" ]; then
                        echo ""
                        echo -e "  ${CYAN}${_link}${NC}"
                        echo ""
                    else
                        log_error "Пользователь '${l}' не найден у цели"
                    fi
                fi
                press_any_key ;;
            9)
                echo -en "  ${BOLD}Метка пользователя:${NC} "; read_line l
                if [ -n "$l" ]; then
                    echo -e "  ${DIM}Сейчас: $(target_user_adtag "$l" | grep . || echo 'нет')${NC}"
                    echo -e "  ${DIM}32 hex-символа от @MTProxybot, 'remove' — снять${NC}"
                    echo -en "  ${BOLD}Рекламная метка:${NC} "; local at; read_line at
                    [ -n "$at" ] && { target_user_adtag "$l" "$at" || true; }
                fi
                press_any_key ;;
            0)  return ;;
        esac
    done
}

tui_secrets_menu() {
    if _superexpert_active; then
        clear_screen
        draw_header "УПРАВЛЕНИЕ СЕКРЕТАМИ"
        echo ""
        log_warn "Включён режим супер эксперта — пользователями управляете вы"
        echo -e "  ${DIM}Секреты живут в секции [access.users] вашего конфига:${NC}"
        echo -e "  ${BOLD}${SUPEREXPERT_FILE}${NC}"
        echo -e "  ${DIM}Добавьте/удалите строки вида ${BOLD}имя = \"32 hex\"${NC}${DIM} и перезапустите прокси.${NC}"
        echo ""
        echo -e "  ${DIM}Ссылки для подключения: главное меню → Ссылки на прокси${NC}"
        press_any_key
        return
    fi
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
        echo -e "  ${DIM}[9]${NC} Ссылки для подключения"
        echo -e "  ${DIM}[10]${NC} Изменить ключ на свой"
        echo -e "  ${DIM}[11]${NC} Экспорт секретов"
        echo -e "  ${DIM}[12]${NC} Импорт секретов"
        echo -e "  ${DIM}[13]${NC} Рекламная метка пользователя"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1)
                echo -en "  ${BOLD}Метка:${NC} "; local l; read_line l
                [ -n "$l" ] && { secret_add "$l" || true; }; press_any_key ;;
            2)
                echo -en "  ${BOLD}Метка или #:${NC} "; local l; read_line l
                if [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -ge 1 ] && [ "$l" -le "${#SECRETS_LABELS[@]}" ]; then
                    l="${SECRETS_LABELS[$((l - 1))]}"; fi
                [ -n "$l" ] && { secret_remove "$l" || true; }; press_any_key ;;
            3)
                echo -en "  ${BOLD}Метка или #:${NC} "; local l; read_line l
                if [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -ge 1 ] && [ "$l" -le "${#SECRETS_LABELS[@]}" ]; then
                    l="${SECRETS_LABELS[$((l - 1))]}"; fi
                [ -n "$l" ] && { secret_rotate "$l" || true; }; press_any_key ;;
            4)
                echo -en "  ${BOLD}Метка или #:${NC} "; local l; read_line l
                if [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -ge 1 ] && [ "$l" -le "${#SECRETS_LABELS[@]}" ]; then
                    l="${SECRETS_LABELS[$((l - 1))]}"; fi
                [ -n "$l" ] && { secret_toggle "$l" || true; }; press_any_key ;;
            5)
                secret_show_limits; echo ""
                echo -en "  ${BOLD}Метка или #:${NC} "; local l; read_line l
                if [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -ge 1 ] && [ "$l" -le "${#SECRETS_LABELS[@]}" ]; then
                    l="${SECRETS_LABELS[$((l - 1))]}"; fi
                if [ -n "$l" ]; then
                    echo -en "  ${BOLD}Макс. соединений (0=∞):${NC} "; local mc; read_line mc
                    echo -en "  ${BOLD}Макс. IP (0=∞):${NC} "; local mi; read_line mi
                    echo -en "  ${BOLD}Квота (напр. 5G, 0=∞):${NC} "; local dq; read_line dq
                    echo -en "  ${BOLD}Срок (YYYY-MM-DD, 0=нет):${NC} "; local ex; read_line ex
                    secret_set_limits "$l" "${mc:-0}" "${mi:-0}" "${dq:-0}" "${ex:-0}" || true
                fi; press_any_key ;;
            6)
                echo -en "  ${BOLD}Источник:${NC} "; local s; read_line s
                if [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" -ge 1 ] && [ "$s" -le "${#SECRETS_LABELS[@]}" ]; then
                    s="${SECRETS_LABELS[$((s - 1))]}"; fi
                echo -en "  ${BOLD}Новая метка:${NC} "; local n; read_line n
                [ -n "$s" ] && [ -n "$n" ] && { secret_clone "$s" "$n" || true; }; press_any_key ;;
            7)
                echo -en "  ${BOLD}Старая:${NC} "; local o; read_line o
                if [[ "$o" =~ ^[0-9]+$ ]] && [ "$o" -ge 1 ] && [ "$o" -le "${#SECRETS_LABELS[@]}" ]; then
                    o="${SECRETS_LABELS[$((o - 1))]}"; fi
                echo -en "  ${BOLD}Новая:${NC} "; local n; read_line n
                [ -n "$o" ] && [ -n "$n" ] && { secret_rename "$o" "$n" || true; }; press_any_key ;;
            8)
                echo -en "  ${BOLD}Метка или #:${NC} "; local l; read_line l
                if [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -ge 1 ] && [ "$l" -le "${#SECRETS_LABELS[@]}" ]; then
                    l="${SECRETS_LABELS[$((l - 1))]}"; fi
                [ -n "$l" ] && { secret_show_limits "$l" || true; }; press_any_key ;;
            9)
                echo -en "  ${BOLD}Метка или #:${NC} "; local l; read_line l
                if [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -ge 1 ] && [ "$l" -le "${#SECRETS_LABELS[@]}" ]; then
                    l="${SECRETS_LABELS[$((l - 1))]}"; fi
                if [ -n "$l" ]; then
                    local link; link=$(get_proxy_link "$l") || true
                    if [ -n "$link" ]; then
                        echo -e "  ${CYAN}${link}${NC}"
                        echo ""
                    fi
                fi; press_any_key ;;
            10)
                echo -en "  ${BOLD}Метка или #:${NC} "; local l; read_line l
                if [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -ge 1 ] && [ "$l" -le "${#SECRETS_LABELS[@]}" ]; then
                    l="${SECRETS_LABELS[$((l - 1))]}"; fi
                if [ -n "$l" ]; then
                    local idx=-1 ii
                    for ii in "${!SECRETS_LABELS[@]}"; do [ "${SECRETS_LABELS[$ii]}" = "$l" ] && { idx=$ii; break; }; done
                    if [ $idx -ge 0 ]; then
                        echo -e "  ${DIM}Текущий: ${SECRETS_KEYS[$idx]}${NC}"
                        echo -en "  ${BOLD}Новый ключ (32 hex):${NC} "; local nk; read_line nk
                        if [[ "$nk" =~ ^[0-9a-fA-F]{32}$ ]]; then
                            SECRETS_KEYS[$idx]="$nk"
                            save_secrets; reload_proxy_config 2>/dev/null || true
                            log_success "Ключ для '${l}' изменён"
                        elif [ -n "$nk" ]; then log_error "Ключ должен быть ровно 32 hex-символа"; fi
                    else log_error "Секрет '${l}' не найден"; fi
                fi; press_any_key ;;
            11)
                secret_export_file "/tmp/mtproxyl-secrets-$(date +%Y%m%d).csv" || true
                press_any_key ;;
            12)
                echo -e "  ${DIM}Подойдёт и экспорт из пункта [11], и сама база ${SECRETS_FILE}${NC}"
                echo -en "  ${BOLD}Файл для импорта:${NC} "; local f; read_line f
                [ -n "$f" ] && { secret_import_file "$f" || true; }
                press_any_key ;;
            13)
                echo -en "  ${BOLD}Метка или #:${NC} "; local l; read_line l
                if [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -ge 1 ] && [ "$l" -le "${#SECRETS_LABELS[@]}" ]; then
                    l="${SECRETS_LABELS[$((l - 1))]}"; fi
                if [ -n "$l" ]; then
                    echo -e "  ${DIM}Своя метка перекрывает общую из настроек, остальных не трогает.${NC}"
                    echo -e "  ${DIM}Сейчас: $(secret_set_adtag "$l" | grep . || echo 'нет')${NC}"
                    echo -e "  ${DIM}32 hex-символа от @MTProxybot, 'remove' — снять${NC}"
                    echo -en "  ${BOLD}Рекламная метка:${NC} "; local at; read_line at
                    [ -n "$at" ] && { secret_set_adtag "$l" "$at" || true; }
                fi
                press_any_key ;;
            0|"") return ;;
        esac
    done
}
