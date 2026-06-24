#!/bin/bash
# MTProxyL — каталог параметров Telemt
# Формат: "section|key|type|default|hot_reload|validator|hint|description"
#
# Типы: bool, u8, u16, u32, u64, usize, f32, string, enum, custom
# Валидаторы:
#   bool                      — true/false
#   range:MIN:MAX             — целое в диапазоне MIN..MAX
#   range:MIN:MAX:positive    — целое > 0
#   enum:v1,v2,v3             — одно из перечисленных
#   url                       — должен начинаться с http:// или https://
#   ipv4                      — валидный IPv4
#   ipport                    — host:port или ip:port
#   path                      — непустая строка без ..
#   nonempty                  — непустая строка
#   any                       — любая строка
#   custom:FUNCNAME           — вызвать функцию FUNCNAME "$value"

declare -a _EXPERT_CATALOG=()

_catalog() {
    _EXPERT_CATALOG+=("$1|$2|$3|$4|$5|$6|$7|$8")
}

# ── general ──────────────────────────────────────────────────
_catalog "general" "config_strict"            "bool"   "false"  "✘" "bool"                                    "true/false"                         "Отклонять неизвестные TOML-ключи при загрузке конфига"
_catalog "general" "prefer_ipv6"              "bool"   "false"  "✘" "bool"                                    "true/false (устарело, см. network.prefer)" "Устаревший флаг IPv6 (используйте network.prefer)"
_catalog "general" "fast_mode"                "bool"   "true"   "✘" "bool"                                    "true/false"                         "Включает быстрые оптимизированные маршруты"
_catalog "general" "use_middle_proxy"         "bool"   "true"   "✘" "bool"                                    "true/false"                         "Включает режим Middle-End; false = прямая DC-маршрутизация"
_catalog "general" "proxy_secret_path"        "string" "proxy-secret" "✘" "nonempty"                          "путь к файлу"                       "Путь к кэшу proxy-secret"
_catalog "general" "proxy_secret_url"         "string" "https://core.telegram.org/getProxySecret" "✘" "url"   "https://..."                        "URL для загрузки proxy-secret (для заблокированных регионов)"
_catalog "general" "proxy_config_v4_cache_path" "string" "cache/proxy-config-v4.txt" "✘" "nonempty"          "путь к файлу"                       "Путь к кэшу getProxyConfig (IPv4)"
_catalog "general" "proxy_config_v4_url"      "string" "https://core.telegram.org/getProxyConfig" "✘" "url"  "https://..."                        "URL для загрузки getProxyConfig (IPv4)"
_catalog "general" "proxy_config_v6_cache_path" "string" "cache/proxy-config-v6.txt" "✘" "nonempty"          "путь к файлу"                       "Путь к кэшу getProxyConfigV6 (IPv6)"
_catalog "general" "proxy_config_v6_url"      "string" "https://core.telegram.org/getProxyConfigV6" "✘" "url" "https://..."                       "URL для загрузки getProxyConfigV6 (IPv6)"
_catalog "general" "ad_tag"                   "string" ""       "✔" "custom:_validate_ad_tag"               "32 hex-символа"                     "Рекламная метка от @MTProxyBot (32 hex-символа)"
_catalog "general" "middle_proxy_nat_probe"   "bool"   "true"   "✘" "bool"                                    "true/false"                         "STUN-проверка NAT для обнаружения публичного IP"
_catalog "general" "stun_nat_probe_concurrency" "usize" "8"     "✘" "range:1:64"                             "1..64"                              "Макс. параллельных STUN-тестов"
_catalog "general" "middle_proxy_pool_size"   "usize"  "8"      "✘" "range:1:1024"                           "1..1024"                            "Размер пула ME writer"
_catalog "general" "middle_proxy_warm_standby" "usize" "16"     "✘" "range:0:1024"                           "0..1024"                            "Кол-во резервных ME-подключений"
_catalog "general" "me_init_retry_attempts"   "u32"    "0"      "✘" "range:0:1000000"                        "0 = неограничено"                   "Кол-во попыток инициализации ME (0 = бесконечно)"
_catalog "general" "me2dc_fallback"           "bool"   "true"   "✘" "bool"                                    "true/false"                         "Разрешить fallback на прямой DC, когда ME недоступен"
_catalog "general" "me2dc_fast"               "bool"   "false"  "✘" "bool"                                    "true/false"                         "Быстрый ME→Direct fallback для новых сессий"
_catalog "general" "me_keepalive_enabled"     "bool"   "true"   "✘" "bool"                                    "true/false"                         "Включить ME keepalive"
_catalog "general" "me_keepalive_interval_secs" "u64"  "8"      "✘" "range:1:3600"                           "секунды"                            "Интервал ME keepalive в секундах"
_catalog "general" "me_keepalive_jitter_secs" "u64"    "2"      "✘" "range:0:300"                            "секунды"                            "Джиттер keepalive в секундах"
_catalog "general" "me_keepalive_payload_random" "bool" "true"  "✘" "bool"                                    "true/false"                         "Случайный payload в keepalive-пакетах"
_catalog "general" "rpc_proxy_req_every"      "u64"    "0"      "✘" "custom:_validate_rpc_proxy_req"         "0 или 10..300"                      "Интервал RPC_PROXY_REQ (0 = отключено, иначе 10..300)"
_catalog "general" "tg_connect"               "u64"    "10"     "✘" "range:1:600"                            "секунды"                            "Таймаут подключения к Telegram upstream"
_catalog "general" "upstream_connect_retry_attempts" "u32" "2"  "✘" "range:1:100"                            "1..100"                             "Кол-во попыток подключения к upstream"
_catalog "general" "upstream_connect_retry_backoff_ms" "u64" "100" "✘" "range:0:60000"                       "миллисекунды"                       "Задержка между попытками подключения к upstream"
_catalog "general" "upstream_connect_budget_ms" "u64"  "3000"   "✘" "range:1:60000"                          "миллисекунды"                       "Общий лимит времени на одну попытку upstream"
_catalog "general" "upstream_unhealthy_fail_threshold" "u32" "5" "✘" "range:1:1000"                          "1..1000"                            "Кол-во неудач до пометки upstream как нездорового"
_catalog "general" "upstream_connect_failfast_hard_errors" "bool" "false" "✘" "bool"                          "true/false"                         "Пропускать повторные попытки при постоянных ошибках"
_catalog "general" "log_level"                "enum"   "normal" "✔" "enum:debug,verbose,normal,silent"       "debug/verbose/normal/silent"        "Уровень детализации логов"
_catalog "general" "disable_colors"           "bool"   "false"  "✘" "bool"                                    "true/false"                         "Отключить ANSI-цвета в логах"
_catalog "general" "rst_on_close"             "enum"   "off"    "✘" "enum:off,errors,always"                 "off/errors/always"                  "Поведение SO_LINGER(0) при закрытии соединений"
_catalog "general" "update_every"             "u64"    "300"    "✔" "range:1:86400"                          "секунды"                            "Интервал обновления ME-updater"
_catalog "general" "me_reinit_every_secs"     "u64"    "900"    "✔" "range:10:86400"                         "секунды"                            "Интервал повторной инициализации ME"
_catalog "general" "me_floor_mode"            "enum"   "adaptive" "✔" "enum:static,adaptive"                 "static/adaptive"                    "Режим нижнего порога ME writer"
_catalog "general" "me_writer_pick_mode"      "enum"   "p2c"    "✔" "enum:sorted_rr,p2c"                    "sorted_rr/p2c"                      "Режим выбора ME writer"
_catalog "general" "me_writer_pick_sample_size" "u8"   "3"      "✔" "range:2:4"                              "2..4"                               "Кол-во кандидатов для выбора writer в режиме p2c"
_catalog "general" "me_socks_kdf_policy"      "enum"   "strict" "✔" "enum:strict,compat"                    "strict/compat"                      "Политика KDF для ME-handshake"
_catalog "general" "me_bind_stale_mode"       "enum"   "ttl"    "✔" "enum:never,ttl,always"                 "never/ttl/always"                   "Политика биндов к устаревшим writer"
_catalog "general" "me_bind_stale_ttl_secs"   "u64"    "90"     "✔" "range:0:86400"                          "секунды"                            "TTL для биндов к устаревшим writer (режим ttl)"
_catalog "general" "me_instadrain"            "bool"   "false"  "✔" "bool"                                    "true/false"                         "Принудительно удалять устаревшие writer сразу"
_catalog "general" "me_pool_drain_threshold"  "u64"    "32"     "✔" "range:0:10000"                          "0 = отключено"                      "Макс. устаревших writer перед принудительным закрытием"
_catalog "general" "me_pool_drain_ttl_secs"   "u64"    "90"     "✔" "range:0:86400"                          "секунды, 0 = отключено"             "Drain-TTL для устаревших ME writer"
_catalog "general" "proxy_secret_len_max"     "usize"  "256"    "✔" "range:32:4096"                          "32..4096 байт"                      "Макс. длина proxy-secret"
_catalog "general" "hardswap"                 "bool"   "true"   "✔" "bool"                                    "true/false"                         "Стратегия ME-hardswap на основе генерации"
_catalog "general" "me_config_stable_snapshots" "u8"   "2"      "✔" "range:1:255"                            "1..255"                             "Кол-во одинаковых снимков ME перед применением"
_catalog "general" "me_config_apply_cooldown_secs" "u64" "300"  "✔" "range:0:86400"                          "секунды, 0 = без cooldown"          "Время восстановления между обновлениями ME endpoint map"
_catalog "general" "proxy_secret_stable_snapshots" "u8" "2"     "✔" "range:1:255"                            "1..255"                             "Кол-во одинаковых proxy-secret снимков для ротации"
_catalog "general" "proxy_secret_rotate_runtime" "bool" "true"  "✔" "bool"                                    "true/false"                         "Включить runtime ротацию proxy-secret"
_catalog "general" "me_reinit_singleflight"   "bool"   "true"   "✔" "bool"                                    "true/false"                         "Упорядочивать циклы повторной инициализации ME"
_catalog "general" "me_reinit_coalesce_window_ms" "u64" "200"   "✔" "range:0:60000"                          "миллисекунды"                       "Время объединения триггеров перед reinit"
_catalog "general" "me_deterministic_writer_sort" "bool" "true" "✔" "bool"                                    "true/false"                         "Детерминированная сортировка при выборе writer"
_catalog "general" "me_route_backpressure_enabled" "bool" "false" "✔" "bool"                                  "true/false"                         "Адаптивные таймауты при backpressure"
_catalog "general" "me_route_fairshare_enabled" "bool" "false"  "✔" "bool"                                    "true/false"                         "Справедливое распределение нагрузки маршрутизации"
_catalog "general" "me_route_no_writer_mode"  "enum"   "hybrid_async_persistent" "✘" "enum:async_recovery_failfast,inline_recovery_legacy,hybrid_async_persistent" "async_recovery_failfast/inline_recovery_legacy/hybrid_async_persistent" "Поведение маршрута без доступных writer"
_catalog "general" "me_adaptive_floor_idle_secs" "u64" "90"     "✔" "range:0:86400"                          "секунды"                            "Время простоя для снижения adaptive floor"
_catalog "general" "me_adaptive_floor_writers_per_core_total" "u16" "48" "✔" "range:1:65535"                  "1..65535"                           "Лимит writer на ядро CPU в adaptive режиме"
_catalog "general" "me_adaptive_floor_max_active_writers_global" "u32" "256" "✔" "range:1:65535"              "1..65535"                           "Глобальный лимит активных ME writer"
_catalog "general" "me_adaptive_floor_max_warm_writers_global" "u32" "256" "✔" "range:1:65535"                "1..65535"                           "Глобальный лимит warm ME writer"
_catalog "general" "me_pool_min_fresh_ratio"  "f32"    "0.8"    "✔" "custom:_validate_f32_0_1"               "0.0..1.0"                           "Мин. коэффициент свежего покрытия DC перед drain"
_catalog "general" "me_single_endpoint_shadow_writers" "u8" "2" "✔" "range:0:32"                              "0..32"                              "Доп. резервные writer для DC с одним endpoint"
_catalog "general" "me_single_endpoint_outage_mode_enabled" "bool" "true" "✔" "bool"                          "true/false"                         "Агрессивное восстановление при сбое единственного endpoint"
_catalog "general" "me_single_endpoint_outage_disable_quarantine" "bool" "true" "✔" "bool"                     "true/false"                         "Игнорировать карантин endpoint в outage-режиме"
_catalog "general" "me_single_endpoint_outage_backoff_min_ms" "u64" "250" "✔" "range:1:60000"                  "миллисекунды > 0"                   "Мин. задержка reconnect backoff в outage-режиме"
_catalog "general" "me_single_endpoint_outage_backoff_max_ms" "u64" "3000" "✔" "range:1:300000"               "миллисекунды > min"                 "Макс. задержка reconnect backoff в outage-режиме"

