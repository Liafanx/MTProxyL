#!/bin/bash
# MTProxyL — Docker: сборка, запуск, управление контейнером

install_docker() {
    if command -v docker &>/dev/null; then
        log_success "Docker уже установлен"
        return 0
    fi

    log_info "Установка Docker..."
    _wait_apt
    local os; os=$(detect_os)
    case "$os" in
        debian) curl -fsSL https://get.docker.com | sh ;;
        rhel)
            local _repo="https://download.docker.com/linux/centos/docker-ce.repo"
            [ -f /etc/os-release ] && . /etc/os-release
            [ "$ID" = "fedora" ] && _repo="https://download.docker.com/linux/fedora/docker-ce.repo"
            if command -v dnf &>/dev/null; then
                # config-manager живёт в dnf-plugins-core: на минимальных
                # образах RHEL/AlmaLinux/Rocky его нет, и подключение репо
                # молча проваливалось. Последний рубеж — скачать .repo сами.
                dnf install -y dnf-plugins-core &>/dev/null || true
                dnf config-manager --add-repo "$_repo" &>/dev/null \
                    || dnf config-manager addrepo --from-repofile="$_repo" &>/dev/null \
                    || curl -fsSL "$_repo" -o /etc/yum.repos.d/docker-ce.repo \
                    || { log_error "Не удалось подключить репозиторий Docker"; return 1; }
                # --allowerasing: на RHEL9-производных containerd.io конфликтует
                # с runc из подсистемы podman
                dnf install -y docker-ce docker-ce-cli containerd.io \
                    || dnf install -y --allowerasing docker-ce docker-ce-cli containerd.io
            else
                yum install -y yum-utils
                yum-config-manager --add-repo "$_repo" \
                    || curl -fsSL "$_repo" -o /etc/yum.repos.d/docker-ce.repo \
                    || { log_error "Не удалось подключить репозиторий Docker"; return 1; }
                yum install -y docker-ce docker-ce-cli containerd.io
            fi ;;
        alpine) apk add --no-cache docker docker-compose ;;
        *) log_error "ОС не поддерживается. Установите Docker вручную."; return 1 ;;
    esac

    systemctl enable docker 2>/dev/null || true
    systemctl start docker 2>/dev/null || true
    command -v docker &>/dev/null && log_success "Docker установлен" || { log_error "Установка Docker не удалась"; return 1; }
}

wait_for_docker() {
    local retries=10
    while [ $retries -gt 0 ]; do
        docker info &>/dev/null && return 0
        sleep 1; retries=$((retries - 1))
    done
    log_error "Docker не отвечает"
    return 1
}

