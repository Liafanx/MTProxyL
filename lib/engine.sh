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
    engine_is_binary && { binengine_version; return; }
    local ver
    ver=$(cat "${INSTALL_DIR}/.telemt_version" 2>/dev/null)
    [ -n "$ver" ] && { echo "$ver"; return; }
    ver=$(docker images --format '{{.Tag}}' "${DOCKER_IMAGE_BASE}" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    [ -n "$ver" ] && { echo "$ver"; return; }
    echo "unknown"
}

# Версии, лежащие на диске: к ним откатываются без сети.
engine_local_versions() {
    if engine_is_binary; then
        local _cur _prev
        _cur=$(binengine_version)
        [ -n "$_cur" ] && [ "$_cur" != "unknown" ] && echo "$_cur"
        if [ -x "$ENGINE_PREV_BIN" ]; then
            _prev=$(tr -d ' \t\r\n' < "$ENGINE_PREV_VERSION_FILE" 2>/dev/null)
            [ -n "$_prev" ] || _prev=$("$ENGINE_PREV_BIN" --version 2>/dev/null | awk '{print $NF}')
            [ -n "$_prev" ] && echo "$_prev"
        fi
    else
        docker images --format '{{.Tag}}' "${DOCKER_IMAGE_BASE}" 2>/dev/null \
            | grep -E '^[0-9]+\.' | sort -rV
    fi
}

# Всё, что нужно панели одним документом: чем движок носится, что стоит,
# что лежит на диске и что есть в релизах.
engine_versions_json() {
    local _cur; _cur=$(engine_current_version)
    printf '{"backend":"%s","current":"%s","binary":%s,"docker_available":%s,' \
        "$(json_escape "$(engine_backend)")" "$(json_escape "$_cur")" \
        "$(engine_is_binary && echo true || echo false)" \
        "$(command -v docker >/dev/null && echo true || echo false)"

    printf '"local":['
    local _v _first=1
    # Текущая и предыдущая совпадают, если обновлялись на ту же версию —
    # в списке отката такой пункт был бы обманом.
    while IFS= read -r _v; do
        [ -n "$_v" ] || continue
        [ $_first -eq 1 ] || printf ','
        _first=0
        printf '"%s"' "$(json_escape "$_v")"
    done <<< "$(engine_local_versions 2>/dev/null | awk 'NF && !seen[$0]++')"

    printf '],"releases":['
    local _tag _name _date _f2=1
    while IFS='|' read -r _tag _name _date; do
        [ -n "$_tag" ] || continue
        [ $_f2 -eq 1 ] || printf ','
        _f2=0
        printf '{"tag":"%s","name":"%s","date":"%s"}' \
            "$(json_escape "$_tag")" "$(json_escape "$_name")" "$(json_escape "$_date")"
    done <<< "$(engine_list_releases 2>/dev/null)"
    printf ']}\n'
}

# Обновить до конкретной версии
engine_update_to() {
    local target_tag="$1"
    [ -z "$target_tag" ] && { log_error "Укажите версию"; return 1; }
    engine_is_binary && { binengine_update_to "$target_tag"; return; }

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
        local yn; read_line yn "  ${BOLD}Перезапустить прокси? [Y/n]:${NC} "
        if [[ ! "$yn" =~ ^[nN] ]]; then
            load_secrets
            restart_proxy_container
        fi
    fi
}