# ── general.modes ─────────────────────────────────────────────
_catalog "general.modes" "classic"  "bool" "false" "✘" "bool" "true/false" "Классический режим MTProxy"
_catalog "general.modes" "secure"   "bool" "false" "✘" "bool" "true/false" "Защищённый режим (dd-ссылки)"
_catalog "general.modes" "tls"      "bool" "true"  "✘" "bool" "true/false" "Режим TLS (ee-ссылки)"

# ── general.links ─────────────────────────────────────────────
_catalog "general.links" "public_host" "string" ""    "✘" "any"           "домен или IP"  "Публичный хост для tg://-ссылок"
_catalog "general.links" "public_port" "u16"    ""    "✘" "range:1:65535" "1..65535"      "Публичный порт для tg://-ссылок"

# ── general.telemetry ─────────────────────────────────────────
_catalog "general.telemetry" "core_enabled"  "bool"  "true"   "✔" "bool"                    "true/false"            "Включить метрики ядра"
_catalog "general.telemetry" "user_enabled"  "bool"  "true"   "✔" "bool"                    "true/false"            "Включить метрики по пользователям"
_catalog "general.telemetry" "me_level"      "enum"  "normal" "✔" "enum:silent,normal,debug" "silent/normal/debug"  "Уровень телеметрии Middle-End"

