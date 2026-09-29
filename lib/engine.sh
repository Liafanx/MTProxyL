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
    _is_reanimator && { target_engine_versions_json; return; }
    local _cur; _cur=$(engine_current_version)
    local _src=""
    engine_is_binary && _src=$(binengine_source 2>/dev/null)
    printf '{"backend":"%s","current":"%s","binary":%s,"docker_available":%s,"custom":%s,"custom_url":"%s",' \
        "$(json_escape "$(engine_backend)")" "$(json_escape "$_cur")" \
        "$(engine_is_binary && echo true || echo false)" \
        "$(command -v docker >/dev/null && echo true || echo false)" \
        "$([ -n "$_src" ] && echo true || echo false)" "$(json_escape "$_src")"

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
    _is_reanimator && { target_engine_update "$target_tag"; return; }
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
    _is_reanimator && { target_engine_rollback "$_want"; return; }
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
# ── Версия цели реаниматора ───────────────────────────────────
# Меняется только бинарник под telemt.service: конфиг и юнит цели не
# трогаются. Цель в Docker не обновляем — её версией управляет образ. Прошлый
# бинарник MTProxyL держит у себя, откат идёт без сети. Если новая версия не
# поднялась с конфигом цели, прежняя возвращается сама.
TARGET_ENGINE_DIR="${INSTALL_DIR:-/opt/mtproxyl}/target-engine"
TARGET_ENGINE_PREV="${TARGET_ENGINE_DIR}/telemt.prev"
TARGET_ENGINE_PREV_VERSION="${TARGET_ENGINE_DIR}/.version.prev"

_is_reanimator() { [ "${MTPROXYL_MODE:-manager}" = "reanimator" ]; }

# Бинарник цели: из ExecStart юнита, иначе по живому процессу.
target_engine_bin() {
    local _p _pid
    _p=$(systemctl show telemt.service -p ExecStart --value 2>/dev/null \
        | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -1)
    if [ -z "$_p" ] || [ ! -x "$_p" ]; then
        _pid=$(_telemt_host_pids 2>/dev/null | head -1)
        [ -n "$_pid" ] && _p=$(readlink -f "/proc/${_pid}/exe" 2>/dev/null)
    fi
    [ -n "$_p" ] && [ -f "$_p" ] && [ -x "$_p" ] || return 1
    echo "$_p"
}

_target_elf_version() {
    local _v
    _v=$(timeout 10 "$1" --version 2>/dev/null | awk 'tolower($0) ~ /telemt/ {print $NF; exit}')
    echo "${_v#v}"
}

target_engine_version() {
    local _b; _b=$(target_engine_bin) || return 1
    _target_elf_version "$_b"
}

# Пусто — версию цели менять можно; иначе причина, почему нельзя.
target_engine_unsupported_reason() {
    case "${DETECTED_MODE:-unknown}" in
        docker|mtproxymax)
            echo "Цель работает в Docker — её версией управляет образ контейнера"; return ;;
        local|config_only|manual) ;;
        *) echo "Цель не обнаружена: mtproxyl detect"; return ;;
    esac
    if ! command -v systemctl &>/dev/null || ! _telemt_unit_exists; then
        echo "Нет службы telemt.service — запустить новую версию нечем"; return
    fi
    local _b; _b=$(target_engine_bin) || { echo "Не найден бинарник из telemt.service"; return; }
    [ "$(od -An -tx1 -N4 "$_b" 2>/dev/null | tr -d ' \n')" = "7f454c46" ] \
        || echo "ExecStart службы — не бинарник telemt: ${_b}"
}

target_engine_local_versions() {
    local _v
    _v=$(target_engine_version 2>/dev/null) && [ -n "$_v" ] && echo "$_v"
    if [ -x "$TARGET_ENGINE_PREV" ]; then
        _v=$(tr -d ' \t\r\n' < "$TARGET_ENGINE_PREV_VERSION" 2>/dev/null)
        [ -n "$_v" ] || _v=$(_target_elf_version "$TARGET_ENGINE_PREV")
        [ -n "$_v" ] && echo "$_v"
    fi
}

