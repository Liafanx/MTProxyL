#!/bin/bash
# MTProxyL — обновление из архивов релизов, выбор версии и откат.
# Новая версия собирается целиком во временном каталоге и проверяется, а
# подменяется разом: смеси старых и новых файлов после обрыва не бывает.

RELEASE_CACHE_DIR="${INSTALL_DIR}/releases"
RELEASE_KEEP="${RELEASE_KEEP:-5}"
_RELEASE_STAGE=""
_RELEASE_FROM=""

_release_valid_version() { [[ "${1:-}" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; }
_release_asset() { echo "mtproxyl-$1.tar.gz"; }
_release_url() { echo "https://github.com/${GITHUB_REPO}/releases/download/v$1/$(_release_asset "$1")"; }
_release_local() { echo "${RELEASE_CACHE_DIR}/mtproxyl-$1-local.tar.gz"; }
_release_cached() { echo "${RELEASE_CACHE_DIR}/$(_release_asset "$1")"; }
_release_prev_file() { echo "${RELEASE_CACHE_DIR}/previous"; }

release_previous() {
    local _v
    [ -f "$(_release_prev_file)" ] || return 1
    _v=$(tr -d '[:space:]' < "$(_release_prev_file)")
    _release_valid_version "$_v" && echo "$_v"
}

_release_stage_cleanup() {
    [ -n "$_RELEASE_STAGE" ] && rm -rf "$_RELEASE_STAGE"
    _RELEASE_STAGE=""
_RELEASE_FROM=""
}

# Список библиотек — из самого mtproxyl.sh: его цикл загрузки и есть правда.
_release_lib_list() {
    sed -n 's/^for _lib in \(.*\); do$/\1/p' "$1" | head -1
}

# Проверка распакованной версии. Печатает номер версии.
_release_check() {
    local _root="$1" _want="${2:-}" _ver _libs _l _f
    [ -f "${_root}/mtproxyl.sh" ] || { log_error "В архиве нет mtproxyl.sh"; return 1; }
    _ver=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "${_root}/mtproxyl.sh" | head -1)
    _release_valid_version "$_ver" || { log_error "Не удалось определить версию в архиве"; return 1; }
    if [ -n "$_want" ] && [ "$_ver" != "$_want" ]; then
        log_error "В архиве версия ${_ver}, ждали ${_want}"; return 1
    fi
    _libs=$(_release_lib_list "${_root}/mtproxyl.sh")
    [ -n "$_libs" ] || { log_error "В mtproxyl.sh ${_ver} нет списка библиотек"; return 1; }
    for _l in $_libs; do
        [ -f "${_root}/lib/${_l}.sh" ] || { log_error "В версии ${_ver} нет lib/${_l}.sh"; return 1; }
    done
    for _f in "${_root}/mtproxyl.sh" "${_root}"/lib/*.sh; do
        bash -n "$_f" 2>/dev/null || { log_error "Ошибка синтаксиса: ${_f#"${_root}"/}"; return 1; }
    done
    if command -v python3 >/dev/null 2>&1 && [ -d "${_root}/mtproxyl-tgbot/bot" ]; then
        for _f in "${_root}"/mtproxyl-tgbot/bot/*.py; do
            python3 -m py_compile "$_f" 2>/dev/null \
                || { log_error "Ошибка в коде бота: ${_f#"${_root}"/}"; return 1; }
        done
        find "${_root}/mtproxyl-tgbot" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
    fi
    echo "$_ver"
}

# Распаковать архив во временный каталог. Внутри — только обычные файлы и
# каталоги под mtproxyl-<версия>/, иначе архив мог бы писать мимо.
_release_unpack() {
    local _arc="$1" _ver="$2" _names _types _bad
    _names=$(tar -tzf "$_arc" 2>/dev/null) && _types=$(tar -tvzf "$_arc" 2>/dev/null) \
        || { log_error "Архив повреждён: ${_arc}"; return 1; }
    _bad=$(awk -v top="mtproxyl-${_ver}" '
        $0 ~ /(^|\/)\.\.(\/|$)/ || ($0 != top && $0 != top "/" && index($0, top "/") != 1) { print; exit }
    ' <<< "$_names")
    [ -z "$_bad" ] && _bad=$(awk '{ t = substr($1, 1, 1) } t != "-" && t != "d" { print; exit }' <<< "$_types")
    [ -z "$_bad" ] || { log_error "В архиве лишнее: ${_bad}"; return 1; }
    _RELEASE_STAGE=$(mktemp -d "${INSTALL_DIR}/.release-stage.XXXXXX") || return 1
    tar -xzf "$_arc" -C "$_RELEASE_STAGE" --no-same-owner --no-same-permissions 2>/dev/null \
        || { log_error "Не удалось распаковать ${_arc}"; _release_stage_cleanup; return 1; }
    local _root="${_RELEASE_STAGE}/mtproxyl-${_ver}"
    if [ -f "${_root}/SHA256SUMS" ]; then
        (cd "$_root" && sha256sum -c --quiet --strict SHA256SUMS >/dev/null 2>&1) \
            || { log_error "Контрольные суммы внутри архива не сходятся"; _release_stage_cleanup; return 1; }
    fi
    _release_check "$_root" "$_ver" >/dev/null || { _release_stage_cleanup; return 1; }
}

# Скачать архив релиза в кэш и сверить с опубликованной суммой.
_release_download() {
    local _ver="$1" _url _tmp _sum _got
    _url=$(_release_url "$_ver")
    mkdir -p "$RELEASE_CACHE_DIR"; chmod 700 "$RELEASE_CACHE_DIR"
    _sum=$(curl -fsSL --retry 3 --retry-delay 2 --max-time 30 "${_url}.sha256" 2>/dev/null | awk 'NR==1{print $1}')
    [[ "$_sum" =~ ^[0-9a-f]{64}$ ]] || return 1
    _tmp=$(mktemp "${RELEASE_CACHE_DIR}/.dl.XXXXXX") || return 1
    if ! curl -fsSL --retry 3 --retry-delay 2 --max-time 180 "$_url" -o "$_tmp" 2>/dev/null; then
        rm -f "$_tmp"; return 1
    fi
    _got=$(sha256sum "$_tmp" | awk '{print $1}')
    if [ "$_got" != "$_sum" ]; then
        rm -f "$_tmp"
        log_error "Сумма скачанного архива ${_ver} не совпала с опубликованной"
        return 2
    fi
    mv -f "$_tmp" "$(_release_cached "$_ver")"
}

# Подготовить версию из кэша или с GitHub. $2=local — сначала свой снимок
# (откат возвращает ровно тот код, что работал).
_release_stage_version() {
    local _ver="$1" _prefer="${2:-}" _arc _rc
    if [ "$_prefer" = local ] && [ -f "$(_release_local "$_ver")" ]; then
        log_info "Берём сохранённую копию v${_ver}"
        _RELEASE_FROM="сохранённая копия v${_ver}"
        _release_unpack "$(_release_local "$_ver")" "$_ver" && return 0
    fi
    _RELEASE_FROM="архив v${_ver}"
    _arc=$(_release_cached "$_ver")
    if [ -f "$_arc" ]; then
        log_info "Архив v${_ver} уже скачан"
        _release_unpack "$_arc" "$_ver" && return 0
        rm -f "$_arc"
    fi
    log_info "Скачиваем архив v${_ver} с GitHub..."
    _release_download "$_ver"; _rc=$?
    if [ "$_rc" -eq 0 ]; then
        _release_unpack "$_arc" "$_ver" && return 0
        rm -f "$_arc"
    fi
    if [ "$_prefer" != local ] && [ -f "$(_release_local "$_ver")" ]; then
        log_info "Берём сохранённую копию v${_ver}"
        _RELEASE_FROM="сохранённая копия v${_ver}"
        _release_unpack "$(_release_local "$_ver")" "$_ver" && return 0
    fi
    return 1
}

# Запасной путь — файлы ветки, закреплённые за одним коммитом: релиз ещё
# собирается или установка идёт с не релизной ветки.
_release_stage_branch() {
    local _ref="$GITHUB_BRANCH" _sha _base _root _f _libs _l _bot
    _sha=$(curl -fsS --max-time 10 -H 'Accept: application/vnd.github.sha' \
        "https://api.github.com/repos/${GITHUB_REPO}/commits/${GITHUB_BRANCH}" 2>/dev/null)
    [[ "$_sha" =~ ^[0-9a-f]{40}$ ]] && _ref="$_sha"
    _base="https://raw.githubusercontent.com/${GITHUB_REPO}/${_ref}"
    log_info "Скачиваем файлы ветки ${GITHUB_BRANCH}${_sha:+ (коммит ${_sha:0:7})}..."
    _RELEASE_STAGE=$(mktemp -d "${INSTALL_DIR}/.release-stage.XXXXXX") || return 1
    _root="${_RELEASE_STAGE}/branch"
    mkdir -p "${_root}/lib" "${_root}/mtproxyl-tgbot/bot"
    _fetch() { curl -fsS --retry 3 --retry-delay 2 --max-time 30 "${_base}/$1" -o "${_root}/$1" 2>/dev/null; }
    _fetch mtproxyl.sh || { log_error "Не удалось скачать mtproxyl.sh"; _release_stage_cleanup; return 1; }
    _fetch version || true
    _libs=$(_release_lib_list "${_root}/mtproxyl.sh")
    for _l in $_libs; do
        _fetch "lib/${_l}.sh" || { log_error "Не удалось скачать lib/${_l}.sh"; _release_stage_cleanup; return 1; }
    done
    # Список файлов бота — из новой tgbot.sh.
    _bot=$(sed -n '/^_TGBOT_FILES=(/,/^)/{s/^ *"\(.*\)"$/\1/p}' "${_root}/lib/tgbot.sh" 2>/dev/null)
    for _f in $_bot; do
        _fetch "mtproxyl-tgbot/${_f}" || { rm -rf "${_root}/mtproxyl-tgbot"; break; }
    done
    _release_check "$_root" >/dev/null || { _release_stage_cleanup; return 1; }
}

_release_root() { find "$_RELEASE_STAGE" -mindepth 1 -maxdepth 1 -type d | head -1; }

# Снимок установленного кода: откат вернёт именно его.
_release_snapshot() {
    local _tmp _root _f
    mkdir -p "$RELEASE_CACHE_DIR"; chmod 700 "$RELEASE_CACHE_DIR"
    _tmp=$(mktemp -d "${RELEASE_CACHE_DIR}/.snap.XXXXXX") || return 1
    _root="${_tmp}/mtproxyl-${VERSION}"
    mkdir -p "${_root}/lib"
    cp "${INSTALL_DIR}/mtproxyl.sh" "${_root}/" && cp "${LIB_DIR}"/*.sh "${_root}/lib/" \
        || { rm -rf "$_tmp"; return 1; }
    echo "$VERSION" > "${_root}/version"
    if [ -d "${TGBOT_DIR:-/nonexistent}/bot" ]; then
        for _f in "${_TGBOT_FILES[@]}"; do
            [ -f "${TGBOT_DIR}/${_f}" ] || continue
            mkdir -p "${_root}/mtproxyl-tgbot/$(dirname "$_f")"
            cp "${TGBOT_DIR}/${_f}" "${_root}/mtproxyl-tgbot/${_f}"
        done
    fi
    (cd "$_root" && find . -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort | xargs -d '\n' sha256sum > SHA256SUMS)
    tar -czf "${_tmp}/a.tar.gz" -C "$_tmp" "mtproxyl-${VERSION}" \
        && mv -f "${_tmp}/a.tar.gz" "$(_release_local "$VERSION")"
    local _rc=$?
    rm -rf "$_tmp"
    return $_rc
}

# Подмена: всё уже лежит на этом же диске, mv — это rename. Главный скрипт
# последним: его читает работающий bash, а новый inode ему не мешает.
_release_apply() {
    local _root="$1" _f _n
    mkdir -p "$LIB_DIR"
    for _f in "${_root}"/lib/*.sh; do
        _n=$(basename "$_f")
        install -m 644 "$_f" "${LIB_DIR}/.${_n}.new" && mv -f "${LIB_DIR}/.${_n}.new" "${LIB_DIR}/${_n}" || return 1
    done
    [ -f "${_root}/version" ] && install -m 644 "${_root}/version" "${INSTALL_DIR}/version"
    install -m 755 "${_root}/mtproxyl.sh" "${INSTALL_DIR}/.mtproxyl.sh.new" \
        && mv -f "${INSTALL_DIR}/.mtproxyl.sh.new" "${INSTALL_DIR}/mtproxyl.sh"
}

# Старые архивы: держим последние RELEASE_KEEP, текущую и прошлую — всегда.
_release_prune() {
    local _keep_a="$1" _keep_b="$2" _f _n=0
    while IFS= read -r _f; do
        case "$(basename "$_f")" in
            "mtproxyl-${_keep_a}.tar.gz"|"mtproxyl-${_keep_a}-local.tar.gz"|\
            "mtproxyl-${_keep_b}.tar.gz"|"mtproxyl-${_keep_b}-local.tar.gz") continue ;;
        esac
        _n=$((_n + 1))
        [ "$_n" -gt "$RELEASE_KEEP" ] && rm -f "$_f"
    done < <(ls -1t "${RELEASE_CACHE_DIR}"/mtproxyl-*.tar.gz 2>/dev/null)
}

# Версии с архивом на GitHub: «версия|дата», новые сверху.
_release_remote_list() {
    command -v jq >/dev/null 2>&1 || { log_error "Для списка версий нужен jq: apt install jq"; return 1; }
    local _json
    _json=$(curl -fsS --max-time 15 "https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=100" 2>/dev/null) \
        || return 1
    jq -r '.[] | select(.draft | not) | select(.tag_name | test("^v[0-9]+(\\.[0-9]+)+$"))
            | (.tag_name | ltrimstr("v")) as $v
            | select(any(.assets[]; .name == "mtproxyl-" + $v + ".tar.gz"))
            | "\($v)|\(.published_at[0:10])"' <<< "$_json" 2>/dev/null
}

release_list() {
    local _json=false _remote _prev _v _d _local
    [ "${1:-}" = "--json" ] && _json=true
    local _remote_ok=true
    _remote=$(_release_remote_list) || { _remote=""; _remote_ok=false; }
    _prev=$(release_previous)
    _local=$(ls -1 "${RELEASE_CACHE_DIR}"/mtproxyl-*-local.tar.gz 2>/dev/null \
        | sed -n 's|.*/mtproxyl-\(.*\)-local\.tar\.gz$|\1|p')
    if $_json; then
        local _items="" _sep=""
        while IFS='|' read -r _v _d; do
            [ -n "$_v" ] || continue
            _items+="${_sep}{\"version\":\"${_v}\",\"date\":\"${_d}\",\"local\":$(grep -qxF "$_v" <<< "$_local" && echo true || echo false)}"
            _sep=","
        done <<< "$_remote"
        printf '{"current":"%s","previous":"%s","versions":[%s]}\n' "$VERSION" "$_prev" "$_items"
        return 0
    fi
    echo ""
    echo -e "  ${BOLD}Версии MTProxyL с архивом${NC}"
    echo ""
    if ! $_remote_ok; then
        log_warn "Список с GitHub получить не удалось"
    elif [ -z "$_remote" ]; then
        log_info "На GitHub пока нет версий с архивом"
    fi
    while IFS='|' read -r _v _d; do
        [ -n "$_v" ] || continue
        local _mark="  "
        [ "$_v" = "$VERSION" ] && _mark="${GREEN}●${NC} "
        echo -e "  ${_mark}v${_v}  ${DIM}${_d}${NC}$([ "$_v" = "$_prev" ] && echo "  ${DIM}(прошлая)${NC}")"
    done <<< "$_remote"
    for _v in $_local; do
        grep -q "^${_v}|" <<< "$_remote" && continue
        echo -e "     v${_v}  ${DIM}только сохранённая копия${NC}"
    done
    echo ""
    echo -e "  ${DIM}Установить: mtproxyl update --version X.Y.Z · откат: mtproxyl update --rollback${NC}"
}

_release_confirm() {
    local _q="$1" _a
    [ "${MTPROXYL_ASSUME_YES:-}" = "1" ] && return 0
    if [ ! -t 0 ]; then
        log_error "${_q} — подтвердите флагом --yes"
        return 1
    fi
    read_line _a "  ${YELLOW}${_q} [y/N]:${NC} "
    [[ "$_a" =~ ^[yYдД] ]]
}

# mtproxyl update [--version X.Y.Z | --rollback] [--yes] [--no-restart]
self_update() {
    local _restart=true _want="" _rollback=false _explicit=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-restart) _restart=false ;;
            --version) _want="${2:-}"; _explicit=true; shift ;;
            --version=*) _want="${1#*=}"; _explicit=true ;;
            --rollback) _rollback=true; _explicit=true ;;
            --yes|-y) MTPROXYL_ASSUME_YES=1 ;;
            *) log_error "Неизвестный параметр: $1"; return 1 ;;
        esac
        shift
    done

    echo ""
    draw_header "ОБНОВЛЕНИЕ MTPROXYL"
    echo ""

    if $_rollback; then
        _want=$(release_previous) || {
            log_error "Не знаю, с какой версии обновлялись — откатываться не на что"
            log_info "Конкретную версию: mtproxyl update --version X.Y.Z (список — mtproxyl update --list)"
            return 1
        }
    fi
    _want="${_want#v}"
    if $_explicit && ! _release_valid_version "$_want"; then
        log_error "Неверный номер версии: ${_want:-пусто}"; return 1
    fi

    local _source=""
    if ! $_explicit; then
        local _latest
        _latest=$(_github_raw_fetch "version" 8 | tr -d '[:space:]')
        _release_valid_version "$_latest" || {
            log_error "Не удалось узнать последнюю версию"
            log_info "Проверьте интернет и доступность github.com"
            return 1
        }
        if ! _version_gt "$_latest" "$VERSION"; then
            if [ "$_latest" = "$VERSION" ]; then
                log_success "Версия актуальна (v${VERSION})"
            else
                log_success "Установлена v${VERSION}, она новее опубликованной v${_latest}"
            fi
            return 0
        fi
        _want="$_latest"
    elif [ "$_want" = "$VERSION" ]; then
        log_success "v${VERSION} уже установлена"
        return 0
    fi

    log_info "Текущая версия: v${VERSION}"
    log_info "Ставим:         v${_want}"
    # Откат просили прямо — переспрашивать незачем.
    if _version_gt "$VERSION" "$_want" && ! $_rollback; then
        log_warn "Это более старая версия. Настройки и пользователи сохранятся."
        _release_confirm "Установить v${_want}?" || { log_info "Отменено"; return 1; }
    fi
    echo ""

    log_info "Шаг 1/3: Получение и проверка файлов..."
    if [ "$GITHUB_BRANCH" != main ] && ! $_explicit; then
        _release_stage_branch && _source="ветка ${GITHUB_BRANCH}"
    elif _release_stage_version "$_want" "$($_rollback && echo local)"; then
        _source="$_RELEASE_FROM"
    elif ! $_explicit; then
        log_warn "Архива v${_want} пока нет — берём файлы ветки"
        _release_stage_branch && _source="ветка ${GITHUB_BRANCH}"
    fi
    if [ -z "$_source" ]; then
        _release_stage_cleanup
        log_error "Не удалось получить v${_want}"
        $_explicit && log_info "Версии с архивом: mtproxyl update --list"
        return 1
    fi
    local _root _new_ver
    _root=$(_release_root)
    _new_ver=$(_release_check "$_root") || { _release_stage_cleanup; return 1; }
    log_success "Проверено: v${_new_ver} (${_source})"

    log_info "Шаг 2/3: Сохраняем текущую версию для отката..."
    if _release_snapshot; then
        log_success "Копия v${VERSION}: $(_release_local "$VERSION")"
    else
        log_warn "Копию текущей версии сохранить не удалось"
        _release_confirm "Продолжить без копии?" || { _release_stage_cleanup; return 1; }
    fi

    log_info "Шаг 3/3: Замена файлов..."
    if ! _release_apply "$_root"; then
        log_error "Замена прервалась — возвращаем v${VERSION}"
        if _release_stage_cleanup && _release_unpack "$(_release_local "$VERSION")" "$VERSION"; then
            _release_apply "$(_release_root)"
        fi
        _release_stage_cleanup
        return 1
    fi
    echo "$VERSION" > "$(_release_prev_file)"
    log_success "Файлы MTProxyL заменены"
    echo ""

    _release_after_install "$_root" "$_new_ver"
    _release_stage_cleanup
    _release_prune "$_new_ver" "$VERSION"

    log_success "MTProxyL: v${VERSION} → v${_new_ver}"
    log_info "Вернуть прежнюю: mtproxyl update --rollback"

    [ "$_restart" = "false" ] && return 0
    log_info "Перезапуск..."
    # exec не вызывает EXIT: замок снимаем сами, иначе его держало бы меню.
    cli_unlock
    exec "${INSTALL_DIR}/mtproxyl.sh"
}

