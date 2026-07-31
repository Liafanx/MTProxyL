#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  MTProxyL v1.3.1 — Telegram MTProto Proxy Manager
#  https://github.com/Liafanx/MTProxyL
#  by LiafanX
# ═══════════════════════════════════════════════════════════════

set -o pipefail
export LC_NUMERIC=C

VERSION="1.3.1"
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
# На ветке dev держим dev; ПЕРЕД МЕРЖЕМ В main вернуть на main, иначе
# пользователи начнут обновляться из ветки разработки.
# Разово переопределяется: MTPROXYL_BRANCH=main mtproxyl update
GITHUB_BRANCH="${MTPROXYL_BRANCH:-dev}"
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

# Защита stdin при curl | bash (только если это не фоновый/systemd запуск)
if [[ ! -t 0 ]] && [[ -e /dev/tty ]] && ps -p $$ -o stat= | grep -q "+"; then
    exec < /dev/tty 2>/dev/null || true
fi

# Загрузка библиотек
LIB_DIR="${INSTALL_DIR}/lib"
for _lib in colors utils settings detect secrets config docker engine traffic geoblock upstream backup nft selfmask tui_main tui_proxy tui_secrets tui_links tui_settings tui_security tui_traffic tui_engine tui_backup tui_expert tui_nft tui_selfmask tui_addons tui_detect expert_catalog expert_mode install; do
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

        traffic)
            load_settings; load_secrets; load_detect_settings
            show_traffic
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
                reanimator) switch_to_reanimator_mode ;;
                "")         echo -e "  ${BOLD}Текущий режим:${NC} ${MTPROXYL_MODE:-manager}" ;;
                *)          log_error "Использование: mtproxyl mode [manager|reanimator]" ;;
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

        geoblock)
            load_settings
            handle_geoblock_command "$@"
            ;;

        sni-policy)
            load_settings; load_secrets
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
            load_settings
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

        update)
            check_root; load_settings
            self_update
            ;;

         selfmask)
            load_settings
            handle_selfmask_command "$@"
            ;;

        pq-check)
            load_settings; load_detect_settings
            if [ -x "$(_selfmask_pq_openssl_bin)" ]; then
                _addon_check_pq_domain "${1:-$(_current_sni_domain)}"
            else
                log_error "PQ OpenSSL не установлен"
                log_info "Установите через: mtproxyl selfmask setup"
            fi
            ;;            

        install)
            run_installer
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