target_engine_versions_json() {
    local _reason _bin="" _cur=""
    _reason=$(target_engine_unsupported_reason)
    if [ -z "$_reason" ]; then
        _bin=$(target_engine_bin); _cur=$(target_engine_version)
    fi
    printf '{"backend":"target","target":true,"supported":%s,"reason":"%s","bin_path":"%s","config_path":"%s","current":"%s","binary":true,"docker_available":false,"custom":false,"custom_url":"",' \
        "$([ -z "$_reason" ] && echo true || echo false)" "$(json_escape "$_reason")" \
        "$(json_escape "$_bin")" "$(json_escape "${DETECTED_CONFIG_PATH:-}")" "$(json_escape "$_cur")"
    printf '"local":['
    local _v _first=1
    if [ -z "$_reason" ]; then
        while IFS= read -r _v; do
            [ -n "$_v" ] || continue
            [ $_first -eq 1 ] || printf ','
            _first=0
            printf '"%s"' "$(json_escape "$_v")"
        done <<< "$(target_engine_local_versions 2>/dev/null | awk 'NF && !seen[$0]++')"
    fi
    printf '],"releases":['
    local _tag _name _date _f2=1
    if [ -z "$_reason" ]; then
        while IFS='|' read -r _tag _name _date; do
            [ -n "$_tag" ] || continue
            [ $_f2 -eq 1 ] || printf ','
            _f2=0
            printf '{"tag":"%s","name":"%s","date":"%s"}' \
                "$(json_escape "$_tag")" "$(json_escape "$_name")" "$(json_escape "$_date")"
        done <<< "$(engine_list_releases 2>/dev/null)"
    fi
    printf ']}\n'
}

# Кладёт файл на место бинарника цели с владельцем, правами и capabilities
# прежнего: официальный установщик выдаёт их через setcap.
_target_engine_place() {
    local _src="$1" _bin="$2" _caps
    _caps=$(getcap "$_bin" 2>/dev/null | sed -E 's#^[^ ]+ (= )?##')
    install -m 0755 "$_src" "${_bin}.mtproxyl-new" || return 1
    chown --reference="$_bin" "${_bin}.mtproxyl-new" 2>/dev/null || true
    chmod --reference="$_bin" "${_bin}.mtproxyl-new" 2>/dev/null || true
    [ -n "$_caps" ] && command -v setcap &>/dev/null && setcap "$_caps" "${_bin}.mtproxyl-new" 2>/dev/null
    mv -f "${_bin}.mtproxyl-new" "$_bin"
}

# Цель поднялась: служба активна с одним и тем же PID несколько секунд подряд
# и, если API включён, API отвечает.
_target_engine_healthy() {
    local _i _pid _last="" _stable=0
    for _i in $(seq 1 30); do
        sleep 1
        if systemctl is-active --quiet telemt.service; then
            _pid=$(systemctl show telemt.service -p MainPID --value 2>/dev/null)
            if [ -n "$_pid" ] && [ "$_pid" != "0" ] && [ "$_pid" = "$_last" ]; then
                _stable=$((_stable + 1))
            else
                _stable=0
            fi
            _last="$_pid"
            [ "$_stable" -ge 5 ] && break
        else
            _stable=0; _last=""
        fi
    done
    [ "$_stable" -ge 5 ] || return 1
    if _telemt_api_enabled; then
        _wait_target_api 20 >/dev/null 2>&1 || return 1
    fi
    return 0
}