# ── network ───────────────────────────────────────────────────
_catalog "network" "ipv4"              "bool"  "true"  "✘" "bool"          "true/false"            "Включить IPv4-подключения"
_catalog "network" "ipv6"              "bool"  "false" "✘" "bool"          "true/false"            "Включить IPv6-подключения"
_catalog "network" "prefer"            "u8"    "4"     "✘" "enum:4,6"     "4/6"                   "Предпочтительный IP-протокол"
_catalog "network" "multipath"         "bool"  "false" "✘" "bool"          "true/false"            "Включить multipath сетевое поведение"
_catalog "network" "stun_use"          "bool"  "true"  "✘" "bool"          "true/false"            "Глобальный переключатель STUN"
_catalog "network" "stun_tcp_fallback" "bool"  "true"  "✘" "bool"          "true/false"            "Резервный TCP для STUN если UDP недоступен"
_catalog "network" "cache_public_ip_path" "string" "cache/public_ip.txt" "✘" "nonempty"  "путь"   "Путь к кэшу определённого публичного IP"

# ── server ────────────────────────────────────────────────────
_catalog "server" "port"                         "u16"    "443"   "✘" "range:1:65535"                         "1..65535"                           "Порт прослушивания прокси"
_catalog "server" "listen_addr_ipv4"             "string" "0.0.0.0" "✘" "ipv4"                               "IPv4-адрес"                         "Прослушиваемый IPv4-адрес"
_catalog "server" "listen_addr_ipv6"             "string" "::"    "✘" "any"                                   "IPv6-адрес или ::"                  "Прослушиваемый IPv6-адрес"
_catalog "server" "listen_unix_sock"             "string" ""      "✘" "any"                                   "путь к unix-сокету"                 "Путь к Unix-сокету для прослушивания"
_catalog "server" "listen_unix_sock_perm"        "string" ""      "✘" "custom:_validate_octal_perm"           "0666/0777/0600 и т.д."              "Права доступа для Unix-сокета (восьмеричная строка)"
_catalog "server" "listen_tcp"                   "bool"   ""      "✘" "bool"                                  "true/false (или пусто = авто)"      "Явное включение/отключение TCP-прослушивания"
_catalog "server" "client_mss"                   "string" ""      "✘" "custom:_validate_client_mss"           "extreme-low/tspu/2in8/88..4096"     "MSS для входящих TCP-клиентов"
_catalog "server" "proxy_protocol"               "bool"   "false" "✘" "bool"                                  "true/false"                         "Включить PROXY protocol от HAProxy"
_catalog "server" "proxy_protocol_header_timeout_ms" "u64" "500"  "✘" "range:1:60000"                         "миллисекунды > 0"                   "Таймаут чтения PROXY-заголовка"
_catalog "server" "metrics_port"                 "u16"    ""      "✘" "range:1:65535"                         "1..65535"                           "Порт endpoint метрик Prometheus"
_catalog "server" "metrics_listen"               "string" ""      "✘" "custom:_validate_ipport"               "IP:PORT"                            "Полный адрес метрик (переопределяет metrics_port)"
_catalog "server" "max_connections"              "u32"    "10000" "✘" "range:0:10000000"                      "0 = без ограничений"                "Макс. одновременных клиентских соединений"
_catalog "server" "accept_permit_timeout_ms"     "u64"    "250"   "✘" "range:0:60000"                         "0 = без ограничений"                "Таймаут ожидания разрешения на подключение"
_catalog "server" "listen_backlog"               "u32"    "1024"  "✘" "range:0:65535"                         "0 = системный дефолт"               "Значение backlog для listen(2)"