# Что меняется вместе с кодом: службы, права панели и API, бот.
_release_after_install() {
    local _root="$1" _new_ver="$2"
    if [ -n "${BLOCKLIST_COUNTRIES:-}" ] && [ -r "${LIB_DIR}/geoblock.sh" ]; then
        source "${LIB_DIR}/geoblock.sh"
        if declare -F geoblock_install_service >/dev/null; then
            geoblock_install_service >/dev/null 2>&1 \
                && log_success "Автовосстановление гео-блокировки включено" \
                || log_warn "Не удалось включить службу ${GEOBLOCK_SERVICE:-mtproxyl-geoblock}"
            if ! geoblock_rules_active || ! geoblock_rules_match_ports; then
                geoblock_restore >/dev/null 2>&1 \
                    && log_success "Правила гео-блокировки восстановлены" \
                    || log_warn "Правила не восстановились — выполните: mtproxyl geoblock reapply"
            fi
        fi
    fi

    # Код бота — из того же архива, что и скрипт.
    if tgbot_installed 2>/dev/null; then
        [ -r "${LIB_DIR}/tgbot.sh" ] && source "${LIB_DIR}/tgbot.sh"
        log_info "Обновляем телеграм-бота..."
        local _src=""
        [ -d "${_root}/mtproxyl-tgbot/bot" ] && _src="${_root}/mtproxyl-tgbot"
        if MTPROXYL_TGBOT_SRC="$_src" tgbot_update_sources; then
            log_success "Телеграм-бот обновлён и перезапущен"
        else
            log_warn "Код бота обновить не удалось — повторите: mtproxyl tgbot update"
        fi
    fi

    if [ "${WARP_ENABLED:-false}" = true ]; then
        "${INSTALL_DIR}/mtproxyl.sh" warp refresh \
            || log_warn "WARP требует обновления: mtproxyl warp refresh"
    fi
    if awg_is_enabled 2>/dev/null; then
        "${INSTALL_DIR}/mtproxyl.sh" awg refresh \
            || log_warn "Выход через AWG требует обновления: mtproxyl awg refresh"
    fi
    # Новая раскладка zapret2 — только у работающего и только если изменилась.
    "${INSTALL_DIR}/mtproxyl.sh" nft zapret2-refresh \
        || log_warn "Zapret2 не перезапустился — проверьте: mtproxyl nft zapret2-start"

    # Права панели и API пишет уже установленная версия.
    if panel_installed 2>/dev/null; then
        [ -r "${LIB_DIR}/panel.sh" ] && source "${LIB_DIR}/panel.sh"
        log_info "Обновляем права sudo у панели под команды v${_new_ver}..."
        panel_grant >/dev/null 2>&1 \
            && log_success "Панель получила права на команды v${_new_ver}" \
            || log_warn "Права не обновились — выполните: mtproxyl panel install"
    fi
    if [ "${API_ENABLED:-false}" = true ]; then
        "${INSTALL_DIR}/mtproxyl.sh" api sync-cert >/dev/null 2>&1 \
            && log_success "API управления получил права на команды v${_new_ver}" \
            || log_warn "Права API не обновились — выполните: mtproxyl api update"
    fi
}
