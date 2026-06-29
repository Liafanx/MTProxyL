#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  MTProxyL v1.0.9 — Telegram MTProto Proxy Manager
#  https://github.com/Liafanx/MTProxyL
#  by LiafanX
# ═══════════════════════════════════════════════════════════════

set -o pipefail
export LC_NUMERIC=C

VERSION="1.0.9"
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
GITHUB_RAW="https://raw.githubusercontent.com/${GITHUB_REPO}/dev"
REGISTRY_IMAGE="ghcr.io/liafanx/mtproxyl-telemt"
TELEMT_GITHUB="telemt/telemt"
TELEMT_MIN_VERSION="3.4.22"
TELEMT_COMMIT="ed1895d"

# Bash version check
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "ОШИБКА: MTProxyL требует bash 4.2+. Текущая: ${BASH_VERSION:-unknown}" >&2
    exit 1
fi

# Защита stdin при curl | bash
if [[ ! -t 0 ]] && [[ -e /dev/tty ]]; then
    exec < /dev/tty
fi

# Загрузка библиотек
LIB_DIR="${INSTALL_DIR}/lib"
for _lib in colors utils settings secrets config docker engine traffic geoblock upstream backup nft tui_main tui_proxy tui_secrets tui_links tui_settings tui_security tui_traffic tui_engine tui_backup tui_expert tui_nft expert_catalog expert_mode install; do
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
                check_for_update
                show_main_menu
            else
                run_installer
            fi
            ;;

        start)
            check_root
            load_settings; load_secrets; load_upstreams
            start_proxy_container
            ;;
        stop)
            check_root
            load_settings
            stop_proxy_container
            ;;
        restart)
            check_root
            load_settings; load_secrets; load_upstreams
            restart_proxy_container
            ;;
        status)
            load_settings; load_secrets
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
            load_settings; load_secrets
            show_traffic
            ;;

        connections)
            load_settings; load_secrets
            show_connections
            ;;

        config)
            load_settings
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
            load_settings
            handle_tune_command "$@"
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
            load_settings; load_secrets
            health_check
            ;;

        info)
            load_settings; load_secrets
            show_server_info
            ;;

        logs)
            load_settings
            echo -e "  ${DIM}Потоковые логи (Ctrl+C для остановки)...${NC}"
            docker logs -f --tail 50 "$CONTAINER_NAME" 2>&1
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
                preset)   check_root; apply_nft_preset "${2:-hard}" ;;
                smart)    check_root; enable_smart_mode ;;
                ios1)     check_root; ios_fix_apply ;;
                ios1-off) check_root; ios_fix_remove ;;
                ios2)     check_root; ios2_fix_apply ;;
                ios2-off) check_root; ios2_fix_remove ;;
                extra-add)
                    check_root; nft_extra_add "$2" "$3" "$4" "$5" ;;
                extra-rm)
                    check_root; nft_extra_remove "$2" ;;
                *)
                    echo -e "  ${BOLD}NFT SYN Limiter:${NC}"
                    echo -e "    ${GREEN}nft apply${NC}        Применить правила"
                    echo -e "    ${GREEN}nft remove${NC}       Удалить правила"
                    echo -e "    ${GREEN}nft smart${NC}        Smart By-MEKO (рекомендуется)"
                    echo -e "    ${GREEN}nft preset${NC} X     Пресет (hard/medium/soft/smart)"
                    echo -e "    ${GREEN}nft service${NC}      Установить службу"
                    echo -e "    ${GREEN}nft drop${NC}         Счётчик правил"
                    echo -e "    ${GREEN}nft ios1${NC}         iOS Fix v1 (keepalive)"
                    echo -e "    ${GREEN}nft ios1-off${NC}     Откатить iOS Fix v1"
                    echo -e "    ${GREEN}nft ios2${NC}         iOS Fix v2 (MSS+redirect)"
                    echo -e "    ${GREEN}nft ios2-off${NC}     Откатить iOS Fix v2"
                    echo -e "    ${GREEN}nft extra-add${NC}    Доп. правило"
                    echo -e "    ${GREEN}nft extra-rm${NC} N   Удалить доп. правило"
                    ;;
            esac
            ;;

        update)
            check_root; load_settings
            self_update
            ;;

        install)
            run_installer
            ;;

        menu)
            load_settings; load_secrets; load_upstreams
            show_main_menu
            ;;

        uninstall)
            check_root; load_settings; load_secrets
            uninstall
            exit 0
            ;;

        version)
            echo -e "  ${BOLD}MTProxyL${NC} v${VERSION}"
            echo -e "  ${DIM}Движок: telemt v$(get_telemt_version) (Rust)${NC}"
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
    cli_main "$@"
}

main "$@"
