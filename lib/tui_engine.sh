#!/bin/bash
# MTProxyL — подменю: движок

_tui_engine_custom() {
    echo ""
    echo -e "  ${DIM}Своя сборка telemt: ссылка https на бинарник или архив .tar.gz с ним,${NC}"
    echo -e "  ${DIM}например релиз с GitHub:${NC}"
    echo -e "  ${DIM}https://github.com/telemt/telemt/releases/download/3.5.13/telemt-x86_64-linux-musl.tar.gz${NC}"
    echo -e "  ${DIM}Бинарник запускается от root — ставьте только сборки, которым доверяете.${NC}"
    echo -e "  ${DIM}Вернуться к прежнему: пункт «Откатить».${NC}"
    echo ""
    local _url _sha
    read_line _url "  ${BOLD}Ссылка:${NC} "
    [ -n "$_url" ] || { log_info "Отменено"; return 0; }
    read_line _sha "  ${BOLD}sha256 [Enter — без проверки]:${NC} "
    engine_install_custom "$_url" ${_sha:+--sha256 "$_sha"}
}

_tui_engine_service_name() {
    echo ""
    echo -e "  ${BOLD}Имя службы и бинарника движка${NC}"
    echo -e "  ${DIM}Сейчас: ${ENGINE_SERVICE} — $(binengine_naming_title | sed 's/ (.*//')${NC}"
    echo -e "  ${CYAN}[1]${NC}  случайное ${DIM}обычное на вид имя, по списку служб не видно прокси; повторный выбор — новое имя${NC}"
    echo -e "  ${CYAN}[2]${NC}  стандартное ${DIM}${ENGINE_SERVICE_STANDARD}${NC}"
    echo -e "  ${DIM}[0]${NC}  Отмена"
    local _c; _c=$(read_choice "выбор" "0")
    case "$_c" in
        1) binengine_set_naming random ;;
        2) binengine_set_naming standard ;;
    esac
}

# Тюнинг mtdd: ключи из белого списка, порт/домен/тег — в настройках MTProxyL.
tui_mtdd_tune_menu() {
    while true; do
        clear_screen
        mtdd_handle_tune list
        echo -e "  ${DIM}[1]${NC} Задать параметр"
        echo -e "  ${DIM}[2]${NC} Сбросить параметр (значение mtdd по умолчанию)"
        echo -e "  ${DIM}[0]${NC} Назад"
        local _c _k _v; _c=$(read_choice "выбор" "0")
        case "$_c" in
            1) read_line _k "  ${BOLD}Параметр:${NC} "; [ -n "$_k" ] || continue
               read_line _v "  ${BOLD}Значение:${NC} "; [ -n "$_v" ] || continue
               mtdd_handle_tune set "$_k" "$_v"; press_any_key ;;
            2) read_line _k "  ${BOLD}Параметр:${NC} "; [ -n "$_k" ] || continue
               mtdd_handle_tune clear "$_k"; press_any_key ;;
            *) return ;;
        esac
    done
}

# Движок Manager — mtdd: каналы сборок вместо версий, смена на telemt.
tui_mtdd_mgr_engine_menu() {
    while mtdd_mgr_active; do
        clear_screen
        draw_header "ДВИЖОК MTDD"
        echo ""
        echo -e "  ${BOLD}Версия:${NC}    $(mtdd_mgr_version)"
        echo -e "  ${BOLD}Бинарник:${NC}  ${MTDD_MGR_BIN} ${DIM}(из релизов ${MTDD_REPO})${NC}"
        echo -e "  ${BOLD}Служба:${NC}    ${MTDD_MGR_SERVICE}.service"
        echo ""
        echo -e "  ${DIM}[1]${NC} Сборки main и dev"
        echo -e "  ${DIM}[2]${NC} Обновить / сменить канал"
        echo -e "  ${DIM}[3]${NC} Откатить на предыдущую сборку"
        echo -e "  ${DIM}[4]${NC} Тюнинг mtdd (свои ключи конфига)"
        echo -e "  ${DIM}[5]${NC} Медиа-лимиты mtdd"
        echo -e "  ${DIM}[6]${NC} Сменить движок на telemt ${DIM}(ключи и ссылки сохранятся)${NC}"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) handle_engine_command list; press_any_key ;;
            2) handle_engine_command update; press_any_key ;;
            3) handle_engine_command rollback; press_any_key ;;
            4) tui_mtdd_tune_menu ;;
            5) tui_mtdd_media_menu ;;
            6) engine_switch_kind telemt; load_settings; press_any_key ;;
            0|"") return ;;
        esac
    done
}

