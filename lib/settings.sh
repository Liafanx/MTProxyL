#!/bin/bash
# MTProxyL — сохранение / загрузка настроек

# ── Значения по умолчанию ─────────────────────────────────────
MTPROXYL_MODE="manager"
# Чем менеджер держит движок: docker — образ в контейнере, binary — бинарник
# MTProxyL-Telemt под systemd. ENGINE_VERSION пуст = последняя версия telemt.
ENGINE_BACKEND="docker"
ENGINE_VERSION=""
PROXY_PORT=443
PROXY_METRICS_PORT=9090
# REST API движка. MTProxyL включает его явно и вешает на localhost:
# у telemt по умолчанию listen = "0.0.0.0:9091", то есть без явной
# записи API смотрел бы в интернет.
PROXY_API_PORT=9091
PROXY_DOMAIN="autoscout24.ru"
PROXY_CONCURRENCY=8192
PROXY_CPUS=""
PROXY_MEMORY=""
CUSTOM_IP=""
FAKE_CERT_LEN=2048
PROXY_PROTOCOL="false"
PROXY_PROTOCOL_TRUSTED_CIDRS=""
AD_TAG=""
GEOBLOCK_MODE="blacklist"
BLOCKLIST_COUNTRIES=""
MASKING_ENABLED="true"
MASKING_HOST=""
MASKING_PORT=443
MASKING_RELAY_MAX_BYTES=""
UNKNOWN_SNI_ACTION="mask"
PROXY_SECRET_URL=""
PROXY_CONFIG_V4_URL=""
PROXY_CONFIG_V6_URL=""
# Только оптимизация: telemt на сервере нет и не нужен, работаем как набор
# host-фиксов (zapret2, лимитер, By-MEKO, гео). Всё, что требует движка,
# из меню уходит — включая жалобы на его отсутствие.
TOOLS_ONLY="false"
# Порог покрытия дата-центров Telegram, ниже которого бот шлёт уведомление.
DC_THRESHOLD="80"
IP_HISTORY_LIMIT="200"
# Как часто снимать адреса в историю, минут. 0 — только при открытой панели.
IP_HISTORY_INTERVAL="5"
BACKUP_RETENTION_DAYS="30"

# Доступность из России (Globalping). Токен лежит отдельно, в
# ${INSTALL_DIR}/availability/token: settings.conf читается всем миром.
AVAILABILITY_ENABLED="true"
AVAILABILITY_INTERVAL="15"
AVAILABILITY_PROBES="20"
AVAILABILITY_THRESHOLD="50"
AVAILABILITY_HOST=""
AVAILABILITY_PORT=""
AVAILABILITY_SNI=""

# Маршрут до Telegram через Cloudflare WARP (warpscout). В туннель уходят
# только подсети Telegram; клиенты приходят на сервер по-прежнему напрямую.
WARP_ENABLED="false"
# socks — вариант A (SOCKS5 warpscout + redsocks), iface — вариант B
# (интерфейс WireGuard и policy routing).
WARP_MODE="socks"
WARP_PROTO="awg"
# Пусто — лучший по задержке; иначе коды стран (DE,NL) или узлов (FRA,AMS).
WARP_LOCATION=""
WARP_ENDPOINT=""
WARP_SOCKS_PORT="41080"
WARP_REDIR_PORT="41081"
WARP_MTU="1280"
WARP_FWMARK="0x100000"
# Маршруты движка, выключенные на время работы варианта C — вернём при выключении.
WARP_DISABLED_UPSTREAMS=""

# Режим супер эксперта: конфиг движка ведёт пользователь вручную,
# менеджер только копирует его файл на место config.toml
SUPEREXPERT_ENABLED="false"

# Selfmask (локальный nginx + Let's Encrypt либо самоподписанный сертификат)
SELFMASK_ENABLED="false"
SELFMASK_DOMAIN=""
SELFMASK_SITE_SOURCE="stub"
SELFMASK_SITE_DIR="/var/www/mtproxyl-selfmask"
SELFMASK_NGINX_BACKEND_PORT="8444"
SELFMASK_CERT_EMAIL=""
SELFMASK_NGINX_SITE_NAME="mtproxyl-selfmask"
SELFMASK_AUTO_RENEW="true"
SELFMASK_TLS_PROTOCOLS="TLSv1.3"
SELFMASK_CERT_MODE="letsencrypt"  # letsencrypt|selfsigned

