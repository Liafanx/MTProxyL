#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/mtproxyl-selfmask-404.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

INSTALL_DIR="$test_dir"
CONFIG_DIR="$test_dir/config"
SETTINGS_FILE="$test_dir/settings.conf"
VERSION=test
mkdir -p "$CONFIG_DIR"

# shellcheck source=/dev/null
source "$repo/lib/utils.sh"
source "$repo/lib/settings.sh"
source "$repo/lib/selfmask.sh"

site="$test_dir/site"
mkdir -p "$site"

# Тёмный сайт со стилями только для игры: фон берём из body, текст светлый.
printf '*{margin:0}\nbody{position:fixed;background:#1a1a2e;font-family:x}\n.ui h1{color:red}\n' > "$site/style.css"
printf '<!doctype html><title>Game</title>\n' > "$site/index.html"
# Страница из прошлых версий считается нашей и заменяется.
cat > "$site/404.html" << 'HTML_EOF'
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Страница не найдена</title>
<link rel="stylesheet" href="/style.css">
</head>
<body>
  <h1>Страница не найдена</h1>
  <p>Такой страницы здесь нет. Проверьте адрес или вернитесь на <a href="/">главную</a>.</p>
  <p class="footer">&copy; 2026</p>
</body>
</html>
HTML_EOF
[ "$(sha256sum "$site/404.html" | cut -d' ' -f1)" = "$SELFMASK_404_LEGACY_SHA" ]

_selfmask_write_404 "$site" 0
grep -q 'background:#1a1a2e;color:#e6e8ee' "$site/404.html"
if grep -q 'style.css' "$site/404.html"; then echo 'Страница не должна зависеть от стилей сайта' >&2; exit 1; fi

# Сайт сменился — наша страница пересобирается под новый фон.
printf 'body{background:#fafafa}\n' > "$site/style.css"
_selfmask_write_404 "$site" 0
grep -q 'background:#fafafa;color:#1f2330' "$site/404.html"

# Tailwind: фон в классе body.
rm -f "$site/style.css"
printf '<body class="bg-[#0b0f19] text-white">\n' > "$site/index.html"
[ "$(_selfmask_site_bg "$site")" = '#0b0f19' ]

# Правленую пользователем страницу не трогаем.
echo '<!-- своя правка -->' >> "$site/404.html"
_selfmask_write_404 "$site" 0
tail -1 "$site/404.html" | grep -q 'своя правка'

# Совсем чужую тоже.
printf 'custom\n' > "$site/404.html"
_selfmask_write_404 "$site" 0
[ "$(cat "$site/404.html")" = custom ]

echo 'Selfmask 404: OK'