build_telemt_image() {
    local force="${1:-false}"
    local commit="${TELEMT_COMMIT}"
    local version="${TELEMT_MIN_VERSION}-${commit}"

    if [ "$force" = "false" ] && docker image inspect "${DOCKER_IMAGE_BASE}:${version}" &>/dev/null; then
        return 0
    fi

    # Стратегия 1: Pull из реестра
    log_info "Загрузка telemt v${version}..."
    if docker pull "${REGISTRY_IMAGE}:${version}" 2>/dev/null; then
        docker tag "${REGISTRY_IMAGE}:${version}" "${DOCKER_IMAGE_BASE}:${version}"
        docker tag "${DOCKER_IMAGE_BASE}:${version}" "${DOCKER_IMAGE_BASE}:latest" 2>/dev/null || true
        log_success "Загружен telemt v${version}"
        echo "$version" > "${INSTALL_DIR}/.telemt_version"
        return 0
    fi

    # Стратегия 2: Pull latest — ТОЛЬКО при обычной установке, не при явном выборе версии
    if [ "$force" != "source" ] && [ "$force" != "true" ]; then
        log_info "Точная версия не найдена, пробуем latest..."
        if docker pull "${REGISTRY_IMAGE}:latest" 2>/dev/null; then
            docker tag "${REGISTRY_IMAGE}:latest" "${DOCKER_IMAGE_BASE}:${version}"
            docker tag "${DOCKER_IMAGE_BASE}:${version}" "${DOCKER_IMAGE_BASE}:latest" 2>/dev/null || true
            log_success "Загружен telemt (latest)"
            echo "$version" > "${INSTALL_DIR}/.telemt_version"
            return 0
        fi
    fi

    # Стратегия 3: Сборка из исходников
    log_warn "Образ недоступен, компиляция из исходников..."
    local build_dir
    build_dir=$(mktemp -d "${TMPDIR:-/tmp}/mtproxyl-build.XXXXXX")

    cat > "${build_dir}/Dockerfile" << 'DOCKERFILE_EOF'
FROM rust:1-bookworm AS builder
ARG TELEMT_COMMIT
RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*
RUN git clone "https://github.com/telemt/telemt.git" /build
WORKDIR /build
RUN git checkout "${TELEMT_COMMIT}"
ENV CARGO_PROFILE_RELEASE_LTO=true CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 CARGO_PROFILE_RELEASE_DEBUG=false
RUN cargo build --release && strip target/release/telemt 2>/dev/null || true && cp target/release/telemt /telemt

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /telemt /usr/local/bin/telemt
RUN chmod +x /usr/local/bin/telemt
STOPSIGNAL SIGINT
ENTRYPOINT ["telemt"]
DOCKERFILE_EOF

    log_info "Компиляция (первая сборка может занять несколько минут)..."
    local _platform=""
    case "$(uname -m)" in
        x86_64|amd64) _platform="linux/amd64" ;;
        aarch64|arm64) _platform="linux/arm64" ;;
    esac

    local _build_cmd=(docker build --build-arg "TELEMT_COMMIT=${commit}" -t "${DOCKER_IMAGE_BASE}:${version}")
    [ -n "$_platform" ] && _build_cmd+=(--platform "$_platform")
    _build_cmd+=("$build_dir")

    if "${_build_cmd[@]}"; then
        docker tag "${DOCKER_IMAGE_BASE}:${version}" "${DOCKER_IMAGE_BASE}:latest" 2>/dev/null || true
        log_success "Собран telemt v${version}"
        echo "$version" > "${INSTALL_DIR}/.telemt_version"
    else
        log_error "Сборка не удалась — нужно минимум 2ГБ RAM"
        rm -rf "$build_dir"
        return 1
    fi
    rm -rf "$build_dir"
}

get_telemt_version() {
    engine_is_binary && { binengine_version; return; }
    local ver
    ver=$(cat "${INSTALL_DIR}/.telemt_version" 2>/dev/null)
    [ -n "$ver" ] && { echo "$ver"; return; }
    ver=$(docker images --format '{{.Tag}}' "${DOCKER_IMAGE_BASE}" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    [ -n "$ver" ] && { echo "$ver"; return; }
    echo "unknown"
}

get_docker_image() {
    local ver; ver=$(get_telemt_version)
    [ "$ver" = "unknown" ] && echo "${DOCKER_IMAGE_BASE}:latest" || echo "${DOCKER_IMAGE_BASE}:${ver}"
}

is_proxy_running() {
    if [ "${MTPROXYL_MODE:-manager}" != "manager" ]; then
        case "${DETECTED_MODE:-unknown}" in
            docker|mtproxymax)
                [ -n "$DETECTED_CONTAINER" ] || return 1
                # docker ps показывает и контейнер в состоянии Restarting —
                # падающая в цикле цель выглядела бы как «РАБОТАЕТ»
                local _tst
                _tst=$(docker inspect -f '{{.State.Running}}|{{.State.Restarting}}' "$DETECTED_CONTAINER" 2>/dev/null) || return 1
                [ "$_tst" = "true|false" ] ;;
            local|config_only|manual)
                # Есть юнит — он и есть источник правды: после `systemctl stop`
                # цель остановлена, даже если на хосте виден процесс telemt из
                # контейнера (в хостовом PID namespace они тоже видны).
                if _telemt_unit_exists; then
                    systemctl is-active --quiet telemt.service 2>/dev/null && return 0
                    # Юнит неактивен — работающей цель считаем, только если
                    # telemt подняли мимо systemd, прямо на хосте.
                    _telemt_host_pids >/dev/null
                    return
                fi
                _telemt_host_pids >/dev/null ;;
            *) return 1 ;;
        esac
        return
    fi
    engine_is_binary && { binengine_running; return; }
    # docker ps показывает и контейнер в состоянии Restarting, поэтому
    # падающий в цикле контейнер выглядел как «РАБОТАЕТ». Смотрим состояние.
    local _st
    _st=$(docker inspect -f '{{.State.Running}}|{{.State.Restarting}}' "$CONTAINER_NAME" 2>/dev/null) || return 1
    [ "$_st" = "true|false" ]
}

