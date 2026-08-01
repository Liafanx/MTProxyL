#!/bin/sh
set -eu

# ── Constants ────────────────────────────────────────────────────────────────
REPO="Liafanx/MTProxyL"
# Панель живёт в репозитории MTProxyL, но выпускается отдельно — её релизы
# помечаются собственным префиксом тега.
RELEASE_TAG_PREFIX="mtproxyl-panel-v"
BINARY_NAME="mtproxyl-panel"
SERVICE_NAME="mtproxyl-panel"
SYSTEM_USER="mtproxyl-panel"
BIN_DIR="/usr/local/bin"
PANEL_BINARY_PATH="${BIN_DIR}/${BINARY_NAME}"
CONFIG_DIR="/etc/mtproxyl-panel"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
DATA_DIR="/var/lib/mtproxyl-panel"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SUDOERS_FILE="/etc/sudoers.d/${SERVICE_NAME}"
MTPROXYL_SUDOERS_FILE="/etc/sudoers.d/${SERVICE_NAME}-mtproxyl"
MTPROXYL_SCRIPT="/opt/mtproxyl/mtproxyl.sh"
MTPROXYL_INSTALL_DIR="/opt/mtproxyl"
LEGACY_BIN_DIR="/opt/bin/telemt"
LEGACY_CONFIG_DIR="/opt/etc/mtproxyl-panel"

# Conventional installation paths with a non-root service user

# ── Utilities ────────────────────────────────────────────────────────────────
say()  { printf '[ИНФО]  %s\n' "$*"; }
die()  { printf '[ОШИБКА] %s\n' "$*" >&2; exit 1; }

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
fi

write_root() {
  $SUDO tee "$1" >/dev/null
}

TEMP_DIR=""
cleanup() {
  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    rm -rf -- "$TEMP_DIR"
  fi
}
trap cleanup EXIT INT TERM

ensure_temp_dir() {
  if [ -z "$TEMP_DIR" ]; then
    TEMP_DIR=$(mktemp -d)
  fi
}

command_path() {
  _path=$(command -v "$1" 2>/dev/null || true)
  [ -n "$_path" ] || die "Не найдена команда '$1'. Установите её и повторите запуск."
  echo "$_path"
}

