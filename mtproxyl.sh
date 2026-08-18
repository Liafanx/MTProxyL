#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  MTProxyL v1.4.3 — Telegram MTProto Proxy Manager
#  https://github.com/Liafanx/MTProxyL
#  by LiafanX
# ═══════════════════════════════════════════════════════════════

set -o pipefail

# Почти всё требует root (/opt/mtproxyl, Docker, nft), поэтому поднимаем себя
# сами: `mtproxyl` ведёт себя как `sudo mtproxyl`. Панель уже зовёт нас от
# root через sudo -n, там ветка не срабатывает.
if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- "$0" "$@"
fi

export LC_NUMERIC=C
# apt не должен ничего спрашивать: из панели терминала нет, и диалог debconf
# или needrestart вешает установку намертво.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

VERSION="1.5.2"
SCRIPT_NAME="mtproxyl"
INSTALL_DIR="/opt/mtproxyl"
CONFIG_DIR="${INSTALL_DIR}/mtproxy"
SETTINGS_FILE="${INSTALL_DIR}/settings.conf"
SECRETS_FILE="${INSTALL_DIR}/secrets.conf"
UPSTREAMS_FILE="${INSTALL_DIR}/upstreams.conf"
BACKUP_DIR="${INSTALL_DIR}/backups"
STATS_DIR="${INSTALL_DIR}/relay_stats"
CONNECTION_LOG="${INSTALL_DIR}/connection.log"
CONTAINER_NAME="mtproxyl"
DOCKER_IMAGE_BASE="mtproxyl-telemt"
GITHUB_REPO="Liafanx/MTProxyL"
# Ветка, из которой берутся обновления и библиотеки при self-update.
# Релизная — main; если установка шла из другой ветки, её имя лежит
# в ${INSTALL_DIR}/.branch и обновления идут оттуда же.
GITHUB_BRANCH="${MTPROXYL_BRANCH:-}"
if [ -z "$GITHUB_BRANCH" ] && [ -r "${INSTALL_DIR}/.branch" ]; then
    GITHUB_BRANCH=$(tr -cd 'A-Za-z0-9._/-' < "${INSTALL_DIR}/.branch" 2>/dev/null)
fi
[ -n "$GITHUB_BRANCH" ] || GITHUB_BRANCH="main"
GITHUB_RAW="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}"
REGISTRY_IMAGE="ghcr.io/liafanx/mtproxyl-telemt"
TELEMT_GITHUB="telemt/telemt"
TELEMT_MIN_VERSION="3.4.25"
TELEMT_COMMIT="d851200"

# Bash version check
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "ОШИБКА: MTProxyL требует bash 4.2+. Текущая: ${BASH_VERSION:-unknown}" >&2
    exit 1
fi

# Защита stdin при curl | bash, кроме фонового/systemd запуска.
# Не трогаем stdin, если он нужен команде: `superexpert write` читает конфиг
# из пайпа, и переоткрытие /dev/tty потеряло бы его.
_stdin_is_payload="false"
[ "${MTPROXYL_ASSUME_YES:-}" = "1" ] && _stdin_is_payload="true"
[ "${1:-}" = "superexpert" ] && [ "${2:-}" = "write" ] && _stdin_is_payload="true"

if [ "$_stdin_is_payload" != "true" ] \
   && [[ ! -t 0 ]] && [[ -e /dev/tty ]] && ps -p $$ -o stat= | grep -q "+"; then
    exec < /dev/tty 2>/dev/null || true
fi

# Загрузка библиотек
LIB_DIR="${INSTALL_DIR}/lib"
for _lib in colors utils settings detect secrets config docker engine traffic availability dc warp geoblock geoip upstream backup nft selfmask panel tgbot tui_main tui_proxy tui_secrets tui_links tui_settings tui_security tui_traffic tui_engine tui_backup tui_expert tui_nft tui_selfmask tui_addons tui_tgbot tui_warp tui_detect expert_catalog expert_mode settings_cli install install_args migrate; do
    if [ -f "${LIB_DIR}/${_lib}.sh" ]; then
        # shellcheck source=/dev/null
        source "${LIB_DIR}/${_lib}.sh"
    else
        echo "ОШИБКА: Библиотека не найдена: ${LIB_DIR}/${_lib}.sh" >&2
        echo "Переустановите: curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/main/install.sh | sudo bash" >&2
        exit 1
    fi
done

# Temp file tracking
declare -a _TEMP_FILES=()
_cleanup() {
    for f in "${_TEMP_FILES[@]}"; do
        rm -f "$f" 2>/dev/null
    done
}
trap _cleanup EXIT