# Подозрительные адреса mtdd: таблица, учёт, теневой бан, nftables-блок.
tui_mtdd_suspects_menu() {
    while true; do
        clear_screen
        mtdd_suspects_list 0 || true
        local _on _ban; _on=$(mtdd_cfg_get suspects 2>/dev/null); _ban=$(mtdd_cfg_get suspect_ban_score 2>/dev/null)
        echo -e "  ${DIM}Учёт: $([ "$_on" = true ] && echo включён || echo выключен) · теневой бан: $([ "${_ban:-0}" -gt 0 ] 2>/dev/null && echo "score ≥ ${_ban}" || echo выкл)${NC}"
        echo ""
        echo -e "  ${DIM}[1]${NC} $([ "$_on" = true ] && echo Выключить || echo Включить) учёт"
        echo -e "  ${DIM}[2]${NC} Теневой бан по score ${DIM}(такие соединения уходят на маскировку)${NC}"
        echo -e "  ${DIM}[3]${NC} Заблокировать в nftables по score ${DIM}(порт прокси, до перезагрузки)${NC}"
        echo -e "  ${DIM}[4]${NC} Снять nftables-блок"
        echo -e "  ${DIM}[0]${NC} Назад"
        local _c; _c=$(read_choice "выбор" "0")
        case "$_c" in
            1) if [ "$_on" = true ]; then handle_suspects_command off || true; else handle_suspects_command on || true; fi
               press_any_key ;;
            2) local _s; read_line _s "  ${BOLD}Score 1–100 (0 — выключить):${NC} "
               [ -n "$_s" ] && { handle_suspects_command ban "$_s" || true; }
               press_any_key ;;
            3) local _s; read_line _s "  ${BOLD}Мин. score [60]:${NC} "
               handle_suspects_command block "${_s:-60}" || true
               press_any_key ;;
            4) handle_suspects_command unblock || true; press_any_key ;;
            0|"") return ;;
        esac
    done
}

tui_engine_menu() {
    mtdd_mgr_active && { tui_mtdd_mgr_engine_menu; return; }
    while true; do
        clear_screen
        draw_header "ДВИЖОК TELEMT"
        echo ""
        echo -e "  ${BOLD}Носитель:${NC}  $(engine_backend_title)"
        echo -e "  ${BOLD}Версия:${NC}    telemt v$(get_telemt_version)"
        if engine_is_binary; then
            echo -e "  ${BOLD}Бинарник:${NC}  ${ENGINE_BIN_PATH}"
            echo -e "  ${BOLD}Служба:${NC}    ${ENGINE_SERVICE}.service ${DIM}— имя $(binengine_naming_title | sed 's/ (.*//')${NC}"
            binengine_is_custom && echo -e "  ${BOLD}Источник:${NC}  свой бинарник — $(binengine_source)"
        else
            echo -e "  ${BOLD}Закреплён:${NC} commit ${TELEMT_COMMIT}"
        fi
        echo ""
        echo -e "  ${DIM}[1]${NC} Список версий"
        echo -e "  ${DIM}[2]${NC} Обновить до версии"
        echo -e "  ${DIM}[3]${NC} Откатить"
        if engine_is_binary; then
            echo -e "  ${DIM}[4]${NC} Перекачать текущую версию"
            echo -e "  ${DIM}[5]${NC} Перейти на Docker-образ"
        else
            echo -e "  ${DIM}[4]${NC} Пересобрать"
            echo -e "  ${DIM}[5]${NC} Перейти на бинарник (без Docker)"
        fi
        command -v docker >/dev/null && echo -e "  ${DIM}[6]${NC} Очистить неиспользуемые Docker-образы"
        command -v systemctl >/dev/null && echo -e "  ${DIM}[7]${NC} Свой бинарник telemt по ссылке"
        command -v systemctl >/dev/null && echo -e "  ${DIM}[8]${NC} Имя службы движка"
        [ -z "$(mtdd_mgr_unsupported_reason)" ] && \
            echo -e "  ${DIM}[9]${NC} Сменить движок на mtdd ${DIM}(ключи и ссылки сохранятся)${NC}"
        echo -e "  ${DIM}[0]${NC} Назад"
        local choice; choice=$(read_choice "выбор" "0")
        case "$choice" in
            1) handle_engine_command list; press_any_key ;;
            2) handle_engine_command update; press_any_key ;;
            3) handle_engine_command rollback; press_any_key ;;
            4) handle_engine_command rebuild; press_any_key ;;
            6) handle_engine_command cleanup; press_any_key ;;
            7) _tui_engine_custom; load_settings; press_any_key ;;
            8) _tui_engine_service_name; load_settings; press_any_key ;;
            9) engine_switch_kind mtdd; load_settings; mtdd_mgr_active && return; press_any_key ;;
            5) if engine_is_binary; then
                   engine_switch_backend docker
               else
                   engine_switch_backend binary
               fi
               load_settings; press_any_key ;;
            0|"") return ;;
        esac
    done
}