toml_value() {
  _file="$1"
  _section="$2"
  _key="$3"
  awk -v section="[$_section]" -v key="$_key" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[[^[]/ {
      in_section = ($0 == section)
      next
    }
    in_section {
      line = $0
      sub(/[[:space:]]*#.*/, "", line)
      split(line, parts, "=")
      current_key = parts[1]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", current_key)
      if (current_key == key) {
        value = substr(line, index(line, "=") + 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        gsub(/^"/, "", value)
        gsub(/"$/, "", value)
        print value
        exit
      }
    }
  ' "$_file"
}

# ── Architecture ─────────────────────────────────────────────────────────────
detect_arch() {
  _arch=$(uname -m)
  case "$_arch" in
    x86_64)  echo "x86_64"  ;;
    aarch64) echo "aarch64" ;;
    *)       die "Неподдерживаемая архитектура: $_arch" ;;
  esac
}

# ── Telemt binary location ───────────────────────────────────────────────────
detect_telemt() {
  for _candidate in \
    "$BIN_DIR/telemt" \
    "$LEGACY_BIN_DIR/telemt" \
    /bin/telemt \
    /usr/bin/telemt \
    /usr/local/bin/telemt; do
    if [ -x "$_candidate" ]; then
      echo "$_candidate"
      return
    fi
  done
  echo "/bin/telemt"
}

# ── Install helper ───────────────────────────────────────────────────────────
install_binary() {
  _src="$1"
  _dst="$2"
  $SUDO install -m 0755 "$_src" "$_dst"
}

# ── Create system user ───────────────────────────────────────────────────────
create_system_user() {
  if id "$SYSTEM_USER" >/dev/null 2>&1; then
    say "Системный пользователь '$SYSTEM_USER' уже существует"
  else
    $SUDO useradd --system --shell /usr/sbin/nologin --home /nonexistent "$SYSTEM_USER" 2>/dev/null \
      || $SUDO adduser --system --shell /usr/sbin/nologin --home /nonexistent --disabled-password "$SYSTEM_USER" 2>/dev/null \
      || die "Не удалось создать пользователя '$SYSTEM_USER'. Создайте его вручную и повторите."
    say "Создан системный пользователь '$SYSTEM_USER'"
  fi
}

# ── Join telemt group for config access ─────────────────────────────────────
join_telemt_group() {
  _telemt_group=""
  # Detect telemt group from its config directory
  if [ -d "/etc/telemt" ]; then
    _telemt_group=$(stat -c '%G' /etc/telemt 2>/dev/null || true)
  fi
  # Fallback: check if 'telemt' group exists directly
  if [ -z "$_telemt_group" ] || [ "$_telemt_group" = "root" ]; then
    if command -v getent >/dev/null 2>&1; then
      getent group telemt >/dev/null 2>&1 && _telemt_group="telemt"
    elif grep -q "^telemt:" /etc/group 2>/dev/null; then
      _telemt_group="telemt"
    fi
  fi

  if [ -n "$_telemt_group" ] && [ "$_telemt_group" != "root" ]; then
    if id -nG "$SYSTEM_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$_telemt_group"; then
      say "Пользователь '$SYSTEM_USER' уже в группе '$_telemt_group'"
    else
      $SUDO usermod -aG "$_telemt_group" "$SYSTEM_USER" 2>/dev/null \
        || $SUDO adduser "$SYSTEM_USER" "$_telemt_group" 2>/dev/null \
        || { say "ВНИМАНИЕ: не удалось добавить '$SYSTEM_USER' в группу '$_telemt_group' — добавьте вручную для доступа к конфигу telemt"; return; }
      say "Пользователь '$SYSTEM_USER' добавлен в группу '$_telemt_group' для доступа к конфигу telemt"
    fi
  else
    say "ВНИМАНИЕ: группа telemt не найдена — панель не получит доступ к конфигу telemt"
    say "После установки telemt повторите установку или выполните: sudo usermod -aG telemt $SYSTEM_USER"
  fi
}

# ── Check required commands ──────────────────────────────────────────────────
check_deps() {
  for _cmd in curl tar openssl systemctl; do
    command -v "$_cmd" >/dev/null 2>&1 || die "Не найдена команда '$_cmd'. Установите её и повторите запуск."
  done
  # sha256sum is optional (used for checksum verification)
  if ! command -v sha256sum >/dev/null 2>&1; then
    say "ВНИМАНИЕ: sha256sum не найден — проверка контрольной суммы будет пропущена"
  fi
}

# ── Set up directories ──────────────────────────────────────────────────────
setup_directories() {
  say "Создание каталогов..."
  $SUDO mkdir -p "$BIN_DIR"
  $SUDO mkdir -p "$CONFIG_DIR"
  $SUDO mkdir -p "$DATA_DIR/staging"
  $SUDO chown "$SYSTEM_USER:$SYSTEM_USER" "$CONFIG_DIR"
  $SUDO chown "$SYSTEM_USER:$SYSTEM_USER" "$DATA_DIR"
  $SUDO chown "$SYSTEM_USER:$SYSTEM_USER" "$DATA_DIR/staging"
}

warn_legacy_install() {
  if [ -e "$LEGACY_BIN_DIR/$BINARY_NAME" ] || [ -d "$LEGACY_CONFIG_DIR" ]; then
    say "ВНИМАНИЕ: обнаружена старая установка в /opt."
    say "Установщик теперь использует $PANEL_BINARY_PATH и $CONFIG_FILE."
    say "Удалите старые пути в /opt вручную, убедившись что новая установка работает."
  fi
}

install_sudoers_dropin() {
  _telemt_path="$1"
  _telemt_service="$2"
  _telemt_config="${3:-/etc/telemt/telemt.toml}"

  [ -n "$_telemt_path" ] || _telemt_path=$(detect_telemt)
  [ -n "$_telemt_service" ] || _telemt_service="telemt"

  _cp=$(command_path cp)
  _mv=$(command_path mv)
  _chmod=$(command_path chmod)
  _rm=$(command_path rm)
  _tee=$(command_path tee)
  _systemctl=$(command_path systemctl)
  _journalctl=$(command_path journalctl)
  _visudo=$(command -v visudo 2>/dev/null || true)

  _panel_tmp="${BIN_DIR}/.${BINARY_NAME}.tmp"
  _panel_backup="${DATA_DIR}/staging/${BINARY_NAME}.bak"
  _telemt_name=$(basename "$_telemt_path")
  _telemt_dir=$(dirname "$_telemt_path")
  _telemt_tmp="${_telemt_dir}/.${_telemt_name}.tmp"
  _telemt_backup="${DATA_DIR}/staging/${_telemt_name}.bak"

  say "Установка прав sudo для обновления..."
  ensure_temp_dir
  _tmp="$TEMP_DIR/sudoers"
  cat >"$_tmp" <<EOF
$SYSTEM_USER ALL=(root) NOPASSWD: $_cp -f $PANEL_BINARY_PATH $_panel_backup
$SYSTEM_USER ALL=(root) NOPASSWD: $_cp -f $_telemt_path $_telemt_backup
$SYSTEM_USER ALL=(root) NOPASSWD: $_cp -f ${DATA_DIR}/staging/${BINARY_NAME} $_panel_tmp
$SYSTEM_USER ALL=(root) NOPASSWD: $_cp -f ${DATA_DIR}/staging/$_telemt_name $_telemt_tmp
$SYSTEM_USER ALL=(root) NOPASSWD: $_chmod 0755 $_panel_tmp
$SYSTEM_USER ALL=(root) NOPASSWD: $_chmod 0755 $_telemt_tmp
$SYSTEM_USER ALL=(root) NOPASSWD: $_mv -f $_panel_tmp $PANEL_BINARY_PATH
$SYSTEM_USER ALL=(root) NOPASSWD: $_mv -f $_telemt_tmp $_telemt_path
$SYSTEM_USER ALL=(root) NOPASSWD: $_rm -f $_panel_tmp
$SYSTEM_USER ALL=(root) NOPASSWD: $_rm -f $_telemt_tmp
$SYSTEM_USER ALL=(root) NOPASSWD: $_systemctl restart $SERVICE_NAME
$SYSTEM_USER ALL=(root) NOPASSWD: $_systemctl restart $_telemt_service
$SYSTEM_USER ALL=(root) NOPASSWD: $_systemctl start $SERVICE_NAME
$SYSTEM_USER ALL=(root) NOPASSWD: $_systemctl start $_telemt_service
$SYSTEM_USER ALL=(root) NOPASSWD: $_journalctl -u $_telemt_service -n * --no-pager -o short-iso
$SYSTEM_USER ALL=(root) NOPASSWD: $_journalctl -u $_telemt_service -n * --since * --no-pager -o short-iso
$SYSTEM_USER ALL=(root) NOPASSWD: $_journalctl -u $_telemt_service -f --no-pager -o short-iso
$SYSTEM_USER ALL=(root) NOPASSWD: $_journalctl -u $_telemt_service -f --since * --no-pager -o short-iso
$SYSTEM_USER ALL=(root) NOPASSWD: $_tee $_telemt_config
EOF

  if [ -n "$_visudo" ]; then
    $SUDO "$_visudo" -cf "$_tmp" >/dev/null || die "Сгенерированный файл sudoers некорректен"
  fi

  $SUDO mkdir -p "$(dirname "$SUDOERS_FILE")"
  $SUDO install -m 0440 "$_tmp" "$SUDOERS_FILE"
  say "Права sudo установлены: $SUDOERS_FILE"
}

# ── Sudoers for the MTProxyL bridge ─────────────────────────────────────────
# Separate drop-in from the updater one: MTProxyL is optional, so this is only
# written when the integration is enabled, and removing it disables the feature
# without touching update permissions.
install_mtproxyl_sudoers() {
  _script="$1"
  _install_dir="$2"

  [ -n "$_script" ] || _script="/opt/mtproxyl/mtproxyl.sh"
  [ -n "$_install_dir" ] || _install_dir="/opt/mtproxyl"

  _visudo=$(command -v visudo 2>/dev/null || true)

  say "Установка прав sudo для команд MTProxyL..."
  ensure_temp_dir
  _tmp="$TEMP_DIR/sudoers-mtproxyl"

  # Only the exact subcommands the panel calls are permitted; `mtproxyl` as a
  # whole is not. The restore rule is the one wildcard, and it is pinned to the
  # backup directory and archive naming scheme. The panel additionally
  # validates the filename before building this argument.
  #
  # env_keep is required: sudo resets the environment, which would strip
  # MTPROXYL_ASSUME_YES and leave the script waiting on a prompt forever.
  cat >"$_tmp" <<EOF
Defaults:$SYSTEM_USER env_keep += "MTPROXYL_ASSUME_YES"

$SYSTEM_USER ALL=(root) NOPASSWD: $_script mode
$SYSTEM_USER ALL=(root) NOPASSWD: $_script mode --json
$SYSTEM_USER ALL=(root) NOPASSWD: $_script mode manager
$SYSTEM_USER ALL=(root) NOPASSWD: $_script mode reanimator
$SYSTEM_USER ALL=(root) NOPASSWD: $_script selfmask status --json
$SYSTEM_USER ALL=(root) NOPASSWD: $_script selfmask setup
$SYSTEM_USER ALL=(root) NOPASSWD: $_script selfmask apply
$SYSTEM_USER ALL=(root) NOPASSWD: $_script selfmask settable
$SYSTEM_USER ALL=(root) NOPASSWD: $_script selfmask set SELFMASK_[A-Z_]* *
$SYSTEM_USER ALL=(root) NOPASSWD: $_script selfmask verify
$SYSTEM_USER ALL=(root) NOPASSWD: $_script selfmask disable
$SYSTEM_USER ALL=(root) NOPASSWD: $_script backup
$SYSTEM_USER ALL=(root) NOPASSWD: $_script backup list --json
$SYSTEM_USER ALL=(root) NOPASSWD: $_script restore ${_install_dir}/backups/mtproxyl-[0-9]*.tar.gz
$SYSTEM_USER ALL=(root) NOPASSWD: $_script nft status --json
$SYSTEM_USER ALL=(root) NOPASSWD: $_script nft settable
$SYSTEM_USER ALL=(root) NOPASSWD: $_script nft set [A-Z]* *
$SYSTEM_USER ALL=(root) NOPASSWD: $_script nft apply
$SYSTEM_USER ALL=(root) NOPASSWD: $_script nft remove
$SYSTEM_USER ALL=(root) NOPASSWD: $_script nft service
$SYSTEM_USER ALL=(root) NOPASSWD: $_script nft smart
$SYSTEM_USER ALL=(root) NOPASSWD: $_script nft drop
$SYSTEM_USER ALL=(root) NOPASSWD: $_script nft preset classic
$SYSTEM_USER ALL=(root) NOPASSWD: $_script nft preset smart
$SYSTEM_USER ALL=(root) NOPASSWD: $_script nft ios1
$SYSTEM_USER ALL=(root) NOPASSWD: $_script nft ios1-off
$SYSTEM_USER ALL=(root) NOPASSWD: $_script nft ios2
$SYSTEM_USER ALL=(root) NOPASSWD: $_script nft ios2-off
$SYSTEM_USER ALL=(root) NOPASSWD: $_script nft zapret2
$SYSTEM_USER ALL=(root) NOPASSWD: $_script nft zapret2-start
$SYSTEM_USER ALL=(root) NOPASSWD: $_script nft zapret2-stop
$SYSTEM_USER ALL=(root) NOPASSWD: $_script nft zapret2-rm
$SYSTEM_USER ALL=(root) NOPASSWD: $_script nft zapret2-wscale
$SYSTEM_USER ALL=(root) NOPASSWD: $_script geoblock list --json
$SYSTEM_USER ALL=(root) NOPASSWD: $_script geoblock add [a-z][a-z]
$SYSTEM_USER ALL=(root) NOPASSWD: $_script geoblock remove [a-z][a-z]
$SYSTEM_USER ALL=(root) NOPASSWD: $_script upstream list --json
$SYSTEM_USER ALL=(root) NOPASSWD: $_script upstream add [A-Za-z0-9]* * * * * * *
$SYSTEM_USER ALL=(root) NOPASSWD: $_script upstream remove [A-Za-z0-9]*
$SYSTEM_USER ALL=(root) NOPASSWD: $_script upstream enable [A-Za-z0-9]*
$SYSTEM_USER ALL=(root) NOPASSWD: $_script upstream disable [A-Za-z0-9]*
$SYSTEM_USER ALL=(root) NOPASSWD: $_script upstream test [A-Za-z0-9]*
$SYSTEM_USER ALL=(root) NOPASSWD: $_script expert list --catalog
$SYSTEM_USER ALL=(root) NOPASSWD: $_script expert list --json
$SYSTEM_USER ALL=(root) NOPASSWD: $_script expert set [a-z]* [a-z]* * --no-apply
$SYSTEM_USER ALL=(root) NOPASSWD: $_script expert clear [a-z]* [a-z]* --no-apply
$SYSTEM_USER ALL=(root) NOPASSWD: $_script expert apply
$SYSTEM_USER ALL=(root) NOPASSWD: $_script superexpert status --json
$SYSTEM_USER ALL=(root) NOPASSWD: $_script superexpert show
$SYSTEM_USER ALL=(root) NOPASSWD: $_script superexpert write
$SYSTEM_USER ALL=(root) NOPASSWD: $_script superexpert on
$SYSTEM_USER ALL=(root) NOPASSWD: $_script superexpert off
$SYSTEM_USER ALL=(root) NOPASSWD: $_script pq-check
$SYSTEM_USER ALL=(root) NOPASSWD: $_script pq-check [A-Za-z0-9]*
EOF

  if [ -n "$_visudo" ]; then
    $SUDO "$_visudo" -cf "$_tmp" >/dev/null || die "Сгенерированный файл sudoers для MTProxyL некорректен"
  fi

  $SUDO mkdir -p "$(dirname "$MTPROXYL_SUDOERS_FILE")"
  $SUDO install -m 0440 "$_tmp" "$MTPROXYL_SUDOERS_FILE"
  say "Права sudo для MTProxyL установлены: $MTPROXYL_SUDOERS_FILE"
}

# ── Systemd unit (non-root service with sudoers-backed updates) ─────────────
generate_service() {
  cat <<EOF
[Unit]
Description=MTProxyL-Panel
After=network.target

[Service]
Type=simple
User=$SYSTEM_USER
ExecStart=$PANEL_BINARY_PATH --config $CONFIG_FILE
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

# Hardening compatible with sudo-based updater operations
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$CONFIG_DIR $DATA_DIR

[Install]
WantedBy=multi-user.target
EOF
}

# ── Read a value with default ────────────────────────────────────────────────
prompt() {
  _prompt="$1"
  _default="$2"
  if [ -n "$_default" ]; then
    printf '%s [%s]: ' "$_prompt" "$_default" >&2
  else
    printf '%s: ' "$_prompt" >&2
  fi
  read -r _val < /dev/tty
  echo "${_val:-$_default}"
}

prompt_secret() {
  _prompt="$1"
  printf '%s: ' "$_prompt" >&2
  stty -echo 2>/dev/null || true
  read -r _val < /dev/tty
  stty echo 2>/dev/null || true
  printf '\n' >&2
  echo "$_val"
}

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Установщик MTProxyL-Panel

Создаёт отдельного системного пользователя '$SYSTEM_USER', ставит панель в
стандартные пути Linux и настраивает узкие права sudo для обновления и
для команд MTProxyL.

Использование: $0 <команда> [параметры]

Команды:
  install [версия]        Установить или обновить (по умолчанию — последний релиз)
  install --from-source[=ветка]
                          Собрать из исходников (Docker либо Go+Node)
  uninstall               Удалить бинарник, службу и права sudo
  purge                   Удалить всё, включая конфиг, данные и пользователя
  --help                  Показать эту справку

Примеры:
  $0 install                            Последний релиз панели
  $0 install ${RELEASE_TAG_PREFIX}0.1.0        Конкретная версия
  $0 install --from-source=dev          Сборка из ветки dev
  $0 uninstall                          Удалить службу и бинарник
  $0 purge                              Удалить всё

Каталоги:
  Бинарник: $PANEL_BINARY_PATH
  Конфиг:   $CONFIG_FILE
  Данные:   $DATA_DIR
EOF
}

# ═════════════════════════════════════════════════════════════════════════════
#  INSTALL
# ═════════════════════════════════════════════════════════════════════════════
do_install() {
  _version="${1:-}"

  printf '\n  Установка MTProxyL-Panel\n\n'

  # ── Stage 0: Check dependencies ────────────────────────────────────────
  check_deps

  # ── Stage 1: Create system user and directories ─────────────────────────
  warn_legacy_install
  create_system_user
  join_telemt_group
  setup_directories

  # ── Stage 2: Detect architecture ─────────────────────────────────────────
  say "Определение архитектуры..."
  ARCH=$(detect_arch)
  say "Архитектура: $ARCH"

  # ── Stage 3: Obtain the binary ───────────────────────────────────────────
  FROM_SOURCE=false
  if [ "${_version#--from-source}" != "$_version" ]; then
    # --from-source[=ветка]
    FROM_SOURCE=true
    _branch="${_version#--from-source}"
    _branch="${_branch#=}"
    build_from_source "${_branch:-main}"
  elif [ -n "$_version" ]; then
    TAG="$_version"
    say "Запрошенная версия: $TAG"
  else
    say "Поиск последнего релиза..."
    # The panel shares a repository with MTProxyL, so /releases/latest would
    # return an MTProxyL release that carries no panel assets. Pick the newest
    # tag with the panel prefix instead.
    _releases=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=100") \
      || die "Не удалось обратиться к API GitHub"
    # Пустой результат — это «релизов панели пока нет», а не сбой сети:
    # grep вернул бы ненулевой код и увёл в неверное сообщение.
    TAG=$(printf '%s\n' "$_releases" | grep '"tag_name"' | cut -d'"' -f4 \
      | grep "^${RELEASE_TAG_PREFIX}" | head -1 || true)
    if [ -z "$TAG" ]; then
      say "Релизов ${RELEASE_TAG_PREFIX}* в $REPO не найдено."
      say "Панель выпускается отдельно от MTProxyL. Опубликуйте тег"
      say "'${RELEASE_TAG_PREFIX}X.Y.Z' либо укажите версию явно:"
      say "  sh install.sh install ${RELEASE_TAG_PREFIX}0.1.0"
      say "Либо соберите прямо из ветки:"
      say "  sh install.sh install --from-source=dev"
      die "Нет доступного релиза панели"
    fi
    say "Последняя версия: $TAG"
  fi

  if [ "$FROM_SOURCE" = "false" ]; then
  TARBALL="mtproxyl-panel-${ARCH}-linux-gnu.tar.gz"
  URL="https://github.com/$REPO/releases/download/$TAG/$TARBALL"
  ensure_temp_dir
  TMP_TAR="$TEMP_DIR/$TARBALL"

  say "Скачивание $TARBALL..."
  curl -fSL "$URL" -o "$TMP_TAR" \
    || die "Скачивание не удалось. Проверьте, что версия $TAG существует."

  # Verify SHA256 checksum if available
  if command -v sha256sum >/dev/null 2>&1; then
    CHECKSUM_URL="https://github.com/$REPO/releases/download/$TAG/checksums.txt"
    TMP_CHECKSUMS="$TEMP_DIR/checksums.txt"
    if curl -fsSL "$CHECKSUM_URL" -o "$TMP_CHECKSUMS" 2>/dev/null; then
      say "Проверка контрольной суммы SHA256..."
      EXPECTED=$(grep "$TARBALL" "$TMP_CHECKSUMS" | awk '{print $1}')
      if [ -n "$EXPECTED" ]; then
        ACTUAL=$(sha256sum "$TMP_TAR" | awk '{print $1}')
        if [ "$EXPECTED" != "$ACTUAL" ]; then
          die "Контрольная сумма не совпала! Ожидалась: $EXPECTED, получена: $ACTUAL"
        fi
        say "Контрольная сумма верна"
      else
        say "ВНИМАНИЕ: в файле сумм нет записи для $TARBALL — проверка пропущена"
      fi
    else
      say "ВНИМАНИЕ: файл контрольных сумм недоступен — проверка пропущена"
    fi
  fi

  say "Распаковка..."
  tar -xzf "$TMP_TAR" -C "$TEMP_DIR"
  EXTRACTED="$TEMP_DIR/mtproxyl-panel-${ARCH}-linux"

  install_binary "$EXTRACTED" "$PANEL_BINARY_PATH"
  say "Установлено: $PANEL_BINARY_PATH ($TAG)"
  fi

  # ── Stage 4: Configure ──────────────────────────────────────────────────
  if [ -f "$CONFIG_FILE" ]; then
    say "Конфиг уже существует ($CONFIG_FILE) — мастер настройки пропущен"
    TELEMT_PATH=$(toml_value "$CONFIG_FILE" telemt binary_path || true)
    TELEMT_SERVICE=$(toml_value "$CONFIG_FILE" telemt service_name || true)
    [ -n "${TELEMT_PATH:-}" ] || TELEMT_PATH=$(detect_telemt)
    [ -n "${TELEMT_SERVICE:-}" ] || TELEMT_SERVICE="telemt"
    # Honour whatever the existing config says rather than re-prompting, so a
    # re-run does not silently grant or revoke MTProxyL permissions.
    MTPROXYL_ENABLED=$(toml_value "$CONFIG_FILE" mtproxyl enabled || true)
    [ -n "${MTPROXYL_ENABLED:-}" ] || MTPROXYL_ENABLED="false"
    _cfg_script=$(toml_value "$CONFIG_FILE" mtproxyl script_path || true)
    [ -n "${_cfg_script:-}" ] && MTPROXYL_SCRIPT="$_cfg_script"
    _cfg_dir=$(toml_value "$CONFIG_FILE" mtproxyl install_dir || true)
    [ -n "${_cfg_dir:-}" ] && MTPROXYL_INSTALL_DIR="$_cfg_dir"
    $SUDO chown "$SYSTEM_USER:$SYSTEM_USER" "$CONFIG_FILE"
    $SUDO chmod 600 "$CONFIG_FILE"
  else
    say "Первичная настройка..."
    echo ""

    TELEMT_URL=$(prompt "Адрес API telemt" "http://127.0.0.1:9091")
    TELEMT_AUTH=$(prompt "Заголовок авторизации API telemt (пусто, если нет)" "")
    ADMIN_USER=$(prompt "Логин администратора" "admin")
    ADMIN_PASS=$(prompt_secret "Пароль администратора")

    [ -n "$ADMIN_PASS" ] || die "Пароль не может быть пустым"

    TELEMT_DETECTED=$(detect_telemt)
    TELEMT_PATH=$(prompt "Путь к бинарнику telemt" "$TELEMT_DETECTED")

    TELEMT_SERVICE=$(prompt "Имя systemd-службы telemt" "telemt")

    # MTProxyL integration is optional and only offered when it is actually
    # installed here, so a standalone panel install is not bothered by it.
    MTPROXYL_ENABLED="false"
    if [ -x "$MTPROXYL_SCRIPT" ]; then
      say "Обнаружен MTProxyL: $MTPROXYL_SCRIPT"
      _answer=$(prompt "Включить интеграцию с MTProxyL (режим, Selfmask, лимитер)? [y/N]" "y")
      case "$_answer" in
        [yY]*) MTPROXYL_ENABLED="true" ;;
      esac
    fi

    say "Вычисление хеша пароля..."
    # Use printf to pipe password to avoid heredoc indentation issues
    PASS_HASH=$(printf '%s\n' "$ADMIN_PASS" | "$PANEL_BINARY_PATH" hash-password) \
      || die "Не удалось вычислить хеш пароля"

    JWT_SECRET=$(openssl rand -hex 32)

    # Build config with standard paths
    _cfg="listen = \"0.0.0.0:8080\"
data_dir = \"$DATA_DIR\"

[telemt]
url = \"$TELEMT_URL\""

    if [ -n "$TELEMT_AUTH" ]; then
      _cfg="$_cfg
auth_header = \"$TELEMT_AUTH\""
    fi

    _cfg="$_cfg
binary_path = \"$TELEMT_PATH\"
service_name = \"$TELEMT_SERVICE\"

[panel]
binary_path = \"$PANEL_BINARY_PATH\"
service_name = \"$SERVICE_NAME\"

[mtproxyl]
enabled = $MTPROXYL_ENABLED
script_path = \"$MTPROXYL_SCRIPT\"
install_dir = \"$MTPROXYL_INSTALL_DIR\"
use_sudo = true

[auth]
username = \"$ADMIN_USER\"
password_hash = \"$PASS_HASH\"
jwt_secret = \"$JWT_SECRET\"
session_ttl = \"24h\""

    printf '%s\n' "$_cfg" | write_root "$CONFIG_FILE"
    $SUDO chown "$SYSTEM_USER:$SYSTEM_USER" "$CONFIG_FILE"
    $SUDO chmod 600 "$CONFIG_FILE"
    say "Конфиг сохранён: $CONFIG_FILE"
  fi

  install_sudoers_dropin "$TELEMT_PATH" "$TELEMT_SERVICE" "/etc/telemt/telemt.toml"

  if [ "${MTPROXYL_ENABLED:-false}" = "true" ]; then
    install_mtproxyl_sudoers "$MTPROXYL_SCRIPT" "$MTPROXYL_INSTALL_DIR"
  else
    # Drop stale permissions if the integration was turned off.
    $SUDO rm -f "$MTPROXYL_SUDOERS_FILE"
  fi

  # ── Stage 5: Install service ─────────────────────────────────────────────
  say "Установка systemd-службы..."
  generate_service | write_root "$SERVICE_FILE"
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable "$SERVICE_NAME"
  $SUDO systemctl start "$SERVICE_NAME"
  say "Служба $SERVICE_NAME запущена и включена в автозагрузку"

  # ── Stage 6: Done ───────────────────────────────────────────────────────
  _ip=$(hostname -I 2>/dev/null | awk '{print $1}') || _ip="<server-ip>"
  printf '\n'
  say "Установка завершена"
  printf '\n'
  printf '  Адрес панели:  http://%s:8080\n' "$_ip"
  printf '  Пользователь:  %s\n' "$SYSTEM_USER"
  printf '  Бинарник:      %s\n' "$PANEL_BINARY_PATH"
  printf '  Конфиг:        %s\n' "$CONFIG_FILE"
  printf '  Данные:        %s\n' "$DATA_DIR"
  printf '  Права sudo:    %s\n' "$SUDOERS_FILE"
  printf '  Служба:        %s\n' "$SERVICE_NAME"
  printf '\n'
  printf '  Полезные команды:\n'
  printf '    sudo systemctl status  %s\n' "$SERVICE_NAME"
  printf '    sudo systemctl restart %s\n' "$SERVICE_NAME"
  printf '    sudo journalctl -u %s -f\n' "$SERVICE_NAME"
  printf '\n'
}

# ═════════════════════════════════════════════════════════════════════════════
#  UNINSTALL
# ═════════════════════════════════════════════════════════════════════════════
do_uninstall() {
  printf '\n  Удаление MTProxyL-Panel\n\n'

  if [ -f "$SERVICE_FILE" ]; then
    say "Остановка службы..."
    $SUDO systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    $SUDO systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    $SUDO rm -f "$SERVICE_FILE"
    $SUDO systemctl daemon-reload
    say "Служба удалена"
  else
    say "Служба не найдена — пропускаем"
  fi

  if [ -f "$BIN_DIR/$BINARY_NAME" ]; then
    $SUDO rm -f "$PANEL_BINARY_PATH"
    say "Бинарник удалён"
  else
    say "Бинарник не найден — пропускаем"
  fi

  if [ -f "$SUDOERS_FILE" ]; then
    $SUDO rm -f "$SUDOERS_FILE"
    say "Права sudo удалены"
  fi

  # Leaving this behind would keep granting root commands to a user that is
  # about to be removed.
  if [ -f "$MTPROXYL_SUDOERS_FILE" ]; then
    $SUDO rm -f "$MTPROXYL_SUDOERS_FILE"
    say "Права sudo для MTProxyL удалены"
  fi

  printf '\n'
  say "Удаление завершено"
  say "Конфиг ($CONFIG_DIR) и данные ($DATA_DIR) сохранены"
  say "Полное удаление вместе с пользователем '$SYSTEM_USER': $0 purge"
  printf '\n'
}

# ═════════════════════════════════════════════════════════════════════════════
#  PURGE
# ═════════════════════════════════════════════════════════════════════════════
do_purge() {
  do_uninstall

  say "Удаление конфига и данных..."
  $SUDO rm -rf "$CONFIG_DIR"
  $SUDO rm -rf "$DATA_DIR"

  # Remove system user if no other processes depend on it
  if id "$SYSTEM_USER" >/dev/null 2>&1; then
    say "Удаление пользователя '$SYSTEM_USER'..."
    $SUDO userdel "$SYSTEM_USER" 2>/dev/null || true
  fi

  say "Полное удаление завершено — файлы mtproxyl-panel удалены"
  printf '\n'
}

# ── Build from source ────────────────────────────────────────────────────────
# Нужна, пока релиз не выпущен: позволяет собрать панель прямо из ветки
# репозитория и проверить её до публикации тега.
build_from_source() {
  _branch="${1:-main}"

  command -v git >/dev/null 2>&1 \
    || die "Для сборки из исходников нужен git. Установите его и повторите."

  ensure_temp_dir
  _src="$TEMP_DIR/src"

  say "Клонирование $REPO (ветка: $_branch)..."
  git clone --depth 1 --branch "$_branch" "https://github.com/${REPO}.git" "$_src" \
    || die "Клонирование не удалось. Проверьте имя ветки и доступ к сети."

  [ -d "$_src/mtproxyl-panel" ] || die "В ветке '$_branch' нет каталога mtproxyl-panel/"

  # Docker — предпочтительный путь: тулчейн живёт в контейнере и не остаётся
  # на сервере. MTProxyL так же собирает telemt, поэтому Docker обычно уже есть.
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    build_in_docker "$_src/mtproxyl-panel" "$_branch"
  elif command -v go >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    build_natively "$_src/mtproxyl-panel" "$_branch"
  else
    say "Не найдены ни Docker, ни Go/Node."
    say "Выберите один из вариантов:"
    say "  - установить Docker (MTProxyL умеет это сам), либо"
    say "  - установить Go 1.25+ и Node.js 20+, либо"
    say "  - опубликовать релиз ${RELEASE_TAG_PREFIX}X.Y.Z и ставить из него"
    die "Нет способа собрать из исходников"
  fi
}

build_in_docker() {
  _dir="$1"
  _branch="$2"
  _img="mtproxyl-panel-build:${_branch}"
  # Собираем только стадию с бинарником — рантайм-образ нам не нужен.
  _arch=$(detect_arch)
  case "$_arch" in
    x86_64)  _goarch="amd64" ;;
    aarch64) _goarch="arm64" ;;
    *)       die "Неподдерживаемая архитектура для сборки: $_arch" ;;
  esac

  say "Сборка в Docker (несколько минут)..."
  docker build --target backend \
    --build-arg "TARGETARCH=${_goarch}" \
    --build-arg "VERSION=source-${_branch}" \
    -t "$_img" "$_dir" \
    || die "Сборка в Docker не удалась"

  # Бинарник достаём из промежуточного контейнера: запускать его не нужно.
  _cid=$(docker create "$_img") || die "Не удалось создать контейнер сборки"
  docker cp "${_cid}:/app/mtproxyl-panel" "$_dir/mtproxyl-panel" \
    || { docker rm -f "$_cid" >/dev/null 2>&1; die "Не удалось извлечь бинарник"; }
  docker rm -f "$_cid" >/dev/null 2>&1 || true
  docker rmi "$_img" >/dev/null 2>&1 || true

  install_binary "$_dir/mtproxyl-panel" "$PANEL_BINARY_PATH"
  say "Установлено: $PANEL_BINARY_PATH (собрано из ветки $_branch в Docker)"
}

build_natively() {
  _dir="$1"
  _branch="$2"

  say "Сборка фронтенда (несколько минут)..."
  ( cd "$_dir/frontend" && npm ci --no-audit --no-fund && npm run build ) \
    || die "Сборка фронтенда не удалась"

  say "Сборка бинарника..."
  # Как в релизном Makefile: статический бинарник со встроенным фронтендом.
  ( cd "$_dir" && CGO_ENABLED=0 go build -ldflags="-s -w -X main.version=source-${_branch}" -o mtproxyl-panel . ) \
    || die "Сборка бэкенда не удалась"

  install_binary "$_dir/mtproxyl-panel" "$PANEL_BINARY_PATH"
  say "Установлено: $PANEL_BINARY_PATH (собрано из ветки $_branch)"
}

# ═════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═════════════════════════════════════════════════════════════════════════════
_cmd="${1:-install}"
shift 2>/dev/null || true

case "$_cmd" in
  install)    do_install "${1:-}" ;;
  uninstall)  do_uninstall ;;
  purge)      do_purge ;;
  --help|-h)  usage ;;
  *)          usage; exit 1 ;;
esac