# ── server.conntrack_control ──────────────────────────────────
_catalog "server.conntrack_control" "inline_conntrack_control" "bool"  "true"      "✘" "bool"                          "true/false"                      "Главный переключатель conntrack-control"
_catalog "server.conntrack_control" "mode"                     "enum"  "tracked"   "✘" "enum:tracked,notrack,hybrid"   "tracked/notrack/hybrid"          "Режим conntrack"
_catalog "server.conntrack_control" "backend"                  "enum"  "auto"      "✘" "enum:auto,nftables,iptables"   "auto/nftables/iptables"          "Backend для notrack-правил"
_catalog "server.conntrack_control" "profile"                  "enum"  "balanced"  "✘" "enum:conservative,balanced,aggressive" "conservative/balanced/aggressive" "Профиль давления conntrack"
_catalog "server.conntrack_control" "pressure_high_watermark_pct" "u8" "85"        "✘" "range:1:100"                  "1..100"                          "Порог входа в pressure mode (%)"
_catalog "server.conntrack_control" "pressure_low_watermark_pct"  "u8" "70"        "✘" "range:1:99"                   "1..99 < high"                    "Порог выхода из pressure mode (%)"
_catalog "server.conntrack_control" "delete_budget_per_sec"    "u64"   "4096"      "✘" "range:1:1000000"              "1..1000000"                      "Макс. удалений conntrack в секунду"