# Ставит файл вместо бинарника цели и перезапускает службу. Заменённый уходит
# в «предыдущую» только при успехе; при неудаче он возвращается на место.
_target_engine_switch() {
    local _src="$1" _label="$2" _bin _cur
    _bin=$(target_engine_bin) || { log_error "Не найден бинарник цели"; return 1; }
    _cur=$(_target_elf_version "$_bin")
    mkdir -p "$TARGET_ENGINE_DIR" && chmod 700 "$TARGET_ENGINE_DIR"
    cp -f "$_bin" "${TARGET_ENGINE_DIR}/telemt.cur" || { log_error "Не удалось сохранить текущий бинарник"; return 1; }
    _target_engine_place "$_src" "$_bin" || {
        rm -f "${TARGET_ENGINE_DIR}/telemt.cur" "${_bin}.mtproxyl-new"
        log_error "Не удалось заменить ${_bin}"
        return 1
    }
    log_info "Перезапуск telemt.service..."
    systemctl restart telemt.service >/dev/null 2>&1 || true
    if _target_engine_healthy; then
        mv -f "${TARGET_ENGINE_DIR}/telemt.cur" "$TARGET_ENGINE_PREV"
        printf '%s\n' "${_cur:-unknown}" > "$TARGET_ENGINE_PREV_VERSION"
        log_success "telemt ${_label} работает: ${_bin}. Конфиг цели не менялся"
        return 0
    fi
    log_error "telemt ${_label} не поднялся с конфигом цели — возвращаем ${_cur:-прежнюю версию}"
    journalctl -u telemt.service -n 5 --no-pager -o cat 2>/dev/null | sed 's/^/    /'
    _target_engine_place "${TARGET_ENGINE_DIR}/telemt.cur" "$_bin" || true
    rm -f "${TARGET_ENGINE_DIR}/telemt.cur"
    systemctl restart telemt.service >/dev/null 2>&1 || true
    if _target_engine_healthy; then
        log_info "Прежняя версия ${_cur} снова работает"
    else
        log_warn "Прежняя версия тоже не поднялась — проверьте: journalctl -u telemt -n 50"
    fi
    return 1
}

target_engine_update() {
    local _want="${1:-}" _reason
    _reason=$(target_engine_unsupported_reason)
    [ -z "$_reason" ] || { log_error "$_reason"; return 1; }
    check_root
    local _ver="$_want" _cur _asset _tmpd _new
    if [ -z "$_ver" ] || [ "$_ver" = "latest" ]; then
        _ver=$(binengine_latest_version)
        [ -n "$_ver" ] || { log_error "Не удалось узнать последнюю версию telemt"; return 1; }
    fi
    _cur=$(target_engine_version)
    log_info "Текущая версия цели: ${_cur:-неизвестна}"
    if [ -n "$_cur" ] && [ "${_ver#v}" = "${_cur#v}" ]; then
        log_info "telemt ${_cur} уже установлен"
        return 0
    fi
    _asset=$(binengine_asset_name) || { log_error "Архитектура $(uname -m) не поддерживается сборками telemt"; return 1; }
    _tmpd=$(mktemp -d "${TMPDIR:-/tmp}/mtproxyl-target.XXXXXX") || return 1
    if ! _binengine_fetch_into "$_tmpd" "$_ver" "$_asset"; then
        rm -rf "$_tmpd"; return 1
    fi
    _new=$(_target_elf_version "${_tmpd}/telemt")
    if [ -z "$_new" ]; then
        rm -rf "$_tmpd"
        log_error "Скачанный telemt ${_ver} не запускается на этом сервере"
        return 1
    fi
    local _rc=0
    _target_engine_switch "${_tmpd}/telemt" "$_new" || _rc=$?
    rm -rf "$_tmpd"
    return $_rc
}

# Откат на бинарник с диска. Тег, которого на диске нет, ставится из релизов.
target_engine_rollback() {
    local _want="${1:-}" _reason
    _reason=$(target_engine_unsupported_reason)
    [ -z "$_reason" ] || { log_error "$_reason"; return 1; }
    check_root
    local _prev=""
    [ -x "$TARGET_ENGINE_PREV" ] && _prev=$(tr -d ' \t\r\n' < "$TARGET_ENGINE_PREV_VERSION" 2>/dev/null)
    if [ -n "$_want" ] && [ "$_want" != "--yes" ] && [ "${_want#v}" != "${_prev#v}" ]; then
        target_engine_update "$_want"
        return
    fi
    if [ ! -x "$TARGET_ENGINE_PREV" ]; then
        log_error "Предыдущей версии на диске нет — откатывать не к чему"
        log_info "Поставьте нужную версию: mtproxyl engine update <версия>"
        return 1
    fi
    if [ "$_want" != "--yes" ] && [ -z "$_want" ]; then
        echo ""
        echo -e "  ${BOLD}Текущая:${NC}    $(target_engine_version)"
        echo -e "  ${BOLD}Предыдущая:${NC} ${_prev:-неизвестна}"
        local _yn; read_line _yn "  ${BOLD}Откатиться? [y/N]:${NC} "
        [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 0; }
    fi
    local _tmp; _tmp=$(mktemp "${TMPDIR:-/tmp}/mtproxyl-target-prev.XXXXXX") || return 1
    cp -f "$TARGET_ENGINE_PREV" "$_tmp" || { rm -f "$_tmp"; return 1; }
    local _rc=0
    _target_engine_switch "$_tmp" "${_prev:-предыдущая}" || _rc=$?
    rm -f "$_tmp"
    return $_rc
}