# WEB Proxy (движок 3.5.1+). Публичный порт остаётся PROXY_PORT: на нём стоит
# nginx с ssl_preread и разводит по SNI. Домен, сертификат и сайт по умолчанию
# берутся у Selfmask — пустое значение означает «взять оттуда».
WEB_ENABLED="false"
# shared — WEB и FakeTLS на одном публичном порту, nginx разводит их по SNI.
# split — у WEB свой порт, движок остаётся на PROXY_PORT напрямую; тогда
# ssl_preread не нужен, а zapret2 и лимитер фильтруются по порту прокси.
WEB_LAYOUT="shared"
WEB_PUBLIC_PORT="443"       # порт, на который приходит клиент WEB
WEB_DOMAIN=""
WEB_CARRIER="websocket"        # https|https-lanes|websocket|websocket-lanes
WEB_SECRET_MODE="dd"        # plain|dd, ee движок в WEB не поддерживает
WEB_LISTEN_PORT="15080"     # приватный listener telemt, transport = "web"
WEB_TLS_PORT="15444"        # https-сервер nginx на loopback
WEB_MTPROXY_PORT="15443"    # куда nginx отдаёт FakeTLS после разбора SNI
WEB_DECOY_MODE="static_directory"   # static_directory|http_upstream
WEB_DECOY_DIR=""
WEB_DECOY_UPSTREAM=""
WEB_DEBUG="false"           # [web.debug].enabled, страница /web-status

# Снимок того, что было до включения Selfmask — иначе отключение не может
# вернуть прежний fake SNI. Файл per-mode: один набор имён на оба режима.
SELFMASK_PREV_SAVED="false"
SELFMASK_PREV_DOMAIN=""
SELFMASK_PREV_MASK_HOST=""
SELFMASK_PREV_MASK_PORT=""
SELFMASK_PREV_UNKNOWN_SNI=""
SELFMASK_PREV_MASKING_ENABLED=""
SELFMASK_PREV_FAKE_CERT_LEN=""
SELFMASK_PREV_PUBLIC_HOST=""

# Порт, запомненный за каждым режимом: при переключении режима порт
# восстанавливается, а не тянется из предыдущего режима.
PORT_PROFILE_MANAGER=""
PORT_PROFILE_REANIMATOR=""

# Права на settings.conf: порт, fake SNI и домен видно снаружи по одному
# подключению, секретов в файле нет — они в secrets.conf с правами 600.
# Каталог остаётся 711: проход к файлу с известным именем, без листинга.
_SETTINGS_FILE_MODE="644"
_INSTALL_DIR_MODE="711"