# ── server.api ────────────────────────────────────────────────
_catalog "server.api" "enabled"                   "bool"   "true"         "✘" "bool"                          "true/false"                         "Включить REST API"
_catalog "server.api" "listen"                    "string" "0.0.0.0:9091" "✘" "custom:_validate_ipport"       "IP:PORT"                            "Адрес биндинга API"
_catalog "server.api" "auth_header"               "string" ""             "✘" "any"                           "Bearer TOKEN или пусто"             "Ожидаемый Authorization заголовок"
_catalog "server.api" "request_body_limit_bytes"  "usize"  "65536"        "✘" "range:1:104857600"             "байты > 0"                          "Макс. размер тела HTTP-запроса"
_catalog "server.api" "minimal_runtime_enabled"   "bool"   "true"         "✘" "bool"                          "true/false"                         "Включить minimal runtime snapshot"
_catalog "server.api" "minimal_runtime_cache_ttl_ms" "u64" "1000"         "✘" "range:0:60000"                 "0 = без кэша"                       "TTL minimal runtime snapshot"
_catalog "server.api" "runtime_edge_enabled"      "bool"   "false"        "✘" "bool"                          "true/false"                         "Включить runtime edge endpoint"
_catalog "server.api" "runtime_edge_cache_ttl_ms" "u64"    "1000"         "✘" "range:0:60000"                 "миллисекунды"                       "TTL кэша runtime edge payload"
_catalog "server.api" "runtime_edge_top_n"        "usize"  "10"           "✘" "range:1:1000"                  "1..1000"                            "Top-N для edge-рейтинга"
_catalog "server.api" "runtime_edge_events_capacity" "usize" "256"        "✘" "range:16:4096"                 "16..4096"                           "Ёмкость кольцевого буфера edge-событий"
_catalog "server.api" "read_only"                 "bool"   "false"        "✘" "bool"                          "true/false"                         "Режим только чтение для API"
_catalog "server.api" "gray_action"               "enum"   "drop"         "✘" "enum:drop,api,200"             "drop/api/200"                       "Политика API в ограниченных состояниях"

# ── timeouts ──────────────────────────────────────────────────
_catalog "timeouts" "client_first_byte_idle_secs"               "u64" "300"  "✘" "range:0:86400"  "0 = отключено"                      "Макс. ожидание первого байта от клиента"
_catalog "timeouts" "client_handshake"                           "u64" "30"   "✘" "range:1:3600"   "секунды > 0"                        "Таймаут начального handshake клиента"
_catalog "timeouts" "relay_idle_policy_v2_enabled"               "bool" "true" "✘" "bool"          "true/false"                         "Политика простоя клиента v2"
_catalog "timeouts" "relay_client_idle_soft_secs"                "u64" "120"  "✘" "range:1:86400"  "секунды > 0"                        "Мягкий порог простоя клиента в relay"
_catalog "timeouts" "relay_client_idle_hard_secs"                "u64" "360"  "✘" "range:1:86400"  "секунды >= soft"                    "Жёсткий порог простоя клиента в relay"
_catalog "timeouts" "relay_idle_grace_after_downstream_activity_secs" "u64" "30" "✘" "range:0:86400" "секунды"                          "Дополнительная отсрочка простоя после downstream активности"
_catalog "timeouts" "client_keepalive"                           "u64" "15"   "✘" "range:0:86400"  "секунды"                            "Таймаут keepalive клиента"
_catalog "timeouts" "client_ack"                                 "u64" "90"   "✘" "range:0:86400"  "секунды"                            "Таймаут ACK от клиента"
_catalog "timeouts" "me_one_retry"                               "u8"  "12"   "✘" "range:0:255"    "0..255"                             "Лимит быстрых попыток reconnect для DC с одним endpoint"
_catalog "timeouts" "me_one_timeout_ms"                          "u64" "1200" "✘" "range:1:60000"  "миллисекунды"                       "Таймаут одной быстрой попытки reconnect"

