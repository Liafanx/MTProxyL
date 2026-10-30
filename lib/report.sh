#!/bin/bash
# MTProxyL — сводка для issue: версии, режим, состояние, последние ошибки.
# IP, ключи, токены и свои домены вырезаются; файл всё равно стоит прочитать
# перед отправкой.

# Что из settings.conf можно показать: ни адресов, ни доменов, ни меток.
_REPORT_SETTINGS="MTPROXYL_MODE ENGINE_BACKEND ENGINE_VERSION ENGINE_SERVICE_NAMING PROXY_MODE PROXY_PORT PROXY_CONCURRENCY PROXY_CPUS PROXY_MEMORY FAKE_CERT_LEN PROXY_PROTOCOL GEOBLOCK_MODE MASKING_ENABLED UNKNOWN_SNI_ACTION TOOLS_ONLY DC_THRESHOLD DC_RESTART_ENABLED DC_RESTART_THRESHOLD DC_RESTART_COOLDOWN AVAILABILITY_ENABLED AVAILABILITY_INTERVAL WARP_ENABLED WARP_MODE WARP_PROTO API_ENABLED"

# Значения, по которым узнаётся сервер, — их вырезаем дословно.
_report_private_words() {
    local _w
    for _w in "${CUSTOM_IP:-}" ${SERVER_IPS//,/ } "${PROXY_DOMAIN:-}" "${MASKING_HOST:-}" \
              "${SELFMASK_DOMAIN:-}" "${AVAILABILITY_HOST:-}" "${DONOR_HOST:-}" \
              "$(hostname 2>/dev/null)" "$(hostname -f 2>/dev/null)"; do
        [ "${#_w}" -ge 4 ] && echo "$_w"
    done | sort -u
}

_report_mask() {
    local _f="$1" _w _re
    while IFS= read -r _w; do
        [ -n "$_w" ] || continue
        _re=$(printf '%s' "$_w" | sed 's/[][\.*^$/|]/\\&/g')
        sed -i "s|${_re}|<скрыто>|g" "$_f"
    done < <(_report_private_words)
    sed -i -E \
        -e 's/\x1b\[[0-9;]*[A-Za-z]//g' \
        -e 's#tg://[^ ]*|https://t\.me/proxy[^ ]*#<ссылка>#g' \
        -e 's/[0-9]{8,12}:[A-Za-z0-9_-]{30,}/<токен>/g' \
        -e 's/(ee|dd)?[0-9a-fA-F]{32,}/<ключ>/g' \
        -e 's/[A-Za-z0-9+=_-]{40,}/<токен>/g' \
        -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<ip>/g' \
        -e 's/([0-9a-fA-F]{0,4}:){3,7}[0-9a-fA-F]{0,4}/<ip6>/g' \
        "$_f"
}

_report_run() {
    local _title="$1"; shift
    echo ""
    echo "== ${_title} =="
    timeout 60 "${INSTALL_DIR}/mtproxyl.sh" "$@" 2>&1 | head -n 120
}

report_create() {
    local _out="" _stdout=false
    case "${1:-}" in
        --stdout|-) _stdout=true ;;
        "") _out="/tmp/mtproxyl-report-$(date +%Y%m%d-%H%M%S).txt" ;;
        *) _out="$1" ;;
    esac
    local _tmp; _tmp=$(_mktemp) || return 1
    $_stdout || log_info "Собираем сводку (до минуты)..."
    {
        echo "MTProxyL report — $(date -u '+%Y-%m-%d %H:%M UTC')"
        echo "IP, ключи, токены и домены сервера скрыты. Проверьте файл перед отправкой."
        echo ""
        echo "== Версии =="
        echo "MTProxyL: ${VERSION} (ветка ${GITHUB_BRANCH})"
        echo "Режим: ${MTPROXYL_MODE:-manager}"
        echo "Движок: ${ENGINE_BACKEND:-?} ${ENGINE_VERSION:-}"
        panel_installed 2>/dev/null && echo "Панель: установлена"
        tgbot_installed 2>/dev/null && echo "Бот: установлен"
        echo ""
        echo "== Система =="
        (. /etc/os-release 2>/dev/null && echo "ОС: ${PRETTY_NAME:-?}")
        echo "Ядро: $(uname -r) $(uname -m)"
        echo "CPU: $(nproc 2>/dev/null)  RAM: $(free -m 2>/dev/null | awk '/^Mem:/{print $2 " МБ, свободно " $7 " МБ"}')"
        echo "Диск ${INSTALL_DIR}: $(df -Pm "$INSTALL_DIR" 2>/dev/null | awk 'NR==2{print $4 " МБ свободно"}')"
        echo "Аптайм: $(uptime -p 2>/dev/null)  нагрузка: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
        command -v docker >/dev/null 2>&1 && echo "Docker: $(docker --version 2>/dev/null)"
        echo ""
        echo "== Настройки =="
        local _k
        for _k in $_REPORT_SETTINGS; do
            [ -n "${!_k:-}" ] && echo "${_k}=${!_k}"
        done
        echo "Пользователей: ${#SECRETS_LABELS[@]}, включено: $(printf '%s\n' "${SECRETS_ENABLED[@]}" | grep -cx true)"
        echo ""
        echo "== Службы =="
        systemctl list-units --all --no-legend --plain 'mtproxyl*' 'telemt*' 2>/dev/null \
            | awk '{print $1, $3, $4}' | head -40
        _report_run "Статус" status
        _report_run "Дата-центры" dc status
        _report_run "Выход к Telegram" egress
        _report_run "Проверка" health
        echo ""
        echo "== Предупреждения и ошибки движка (последние) =="
        if [ "${MTPROXYL_MODE:-manager}" = manager ] && declare -F engine_is_binary >/dev/null && engine_is_binary; then
            journalctl -u "$ENGINE_SERVICE" -n 2000 --no-pager -o short-iso 2>/dev/null
        elif [ "${MTPROXYL_MODE:-manager}" = manager ]; then
            docker logs --tail 2000 "$CONTAINER_NAME" 2>&1
        elif _telemt_unit_exists 2>/dev/null; then
            journalctl -u telemt.service -n 2000 --no-pager -o short-iso 2>/dev/null
        fi | grep -iE 'warn|error|fail|panic' | tail -n 40
    } > "$_tmp" 2>&1
    _report_mask "$_tmp"
    if $_stdout; then
        cat "$_tmp"; rm -f "$_tmp"
        return 0
    fi
    (umask 077; cat "$_tmp" > "$_out") || { rm -f "$_tmp"; log_error "Не удалось записать ${_out}"; return 1; }
    rm -f "$_tmp"
    log_success "Сводка: ${_out}"
    log_info "Прочитайте её и приложите к issue: https://github.com/${GITHUB_REPO}/issues"
}