target_engine_status() {
    local _reason; _reason=$(target_engine_unsupported_reason)
    echo -e "  ${BOLD}Движок цели Reanimator${NC}"
    if [ -n "$_reason" ]; then
        echo -e "  ${DIM}${_reason}${NC}"
        return 0
    fi
    local _prev=""
    [ -x "$TARGET_ENGINE_PREV" ] && _prev=$(tr -d ' \t\r\n' < "$TARGET_ENGINE_PREV_VERSION" 2>/dev/null)
    echo -e "  ${DIM}Установлен:${NC}  v$(target_engine_version)"
    echo -e "  ${DIM}Бинарник:${NC}    $(target_engine_bin)"
    echo -e "  ${DIM}Конфиг:${NC}      ${DETECTED_CONFIG_PATH:-—} ${DIM}(при смене версии не меняется)${NC}"
    [ -n "$_prev" ] && echo -e "  ${DIM}Для отката:${NC}  v${_prev}"
}

handle_engine_command() {
    local subcmd="${1:-status}"
    shift 2>/dev/null || true
    # У реаниматора — только версия бинарника цели.
    if _is_reanimator; then
        case "$subcmd" in
            status|list|update|rollback|versions) ;;
            *) _require_manager_mode; return 1 ;;
        esac
    else
        _require_manager_mode || return 1
    fi

    case "$subcmd" in
        status)
            if [ "${1:-}" = "--json" ]; then
                engine_versions_json
                return 0
            fi
            _is_reanimator && { target_engine_status; return 0; }
            echo -e "  ${BOLD}Движок Telemt${NC}"
            echo -e "  ${DIM}Носитель:${NC}   $(engine_backend_title)"
            echo -e "  ${DIM}Установлен:${NC}  v$(engine_current_version)"
            if engine_is_binary; then
                echo -e "  ${DIM}Бинарник:${NC}    ${ENGINE_BIN_PATH}"
                echo -e "  ${DIM}Служба:${NC}      ${ENGINE_SERVICE}.service"
                binengine_is_custom && echo -e "  ${DIM}Источник:${NC}    свой бинарник — $(binengine_source)"
            else
                echo -e "  ${DIM}Закреплён:${NC}   commit ${TELEMT_COMMIT}"
            fi
            ;;
        backend)
            engine_switch_backend "${1:-}"
            ;;
        custom)
            engine_install_custom "$@"
            ;;
        list)
            echo ""
            draw_header "ДОСТУПНЫЕ ВЕРСИИ TELEMT"
            echo ""
            local releases
            releases=$(engine_list_releases)
            if [ -n "$releases" ]; then
                local current
                if _is_reanimator; then current=$(target_engine_version); else current=$(engine_current_version); fi
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
            if _is_reanimator; then
                local _why; _why=$(target_engine_unsupported_reason)
                [ -z "$_why" ] || { log_error "$_why"; return 1; }
            fi
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
                if binengine_is_custom; then
                    log_info "Перекачиваем свой бинарник по той же ссылке"
                    binengine_install_custom "$(binengine_source)" || return 1
                else
                    log_info "Бинарный движок не собирается — перекачиваем текущую версию"
                    binengine_fetch "$(binengine_version)" || return 1
                fi
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
            echo -e "  ${DIM}custom <ссылка> [--sha256 <хеш>] [--yes]${NC}"
            echo -e "                  Поставить свой бинарник telemt по ссылке https"
            echo ""
            echo -e "  ${DIM}В Reanimator доступны status, list, update и rollback: меняется только${NC}"
            echo -e "  ${DIM}бинарник цели под telemt.service, конфиг цели не трогается.${NC}"
            ;;
    esac
}