# ── censorship ────────────────────────────────────────────────
_catalog "censorship" "tls_domain"                      "string" "petrovich.ru" "✘" "custom:_validate_tls_domain"         "домен (без пробелов и /)"           "Основной FakeTLS домен"
_catalog "censorship" "tls_domains"                     "string[]" "[]"         "✘" "custom:_validate_domain_list"        "домен1,домен2,домен3"               "Дополнительные TLS-домены для поддержки старых ссылок и нескольких ee-ссылок"
_catalog "censorship" "unknown_sni_action"              "enum"   "drop"         "✘" "enum:drop,mask,accept,reject_handshake" "drop/mask/accept/reject_handshake" "Действие при неизвестном SNI"
_catalog "censorship" "mask"                            "bool"   "true"         "✘" "bool"                                "true/false"                         "Включить маскировку трафика"
_catalog "censorship" "mask_host"                       "string" ""             "✘" "any"                                 "хост или пусто"                     "Хост mask-бэкенда (по умолчанию = tls_domain)"
_catalog "censorship" "mask_port"                       "u16"    "443"          "✘" "range:1:65535"                       "1..65535"                           "Порт mask-бэкенда"
_catalog "censorship" "mask_unix_sock"                  "string" ""             "✘" "any"                                 "путь к unix-сокету"                 "Unix-сокет mask-бэкенда (взаимоисключает mask_host)"
_catalog "censorship" "fake_cert_len"                   "usize"  "2048"         "✘" "range:512:65536"                     "512..65536"                         "Длина синтетического cert payload"
_catalog "censorship" "tls_emulation"                   "bool"   "true"         "✘" "bool"                                "true/false"                         "Эмуляция TLS из кэшированных реальных сайтов"
_catalog "censorship" "tls_front_dir"                   "string" "tlsfront"     "✘" "nonempty"                            "путь"                               "Директория кэша TLS-front"
_catalog "censorship" "server_hello_delay_min_ms"       "u64"    "0"            "✘" "range:0:30000"                       "миллисекунды"                       "Мин. задержка ServerHello"
_catalog "censorship" "server_hello_delay_max_ms"       "u64"    "0"            "✘" "range:0:30000"                       "миллисекунды < handshake*1000"      "Макс. задержка ServerHello"
_catalog "censorship" "tls_new_session_tickets"         "u8"     "0"            "✘" "range:0:255"                         "0..255"                             "Кол-во NewSessionTicket после handshake"
_catalog "censorship" "tls_full_cert_ttl_secs"          "u64"    "90"           "✘" "range:0:86400"                       "секунды"                            "TTL отправки полного cert payload"
_catalog "censorship" "serverhello_compact"             "bool"   "false"        "✘" "bool"                                "true/false"                         "Компактный ServerHello профиль"
_catalog "censorship" "alpn_enforce"                    "bool"   "true"         "✘" "bool"                                "true/false"                         "Принудительный ALPN по предпочтениям клиента"
_catalog "censorship" "mask_proxy_protocol"             "u8"     "0"            "✘" "range:0:2"                           "0 = откл, 1 = v1, 2 = v2"          "PROXY protocol к mask-бэкенду"
_catalog "censorship" "mask_shape_hardening"            "bool"   "true"         "✘" "bool"                                "true/false"                         "Усиление shape-channel маскировки"
_catalog "censorship" "mask_shape_hardening_aggressive_mode" "bool" "false"     "✘" "bool"                                "true/false"                         "Агрессивный режим shape-hardening"
_catalog "censorship" "mask_shape_bucket_floor_bytes"   "usize"  "512"          "✘" "range:1:67108864"                    "байты > 0"                          "Мин. размер группы данных при shape-hardening"
_catalog "censorship" "mask_shape_bucket_cap_bytes"     "usize"  "4096"         "✘" "range:1:67108864"                    "байты >= floor"                     "Макс. размер группы данных при shape-hardening"
_catalog "censorship" "mask_shape_above_cap_blur"       "bool"   "false"        "✘" "bool"                                "true/false"                         "Добавлять random-bytes к данным выше cap"
_catalog "censorship" "mask_shape_above_cap_blur_max_bytes" "usize" "512"       "✘" "range:1:1048576"                     "1..1048576"                         "Макс. доп. байт при above-cap blur"
_catalog "censorship" "mask_relay_max_bytes"            "usize"  "5242880"      "✘" "range:1:67108864"                    "байты > 0"                          "Макс. байт на fallback-маскировке (per direction)"
_catalog "censorship" "mask_relay_timeout_ms"           "u64"    "60000"        "✘" "range:1:3600000"                     "миллисекунды >= idle_timeout"       "Жёсткий лимит времени fallback-маскировки"
_catalog "censorship" "mask_relay_idle_timeout_ms"      "u64"    "5000"         "✘" "range:1:3600000"                     "миллисекунды <= relay_timeout"      "Idle-таймаут в маскирующем прокси"
_catalog "censorship" "mask_classifier_prefetch_timeout_ms" "u64" "5"          "✘" "range:5:50"                          "5..50"                              "Таймаут prefetch первых данных при маскировке"
_catalog "censorship" "mask_timing_normalization_enabled"   "bool" "false"      "✘" "bool"                                "true/false"                         "Нормализация таймингов маскировки"
_catalog "censorship" "mask_timing_normalization_floor_ms"  "u64"  "0"         "✘" "range:0:60000"                       "миллисекунды"                       "Нижняя граница нормализации таймингов"
_catalog "censorship" "mask_timing_normalization_ceiling_ms" "u64" "0"         "✘" "range:0:60000"                       "миллисекунды >= floor"              "Верхняя граница нормализации таймингов"

