#!/bin/bash
# MTProxyL — управление движком Telemt

# Получить список версий с GitHub
engine_list_releases() {
    local releases
    releases=$(curl -fsS --max-time 10 "https://api.github.com/repos/${TELEMT_GITHUB}/releases?per_page=20" 2>/dev/null) || {
        log_error "Не удалось получить список релизов"
        return 1
    }

    echo "$releases" | python3 -c "
import json, sys
try:
    releases = json.load(sys.stdin)
    for r in releases[:15]:
        tag = r.get('tag_name', '?')
        name = r.get('name', tag)
        date = r.get('published_at', '')[:10]
        pre = ' (pre-release)' if r.get('prerelease') else ''
        print(f'{tag}|{name}|{date}{pre}')
except:
    pass
" 2>/dev/null
}

# Получить текущую версию
engine_current_version() {
    local ver
    ver=$(cat "${INSTALL_DIR}/.telemt_version" 2>/dev/null)
    [ -n "$ver" ] && { echo "$ver"; return; }
    ver=$(docker images --format '{{.Tag}}' "${DOCKER_IMAGE_BASE}" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    [ -n "$ver" ] && { echo "$ver"; return; }
    echo "unknown"
}

# Обновить до конкретной версии
engine_update_to() {
    local target_tag="$1"
    [ -z "$target_tag" ] && { log_error "Укажите версию"; return 1; }

    log_info "Получение информации о версии ${target_tag}..."

    # Получить commit hash
    local release_info commit_hash
    release_info=$(curl -fsS --max-time 10 "https://api.github.com/repos/${TELEMT_GITHUB}/releases/tags/${target_tag}" 2>/dev/null)
    if [ -n "$release_info" ]; then
        commit_hash=$(echo "$release_info" | python3 -c "
import json, sys
try:
    r = json.load(sys.stdin)
    sha = r.get('target_commitish', '')[:7]
    print(sha if sha else '?')
except: print('?')
" 2>/dev/null)
    fi

    if [ -z "$commit_hash" ] || [ "$commit_hash" = "?" ]; then
        commit_hash=$(curl -fsS --max-time 10 "https://api.github.com/repos/${TELEMT_GITHUB}/git/ref/tags/${target_tag}" 2>/dev/null | \
            python3 -c "import json,sys; print(json.load(sys.stdin)['object']['sha'][:7])" 2>/dev/null) || true
    fi

    [ -z "$commit_hash" ] || [ "$commit_hash" = "?" ] && {
        log_warn "Не удалось определить commit hash, используем tag"
        commit_hash="${target_tag#v}"
    }

    local version_tag="${target_tag#v}-${commit_hash}"
    log_info "Сборка образа: ${version_tag}"

    local current_ver
    current_ver=$(engine_current_version)
    log_info "Текущая версия: ${current_ver}"

    # Стратегия 1: Pull exact tag
    log_info "Поиск готового образа ${version_tag}..."
    if docker pull "${REGISTRY_IMAGE}:${version_tag}" 2>/dev/null; then
        docker tag "${REGISTRY_IMAGE}:${version_tag}" "${DOCKER_IMAGE_BASE}:${version_tag}"
        docker tag "${DOCKER_IMAGE_BASE}:${version_tag}" "${DOCKER_IMAGE_BASE}:latest" 2>/dev/null || true
        echo "$version_tag" > "${INSTALL_DIR}/.telemt_version"
        log_success "Загружен telemt v${version_tag}"
    else
        # Стратегия 2: Source build (без fallback на latest)
        log_warn "Готовый образ не найден — сборка из исходников..."
        log_info "Это может занять несколько минут..."

        local old_commit="${TELEMT_COMMIT}"
        local old_version="${TELEMT_MIN_VERSION}"
        TELEMT_COMMIT="${commit_hash}"
        TELEMT_MIN_VERSION="${target_tag#v}"


        docker rmi "${DOCKER_IMAGE_BASE}:${version_tag}" >/dev/null 2>&1 || true
        if build_telemt_image source; then
            log_success "Движок собран: v${version_tag}"
        else
            log_error "Сборка не удалась"
            TELEMT_COMMIT="$old_commit"
            TELEMT_MIN_VERSION="$old_version"
            return 1
        fi
    fi

    # Предложить перезапуск
    if is_proxy_running; then
        echo -en "  ${BOLD}Перезапустить прокси? [Y/n]:${NC} "
        local yn; read -r yn
        if [[ ! "$yn" =~ ^[nN]$ ]]; then
            load_secrets
            restart_proxy_container
        fi
    fi
}

# Откат к предыдущей версии
engine_rollback() {
    local images
    images=$(docker images --format '{{.Tag}}' "${DOCKER_IMAGE_BASE}" 2>/dev/null | grep -E '^[0-9]+\.' | sort -rV)

    if [ -z "$images" ]; then
        log_error "Нет доступных образов для отката"
        return 1
    fi

    local current
    current=$(engine_current_version)

    echo ""
    draw_header "ДОСТУПНЫЕ ВЕРСИИ ДВИЖКА"
    echo ""
    local idx=0
    while IFS= read -r tag; do
        idx=$((idx + 1))
        if [ "$tag" = "$current" ]; then
            echo -e "  ${DIM}[$idx]${NC} ${BOLD}${tag}${NC} ${GREEN}← текущая${NC}"
        else
            echo -e "  ${DIM}[$idx]${NC} ${tag}"
        fi
    done <<< "$images"

    echo ""
    echo -en "  ${BOLD}Номер версии для отката:${NC} "
    local choice; read -r choice

    local selected
    selected=$(echo "$images" | sed -n "${choice}p")
    [ -z "$selected" ] && { log_error "Неверный номер"; return 1; }
    [ "$selected" = "$current" ] && { log_info "Это уже текущая версия"; return 0; }

    echo "$selected" > "${INSTALL_DIR}/.telemt_version"
    log_success "Версия переключена на ${selected}"

    if is_proxy_running; then
        echo -en "  ${BOLD}Перезапустить прокси? [Y/n]:${NC} "
        local yn; read -r yn
        if [[ ! "$yn" =~ ^[nN]$ ]]; then
            load_secrets
            restart_proxy_container
        fi
    fi
}

# CLI handler
handle_engine_command() {
    local subcmd="${1:-status}"
    shift 2>/dev/null || true

    case "$subcmd" in
        status)
            echo -e "  ${BOLD}Движок Telemt${NC}"
            echo -e "  ${DIM}Установлен:${NC}  v$(engine_current_version)"
            echo -e "  ${DIM}Закреплён:${NC}   commit ${TELEMT_COMMIT}"
            ;;
        list)
            echo ""
            draw_header "ДОСТУПНЫЕ ВЕРСИИ TELEMT"
            echo ""
            local releases
            releases=$(engine_list_releases)
            if [ -n "$releases" ]; then
                local current
                current=$(engine_current_version)
                printf "  ${BOLD}%-12s %-30s %-12s${NC}\n" "ТЕГ" "НАЗВАНИЕ" "ДАТА"
                echo -e "  ${DIM}$(_repeat '─' 56)${NC}"
                while IFS='|' read -r tag name date; do
                    local marker=""
                    [[ "$current" == *"${tag#v}"* ]] && marker=" ${GREEN}← текущая${NC}"
                    printf "  %-12s %-30s %-12s%b\n" "$tag" "$name" "$date" "$marker"
                done <<< "$releases"
            else
                log_error "Не удалось получить список"
            fi
            echo ""
            ;;
        update)
            check_root
            if [ -n "$1" ]; then
                engine_update_to "$1"
            else
                echo ""
                log_info "Получение списка версий..."
                local releases
                releases=$(engine_list_releases)
                [ -z "$releases" ] && { log_error "Не удалось получить список"; return 1; }

                echo ""
                local idx=0
                while IFS='|' read -r tag name date; do
                    idx=$((idx + 1))
                    echo -e "  ${DIM}[$idx]${NC} ${BOLD}${tag}${NC} — ${name} (${date})"
                done <<< "$releases"

                echo ""
                echo -en "  ${BOLD}Номер версии для установки:${NC} "
                local choice; read -r choice
                local selected_tag
                selected_tag=$(echo "$releases" | sed -n "${choice}p" | cut -d'|' -f1)
                [ -z "$selected_tag" ] && { log_error "Неверный номер"; return 1; }

                engine_update_to "$selected_tag"
            fi
            ;;
        rollback)
            check_root
            engine_rollback
            ;;
        rebuild)
            check_root
            build_telemt_image true
            if is_proxy_running; then
                load_secrets
                restart_proxy_container
            fi
            ;;
        *)
            echo -e "  ${BOLD}Использование:${NC} mtproxyl engine <команда>"
            echo ""
            echo -e "  ${DIM}status${NC}          Текущая версия"
            echo -e "  ${DIM}list${NC}            Список доступных версий"
            echo -e "  ${DIM}update [tag]${NC}    Обновить до версии"
            echo -e "  ${DIM}rollback${NC}        Откатить к предыдущей"
            echo -e "  ${DIM}rebuild${NC}         Пересобрать текущий образ"
            ;;
    esac
}