save_settings() {
    mkdir -p "$INSTALL_DIR"
    chmod "$_INSTALL_DIR_MODE" "$INSTALL_DIR" 2>/dev/null || true
    local tmp
    # Временный файл рядом с целевым: mv в пределах одной ФС — это rename(2),
    # то есть замена целиком. Через /tmp (обычно tmpfs) mv выродился бы в
    # copy+truncate, и читатель увидел бы файл в середине записи.
    tmp=$(_mktemp "$INSTALL_DIR") || { log_error "Не удалось создать временный файл"; return 1; }

    cat > "$tmp" << SETTINGS_EOF
# MTProxyL — настройки v${VERSION}
# Создано: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# НЕ РЕДАКТИРУЙТЕ ВРУЧНУЮ — используйте 'mtproxyl' для изменения

# Режим работы: manager (владеет своим telemt) | reanimator (чинит чужой)
MTPROXYL_MODE='${MTPROXYL_MODE}'

# Движок менеджера: docker | binary
ENGINE_BACKEND='${ENGINE_BACKEND}'
ENGINE_VERSION='${ENGINE_VERSION}'

# Конфигурация прокси
PROXY_PORT='${PROXY_PORT}'
PROXY_METRICS_PORT='${PROXY_METRICS_PORT}'
PROXY_API_PORT='${PROXY_API_PORT}'
PROXY_DOMAIN='${PROXY_DOMAIN}'
PROXY_CONCURRENCY='${PROXY_CONCURRENCY}'
PROXY_CPUS='${PROXY_CPUS}'
PROXY_MEMORY='${PROXY_MEMORY}'
CUSTOM_IP='${CUSTOM_IP}'
FAKE_CERT_LEN='${FAKE_CERT_LEN}'
PROXY_PROTOCOL='${PROXY_PROTOCOL}'
PROXY_PROTOCOL_TRUSTED_CIDRS='${PROXY_PROTOCOL_TRUSTED_CIDRS}'

# Рекламная метка (от @MTProxyBot)
AD_TAG='${AD_TAG}'

# Гео-блокировка
GEOBLOCK_MODE='${GEOBLOCK_MODE}'
BLOCKLIST_COUNTRIES='${BLOCKLIST_COUNTRIES}'

# Маскировка трафика
MASKING_ENABLED='${MASKING_ENABLED}'
MASKING_HOST='${MASKING_HOST}'
MASKING_PORT='${MASKING_PORT}'
MASKING_RELAY_MAX_BYTES='${MASKING_RELAY_MAX_BYTES}'
UNKNOWN_SNI_ACTION='${UNKNOWN_SNI_ACTION}'

# Пользовательские URL инфраструктуры Telegram
PROXY_SECRET_URL='${PROXY_SECRET_URL}'
PROXY_CONFIG_V4_URL='${PROXY_CONFIG_V4_URL}'
PROXY_CONFIG_V6_URL='${PROXY_CONFIG_V6_URL}'

# Автообновление

# Автоматическая ротация секретов
TOOLS_ONLY='${TOOLS_ONLY}'
DC_THRESHOLD='${DC_THRESHOLD}'
IP_HISTORY_LIMIT='${IP_HISTORY_LIMIT}'
IP_HISTORY_INTERVAL='${IP_HISTORY_INTERVAL}'
BACKUP_RETENTION_DAYS='${BACKUP_RETENTION_DAYS}'

# Доступность из России
AVAILABILITY_ENABLED='${AVAILABILITY_ENABLED}'
AVAILABILITY_INTERVAL='${AVAILABILITY_INTERVAL}'
AVAILABILITY_PROBES='${AVAILABILITY_PROBES}'
AVAILABILITY_THRESHOLD='${AVAILABILITY_THRESHOLD}'
AVAILABILITY_HOST='${AVAILABILITY_HOST}'
AVAILABILITY_PORT='${AVAILABILITY_PORT}'
AVAILABILITY_SNI='${AVAILABILITY_SNI}'

# Маршрут до Telegram через WARP
WARP_ENABLED='${WARP_ENABLED}'
WARP_MODE='${WARP_MODE}'
WARP_PROTO='${WARP_PROTO}'
WARP_LOCATION='${WARP_LOCATION}'
WARP_ENDPOINT='${WARP_ENDPOINT}'
WARP_SOCKS_PORT='${WARP_SOCKS_PORT}'
WARP_REDIR_PORT='${WARP_REDIR_PORT}'
WARP_MTU='${WARP_MTU}'
WARP_FWMARK='${WARP_FWMARK}'
WARP_DISABLED_UPSTREAMS='${WARP_DISABLED_UPSTREAMS}'

# Selfmask
SELFMASK_ENABLED='${SELFMASK_ENABLED}'
SELFMASK_DOMAIN='${SELFMASK_DOMAIN}'
SELFMASK_SITE_SOURCE='${SELFMASK_SITE_SOURCE}'
SELFMASK_SITE_DIR='${SELFMASK_SITE_DIR}'
SELFMASK_NGINX_BACKEND_PORT='${SELFMASK_NGINX_BACKEND_PORT}'
SELFMASK_CERT_EMAIL='${SELFMASK_CERT_EMAIL}'
SELFMASK_NGINX_SITE_NAME='${SELFMASK_NGINX_SITE_NAME}'
SELFMASK_AUTO_RENEW='${SELFMASK_AUTO_RENEW}'
SELFMASK_TLS_PROTOCOLS='${SELFMASK_TLS_PROTOCOLS}'
SELFMASK_CERT_MODE='${SELFMASK_CERT_MODE}'

# WEB Proxy
WEB_ENABLED='${WEB_ENABLED}'
WEB_LAYOUT='${WEB_LAYOUT}'
WEB_PUBLIC_PORT='${WEB_PUBLIC_PORT}'
WEB_DOMAIN='${WEB_DOMAIN}'
WEB_CARRIER='${WEB_CARRIER}'
WEB_SECRET_MODE='${WEB_SECRET_MODE}'
WEB_LISTEN_PORT='${WEB_LISTEN_PORT}'
WEB_TLS_PORT='${WEB_TLS_PORT}'
WEB_MTPROXY_PORT='${WEB_MTPROXY_PORT}'
WEB_DECOY_MODE='${WEB_DECOY_MODE}'
WEB_DECOY_DIR='${WEB_DECOY_DIR}'
WEB_DECOY_UPSTREAM='${WEB_DECOY_UPSTREAM}'
WEB_DEBUG='${WEB_DEBUG}'

# Режим супер эксперта
SUPEREXPERT_ENABLED='${SUPEREXPERT_ENABLED}'

# Порты, запомненные за режимами
PORT_PROFILE_MANAGER='${PORT_PROFILE_MANAGER}'
PORT_PROFILE_REANIMATOR='${PORT_PROFILE_REANIMATOR}'

# Блокировка IP адресов
IPBLOCK_ENABLED='${IPBLOCK_ENABLED}'
IPBLOCK_ACTION='${IPBLOCK_ACTION}'
IPBLOCK_LIST='${IPBLOCK_LIST}'
IPBLOCK_LIST6='${IPBLOCK_LIST6}'
SETTINGS_EOF

    chmod "$_SETTINGS_FILE_MODE" "$tmp"
    mv "$tmp" "$SETTINGS_FILE"

    save_selfmask_settings
}