# Состояние собственного контейнера: running|restarting|exited|created|absent
own_container_state() {
    engine_is_binary && { binengine_state; return; }
    command -v docker &>/dev/null || { echo "absent"; return; }
    local _running _restarting _status
    _status=$(docker inspect -f '{{.State.Status}}|{{.State.Running}}|{{.State.Restarting}}' "$CONTAINER_NAME" 2>/dev/null) || { echo "absent"; return; }
    IFS='|' read -r _status _running _restarting <<< "$_status"
    if [ "$_restarting" = "true" ]; then echo "restarting"; return; fi
    if [ "$_running" = "true" ]; then echo "running"; return; fi
    echo "${_status:-absent}"
}

# Короткая причина, почему свой контейнер не работает — только когда это
# действительно проблема. Чистая остановка (exited с кодом 0) — обычное
# состояние после «Остановить», её не показываем и логами не пугаем.
own_container_problem() {
    engine_is_binary && { binengine_problem; return; }
    local _st; _st=$(own_container_state)
    case "$_st" in
        running|absent|created) return 1 ;;
    esac

    local _code
    _code=$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER_NAME" 2>/dev/null)
    [ "$_st" = "exited" ] && [ "${_code:-0}" = "0" ] && return 1

    # Берём последнюю строку, похожую на ошибку; если таких нет — просто
    # последнюю. Timestamp отрезаем, он в панели только мешает.
    local _log _err
    _log=$(docker logs --tail 20 "$CONTAINER_NAME" 2>&1 | tr -d '\r')
    _err=$(grep -iE 'error|panic|fatal|denied|refused|in use|failed' <<< "$_log" | tail -1)
    [ -z "$_err" ] && _err=$(tail -1 <<< "$_log")
    _err=$(sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z?[[:space:]]*//' <<< "$_err" | cut -c1-100)

    echo "${_st} (exit=${_code:-?})${_err:+: ${_err}}"
}

get_proxy_uptime() {
    is_proxy_running || { echo "0"; return; }
    if [ "${MTPROXYL_MODE:-manager}" != "manager" ]; then
        case "${DETECTED_MODE:-unknown}" in
            docker|mtproxymax)
                local started_at
                started_at=$(docker inspect --format '{{.State.StartedAt}}' "$DETECTED_CONTAINER" 2>/dev/null)
                [ -z "$started_at" ] && { echo "0"; return; }
                local start_epoch now_epoch
                start_epoch=$(_iso_to_epoch "$started_at")
                now_epoch=$(date +%s)
                [ "$start_epoch" -gt 0 ] 2>/dev/null && echo $((now_epoch - start_epoch)) || echo "0" ;;
            local|config_only|manual)
                # ActiveEnterTimestamp остаётся и после остановки службы,
                # поэтому берём его только у активного юнита; процесс,
                # запущенный мимо systemd, считаем по времени жизни.
                local since_epoch now_epoch _pid
                if _telemt_unit_exists && systemctl is-active --quiet telemt.service 2>/dev/null; then
                    since_epoch=$(systemctl show telemt.service -p ActiveEnterTimestamp --value 2>/dev/null | xargs -I{} date -d {} +%s 2>/dev/null)
                    now_epoch=$(date +%s)
                    [ -n "$since_epoch" ] && [ "$since_epoch" -gt 0 ] 2>/dev/null && echo $((now_epoch - since_epoch)) || echo "0"
                    return
                fi
                local _et=""
                _pid=$(_telemt_host_pids | head -1)
                [ -n "$_pid" ] && _et=$(ps -o etimes= -p "$_pid" 2>/dev/null | tr -cd '0-9')
                echo "${_et:-0}" ;;
            *) echo "0" ;;
        esac
        return
    fi
    engine_is_binary && { binengine_uptime; return; }
    local started_at
    started_at=$(docker inspect --format '{{.State.StartedAt}}' "$CONTAINER_NAME" 2>/dev/null)
    [ -z "$started_at" ] && { echo "0"; return; }
    local start_epoch now_epoch
    start_epoch=$(_iso_to_epoch "$started_at")
    now_epoch=$(date +%s)
    [ "$start_epoch" -gt 0 ] 2>/dev/null && echo $((now_epoch - start_epoch)) || echo "0"
}

# ── Абстракция цели: работает и на своём контейнере, и на чужой цели ──
# _telemt_unit_exists() определён в lib/detect.sh — им же пользуется
# detect_telemt(), чтобы остановленная служба определялась как local.