# ── censorship.tls_fetch ──────────────────────────────────────
_catalog "censorship.tls_fetch" "strict_route"            "bool" "true"  "✘" "bool"           "true/false"         "Завершать TLS-запрос с ошибкой если upstream недоступен"
_catalog "censorship.tls_fetch" "attempt_timeout_ms"      "u64"  "5000"  "✘" "range:1:60000"  "миллисекунды > 0"   "Таймаут одной попытки получения TLS-профиля"
_catalog "censorship.tls_fetch" "total_budget_ms"         "u64"  "15000" "✘" "range:1:300000" "миллисекунды > 0"   "Общий бюджет на все попытки получения TLS-данных"
_catalog "censorship.tls_fetch" "grease_enabled"          "bool" "false" "✘" "bool"           "true/false"         "GREASE-значения в ClientHello"
_catalog "censorship.tls_fetch" "deterministic"           "bool" "false" "✘" "bool"           "true/false"         "Детерминированная случайность ClientHello (для отладки)"
_catalog "censorship.tls_fetch" "profile_cache_ttl_secs"  "u64"  "600"  "✘" "range:0:86400"  "0 = без кэша"       "TTL кэша победившего TLS-профиля"

# ── access ────────────────────────────────────────────────────
_catalog "access" "user_max_tcp_conns_global_each"   "usize" "0"              "✔" "range:0:1000000"            "0 = отключено"              "Глобальный лимит TCP соединений на пользователя"
_catalog "access" "user_max_unique_ips_global_each"  "usize" "0"              "✔" "range:0:1000000"            "0 = отключено"              "Глобальный лимит уникальных IP на пользователя"
_catalog "access" "user_max_unique_ips_mode"         "enum"  "active_window"  "✔" "enum:active_window,time_window,combined" "active_window/time_window/combined" "Режим учёта уникальных IP"
_catalog "access" "user_max_unique_ips_window_secs"  "u64"   "30"             "✔" "range:1:86400"              "секунды > 0"                "Размер временного окна уникальных IP"
_catalog "access" "replay_check_len"                 "usize" "65536"          "✘" "range:0:10000000"           "0 = отключено"              "Кол-во запоминаемых сообщений для защиты от replay"
_catalog "access" "replay_window_secs"               "u64"   "120"            "✘" "range:0:86400"              "секунды"                    "Окно памяти replay-защиты"
_catalog "access" "ignore_time_skew"                 "bool"  "false"          "✘" "bool"                       "true/false"                 "Отключить проверку временного смещения для replay"

# ── upstreams ─────────────────────────────────────────────────
# Upstreams — только через nano, это массив таблиц TOML
# Для меню не предназначено

# ── Список доступных секций для меню ─────────────────────────
_EXPERT_SECTIONS=(
    "general"
    "general.modes"
    "general.links"
    "general.telemetry"
    "network"
    "server"
    "server.conntrack_control"
    "server.api"
    "timeouts"
    "censorship"
    "censorship.tls_fetch"
    "access"
)

# ── Валидаторы ────────────────────────────────────────────────
_validate_bool() {
    [[ "$1" =~ ^(true|false)$ ]] || { echo "Допустимо: true или false"; return 1; }
}

_validate_range() {
    local val="$1" min="$2" max="$3"
    [[ "$val" =~ ^[0-9]+$ ]] || { echo "Должно быть целым числом"; return 1; }
    [ "$val" -ge "$min" ] && [ "$val" -le "$max" ] || { echo "Диапазон: ${min}..${max}"; return 1; }
}