# ── Selfmask: отдельный набор настроек на каждый режим ─────────
# PQ nginx на хосте один, но «чей» selfmask настроен — у manager и reanimator
# своё, иначе после переключения светится чужой.
_selfmask_conf_file() {
    echo "${INSTALL_DIR}/selfmask-${MTPROXYL_MODE:-manager}.conf"
}

save_selfmask_settings() {
    mkdir -p "$INSTALL_DIR"
    local _f; _f=$(_selfmask_conf_file)
    local _tmp
    _tmp=$(_mktemp "$INSTALL_DIR") || { log_error "Не удалось создать временный файл"; return 1; }
    cat > "$_tmp" << SELFMASK_EOF
# MTProxyL — настройки Selfmask для режима ${MTPROXYL_MODE:-manager}
SELFMASK_ENABLED='${SELFMASK_ENABLED}'
SELFMASK_DOMAIN='${SELFMASK_DOMAIN}'
SELFMASK_SITE_SOURCE='${SELFMASK_SITE_SOURCE}'
SELFMASK_SITE_DIR='${SELFMASK_SITE_DIR}'
SELFMASK_NGINX_BACKEND_PORT='${SELFMASK_NGINX_BACKEND_PORT}'
SELFMASK_CERT_EMAIL='${SELFMASK_CERT_EMAIL}'
SELFMASK_NGINX_SITE_NAME='${SELFMASK_NGINX_SITE_NAME}'
SELFMASK_AUTO_RENEW='${SELFMASK_AUTO_RENEW}'
SELFMASK_TLS_PROTOCOLS='${SELFMASK_TLS_PROTOCOLS}'
SELFMASK_CERT_MODE='${SELFMASK_CERT_MODE}'

# Что было до включения Selfmask — для возврата при отключении
SELFMASK_PREV_SAVED='${SELFMASK_PREV_SAVED}'
SELFMASK_PREV_DOMAIN='${SELFMASK_PREV_DOMAIN}'
SELFMASK_PREV_MASK_HOST='${SELFMASK_PREV_MASK_HOST}'
SELFMASK_PREV_MASK_PORT='${SELFMASK_PREV_MASK_PORT}'
SELFMASK_PREV_UNKNOWN_SNI='${SELFMASK_PREV_UNKNOWN_SNI}'
SELFMASK_PREV_MASKING_ENABLED='${SELFMASK_PREV_MASKING_ENABLED}'
SELFMASK_PREV_FAKE_CERT_LEN='${SELFMASK_PREV_FAKE_CERT_LEN}'
SELFMASK_PREV_PUBLIC_HOST='${SELFMASK_PREV_PUBLIC_HOST}'
SELFMASK_EOF
    chmod 600 "$_tmp"
    mv "$_tmp" "$_f"
}

