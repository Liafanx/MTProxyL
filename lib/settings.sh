#!/bin/bash
# MTProxyL — сохранение / загрузка настроек

# ── Значения по умолчанию ─────────────────────────────────────
PROXY_PORT=443
PROXY_METRICS_PORT=9090
PROXY_DOMAIN="cloudflare.com"
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
AUTO_UPDATE_ENABLED="true"
SECRET_AUTO_ROTATE_DAYS="0"
BACKUP_RETENTION_DAYS="30"

save_settings() {
    mkdir -p "$INSTALL_DIR"
    local tmp
    tmp=$(_mktemp) || { log_error "Не удалось создать временный файл"; return 1; }

    cat > "$tmp" << SETTINGS_EOF
# MTProxyL — настройки v${VERSION}
# Создано: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# НЕ РЕДАКТИРУЙТЕ ВРУЧНУЮ — используйте 'mtproxyl' для изменения

# Конфигурация прокси
PROXY_PORT='${PROXY_PORT}'
PROXY_METRICS_PORT='${PROXY_METRICS_PORT}'
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
AUTO_UPDATE_ENABLED='${AUTO_UPDATE_ENABLED}'

# Автоматическая ротация секретов
SECRET_AUTO_ROTATE_DAYS='${SECRET_AUTO_ROTATE_DAYS}'
BACKUP_RETENTION_DAYS='${BACKUP_RETENTION_DAYS}'
SETTINGS_EOF

    chmod 600 "$tmp"
    mv "$tmp" "$SETTINGS_FILE"
}

load_settings() {
    [ -f "$SETTINGS_FILE" ] || return 0

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
            PROXY_PORT|PROXY_METRICS_PORT|PROXY_DOMAIN|PROXY_CONCURRENCY|\
            PROXY_CPUS|PROXY_MEMORY|CUSTOM_IP|FAKE_CERT_LEN|\
            PROXY_PROTOCOL|PROXY_PROTOCOL_TRUSTED_CIDRS|\
            AD_TAG|GEOBLOCK_MODE|BLOCKLIST_COUNTRIES|\
            MASKING_ENABLED|MASKING_HOST|MASKING_PORT|MASKING_RELAY_MAX_BYTES|\
            UNKNOWN_SNI_ACTION|\
            PROXY_SECRET_URL|PROXY_CONFIG_V4_URL|PROXY_CONFIG_V6_URL|\
            AUTO_UPDATE_ENABLED|SECRET_AUTO_ROTATE_DAYS|BACKUP_RETENTION_DAYS)
                printf -v "$key" '%s' "$val"
                ;;
        esac
    done < "$SETTINGS_FILE"

    # Валидация
    [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] && [ "$PROXY_PORT" -ge 1 ] && [ "$PROXY_PORT" -le 65535 ] || PROXY_PORT=443
    [[ "$PROXY_METRICS_PORT" =~ ^[0-9]+$ ]] && [ "$PROXY_METRICS_PORT" -ge 1 ] && [ "$PROXY_METRICS_PORT" -le 65535 ] || PROXY_METRICS_PORT=9090
    [[ "$MASKING_PORT" =~ ^[0-9]+$ ]] && [ "$MASKING_PORT" -ge 1 ] && [ "$MASKING_PORT" -le 65535 ] || MASKING_PORT=443
    [[ "$FAKE_CERT_LEN" =~ ^[0-9]+$ ]] && [ "$FAKE_CERT_LEN" -ge 512 ] || FAKE_CERT_LEN=2048
    [[ "$PROXY_CONCURRENCY" =~ ^[0-9]+$ ]] || PROXY_CONCURRENCY=8192
    [[ "$PROXY_PROTOCOL" == "true" ]] || PROXY_PROTOCOL="false"
    [[ "$GEOBLOCK_MODE" == "whitelist" ]] || GEOBLOCK_MODE="blacklist"
    case "$UNKNOWN_SNI_ACTION" in
        mask|drop|accept|reject_handshake) ;;
        *) UNKNOWN_SNI_ACTION="mask" ;;
    esac
}