restart_target() {
    if [ "${MTPROXYL_MODE:-manager}" != "manager" ]; then
        case "${DETECTED_MODE:-unknown}" in
            docker)
                log_info "Перезапуск контейнера ${DETECTED_CONTAINER}..."
                docker restart "$DETECTED_CONTAINER" &>/dev/null \
                    && log_success "Контейнер перезапущен" \
                    || log_warn "Не удалось перезапустить контейнер" ;;
            mtproxymax)
                command -v mtproxymax &>/dev/null && mtproxymax restart &>/dev/null \
                    && log_success "mtproxymax перезапущен" \
                    || log_warn "Не удалось перезапустить mtproxymax" ;;
            local|config_only|manual)
                if _telemt_unit_exists; then
                    log_info "Перезапуск telemt.service..."
                    systemctl restart telemt.service &>/dev/null \
                        && log_success "telemt.service перезапущен" \
                        || log_warn "Не удалось перезапустить telemt.service"
                elif _telemt_host_pids >/dev/null; then
                    # shellcheck disable=SC2046
                    kill -HUP $(_telemt_host_pids) 2>/dev/null \
                        && log_success "Процессу telemt отправлен SIGHUP" \
                        || log_warn "Не удалось отправить сигнал telemt"
                else
                    log_warn "telemt не запущен и systemd-юнит не найден — запустите цель вручную"
                fi ;;
            *) log_warn "Нет способа перезапустить обнаруженную цель (${DETECTED_MODE:-unknown})" ;;
        esac
        return
    fi
    restart_proxy_container
}

start_target() {
    if [ "${MTPROXYL_MODE:-manager}" != "manager" ]; then
        if is_proxy_running; then
            log_info "Цель уже запущена"
            return 0
        fi
        case "${DETECTED_MODE:-unknown}" in
            docker)
                [ -n "$DETECTED_CONTAINER" ] || { log_warn "Контейнер цели не определён"; return 1; }
                log_info "Запуск контейнера ${DETECTED_CONTAINER}..."
                docker start "$DETECTED_CONTAINER" &>/dev/null \
                    && log_success "Контейнер запущен" \
                    || log_warn "Не удалось запустить контейнер" ;;
            mtproxymax)
                command -v mtproxymax &>/dev/null && mtproxymax start &>/dev/null \
                    && log_success "mtproxymax запущен" \
                    || log_warn "Не удалось запустить mtproxymax" ;;
            local|config_only|manual)
                if _telemt_unit_exists; then
                    log_info "Запуск telemt.service..."
                    systemctl start telemt.service &>/dev/null \
                        && log_success "telemt.service запущен" \
                        || { log_warn "Не удалось запустить telemt.service"
                             journalctl -u telemt.service -n 10 --no-pager 2>/dev/null | sed 's/^/    /'; }
                else
                    log_warn "systemd-юнит telemt.service не найден — запустите цель вручную"
                fi ;;
            *) log_warn "Нет способа запустить обнаруженную цель (${DETECTED_MODE:-unknown})" ;;
        esac
        return
    fi
    start_proxy_container
}

stop_target() {
    if [ "${MTPROXYL_MODE:-manager}" != "manager" ]; then
        case "${DETECTED_MODE:-unknown}" in
            docker)
                log_info "Остановка контейнера ${DETECTED_CONTAINER}..."
                docker stop "$DETECTED_CONTAINER" &>/dev/null && log_success "Контейнер остановлен" || log_warn "Не удалось остановить контейнер" ;;
            mtproxymax)
                command -v mtproxymax &>/dev/null && mtproxymax stop &>/dev/null && log_success "mtproxymax остановлен" || log_warn "Не удалось остановить mtproxymax" ;;
            local|config_only|manual)
                if _telemt_unit_exists; then
                    systemctl stop telemt.service &>/dev/null && log_success "telemt.service остановлен" || log_warn "Не удалось остановить telemt.service"
                    # Служба остановлена, а процесс на хосте всё ещё жив: его
                    # запускали мимо systemd либо он не завершился. Без этого
                    # предупреждения цель осталась бы «работающей» без причины.
                    if _telemt_host_pids >/dev/null; then
                        log_warn "На хосте остался процесс telemt (PID: $(_telemt_host_pids | tr '\n' ' ')) — запущен не через systemd"
                    fi
                elif _telemt_host_pids >/dev/null; then
                    # shellcheck disable=SC2046
                    kill $(_telemt_host_pids) 2>/dev/null \
                        && log_success "Процесс telemt остановлен" \
                        || log_warn "Не удалось остановить процесс telemt"
                else
                    log_warn "Процесс telemt на хосте не найден"
                fi ;;
            *) log_warn "Нет способа остановить обнаруженную цель (${DETECTED_MODE:-unknown})" ;;
        esac
        return
    fi
    stop_proxy_container
}