# Значения из per-mode файла перекрывают то, что пришло из settings.conf.
# Если файла ещё нет (обновление со старой версии) — остаются текущие,
# и они запишутся в per-mode файл при первом сохранении.
load_selfmask_settings() {
    local _f; _f=$(_selfmask_conf_file)
    [ -f "$_f" ] || return 0
    local _line _key _val
    while IFS= read -r _line; do
        [[ "$_line" =~ ^[[:space:]]*# ]] && continue
        [[ "$_line" =~ ^([A-Z_][A-Z0-9_]*)=\'([^\']*)\'$ ]] || continue
        _key="${BASH_REMATCH[1]}"; _val="${BASH_REMATCH[2]}"
        case "$_key" in
            SELFMASK_ENABLED|SELFMASK_DOMAIN|SELFMASK_SITE_SOURCE|SELFMASK_SITE_DIR|\
            SELFMASK_NGINX_BACKEND_PORT|SELFMASK_CERT_EMAIL|SELFMASK_NGINX_SITE_NAME|\
            SELFMASK_AUTO_RENEW|SELFMASK_TLS_PROTOCOLS|SELFMASK_CERT_MODE|\
            SELFMASK_PREV_SAVED|SELFMASK_PREV_DOMAIN|SELFMASK_PREV_MASK_HOST|\
            SELFMASK_PREV_MASK_PORT|SELFMASK_PREV_UNKNOWN_SNI|\
            SELFMASK_PREV_MASKING_ENABLED|SELFMASK_PREV_FAKE_CERT_LEN|\
            SELFMASK_PREV_PUBLIC_HOST)
                printf -v "$_key" '%s' "$_val" ;;
        esac
    done < "$_f"
}

_selfmask_reset_defaults() {
    SELFMASK_ENABLED="false"
    SELFMASK_DOMAIN=""
    SELFMASK_SITE_SOURCE="stub"
    SELFMASK_SITE_DIR="/var/www/mtproxyl-selfmask"
    SELFMASK_NGINX_BACKEND_PORT="8444"
    SELFMASK_CERT_EMAIL=""
    SELFMASK_NGINX_SITE_NAME="mtproxyl-selfmask"
    SELFMASK_AUTO_RENEW="true"
    SELFMASK_TLS_PROTOCOLS="TLSv1.3"
    SELFMASK_CERT_MODE="letsencrypt"
    SELFMASK_PREV_SAVED="false"
    SELFMASK_PREV_DOMAIN=""
    SELFMASK_PREV_MASK_HOST=""
    SELFMASK_PREV_MASK_PORT=""
    SELFMASK_PREV_UNKNOWN_SNI=""
    SELFMASK_PREV_MASKING_ENABLED=""
    SELFMASK_PREV_FAKE_CERT_LEN=""
    SELFMASK_PREV_PUBLIC_HOST=""
}

# Смена режима: профиль старого режима сохраняем, профиль нового
# подгружаем (а если его ещё нет — начинаем с чистых значений, чтобы
# selfmask одного режима не «протёк» в другой).
switch_selfmask_profile() {
    local _new="$1"
    save_selfmask_settings
    MTPROXYL_MODE="$_new"
    if [ -f "$(_selfmask_conf_file)" ]; then
        load_selfmask_settings
    else
        _selfmask_reset_defaults
    fi
}

# Запоминаем порт уходящего режима и восстанавливаем порт входящего.
# Для manager, если запомненного нет, берём порт из его же config.toml.
# Возвращает 0, если порт изменился (вызывающий переприменяет правила).
switch_port_profile() {
    local _new="$1" _old="${MTPROXYL_MODE:-manager}"
    local _before="${PROXY_PORT:-}"

    case "$_old" in
        manager)    PORT_PROFILE_MANAGER="$_before" ;;
        reanimator) PORT_PROFILE_REANIMATOR="$_before" ;;
    esac

    local _restore=""
    case "$_new" in
        manager)
            _restore="${PORT_PROFILE_MANAGER}"
            local _ecfg; _ecfg=$(engine_config_path 2>/dev/null || echo "${CONFIG_DIR}/config.toml")
            if [ -z "$_restore" ] && [ -f "$_ecfg" ]; then
                _restore=$(awk '/^port[[:space:]]*=/{gsub(/[^0-9]/,"",$3); print $3; exit}' "$_ecfg" 2>/dev/null)
            fi ;;
        reanimator) _restore="${PORT_PROFILE_REANIMATOR}" ;;
    esac

    [ -n "$_restore" ] && [[ "$_restore" =~ ^[0-9]+$ ]] && PROXY_PORT="$_restore"
    [ "$PROXY_PORT" != "$_before" ]
}