# Откат к предыдущей версии
# Аргумент — тег из локальных образов или --yes: панель спрашивает сама,
# и второй раз спрашивать её нечем.
engine_rollback() {
    local _want="${1:-}"
    engine_is_binary && { binengine_rollback "$_want"; return; }
    local images
    images=$(docker images --format '{{.Tag}}' "${DOCKER_IMAGE_BASE}" 2>/dev/null | grep -E '^[0-9]+\.' | sort -rV)

    if [ -z "$images" ]; then
        log_error "Нет доступных образов для отката"
        return 1
    fi

    local current
    current=$(engine_current_version)

    if [ -n "$_want" ] && [ "$_want" != "--yes" ]; then
        grep -qxF "$_want" <<< "$images" || {
            log_error "Образа ${_want} на диске нет"
            return 1
        }
        [ "$_want" = "$current" ] && { log_info "Это уже текущая версия"; return 0; }
        echo "$_want" > "${INSTALL_DIR}/.telemt_version"
        log_success "Версия переключена на ${_want}"
        if is_proxy_running; then
            load_secrets
            restart_proxy_container
        fi
        return 0
    fi

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
    local choice; read_line choice "  ${BOLD}Номер версии для отката:${NC} "

    local selected
    selected=$(echo "$images" | sed -n "${choice}p")
    [ -z "$selected" ] && { log_error "Неверный номер"; return 1; }
    [ "$selected" = "$current" ] && { log_info "Это уже текущая версия"; return 0; }

    echo "$selected" > "${INSTALL_DIR}/.telemt_version"
    log_success "Версия переключена на ${selected}"

    if is_proxy_running; then
        local yn; read_line yn "  ${BOLD}Перезапустить прокси? [Y/n]:${NC} "
        if [[ ! "$yn" =~ ^[nN] ]]; then
            load_secrets
            restart_proxy_container
        fi
    fi
}

# Не трогаем используемые образы, latest, текущий и одну версию для отката.
_engine_cleanup_rows() {
    command -v docker >/dev/null || { log_error "Docker не установлен" >&2; return 1; }
    local _images _containers _used="" _current _repo _tag _id _size _versions="" _keep=""
    _images=$(docker image ls --no-trunc --format '{{.Repository}}|{{.Tag}}|{{.ID}}|{{.Size}}') || return 1
    _containers=$(docker ps -aq --no-trunc) || return 1
    if [ -n "$_containers" ]; then
        local -a _ids=()
        mapfile -t _ids <<< "$_containers"
        _used=$(docker inspect --format '{{.Image}}' "${_ids[@]}") || return 1
    fi
    local -A _protected=()
    while IFS= read -r _id; do [ -z "$_id" ] || _protected["$_id"]=1; done <<< "$_used"
    _current=$(cat "$INSTALL_DIR/.telemt_version" 2>/dev/null) || _current=""
    while IFS='|' read -r _repo _tag _id _size; do
        [ -n "$_id" ] || continue
        case "$_repo" in
            "$DOCKER_IMAGE_BASE"|"$REGISTRY_IMAGE")
                if [ "$_tag" = latest ] || { [ -n "$_current" ] && [ "$_tag" = "$_current" ]; }; then
                    _protected["$_id"]=1
                fi
                [[ "$_tag" =~ ^[0-9]+\. ]] && _versions+="${_tag}|${_id}"$'\n'
                ;;
            *) _protected["$_id"]=1 ;;
        esac
    done <<< "$_images"
    while IFS='|' read -r _tag _id; do
        [ -n "$_id" ] && [ -z "${_protected[$_id]:-}" ] || continue
        if [ -n "$_current" ] && [ "$(printf '%s\n%s\n' "${_tag%%-*}" "${_current%%-*}" | sort -V | head -1)" != "${_tag%%-*}" ]; then
            continue
        fi
        _keep="$_id"; break
    done < <(printf '%s' "$_versions" | sort -t'|' -k1,1Vr)
    [ -z "$_keep" ] || _protected["$_keep"]=1
    while IFS='|' read -r _repo _tag _id _size; do
        [ -n "$_id" ] && [ -z "${_protected[$_id]:-}" ] || continue
        case "$_repo" in "$DOCKER_IMAGE_BASE"|"$REGISTRY_IMAGE") ;; *) continue ;; esac
        [[ "$_tag" =~ ^[0-9]+\. ]] || continue
        printf '%s:%s|%s|%s\n' "$_repo" "$_tag" "$_id" "$_size"
    done <<< "$_images"
    return 0
}