_validate_url() {
    [[ "$1" =~ ^https?:// ]] || { echo "Должно начинаться с http:// или https://"; return 1; }
}

_validate_ipv4() {
    if [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'; local -a o=($1)
        for _oc in "${o[@]}"; do
            [ "$_oc" -ge 0 ] && [ "$_oc" -le 255 ] || { echo "Некорректный IPv4"; return 1; }
        done
        return 0
    fi
    echo "Некорректный IPv4-адрес"; return 1
}

_validate_ipport() {
    local _h="${1%:*}" _p="${1##*:}"
    [[ "$_p" =~ ^[0-9]+$ ]] && [ "$_p" -ge 1 ] && [ "$_p" -le 65535 ] || { echo "Формат: HOST:PORT (порт 1..65535)"; return 1; }
    [ -n "$_h" ] || { echo "Хост не может быть пустым"; return 1; }
}

_validate_nonempty() {
    [ -n "$1" ] || { echo "Значение не может быть пустым"; return 1; }
}

_validate_octal_perm() {
    [[ "$1" =~ ^0[0-7]{3}$ ]] || { echo "Формат: 0666, 0777, 0600 и т.д."; return 1; }
}

_validate_ad_tag() {
    [ -z "$1" ] && return 0
    [[ "$1" =~ ^[0-9a-fA-F]{32}$ ]] || { echo "Должно быть ровно 32 hex-символа или пустым"; return 1; }
}

_validate_client_mss() {
    case "$1" in
        ""|extreme-low|tspu|2in8) return 0 ;;
        *) [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 88 ] && [ "$1" -le 4096 ] && return 0 ;;
    esac
    echo "Допустимо: extreme-low, tspu, 2in8 или число 88..4096"; return 1
}

_validate_tls_domain() {
    [ -n "$1" ] || { echo "Домен не может быть пустым"; return 1; }
    [[ "$1" =~ [[:space:]] ]] && { echo "Домен не может содержать пробелы"; return 1; }
    [[ "$1" =~ / ]] && { echo "Домен не может содержать /"; return 1; }
    [[ "$1" =~ \. ]] || { echo "Домен должен содержать точку"; return 1; }
}

_validate_domain_list() {
    [ -z "$1" ] && { echo "Список доменов не может быть пустым"; return 1; }

    local oldIFS="$IFS"
    IFS=','
    read -ra _domains <<< "$1"
    IFS="$oldIFS"

    [ "${#_domains[@]}" -eq 0 ] && { echo "Не удалось разобрать список доменов"; return 1; }

    local _d
    for _d in "${_domains[@]}"; do
        # trim spaces
        _d="${_d#"${_d%%[![:space:]]*}"}"
        _d="${_d%"${_d##*[![:space:]]}"}"
        _validate_tls_domain "$_d" || return 1
    done

    return 0
}

_validate_rpc_proxy_req() {
    [ "$1" = "0" ] && return 0
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 10 ] && [ "$1" -le 300 ] && return 0
    echo "Допустимо: 0 или 10..300"; return 1
}

_validate_f32_0_1() {
    [[ "$1" =~ ^[0-9]*\.?[0-9]+$ ]] || { echo "Должно быть числом 0.0..1.0"; return 1; }
    awk -v v="$1" 'BEGIN{exit !(v >= 0.0 && v <= 1.0)}' || { echo "Диапазон: 0.0..1.0"; return 1; }
}

# Главная функция валидации по типу из каталога
_expert_validate() {
    local validator="$1" value="$2"
    [ -z "$validator" ] && return 0

    case "$validator" in
        bool)
            _validate_bool "$value" ;;
        range:*:*)
            local _min="${validator#range:}"; local _max="${_min#*:}"; _min="${_min%%:*}"
            _validate_range "$value" "$_min" "$_max" ;;
        enum:*)
            local _opts="${validator#enum:}"
            IFS=',' read -ra _arr <<< "$_opts"
            for _o in "${_arr[@]}"; do [ "$value" = "$_o" ] && return 0; done
            echo "Допустимые значения: ${_opts//,/ / }"; return 1 ;;
        url)            _validate_url "$value" ;;
        ipv4)           _validate_ipv4 "$value" ;;
        ipport)         _validate_ipport "$value" ;;
        path|nonempty)  _validate_nonempty "$value" ;;
        any)            return 0 ;;
        custom:*)
            local _func="${validator#custom:}"
            if declare -f "$_func" &>/dev/null; then
                "$_func" "$value"
            else
                log_warn "Валидатор '$_func' не найден, пропускаем"
                return 0
            fi ;;
        *) return 0 ;;
    esac
}

# Поиск записи в каталоге
_expert_find() {
    local section="$1" key="$2"
    local _entry
    for _entry in "${_EXPERT_CATALOG[@]}"; do
        local _s="${_entry%%|*}"; local _rest="${_entry#*|}"
        local _k="${_rest%%|*}"
        if [ "$_s" = "$section" ] && [ "$_k" = "$key" ]; then
            echo "$_entry"; return 0
        fi
    done
    return 1
}

# Получить список ключей секции
_expert_keys_of_section() {
    local section="$1"
    for _entry in "${_EXPERT_CATALOG[@]}"; do
        local _s="${_entry%%|*}"; local _rest="${_entry#*|}"
        local _k="${_rest%%|*}"
        [ "$_s" = "$section" ] && echo "$_k"
    done
}

# Парсинг полей записи
_expert_parse() {
    local _e="$1"
    EXPERT_P_SECTION="${_e%%|*}";   _e="${_e#*|}"
    EXPERT_P_KEY="${_e%%|*}";       _e="${_e#*|}"
    EXPERT_P_TYPE="${_e%%|*}";      _e="${_e#*|}"
    EXPERT_P_DEFAULT="${_e%%|*}";   _e="${_e#*|}"
    EXPERT_P_HOT="${_e%%|*}";       _e="${_e#*|}"
    EXPERT_P_VALIDATOR="${_e%%|*}"; _e="${_e#*|}"
    EXPERT_P_HINT="${_e%%|*}";      _e="${_e#*|}"
    EXPERT_P_DESC="$_e"
}
