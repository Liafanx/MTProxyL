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
                dnf config-manager --add-repo "$_repo" 2>/dev/null || dnf config-manager --addrepo "$_repo" 2>/dev/null
                dnf install -y docker-ce docker-ce-cli containerd.io
            else
                yum install -y yum-utils
                yum-config-manager --add-repo "$_repo"
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
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"
}

get_proxy_uptime() {
    is_proxy_running || { echo "0"; return; }
    local started_at
    started_at=$(docker inspect --format '{{.State.StartedAt}}' "$CONTAINER_NAME" 2>/dev/null)
    [ -z "$started_at" ] && { echo "0"; return; }
    local start_epoch now_epoch
    start_epoch=$(_iso_to_epoch "$started_at")
    now_epoch=$(date +%s)
    [ "$start_epoch" -gt 0 ] 2>/dev/null && echo $((now_epoch - start_epoch)) || echo "0"
}

run_proxy_container() {
    build_telemt_image || { log_error "Не удалось собрать образ"; return 1; }

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

local _run_err
    _run_err=$(docker run -d "${_args[@]}" \
        --ulimit nofile=65535:65535 \
        -v "${CONFIG_DIR}/config.toml:/etc/telemt.toml:ro" \
        "$(get_docker_image)" /etc/telemt.toml 2>&1) || {
            log_error "Не удалось запустить контейнер"
            echo "$_run_err" | sed 's/^/    /' >&2
            return 1
        }

    sleep 2
    if is_proxy_running; then
        log_success "Прокси запущен на порту ${PROXY_PORT}"

        local server_ip; server_ip=$(get_public_ip)
        [ -n "$server_ip" ] && {
            echo ""
            local i
            for i in "${!SECRETS_LABELS[@]}"; do
                [ "${SECRETS_ENABLED[$i]}" = "true" ] || continue
                local fs; fs=$(build_faketls_secret "${SECRETS_KEYS[$i]}")
                echo -e "  ${BOLD}${SECRETS_LABELS[$i]}:${NC} ${CYAN}tg://proxy?server=${server_ip}&port=${PROXY_PORT}&secret=${fs}${NC}"
            done
            echo ""
        }
        return 0
    else
        log_error "Контейнер не запустился — проверьте логи: docker logs ${CONTAINER_NAME}"
        return 1
    fi
}

stop_proxy_container() {
    if is_proxy_running; then
        flush_traffic_to_disk 2>/dev/null || true
        docker update --restart=no "$CONTAINER_NAME" &>/dev/null || true
        docker stop --timeout 10 "$CONTAINER_NAME" 2>/dev/null && log_success "Прокси остановлен" || { log_error "Не удалось остановить"; return 1; }
    else
        log_info "Прокси не запущен"
    fi
}

start_proxy_container() {
    if is_proxy_running; then
        log_info "Прокси уже запущен"
        return 0
    fi
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    run_proxy_container
}

restart_proxy_container() {
    stop_proxy_container 2>/dev/null || true
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    run_proxy_container
}

reload_proxy_config() {
    generate_telemt_config || { log_error "Ошибка генерации конфига"; return 1; }
    flush_traffic_to_disk 2>/dev/null || true
    is_proxy_running && docker kill -s SIGHUP "$CONTAINER_NAME" 2>/dev/null || true
    log_info "Конфиг обновлён (горячая перезагрузка)"
}