engine_cleanup_images() {
    local _mode="${1:-}" _rows _ref _id _size _fresh _actual _failed=0 _removed=0
    case "$_mode" in ''|--yes|--json|--dry-run) ;; *) log_error "cleanup [--dry-run|--json|--yes]"; return 1 ;; esac
    _rows=$(_engine_cleanup_rows) || return 1
    if [ "$_mode" = --json ]; then
        local _sep=""
        printf '{"candidates":['
        while IFS='|' read -r _ref _id _size; do
            [ -n "$_ref" ] || continue
            printf '%s{"reference":"%s","id":"%s","size":"%s"}' "$_sep" \
                "$(json_escape "$_ref")" "$(json_escape "$_id")" "$(json_escape "$_size")"
            _sep=,
        done <<< "$_rows"
        printf ']}\n'
        return 0
    fi
    [ -n "$_rows" ] || { log_info "Нет неиспользуемых образов для очистки"; return 0; }
    log_info "Теги неиспользуемых образов к удалению:"
    while IFS='|' read -r _ref _id _size; do printf '  %s (%s)\n' "$_ref" "$_size"; done <<< "$_rows"
    log_info "Сохраняются используемые образы, latest, текущий и одна версия для отката. Общие слои могут остаться на диске"
    [ "$_mode" != --dry-run ] || return 0
    check_root
    if [ "$_mode" != --yes ]; then
        local _answer; read_line _answer "  Удалить перечисленные теги образов? [y/N]: "
        [[ "$_answer" =~ ^[yY] ]] || return 0
    fi
    while IFS='|' read -r _ref _id _size; do
        [ -n "$_ref" ] || continue
        _fresh=$(_engine_cleanup_rows) || return 1
        grep -qFx "${_ref}|${_id}|${_size}" <<< "$_fresh" || continue
        _actual=$(docker image inspect --format '{{.Id}}' "$_ref") || { _failed=1; continue; }
        [ "$_actual" = "$_id" ] || continue
        if docker image rm -- "$_ref"; then _removed=$((_removed + 1)); else _failed=1; fi
    done <<< "$_rows"
    log_info "Удалено тегов: $_removed. Для удалённых версий потребуется повторное скачивание"
    return "$_failed"
}

# CLI handler
handle_engine_command() {
    local subcmd="${1:-status}"
    shift 2>/dev/null || true
    _require_manager_mode || return 1

    case "$subcmd" in
        status)
            if [ "${1:-}" = "--json" ]; then
                engine_versions_json
                return 0
            fi
            echo -e "  ${BOLD}Движок Telemt${NC}"
            echo -e "  ${DIM}Носитель:${NC}   $(engine_backend_title)"
            echo -e "  ${DIM}Установлен:${NC}  v$(engine_current_version)"
            if engine_is_binary; then
                echo -e "  ${DIM}Бинарник:${NC}    ${ENGINE_BIN_PATH}"
                echo -e "  ${DIM}Служба:${NC}      ${ENGINE_SERVICE}.service"
            else
                echo -e "  ${DIM}Закреплён:${NC}   commit ${TELEMT_COMMIT}"
            fi
            ;;
        backend)
            engine_switch_backend "${1:-}"
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
                local choice; read_line choice "  ${BOLD}Номер версии для установки:${NC} "
                local selected_tag
                selected_tag=$(echo "$releases" | sed -n "${choice}p" | cut -d'|' -f1)
                [ -z "$selected_tag" ] && { log_error "Неверный номер"; return 1; }

                engine_update_to "$selected_tag"
            fi
            ;;
        rollback)
            check_root
            engine_rollback "${1:-}"
            ;;
        versions)
            engine_versions_json
            ;;
        cleanup)
            engine_cleanup_images "${1:-}"
            ;;
        rebuild)
            check_root
            if engine_is_binary; then
                log_info "Бинарный движок не собирается — перекачиваем текущую версию"
                binengine_fetch "$(binengine_version)" || return 1
                is_proxy_running && { load_secrets; restart_proxy_container; }
                return 0
            fi
            build_telemt_image true || return 1
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
            echo -e "  ${DIM}rollback [tag]${NC}  Откатить к предыдущей или к версии с диска"
            echo -e "  ${DIM}versions${NC}        Версии и релизы одним JSON"
            echo -e "  ${DIM}cleanup${NC}         Очистить неиспользуемые Docker-образы (с просмотром списка)"
            echo -e "  ${DIM}rebuild${NC}         Пересобрать образ / перекачать бинарник"
            echo -e "  ${DIM}backend <тип>${NC}   Сменить носитель движка: docker | binary"
            ;;
    esac
}