_mktemp() {
    local dir="${1:-${TMPDIR:-/tmp}}"
    local tmp
    tmp=$(mktemp "${dir}/.mtproxyl.XXXXXX") || return 1
    chmod 600 "$tmp"
    _TEMP_FILES+=("$tmp")
    echo "$tmp"
}

# ── CLI Dispatcher ────────────────────────────────────────────
cli_main() {
    local cmd="${1:-}"
    shift 2>/dev/null || true

    case "$cmd" in
        "")
            if [ -f "$SETTINGS_FILE" ]; then
                load_settings
                load_secrets
                load_upstreams
                load_nft_settings
                load_detect_settings
                if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
                    detect_telemt || true
                    save_detect_settings
                fi
                check_for_update
                show_main_menu
            else
                run_installer
            fi
            ;;

        start)
            check_root
            load_settings; load_secrets; load_upstreams; load_detect_settings
            start_target
            ;;
        stop)
            check_root
            load_settings; load_detect_settings
            stop_target
            ;;
        restart)
            check_root
            load_settings; load_secrets; load_upstreams; load_detect_settings
            restart_target
            ;;
        status)
            load_settings; load_secrets; load_detect_settings
            if [ "$1" = "--json" ]; then
                show_status_json
            else
                show_status
            fi
            ;;

        secret)
            load_settings; load_secrets
            # В реаниматоре пользователи живут в конфиге цели, а путь к нему
            # знает только обнаружение.
            [ "${MTPROXYL_MODE:-manager}" = "reanimator" ] && load_detect_settings
            handle_secret_command "$@"
            ;;

        upstream)
            load_settings; load_secrets; load_upstreams
            handle_upstream_command "$@"
            ;;

        port)
            load_settings; load_secrets
            handle_port_command "$@"
            ;;

        ip)
            load_settings
            handle_ip_command "$@"
            ;;

        domain)
            load_settings; load_secrets; load_upstreams
            handle_domain_command "$@"
            ;;

        mask-backend)
            load_settings; load_secrets; load_upstreams
            handle_mask_backend "$@"
            ;;

        settings)
            load_settings; load_secrets; load_upstreams
            handle_settings_command "$@"
            ;;

        traffic)
            load_settings; load_secrets; load_detect_settings
            if [ "${1:-}" = "--json" ]; then
                traffic_list_json
            else
                show_traffic
            fi
            ;;

        connections)
            load_settings; load_secrets; load_detect_settings
            show_connections
            ;;

        config)
            load_settings; load_detect_settings
            show_config
            ;;

        expert)
            load_settings; load_secrets; load_upstreams
            handle_expert_command "$@"
            ;;

        superexpert)
            load_settings; load_secrets
            handle_superexpert_command "$@"
            ;;

        engine)
            load_settings
            handle_engine_command "$@"
            ;;

        tune)
            load_settings; load_detect_settings
            handle_tune_command "$@"
            ;;

        mode)
            check_root; load_settings; load_detect_settings
            case "${1:-}" in
                manager)    switch_to_manager_mode ;;
                # Второй аргумент — судьба своего контейнера: remove, stop или
                # keep. Без него вопрос задаётся интерактивно.
                reanimator) switch_to_reanimator_mode "${2:-}" ;;
                --json)
                    # API движка живёт в конфиге активного режима. Панель настроена на
                    # один адрес и после смены режима опрашивала бы чужой движок.
                    _mode_cfg="${CONFIG_DIR}/config.toml"
                    [ "${MTPROXYL_MODE:-manager}" = "reanimator" ] && _mode_cfg="${DETECTED_CONFIG_PATH:-}"
                    _api_port=$(_get_telemt_api_port "$_mode_cfg" 2>/dev/null || echo "")
                    _api_on="false"
                    _telemt_api_enabled "$_mode_cfg" 2>/dev/null && _api_on="true"
                    # Состояние своего контейнера нужно панели до переключения:
                    # уходя в реаниматор, она обязана спросить, что с ним
                    # делать, а спрашивать не о чем, когда контейнера нет.
                    _own_state=$(own_container_state 2>/dev/null || echo unknown)

                    # Откуда брать логи движка текущего режима: свой контейнер, контейнер
                    # цели или systemd-юнит. Панель зовёт то, что настроено при установке.
                    _log_kind="docker"; _log_target="$CONTAINER_NAME"
                    if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
                        case "${DETECTED_MODE:-unknown}" in
                            docker|mtproxymax)
                                _log_kind="docker"; _log_target="${DETECTED_CONTAINER:-}" ;;
                            local|config_only|manual)
                                _log_kind="service"; _log_target="telemt" ;;
                            *)
                                _log_kind=""; _log_target="" ;;
                        esac
                        [ -n "$_log_target" ] || { _log_kind=""; _log_target=""; }
                    fi

                    # Fake SNI тот же, что показывает статус: у реаниматора это tls_domain
                    # конфига цели, а не наш PROXY_DOMAIN.
                    _mode_sni=$(_current_sni_domain 2>/dev/null || echo "")

                    printf '{"mode":"%s","tools_only":%s,"detected_mode":"%s","detected_config":"%s","port":%d,"sni":"%s","engine_config":"%s","api_port":%d,"api_enabled":%s,"own_container":"%s","running":%s,"log_kind":"%s","log_target":"%s"}\n' \
                        "$(json_escape "${MTPROXYL_MODE:-manager}")" \
                        "$([ "${TOOLS_ONLY:-false}" = "true" ] && echo true || echo false)" \
                        "$(json_escape "${DETECTED_MODE:-unknown}")" \
                        "$(json_escape "${DETECTED_CONFIG_PATH:-}")" \
                        "${PROXY_PORT:-0}" \
                        "$(json_escape "${_mode_sni}")" \
                        "$(json_escape "${_mode_cfg}")" \
                        "${_api_port:-0}" \
                        "$_api_on" \
                        "$(json_escape "${_own_state}")" \
                        "$(is_proxy_running 2>/dev/null && echo true || echo false)" \
                        "$(json_escape "${_log_kind}")" \
                        "$(json_escape "${_log_target}")"
                    ;;
                "")         echo -e "  ${BOLD}Текущий режим:${NC} ${MTPROXYL_MODE:-manager}" ;;
                *)          log_error "Использование: mtproxyl mode [manager|reanimator|--json]" ;;
            esac
            ;;

        detect)
            check_root; load_settings; load_detect_settings
            run_target_detection
            save_detect_settings
            sync_port_from_target
            ;;

        install-telemt)
            check_root; load_settings; load_detect_settings
            install_original_telemt
            ;;

        uninstall-telemt)
            check_root; load_settings; load_detect_settings
            uninstall_original_telemt
            ;;

        edit-config)
            check_root; load_settings; load_detect_settings
            if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
                edit_target_config
            else
                log_error "Доступно только в режиме reanimator (свой конфиг: mtproxyl expert / tune)"
                exit 1
            fi
            ;;

        target-config)
            check_root; load_settings; load_detect_settings
            if [ "${MTPROXYL_MODE:-manager}" != "reanimator" ]; then
                log_error "Доступно только в режиме reanimator (свой конфиг: mtproxyl superexpert)"
                exit 1
            fi
            handle_target_config_command "$@"
            ;;

        geoblock)
            load_settings
            handle_geoblock_command "$@"
            ;;

        geoip)
            # Не зависит от режима manager/reanimator и от обнаружения цели —
            # база GeoIP лежит в общесистемном каталоге, а не в конфиге.
            handle_geoip_command "$@"
            ;;

        sni-policy)
            # SNI-политика правит [censorship] конфига цели.
            load_settings; load_secrets; load_detect_settings
            handle_sni_policy "$@"
            ;;

        backup)
            check_root; load_settings; load_secrets; load_upstreams
            handle_backup_command "$@"
            ;;

        restore)
            check_root; load_settings
            handle_restore_command "$@"
            ;;

        health)
            load_settings; load_secrets; load_detect_settings
            health_check
            ;;

        info)
            load_settings; load_secrets; load_detect_settings
            show_server_info
            ;;

        logs)
            load_settings; load_detect_settings
            echo -e "  ${DIM}Потоковые логи (Ctrl+C для остановки)...${NC}"
            show_target_logs 50
            ;;

        metrics)
            # В реаниматоре порт метрик читается из конфига цели —
            # без load_detect_settings путь пуст и метрики «недоступны».
            load_settings; load_detect_settings
            handle_metrics_command "$@"
            ;;

        nft)
            load_settings; load_nft_settings
            case "${1:-}" in
                apply)    check_root; apply_nft_rules ;;
                remove)   check_root; remove_nft_rules ;;
                service)  check_root; install_nft_service ;;
                drop)     show_nft_drop_counter ;;
                preset)   check_root; apply_nft_preset "${2:-classic}" ;;
                smart)    check_root; enable_smart_mode ;;
                ios1)     check_root; ios_fix_apply ;;
                ios1-off) check_root; ios_fix_remove ;;
                ios2)     check_root; ios2_fix_apply ;;
                ios2-off) check_root; ios2_fix_remove ;;
                extra-add)
                    check_root; nft_extra_add "$2" "$3" "$4" "$5" ;;
                extra-rm)
                    check_root; nft_extra_remove "$2" ;;
                zapret2)       check_root; load_nft_settings; zapret2_install ;;
                zapret2-start) check_root; load_nft_settings; zapret2_start_existing ;;
                zapret2-stop)  check_root; load_nft_settings; zapret2_stop ;;
                zapret2-rm)    check_root; load_nft_settings; zapret2_remove ;;
                zapret2-wscale) load_nft_settings; zapret2_check_wscale "true" ;;
                set)      check_root; nft_set_param "$2" "$3" ;;
                settable) nft_settable_json ;;
                status)
                    if [ "${2:-}" = "--json" ]; then
                        nft_status_json
                    else
                        echo -e "  ${BOLD}Лимитер:${NC}   $(nft_status_line)"
                        echo -e "  ${BOLD}iOS Fix:${NC}   $(ios_fix_status_line)"
                        echo -e "  ${BOLD}iOS Fix v2:${NC} $(ios2_fix_status_line)"
                    fi
                    ;;
                *)
                    echo -e "  ${BOLD}NFT SYN Limiter:${NC}"
                    echo -e "    ${GREEN}nft apply${NC}        Применить правила"
                    echo -e "    ${GREEN}nft remove${NC}       Удалить правила"
                    echo -e "    ${GREEN}nft smart${NC}        Smart By-MEKO (рекомендуется)"
                    echo -e "    ${GREEN}nft preset${NC} X     Режим лимитера (classic/smart)"
                    echo -e "    ${GREEN}nft service${NC}      Установить службу"
                    echo -e "    ${GREEN}nft drop${NC}         Счётчик правил"
                    echo -e "    ${GREEN}nft ios1${NC}         iOS Fix v1 (keepalive)"
                    echo -e "    ${GREEN}nft ios1-off${NC}     Откатить iOS Fix v1"
                    echo -e "    ${GREEN}nft ios2${NC}         iOS Fix v2 (MSS+redirect)"
                    echo -e "    ${GREEN}nft ios2-off${NC}     Откатить iOS Fix v2"
                    echo -e "    ${GREEN}nft extra-add${NC}    Доп. правило"
                    echo -e "    ${GREEN}nft extra-rm${NC} N   Удалить доп. правило"
                    echo -e "    ${GREEN}nft status${NC}       Состояние (--json для машинного вывода)"
                    echo -e "    ${GREEN}nft set${NC} K V      Изменить параметр"
                    echo -e "    ${GREEN}nft settable${NC}     Список изменяемых параметров (JSON)"
                    echo ""
                    echo -e "  ${BOLD}Zapret2:${NC}"
                    echo -e "    ${GREEN}nft zapret2${NC}      Установить / переустановить Zapret2 fix"
                    echo -e "    ${GREEN}nft zapret2-start${NC} Запустить Zapret2 (после остановки)"
                    echo -e "    ${GREEN}nft zapret2-stop${NC} Остановить Zapret2"
                    echo -e "    ${GREEN}nft zapret2-rm${NC}   Удалить Zapret2"
                    echo -e "    ${GREEN}nft zapret2-wscale${NC} Проверить wscale / win ACK"
                    ;;
            esac
            ;;

        # Отдельная команда, а не флаг: версии до 1.4.7 проглотили бы
        # `update --check` и запустили настоящее обновление, а неизвестную
        # команду они просто отклоняют. Панель зовёт именно её.
        # Без root и без load_settings: settings.conf доступен только root,
        # а проверке нужен лишь номер версии.
        update-check)
            update_check_json
            ;;

        update)
            case "${1:-}" in
                --check) update_check_json ;;
                *)
                    check_root; load_settings
                    self_update "$@"
                    ;;
            esac
            ;;

        tgbot)
            # Настройки нужны и статусу: он показывает, в каком режиме бот
            # будет работать.
            load_settings 2>/dev/null
            handle_tgbot_command "$@"
            ;;

        dc)
            # Данные о дата-центрах отдаёт движок текущего режима, значит нужны
            # и настройки, и результат детекта: у реаниматора это чужая цель.
            load_settings; load_detect_settings
            handle_dc_command "$@"
            ;;

        warp)
            # Вариант C правит маршруты движка, поэтому грузим и их.
            load_settings; load_secrets; load_upstreams; load_detect_settings
            handle_warp_command "$@"
            ;;

        availability)
            # Цель проверки берётся из настроек активного режима: у реаниматора
            # порт и fake SNI живут в конфиге чужой цели.
            load_settings; load_detect_settings
            _availability_migrate_from_panel
            handle_availability_command "$@"
            ;;

        ip-history)
            check_root; load_settings; load_detect_settings
            case "${1:-status}" in
                flush|snapshot)
                    ip_history_snapshot || { log_warn "Движок не ответил — снимок пропущен"; exit 1; }
                    ;;
                on|enable)
                    # Выключение живёт в настройке: иначе снятый таймер
                    # вернулся бы следующей же командой.
                    [ "$(_ip_history_interval_minutes)" -gt 0 ] || IP_HISTORY_INTERVAL="5"
                    save_settings
                    install_ip_history_timer
                    log_success "Снимки истории IP: каждые $(_ip_history_interval_minutes) мин"
                    ;;
                off|disable)
                    IP_HISTORY_INTERVAL="0"
                    save_settings
                    remove_ip_history_timer
                    log_success "Снимки истории IP выключены"
                    ;;
                status)
                    local _db="${INSTALL_DIR}/relay_stats/user_ips_db"
                    [ "${MTPROXYL_MODE:-manager}" = "reanimator" ] && \
                        _db="${INSTALL_DIR}/relay_stats/target_user_ips_db"
                    if ip_history_timer_active; then
                        echo -e "  ${BOLD}Снимки:${NC} каждые $(_ip_history_interval_minutes) мин"
                        systemctl list-timers "$IP_HISTORY_TIMER" --no-pager 2>/dev/null | sed -n '2p'
                    else
                        echo -e "  ${BOLD}Снимки:${NC} выключены ${DIM}(mtproxyl ip-history on)${NC}"
                    fi
                    echo -e "  ${BOLD}Записей:${NC} $(grep -c '^USER|' "$_db" 2>/dev/null || echo 0)"
                    echo -e "  ${BOLD}Хранить:${NC} $(_user_ip_history_cap) адресов на пользователя"
                    ;;
                *)
                    log_error "ip-history: flush | status | on | off"
                    return 1
                    ;;
            esac
            ;;

         selfmask)
            # load_detect_settings обязателен: в реаниматоре selfmask пишет
            # [censorship] в конфиг цели, а путь к нему в DETECTED_CONFIG_PATH.
            load_settings; load_detect_settings
            handle_selfmask_command "$@"
            ;;

        pq-check)
            load_settings; load_detect_settings
            # Проверку берёт на себя _addon_check_pq_domain: она сама решает,
            # чем проверять — системным OpenSSL или нашим — и объясняет, если
            # не может ничем.
            _addon_check_pq_domain "${1:-$(_addon_pq_default_target)}"
            ;;            

        panel)
            load_settings; load_detect_settings
            handle_panel_command "$@"
            ;;

        swap)
            handle_swap_command "$@"
            ;;

        migrate)
            # Переезд копирует свою же установку — нужны и настройки, и секреты.
            check_root; load_settings; load_secrets; load_detect_settings
            handle_migrate_command "$@"
            ;;

        install)
            # Без аргументов — прежний мастер; с аргументами ставим молча.
            if [ $# -gt 0 ]; then
                load_settings 2>/dev/null || true
                run_installer_args "$@"
            else
                run_installer
            fi
            ;;

        menu)
            load_settings; load_secrets; load_upstreams; load_detect_settings
            show_main_menu
            ;;

        uninstall)
            check_root; load_settings; load_secrets; load_detect_settings
            uninstall
            exit 0
            ;;

        version)
            echo -e "  ${BOLD}MTProxyL${NC} v${VERSION}"
            load_settings 2>/dev/null
            if [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; then
                load_detect_settings
                echo -e "  ${DIM}Режим: reanimator, цель: ${DETECTED_MODE:-unknown}${NC}"
            else
                echo -e "  ${DIM}Движок: telemt v$(get_telemt_version) (Rust)${NC}"
            fi
            # Если стоим не на релизной ветке — это важно видеть сразу
            [ "$GITHUB_BRANCH" != "main" ] && echo -e "  ${YELLOW}Ветка обновлений: ${GITHUB_BRANCH}${NC}"
            echo -e "  ${DIM}by LiafanX${NC}"
            ;;

        help|--help|-h)
            show_cli_help
            ;;

        *)
            log_error "Неизвестная команда: ${cmd}"
            show_cli_help
            return 1
            ;;
    esac
}

# ── Main ──────────────────────────────────────────────────────
main() {
    fix_tty_input 2>/dev/null || true
    cli_main "$@"
}

main "$@"
