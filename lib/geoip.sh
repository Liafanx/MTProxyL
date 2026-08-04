#!/bin/bash
# MTProxyL — база GeoIP (страна/город/ASN для истории IP пользователей)
#
# База не привязана к режиму manager/reanimator: она живёт в общесистемном
# каталоге, который панель и так сканирует наравне с системным пакетом и
# geoipupdate (см. geoipCityCandidates в config.go панели), поэтому установка
# работает одинаково в обоих режимах и не требует перезапуска панели.

GEOIP_DIR="/var/lib/GeoIP"
GEOIP_CITY_FILE="${GEOIP_DIR}/GeoLite2-City.mmdb"
GEOIP_ASN_FILE="${GEOIP_DIR}/GeoLite2-ASN.mmdb"
GEOIP_CITY_URL="https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb"
GEOIP_ASN_URL="https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-ASN.mmdb"

geoip_installed() {
    [ -s "$GEOIP_CITY_FILE" ]
}

_geoip_download_one() {
    local _url="$1" _dest="$2" _label="$3" _tmp
    _tmp="${_dest}.tmp.$$"

    log_info "Загрузка ${_label}..."
    if ! curl -fsSL --max-time 300 "$_url" -o "$_tmp" 2>/dev/null; then
        rm -f "$_tmp"
        log_error "Не удалось загрузить ${_label}"
        return 1
    fi

    # Зеркало отдаёт страницу с ошибкой тем же кодом 200 — по факту это
    # проверка "файл похож на mmdb", а не HTML.
    local _size; _size=$(stat -c %s "$_tmp" 2>/dev/null || echo 0)
    if [ "$_size" -lt 1048576 ]; then
        log_error "${_label}: файл подозрительно маленький (${_size} байт), похоже на ошибку загрузки"
        rm -f "$_tmp"
        return 1
    fi

    chmod 644 "$_tmp"
    mv -f "$_tmp" "$_dest"
}

geoip_install() {
    check_root
    mkdir -p "$GEOIP_DIR"
    chmod 755 "$GEOIP_DIR"

    _geoip_download_one "$GEOIP_CITY_URL" "$GEOIP_CITY_FILE" "GeoLite2-City.mmdb" || return 1
    # ASN — не обязательна: без неё панель просто не покажет провайдера,
    # страна и город уже работают.
    _geoip_download_one "$GEOIP_ASN_URL" "$GEOIP_ASN_FILE" "GeoLite2-ASN.mmdb" || true

    log_success "База GeoIP установлена в ${GEOIP_DIR}"
    log_info "Панель подхватит её сама при следующем запросе — перезапуск не нужен"
}

geoip_remove() {
    check_root
    rm -f "$GEOIP_CITY_FILE" "$GEOIP_ASN_FILE"
    log_success "База GeoIP удалена"
}

geoip_status_json() {
    local _city="false" _asn="false"
    [ -s "$GEOIP_CITY_FILE" ] && _city="true"
    [ -s "$GEOIP_ASN_FILE" ] && _asn="true"
    printf '{"city_installed":%s,"asn_installed":%s,"dir":"%s"}\n' \
        "$_city" "$_asn" "$(json_escape "$GEOIP_DIR")"
}

handle_geoip_command() {
    case "${1:-status}" in
        install)
            geoip_install
            ;;
        remove)
            geoip_remove
            ;;
        status)
            if [ "${2:-}" = "--json" ]; then
                geoip_status_json
            elif geoip_installed; then
                echo -e "  ${BOLD}GeoIP:${NC} ${GREEN}установлен${NC} (${GEOIP_DIR})"
            else
                echo -e "  ${BOLD}GeoIP:${NC} ${DIM}не установлен${NC}"
                echo -e "  ${DIM}Установить: mtproxyl geoip install${NC}"
            fi
            ;;
        *)
            echo -e "  ${BOLD}GeoIP:${NC}"
            echo -e "    ${GREEN}geoip install${NC}   Скачать базы GeoLite2 (страна/город/ASN)"
            echo -e "    ${GREEN}geoip remove${NC}    Удалить базы"
            echo -e "    ${GREEN}geoip status${NC}    Статус (--json для машинного вывода)"
            ;;
    esac
}