# Ctrl+C во время просмотра логов должен возвращать в меню, а не убивать
# скрипт: journalctl -f / docker logs -f получают SIGINT из того же
# терминала, поэтому на время стрима ставим свой обработчик INT.
show_target_logs() {
    local _tail="${1:-30}"
    local _rc=0
    trap ':' INT
    _show_target_logs_stream "$_tail" || _rc=$?
    trap - INT
    echo ""
    return $_rc
}

_show_target_logs_stream() {
    local _tail="${1:-30}"
    if [ "${MTPROXYL_MODE:-manager}" != "manager" ]; then
        case "${DETECTED_MODE:-unknown}" in
            docker|mtproxymax) docker logs -f --tail "$_tail" "$DETECTED_CONTAINER" 2>&1 ;;
            local|config_only|manual)
                if _telemt_unit_exists; then
                    journalctl -u telemt.service -f -n "$_tail"
                else
                    log_warn "Логи недоступны: процесс telemt не привязан к systemd-юниту"
                fi ;;
            *) log_warn "Логи недоступны для обнаруженной цели (${DETECTED_MODE:-unknown})" ;;
        esac
        return
    fi
    engine_is_binary && { journalctl -u "$ENGINE_SERVICE" -f -n "$_tail"; return; }
    docker logs -f --tail "$_tail" "$CONTAINER_NAME" 2>&1
}

reload_target_config() {
    if [ "${MTPROXYL_MODE:-manager}" != "manager" ]; then
        case "${DETECTED_MODE:-unknown}" in
            docker)     docker kill -s SIGHUP "$DETECTED_CONTAINER" 2>/dev/null || restart_target ;;
            local|config_only|manual)
                # shellcheck disable=SC2046
                if _telemt_unit_exists && systemctl is-active --quiet telemt.service 2>/dev/null; then
                    systemctl kill -s HUP telemt.service 2>/dev/null || restart_target
                elif _telemt_host_pids >/dev/null; then
                    kill -HUP $(_telemt_host_pids) 2>/dev/null || restart_target
                else
                    restart_target
                fi ;;
            *)          restart_target ;;
        esac
        return
    fi
    reload_proxy_config
}