# Привести права каталога и settings.conf к нужным — для копий, где каталог
# остался 700 с прошлых версий. Обычный вызов обходится одним stat.
_fix_settings_perms() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || return 0
    [ -f "$SETTINGS_FILE" ] || return 0
    local _cur
    _cur=$(stat -c '%a' "$INSTALL_DIR" "$SETTINGS_FILE" 2>/dev/null | tr '\n' ' ')
    [ "$_cur" = "${_INSTALL_DIR_MODE} ${_SETTINGS_FILE_MODE} " ] && return 0
    chmod "$_INSTALL_DIR_MODE" "$INSTALL_DIR" 2>/dev/null || true
    chmod "$_SETTINGS_FILE_MODE" "$SETTINGS_FILE" 2>/dev/null || true
    # Подкаталоги закрываем явно: до сих пор их прятал только закрытый на
    # листинг родитель, а теперь через него можно пройти.
    chmod 700 "${STATS_DIR:-${INSTALL_DIR}/relay_stats}" "${BACKUP_DIR:-${INSTALL_DIR}/backups}" 2>/dev/null || true
}

load_settings() {
    # Отсутствие settings.conf раньше означало выход сразу, вместе с ним
    # пропускался load_selfmask_settings — и 'selfmask set' затирал значения.
    if [ -f "$SETTINGS_FILE" ]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ "$line" =~ ^[[:space:]]*$ ]] && continue

            if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=\'([^\']*)\'$ ]]; then
                local key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
            elif [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=\"([^\"]*)\"$ ]]; then
                local key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
            elif [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=([^[:space:]]*)$ ]]; then
                local key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
            else
                continue
            fi

            case "$key" in
                MTPROXYL_MODE|ENGINE_BACKEND|ENGINE_VERSION|\
                PROXY_PORT|PROXY_METRICS_PORT|PROXY_API_PORT|PROXY_DOMAIN|PROXY_CONCURRENCY|\
                PROXY_CPUS|PROXY_MEMORY|CUSTOM_IP|FAKE_CERT_LEN|\
                PROXY_PROTOCOL|PROXY_PROTOCOL_TRUSTED_CIDRS|\
                AD_TAG|GEOBLOCK_MODE|BLOCKLIST_COUNTRIES|\
                MASKING_ENABLED|MASKING_HOST|MASKING_PORT|MASKING_RELAY_MAX_BYTES|\
                UNKNOWN_SNI_ACTION|\
                PROXY_SECRET_URL|PROXY_CONFIG_V4_URL|PROXY_CONFIG_V6_URL|\
                BACKUP_RETENTION_DAYS|IP_HISTORY_LIMIT|IP_HISTORY_INTERVAL|TOOLS_ONLY|DC_THRESHOLD|\
                AVAILABILITY_ENABLED|AVAILABILITY_INTERVAL|AVAILABILITY_PROBES|\
                AVAILABILITY_THRESHOLD|AVAILABILITY_HOST|AVAILABILITY_PORT|AVAILABILITY_SNI|\
                WARP_ENABLED|WARP_MODE|WARP_PROTO|WARP_LOCATION|WARP_ENDPOINT|\
                WARP_SOCKS_PORT|WARP_REDIR_PORT|WARP_MTU|WARP_FWMARK|\
                WARP_DISABLED_UPSTREAMS|\
                SELFMASK_ENABLED|SELFMASK_DOMAIN|SELFMASK_SITE_SOURCE|SELFMASK_SITE_DIR|\
                SELFMASK_NGINX_BACKEND_PORT|SELFMASK_CERT_EMAIL|SELFMASK_NGINX_SITE_NAME|\
                SELFMASK_AUTO_RENEW|SELFMASK_TLS_PROTOCOLS|SELFMASK_CERT_MODE|\
                WEB_ENABLED|WEB_LAYOUT|WEB_PUBLIC_PORT|WEB_DOMAIN|WEB_CARRIER|WEB_SECRET_MODE|\
                WEB_LISTEN_PORT|WEB_TLS_PORT|WEB_MTPROXY_PORT|\
                WEB_DECOY_MODE|WEB_DECOY_DIR|WEB_DECOY_UPSTREAM|WEB_DEBUG|\
                SUPEREXPERT_ENABLED|\
                IPBLOCK_ENABLED|IPBLOCK_ACTION|IPBLOCK_LIST|IPBLOCK_LIST6|\
                PORT_PROFILE_MANAGER|PORT_PROFILE_REANIMATOR)
                    printf -v "$key" '%s' "$val"
                    ;;
            esac
        done < "$SETTINGS_FILE"
    fi

    # Валидация
    case "$MTPROXYL_MODE" in
        manager|reanimator) ;;
        *) MTPROXYL_MODE="manager" ;;
    esac
    case "$ENGINE_BACKEND" in
        docker|binary) ;;
        *) ENGINE_BACKEND="docker" ;;
    esac
    [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] && [ "$PROXY_PORT" -ge 1 ] && [ "$PROXY_PORT" -le 65535 ] || PROXY_PORT=443
    [[ "$PROXY_METRICS_PORT" =~ ^[0-9]+$ ]] && [ "$PROXY_METRICS_PORT" -ge 1 ] && [ "$PROXY_METRICS_PORT" -le 65535 ] || PROXY_METRICS_PORT=9090
    [[ "$PROXY_API_PORT" =~ ^[0-9]+$ ]] && [ "$PROXY_API_PORT" -ge 1 ] && [ "$PROXY_API_PORT" -le 65535 ] || PROXY_API_PORT=9091
    [[ "$MASKING_PORT" =~ ^[0-9]+$ ]] && [ "$MASKING_PORT" -ge 1 ] && [ "$MASKING_PORT" -le 65535 ] || MASKING_PORT=443
    [[ "$FAKE_CERT_LEN" =~ ^[0-9]+$ ]] && [ "$FAKE_CERT_LEN" -ge 512 ] || FAKE_CERT_LEN=2048
    [[ "$PROXY_CONCURRENCY" =~ ^[0-9]+$ ]] || PROXY_CONCURRENCY=8192
    [[ "$PROXY_PROTOCOL" == "true" ]] || PROXY_PROTOCOL="false"
    [[ "$GEOBLOCK_MODE" == "whitelist" ]] || GEOBLOCK_MODE="blacklist"
    case "$UNKNOWN_SNI_ACTION" in
        mask|drop|accept|reject_handshake) ;;
        *) UNKNOWN_SNI_ACTION="mask" ;;
    esac

    [[ "$SELFMASK_NGINX_BACKEND_PORT" =~ ^[0-9]+$ ]] && [ "$SELFMASK_NGINX_BACKEND_PORT" -ge 1 ] && [ "$SELFMASK_NGINX_BACKEND_PORT" -le 65535 ] || SELFMASK_NGINX_BACKEND_PORT="8444"
    [ "$SELFMASK_ENABLED" = "true" ] || SELFMASK_ENABLED="false"
    [ "$SELFMASK_AUTO_RENEW" = "false" ] || SELFMASK_AUTO_RENEW="true"
    [ -n "$SELFMASK_SITE_DIR" ] || SELFMASK_SITE_DIR="/var/www/mtproxyl-selfmask"
    [ -n "$SELFMASK_NGINX_SITE_NAME" ] || SELFMASK_NGINX_SITE_NAME="mtproxyl-selfmask"
    [ -n "$SELFMASK_SITE_SOURCE" ] || SELFMASK_SITE_SOURCE="stub"
    [ "$SELFMASK_TLS_PROTOCOLS" = "TLSv1.3" ] || SELFMASK_TLS_PROTOCOLS="TLSv1.3"
    # Selfmask своего режима — уже после того, как известен MTPROXYL_MODE
    load_selfmask_settings

    case "$SELFMASK_CERT_MODE" in
        letsencrypt|selfsigned) ;;
        *) SELFMASK_CERT_MODE="letsencrypt" ;;
    esac

    [ "$WEB_ENABLED" = "true" ] || WEB_ENABLED="false"
    case "$WEB_LAYOUT" in
        shared|split) ;;
        *) WEB_LAYOUT="shared" ;;
    esac
    [[ "$WEB_PUBLIC_PORT" =~ ^[0-9]+$ ]] && [ "$WEB_PUBLIC_PORT" -ge 1 ] && [ "$WEB_PUBLIC_PORT" -le 65535 ] || WEB_PUBLIC_PORT="443"
    [ "$WEB_DEBUG" = "true" ] || WEB_DEBUG="false"
    case "$WEB_CARRIER" in
        https|https-lanes|websocket|websocket-lanes) ;;
        *) WEB_CARRIER="websocket" ;;
    esac
    # ee движок в WEB не принимает — только plain и dd.
    case "$WEB_SECRET_MODE" in
        plain|dd) ;;
        *) WEB_SECRET_MODE="dd" ;;
    esac
    case "$WEB_DECOY_MODE" in
        static_directory|http_upstream) ;;
        *) WEB_DECOY_MODE="static_directory" ;;
    esac
    [[ "$WEB_LISTEN_PORT" =~ ^[0-9]+$ ]] && [ "$WEB_LISTEN_PORT" -ge 1 ] && [ "$WEB_LISTEN_PORT" -le 65535 ] || WEB_LISTEN_PORT="15080"
    [[ "$WEB_TLS_PORT" =~ ^[0-9]+$ ]] && [ "$WEB_TLS_PORT" -ge 1 ] && [ "$WEB_TLS_PORT" -le 65535 ] || WEB_TLS_PORT="15444"
    [[ "$WEB_MTPROXY_PORT" =~ ^[0-9]+$ ]] && [ "$WEB_MTPROXY_PORT" -ge 1 ] && [ "$WEB_MTPROXY_PORT" -le 65535 ] || WEB_MTPROXY_PORT="15443"

    [ "$SUPEREXPERT_ENABLED" = "true" ] || SUPEREXPERT_ENABLED="false"
    [[ "$IP_HISTORY_INTERVAL" =~ ^[0-9]+$ ]] || IP_HISTORY_INTERVAL="5"

    [ "$AVAILABILITY_ENABLED" = "false" ] || AVAILABILITY_ENABLED="true"
    [[ "$AVAILABILITY_INTERVAL" =~ ^[0-9]+$ ]] && [ "$AVAILABILITY_INTERVAL" -ge 1 ] || AVAILABILITY_INTERVAL="15"
    [[ "$AVAILABILITY_PROBES" =~ ^[0-9]+$ ]] && [ "$AVAILABILITY_PROBES" -ge 1 ] && [ "$AVAILABILITY_PROBES" -le 50 ] || AVAILABILITY_PROBES="20"
    [[ "$AVAILABILITY_THRESHOLD" =~ ^[0-9]+$ ]] && [ "$AVAILABILITY_THRESHOLD" -le 100 ] || AVAILABILITY_THRESHOLD="50"

    _fix_settings_perms
    _ensure_ip_history_timer
    _ensure_availability_timer
}