run_proxy_container() {
    if engine_is_binary; then
        binengine_ensure_installed || { log_error "Не удалось поставить бинарник движка"; return 1; }
    else
        build_telemt_image || { log_error "Не удалось собрать образ"; return 1; }
    fi

    # Ensure we have at least one secret
    if [ ${#SECRETS_LABELS[@]} -eq 0 ]; then
        log_info "Нет секретов, создаём default..."
        secret_add "default" "" "true"
    fi

    # Проверяем metrics port — если занят, выбираем свободный
    if ! is_port_available "${PROXY_METRICS_PORT:-9090}"; then
        local _current_metrics="${PROXY_METRICS_PORT:-9090}"
        local _new_metrics
        _new_metrics=$(find_free_metrics_port 9090 9199) || _new_metrics=""
        if [ -n "$_new_metrics" ] && [ "$_new_metrics" != "$_current_metrics" ]; then
            log_warn "Порт метрик ${_current_metrics} занят — переключаемся на ${_new_metrics}"
            PROXY_METRICS_PORT="$_new_metrics"
            save_settings
        elif [ -z "$_new_metrics" ]; then
            log_error "Не удалось найти свободный порт для метрик в диапазоне 9090..9199"
            return 1
        fi
    fi

    # Generate config (один вызов с обработкой ошибки)
    generate_telemt_config || { log_error "Ошибка генерации конфига"; return 1; }

    if engine_is_binary; then
        binengine_launch || return 1
    else
        docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

        log_info "Запуск прокси на порту ${PROXY_PORT}..."
        local _args=(
            --name "$CONTAINER_NAME"
            --restart unless-stopped
            --network host
            --log-opt max-size=10m --log-opt max-file=3
        )
        [ -n "${PROXY_CPUS}" ] && _args+=(--cpus "${PROXY_CPUS}")
        [ -n "${PROXY_MEMORY}" ] && _args+=(--memory "${PROXY_MEMORY}" --memory-swap "${PROXY_MEMORY}")

        local _run_err=""
        _run_err=$(docker run -d "${_args[@]}" \
            --ulimit nofile=65535:65535 \
            -v "${CONFIG_DIR}/config.toml:/etc/telemt.toml:ro" \
            "$(get_docker_image)" /etc/telemt.toml 2>&1) || {
                log_error "Не удалось запустить контейнер"
                echo "$_run_err" | sed 's/^/    /' >&2
                return 1
            }
    fi

    sleep 2
    if is_proxy_running; then
        log_success "Прокси запущен на порту ${PROXY_PORT}"

        local server_ip; server_ip=$(get_public_ip)
        [ -n "$server_ip" ] && {
            echo ""
            local i
            for i in "${!SECRETS_LABELS[@]}"; do
                [ "${SECRETS_ENABLED[$i]}" = "true" ] || continue
                local _kind _fs
                while IFS='|' read -r _kind _fs; do
                    [ -n "$_fs" ] || continue
                    echo -e "  ${BOLD}${SECRETS_LABELS[$i]}${NC} ${DIM}($(link_kind_title "$_kind")):${NC} ${CYAN}tg://proxy?server=${server_ip}&port=${PROXY_PORT}&secret=${_fs}${NC}"
                done <<< "$(build_link_secrets "${SECRETS_KEYS[$i]}")"
            done
            echo ""
        }
        return 0
    elif engine_is_binary; then
        log_error "Движок не запустился — проверьте логи: journalctl -u ${ENGINE_SERVICE} -n 50"
        journalctl -u "$ENGINE_SERVICE" -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
        return 1
    else
        log_error "Контейнер не запустился — проверьте логи: docker logs ${CONTAINER_NAME}"
        docker ps -a --filter "name=^/${CONTAINER_NAME}$" --format '    status={{.Status}}  image={{.Image}}' 2>/dev/null || true
        return 1
    fi
}

# Полностью убрать собственный контейнер (образ и конфиг остаются).
# Нужно при переходе в reanimator и когда контейнер менеджера больше
# не используется, но продолжает держать порт.
remove_own_container() {
    engine_is_binary && { binengine_remove_service; return; }
    _docker_remove_own_container
}

_docker_remove_own_container() {
    command -v docker &>/dev/null || { log_info "Docker не установлен — контейнера нет"; return 0; }
    local _st
    _st=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null) || _st="absent"
    if [ "$_st" = "absent" ]; then
        log_info "Контейнер ${CONTAINER_NAME} отсутствует"
        return 0
    fi
    flush_traffic_to_disk 2>/dev/null || true
    docker update --restart=no "$CONTAINER_NAME" &>/dev/null || true
    docker stop --timeout 10 "$CONTAINER_NAME" &>/dev/null || true
    if docker rm -f "$CONTAINER_NAME" &>/dev/null; then
        log_success "Контейнер ${CONTAINER_NAME} остановлен и удалён"
        log_info "Образ и конфиг сохранены — контейнер поднимется заново при запуске"
        return 0
    fi
    log_error "Не удалось удалить контейнер ${CONTAINER_NAME}"
    return 1
}

stop_proxy_container() {
    engine_is_binary && { binengine_stop; return; }
    if is_proxy_running; then
        flush_traffic_to_disk 2>/dev/null || true
        docker update --restart=no "$CONTAINER_NAME" &>/dev/null || true
        docker stop --timeout 10 "$CONTAINER_NAME" 2>/dev/null && log_success "Прокси остановлен" || { log_error "Не удалось остановить"; return 1; }
    else
        log_info "Прокси не запущен"
    fi
}

start_proxy_container() {
    engine_is_binary && { binengine_start; return; }
    if is_proxy_running; then
        log_info "Прокси уже запущен"
        return 0
    fi
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    run_proxy_container
}

restart_proxy_container() {
    engine_is_binary && { binengine_restart; return; }
    stop_proxy_container 2>/dev/null || true
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    run_proxy_container
}

reload_proxy_config() {
    generate_telemt_config || { log_error "Ошибка генерации конфига"; return 1; }
    flush_traffic_to_disk 2>/dev/null || true
    if engine_is_binary; then
        binengine_reload
    else
        is_proxy_running && docker kill -s SIGHUP "$CONTAINER_NAME" 2>/dev/null || true
    fi
    log_info "Конфиг обновлён (горячая перезагрузка)"
}
