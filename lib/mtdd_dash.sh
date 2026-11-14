#!/bin/bash
# Дашборд метрик mtdd — тот же вид, что у `mtdd-ctl metrics` лаунчера mtdd.
#
# Рендер (_mtdd_dash_py) перенесён без изменений логики из install.sh проекта
# mtdd (функция metrics_python), https://github.com/ugDeDe/mtdd, коммит
# 20f501b (v1.0.0). Изменено только: подсказка «sudo mtdd-ctl metrics --watch»
# заменена на команду MTProxyL. При обновлении — перенести функцию заново.
#
# Лицензия этого фрагмента — MIT, как у mtdd:
#
#   MIT License
#
#   Copyright (c) 2026 mtdd contributors
#
#   Permission is hereby granted, free of charge, to any person obtaining a copy
#   of this software and associated documentation files (the "Software"), to deal
#   in the Software without restriction, including without limitation the rights
#   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#   copies of the Software, and to permit persons to whom the Software is
#   furnished to do so, subject to the following conditions:
#
#   The above copyright notice and this permission notice shall be included in all
#   copies or substantial portions of the Software.
#
#   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
#   SOFTWARE.

# История точек для графиков «Динамика»: своя у MTProxyL, рядом с кэшем.
MTDD_DASH_HISTORY="${INSTALL_DIR:-/opt/mtproxyl}/cache/mtdd-metrics-history.tsv"

# Палитра лаунчера mtdd. Без терминала или при NO_COLOR — без цвета.
_mtdd_dash_run() {
    local _c=0
    [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR+x}" ] && _c=1
    local _script; _script=$(mktemp "${TMPDIR:-/tmp}/mtproxyl-dash.XXXXXX") || return 1
    _mtdd_dash_py > "$_script"
    if [ "$_c" = 1 ]; then
        MTDD_COLOR=1 MTDD_C_RESET=$'\033[0m' MTDD_C_BOLD=$'\033[1m' MTDD_C_DIM=$'\033[2m' \
        MTDD_C_GRAY=$'\033[38;5;245m' MTDD_C_ACCENT=$'\033[38;5;45m' MTDD_C_VIOLET=$'\033[38;5;141m' \
        MTDD_C_GREEN=$'\033[38;5;114m' MTDD_C_YELLOW=$'\033[38;5;221m' MTDD_C_RED=$'\033[38;5;203m' \
            python3 -I "$_script"
    else
        MTDD_COLOR=0 python3 -I "$_script"
    fi
    local _rc=$?
    rm -f "$_script"
    return $_rc
}

# Снять /v1/status и Prometheus в каталог $1. Токены читает помощник сам.
_mtdd_dash_fetch() {
    _mtdd_py dash-input "$1" 2>/dev/null && [ -s "$1/status.json" ]
}

# mtdd_metrics_dashboard [live] — дашборд метрик mtdd (Manager и цель Reanimator).
mtdd_metrics_dashboard() {
    local _work _key _hist="$MTDD_DASH_HISTORY"
    mkdir -p "${_hist%/*}" 2>/dev/null || _hist=""
    _work=$(mktemp -d "${TMPDIR:-/tmp}/mtproxyl-dash.XXXXXX") || return 1
    if ! _mtdd_dash_fetch "$_work"; then
        rm -rf "$_work"
        log_error "API mtdd не отвечает: $(mtdd_api_unavailable_reason)"
        return 1
    fi
    if [ "${1:-}" != live ]; then
        MTDD_JSON="$_work/status.json" MTDD_METRICS_TXT="$_work/metrics.txt" \
        MTDD_HISTORY_FILE="$_hist" _mtdd_dash_run
        rm -rf "$_work"
        return 0
    fi
    # Живой режим: как `mtdd-ctl metrics --watch` — обновление раз в 2 с,
    # выход по q или Ctrl+C. История живого режима своя, во временном каталоге.
    # Ctrl+C только ставит флаг: return из trap вышел бы из той функции, что
    # работала в момент нажатия (fetch, рендер), а не из цикла. Прежний trap
    # меню восстанавливается.
    local _stop=0 _old_int; _old_int=$(trap -p INT)
    trap '_stop=1' INT
    while [ "$_stop" = 0 ]; do
        [ -t 1 ] && printf '\033[H\033[2J'
        if _mtdd_dash_fetch "$_work"; then
            [ "$_stop" = 0 ] || break
            MTDD_LIVE=1 MTDD_METRICS_FORCE=1 MTDD_HISTORY_FILE="$_work/live.tsv" \
            MTDD_JSON="$_work/status.json" MTDD_METRICS_TXT="$_work/metrics.txt" _mtdd_dash_run 2>"$_work/err"
            # Ctrl+C посреди отрисовки — без трейсбека Python; иначе ошибку показываем.
            [ "$_stop" = 0 ] && [ -s "$_work/err" ] && cat "$_work/err" >&2
        else
            [ "$_stop" = 0 ] || break
            log_warn "API mtdd не отвечает — повторяю… ($(mtdd_api_unavailable_reason))"
        fi
        [ "$_stop" = 0 ] || break
        echo -e "  ${DIM}q или Ctrl+C — выход${NC}"
        # Без терминала read сразу падает (а не ждёт 2 с) — тогда пауза сном.
        if { read -rsn1 -t 2 _key </dev/tty; } 2>/dev/null; then
            case "$_key" in q|Q) break ;; esac
        else
            [ $? -gt 128 ] || [ "$_stop" != 0 ] || sleep 2
        fi
    done
    if [ -n "$_old_int" ]; then eval "$_old_int"; else trap - INT; fi
    rm -rf "$_work"
    return 0
}

# Уникальные IP mtdd: seen (прошли рукопожатие, как ip_active у telemt) и
# active (передали ≥ unique_ip_min_bytes) — онлайн и оценка HyperLogLog за
# час, день и неделю. --json — для панели.
mtdd_ip_stats() {
    engine_is_mtdd || { log_error "Статистика уникальных IP — у движка mtdd"; return 1; }
    local _st _j
    _st=$(_mtdd_py get /v1/status 2>/dev/null) || { log_error "API mtdd не отвечает: $(mtdd_api_unavailable_reason)"; return 1; }
    _j=$(jq -c '
        def per(k): {seen: (.unique_ip_history[k].estimate // 0),
                     active: (.unique_ip_history[k + "_active"].estimate // 0),
                     started_at: (.unique_ip_history[k].started_at // null)};
        {available: (.unique_ip_history != null),
         online: {seen: (.unique_ips_seen // 0), active: (.unique_ips_active // 0)},
         hour: per("hour"), day: per("day"), week: per("week"),
         min_bytes: (.unique_ip_history.min_bytes // null),
         collection_started_at: (.unique_ip_history.collection_started_at // null),
         relative_error: (.unique_ip_history.relative_standard_error // null),
         persistent: (.unique_ip_history.persistence_enabled // false),
         timezone: (.unique_ip_history.timezone // "UTC")}' <<< "$_st" 2>/dev/null) \
        || { log_error "Ответ mtdd не разобран"; return 1; }
    if [ "${1:-}" = "--json" ]; then printf '%s\n' "$_j"; return 0; fi
    jq -r '
        def d(t): if t == null then "—" else (t | strftime("%d.%m %H:%M UTC")) end;
        if .available | not then "  Эта сборка mtdd не ведёт историю уникальных IP" else
        "",
        "  Уникальные IP mtdd (seen — прошли рукопожатие; active — передали ≥ \(((.min_bytes // 0) / 1048576 * 10 | floor) / 10) MiB)",
        "",
        "  онлайн   seen \(.online.seen)   active \(.online.active)",
        "  час      seen ≈\(.hour.seen)   active ≈\(.hour.active)   с \(d(.hour.started_at))",
        "  день     seen ≈\(.day.seen)   active ≈\(.day.active)   с \(d(.day.started_at))",
        "  неделя   seen ≈\(.week.seen)   active ≈\(.week.active)   с \(d(.week.started_at))",
        "",
        "  Оценка HyperLogLog, ошибка ±\((.relative_error // 0) * 1000 | round / 10)% · сбор с \(d(.collection_started_at))\(if .persistent then "" else " · не сохраняется при перезапуске" end)",
        "  Сравнивать с telemt (ip_active) — по seen; реальных пользователей — по active."
        end' <<< "$_j"
}

# Точка истории для графиков без показа (таймер снимков истории IP).
mtdd_metrics_record() {
    local _work; _work=$(mktemp -d "${TMPDIR:-/tmp}/mtproxyl-dash.XXXXXX") || return 0
    if _mtdd_dash_fetch "$_work"; then
        mkdir -p "${MTDD_DASH_HISTORY%/*}" 2>/dev/null
        MTDD_RECORD_ONLY=1 MTDD_JSON="$_work/status.json" MTDD_HISTORY_FILE="$MTDD_DASH_HISTORY" \
            _mtdd_dash_run >/dev/null 2>&1
    fi
    rm -rf "$_work"
    return 0
}

_mtdd_dash_py() {
    cat <<'MTDD_DASH_PY'
import json
import os
import re
import shutil
import sys
import textwrap
import time
import unicodedata

# Цвета приходят из bash; без MTDD_COLOR=1 (NO_COLOR, не TTY) они пустые,
# и статус передаётся только символами и текстом.
COLOR = os.environ.get("MTDD_COLOR") == "1"


def c(name):
    return os.environ.get("MTDD_C_" + name, "") if COLOR else ""


RESET = c("RESET")
BOLD = c("BOLD")
DIM = c("DIM")
GRAY = c("GRAY")
ACCENT = c("ACCENT")
VIOLET = c("VIOLET")
GREEN = c("GREEN")
YELLOW = c("YELLOW")
RED = c("RED")

# 8 уровней в одной строке; 3 строки дают 24
BLOCKS = "\u2581\u2582\u2583\u2584\u2585\u2586\u2587\u2588"
GRAPH_ROWS = 3
LEVELS = GRAPH_ROWS * len(BLOCKS)
# минимальная ширина карточки KPI
CARD_MIN = 28
HISTORY_POINTS = 120
ANSI = re.compile(r"\033\[[0-9;]*m")

# Статус: (символ, цвет). Символ есть всегда — цвет его только усиливает.
STATUS = {
    "ok": ("\u2713", GREEN),
    "warn": ("!", YELLOW),
    "bad": ("\u2717", RED),
    "na": ("\u00b7", GRAY),
}


def term_width():
    # Ширина области вывода: на колонку уже терминала, чтобы не переносилось.
    cols = shutil.get_terminal_size((80, 24)).columns
    return max(38, min(119, cols - 1))


WIDTH = term_width()
# ширина содержимого после отступа в 2 пробела
AVAIL = WIDTH - 2


# --- Текст и ширина -------------------------------------------------------

def char_width(ch):
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def width(text):
    return sum(char_width(ch) for ch in ANSI.sub("", text))


def pad(text, size):
    return text + " " * max(0, size - width(text))


def rpad(text, size):
    return " " * max(0, size - width(text)) + text


def clip(text, size):
    # Обрезает по отображаемой ширине, не ломая ANSI-последовательности.
    if width(text) <= size:
        return text
    out, used = [], 0
    for part in re.split(r"(\033\[[0-9;]*m)", text):
        if ANSI.fullmatch(part):
            out.append(part)
            continue
        for ch in part:
            if used + char_width(ch) > size - 1:
                return "".join(out) + "\u2026" + RESET
            out.append(ch)
            used += char_width(ch)
    return "".join(out)


def cell(text, size, color=""):
    body = pad(clip(text, size), size)
    return (color + body + RESET) if color else body


def spread(left, right, size):
    # left у левого края, right у правого, в одну строку шириной size.
    right_w = width(right)
    left = clip(left, max(1, size - right_w - 1))
    return left + " " * max(1, size - width(left) - right_w) + right


def plural(count, one, few, many):
    count = int(count)
    if count % 10 == 1 and count % 100 != 11:
        return one
    if 2 <= count % 10 <= 4 and not 12 <= count % 100 <= 14:
        return few
    return many


def num(value):
    try:
        value = int(value)
    except (TypeError, ValueError):
        return "\u2014"
    return "{:,}".format(value).replace(",", "\u2009")


def human(size):
    try:
        size = float(size or 0)
    except (TypeError, ValueError):
        return "\u2014"
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if size < 1024 or unit == "TiB":
            if unit == "B" or size >= 100:
                return "{:.0f} {}".format(size, unit)
            return "{:.1f} {}".format(size, unit)
        size /= 1024.0
    return "{:.0f} B".format(size)


def human_rate(value):
    return human(value) + "/\u0441"


def ms(value):
    return "{:.0f} ms".format(value)


def human_duration(seconds):
    try:
        seconds = int(seconds)
    except (TypeError, ValueError):
        return "\u2014"
    days, rest = divmod(seconds, 86400)
    hours, rest = divmod(rest, 3600)
    minutes, secs = divmod(rest, 60)
    if days:
        return "{} \u0434 {} \u0447".format(days, hours)
    if hours:
        return "{} \u0447 {} \u043c".format(hours, minutes)
    if minutes:
        return "{} \u043c\u0438\u043d".format(minutes)
    return "{} \u0441".format(secs)


# --- Оформление: статусы, секции, заметки ----------------------------------

def badge(status):
    symbol, color = STATUS[status]
    return color + BOLD + symbol + RESET


def status_text(status, text):
    return badge(status) + " " + STATUS[status][1] + text + RESET


def rtt_status(value):
    if value is None:
        return "na"
    return "ok" if value < 80 else ("warn" if value < 150 else "bad")


def rtt_color(value):
    return STATUS[rtt_status(value)][1]


def section(title):
    return (
        "\n  " + VIOLET + "\u258c" + RESET + " " + BOLD + clip(title, AVAIL - 2) + RESET
        + "\n  " + GRAY + "\u2500" * AVAIL + RESET
    )


def note(text):
    return "  " + DIM + clip(text, AVAIL) + RESET


def wrap_note(text):
    # Длинную заметку переносит по словам на несколько строк.
    return [note(line) for line in textwrap.wrap(text, AVAIL)]


def wrap_items(items):
    # Элементы через « · » с переносом по ширине (для сводок в одну-две строки).
    lines, current = [], ""
    for item in items:
        candidate = (current + " \u00b7 " + item) if current else item
        if current and width(candidate) > AVAIL:
            lines.append(current)
            current = item
        else:
            current = candidate
    if current:
        lines.append(current)
    return [note(line) for line in lines]


def pairs(items):
    # Пары «подпись — значение»: две колонки на широком экране, одна на узком.
    cols = 3 if AVAIL >= 100 else (2 if AVAIL >= 60 else 1)
    col_w = AVAIL // cols
    label_w = 18
    out = []
    for start in range(0, len(items), cols):
        line = "  "
        for label, value in items[start:start + cols]:
            line += GRAY + pad(clip(label, label_w), label_w) + RESET
            line += cell(str(value), col_w - label_w)
        out.append(line.rstrip())
    return out


# --- Разбор данных -----------------------------------------------------------

def load_prom(path):
    series = {}
    if not path:
        return series
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or " " not in line:
                    continue
                key, rest = line.split(" ", 1)
                labels = {}
                if "{" in key:
                    key, raw = key.split("{", 1)
                    for item in raw.rstrip("}").split(","):
                        if "=" not in item:
                            continue
                        label, value = item.split("=", 1)
                        labels[label.strip()] = value.strip().strip('"')
                try:
                    value = float(rest)
                except ValueError:
                    continue
                series.setdefault(key, []).append((labels, value))
    except OSError:
        return {}
    return series


def prom_scalar(prom, key):
    items = prom.get(key) or []
    if not items:
        return None
    return int(items[0][1])


def pnum(prom, key):
    value = prom_scalar(prom, key)
    return num(value) if value is not None else "\u2014"


def history_path():
    return os.environ.get("MTDD_HISTORY_FILE", "")


def history_load(path):
    # TSV из 8 колонок; строки другого вида (старые/битые) пропускаются.
    rows = []
    if not path:
        return rows
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if len(parts) != 8:
                    continue
                try:
                    rows.append([float(part) for part in parts])
                except ValueError:
                    continue
    except OSError:
        return []
    return rows


def history_save(path, rows):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(
                "{:.0f}\t{:.0f}\t{:.0f}\t{:.0f}\t{:.1f}\t{:.0f}\t{:.0f}\t{:.0f}\n".format(*row)
            )
    os.replace(tmp, path)


def sample(data, force=False):
    path = history_path()
    if not path:
        return
    now = time.time()
    rows = history_load(path)
    try:
        interval = float(os.environ.get("MTDD_METRICS_INTERVAL", "25"))
    except ValueError:
        interval = 25.0
    if not force and rows and now - rows[-1][0] < interval:
        return
    me = data.get("me") or {}
    traffic = 0.0
    rtts = []
    for dc in me.get("dcs") or []:
        traffic += float(dc.get("rx_bytes_total", 0)) + float(dc.get("tx_bytes_total", 0))
        if dc.get("connected") and dc.get("ping_rtt_us"):
            rtts.append(float(dc["ping_rtt_us"]) / 1000.0)
    rows.append(
        [
            now,
            float(data.get("connections_active", 0)),
            float(data.get("unique_ips_active", 0)),
            traffic,
            (sum(rtts) / len(rtts)) if rtts else 0.0,
            float(me.get("connected_dcs", 0)),
            float(data.get("connections_rejected_total", 0)),
            float(data.get("connections_accepted_total", 0)),
        ]
    )
    rows = rows[-5000:]
    try:
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        history_save(path, rows)
    except OSError:
        pass


def rate_series(points):
    rates = []
    for prev, cur in zip(points, points[1:]):
        delta_t = cur[0] - prev[0]
        if delta_t <= 0:
            continue
        rates.append(max(0.0, (cur[3] - prev[3]) / delta_t))
    return rates


def estimate(node):
    # Оценка из {"estimate": N} или голого числа; None, если поля нет.
    if isinstance(node, dict):
        node = node.get("estimate")
    if isinstance(node, (int, float)) and not isinstance(node, bool):
        return int(node)
    return None


def period_active(history, key):
    # «Активные» IP за период: имена полей у разных версий сервера могут отличаться.
    own = history.get(key)
    candidates = [history.get(key + "_active")]
    if isinstance(own, dict):
        candidates += [own.get("active"), own.get("active_estimate")]
    for node in candidates:
        value = estimate(node)
        if value is not None:
            return value
    return None


def ip_rows(data, history):
    # [(подпись, замеченные, активные)] — активные None у старых серверов.
    now_active = estimate(data.get("unique_ips_active"))
    now_seen = estimate(data.get("unique_ips_seen"))
    has_active = now_seen is not None or any(
        period_active(history, key) is not None for key in ("hour", "day", "week")
    )
    if has_active:
        rows = [("\u0441\u0435\u0439\u0447\u0430\u0441", now_seen, now_active)]
    else:
        rows = [("\u0441\u0435\u0439\u0447\u0430\u0441", now_active, None)]
    for key, label in (("hour", "\u0447\u0430\u0441"), ("day", "\u0434\u0435\u043d\u044c"), ("week", "\u043d\u0435\u0434\u0435\u043b\u044f")):
        rows.append((label, estimate(history.get(key)), period_active(history, key)))
    return rows, has_active


def fmt_ip(value, approx):
    if value is None:
        return "\u2014"
    return ("\u2248" if approx else "") + num(value)


# --- Карточки KPI ------------------------------------------------------------

def card(title, big, lines, size, body_height):
    # Рамка ╭─ Заголовок ─╮ с body_height строками внутри.
    inner = size - 4
    title = clip(title, size - 6)
    top = (
        GRAY + "\u256d\u2500" + RESET + " " + BOLD + title + RESET + " "
        + GRAY + "\u2500" * (size - width(title) - 5) + "\u256e" + RESET
    )
    body = [big] + lines
    body += [""] * (body_height - len(body))
    out = [top]
    for text in body:
        out.append(
            GRAY + "\u2502" + RESET + " " + pad(clip(text, inner), inner) + " " + GRAY + "\u2502" + RESET
        )
    out.append(GRAY + "\u2570" + "\u2500" * (size - 2) + "\u256f" + RESET)
    return out


def card_columns():
    # Сколько карточек в ряд: 4 на широком терминале, 2 на среднем, 1 на узком.
    if AVAIL >= 4 * CARD_MIN + 3:
        return 4
    if AVAIL >= 2 * CARD_MIN + 1:
        return 2
    return 1


def render_cards(cards):
    per_row = card_columns()
    size = (AVAIL - (per_row - 1)) // per_row
    out = []
    for start in range(0, len(cards), per_row):
        group = cards[start:start + per_row]
        height = max(1 + len(item[2]) for item in group)
        boxes = [card(t, big, lines, size, height) for t, big, lines in group]
        for parts in zip(*boxes):
            out.append("  " + " ".join(parts))
    return out


def with_status(status, value, unit=""):
    text = BOLD + value + RESET
    if unit:
        text += " " + DIM + unit + RESET
    if status:
        text = badge(status) + " " + text
    return text


def connections_card(data):
    accepted = int(data.get("connections_accepted_total") or 0)
    rejected = int(data.get("connections_rejected_total") or 0)
    # Много отказов относительно принятых — повод заглянуть в причины.
    share = rejected / float(accepted + rejected) if accepted + rejected else 0.0
    status = "warn" if accepted + rejected >= 20 and share > 0.2 else "ok"
    return (
        "\u0421\u043e\u0435\u0434\u0438\u043d\u0435\u043d\u0438\u044f",
        with_status(status, num(data.get("connections_active")), "\u0430\u043a\u0442\u0438\u0432\u043d\u044b\u0445"),
        [
            GRAY + "\u043f\u0440\u0438\u043d\u044f\u0442\u043e " + RESET + num(accepted),
            GRAY + "\u043e\u0442\u043a\u043b\u043e\u043d\u0435\u043d\u043e " + RESET + num(rejected),
            GRAY + "\u0440\u0443\u043a\u043e\u043f\u043e\u0436\u0430\u0442\u0438\u0439 " + RESET + num(data.get("handshakes_total")),
        ],
    )


def ips_card(data, history):
    rows, has_active = ip_rows(data, history)
    now = rows[0]
    if has_active:
        head = BOLD + fmt_ip(now[2], False) + RESET + " / " + fmt_ip(now[1], False)
        head += " " + DIM + "\u0430\u043a\u0442. / \u0432\u0438\u0434." + RESET
    else:
        head = BOLD + fmt_ip(now[1], False) + RESET + " " + DIM + "\u0441\u0435\u0439\u0447\u0430\u0441" + RESET
    lines = []
    for label, seen, active in rows[1:]:
        if has_active:
            value = fmt_ip(active, True) + " / " + fmt_ip(seen, True)
        else:
            value = fmt_ip(seen, True)
        lines.append(GRAY + pad(label, 7) + RESET + value)
    return "\u0423\u043d\u0438\u043a\u0430\u043b\u044c\u043d\u044b\u0435 IP", head, lines


def traffic_card(dcs, rates):
    rx = sum(float(dc.get("rx_bytes_total", 0)) for dc in dcs)
    tx = sum(float(dc.get("tx_bytes_total", 0)) for dc in dcs)
    if rates:
        head = with_status(None, human_rate(rates[-1]))
        peak = GRAY + "\u043f\u0438\u043a " + RESET + human_rate(max(rates))
    else:
        head = DIM + "\u0441\u043e\u0431\u0438\u0440\u0430\u044e \u0438\u0441\u0442\u043e\u0440\u0438\u044e\u2026" + RESET
        peak = GRAY + "\u043f\u0438\u043a " + RESET + "\u2014"
    return (
        "\u0422\u0440\u0430\u0444\u0438\u043a \u0432 \u0441\u0435\u043a\u0443\u043d\u0434\u0443",
        head,
        [GRAY + "\u2193 \u043f\u0440\u0438\u043d\u044f\u0442\u043e " + RESET + human(rx), GRAY + "\u2191 \u043e\u0442\u043f\u0440\u0430\u0432\u043b\u0435\u043d\u043e " + RESET + human(tx), peak],
    )


def rtt_card(dcs):
    live = [float(dc["ping_rtt_us"]) / 1000.0 for dc in dcs if dc.get("connected") and dc.get("ping_rtt_us")]
    up = sum(1 for dc in dcs if dc.get("connected"))
    if live:
        avg = sum(live) / len(live)
        head = with_status(rtt_status(avg), ms(avg))
        spread_text = "{:.0f}\u2013{:.0f} ms".format(min(live), max(live))
    else:
        head = with_status("na", "\u2014")
        spread_text = "\u2014"
    return (
        "ME RTT",
        head,
        [GRAY + "\u043f\u043e DC " + RESET + spread_text, GRAY + "DC \u0432 \u0441\u0435\u0442\u0438 " + RESET + "{} \u0438\u0437 {}".format(up, len(dcs))],
    )


# --- Графики ------------------------------------------------------------------

def resample(values, size):
    # Подгоняет ряд под size колонок: растягивает или усредняет по корзинам.
    count = len(values)
    if count == size:
        return list(values)
    if count < size:
        return [values[min(count - 1, int(i * count / size))] for i in range(size)]
    out = []
    for i in range(size):
        first = int(i * count / size)
        last = max(first + 1, int((i + 1) * count / size))
        chunk = values[first:last]
        out.append(sum(chunk) / len(chunk))
    return out


def level_of(value, low, high):
    # Уровень 1..24: минимум 1, чтобы нулевая линия всегда была видна.
    if high <= low:
        return LEVELS // 2 if low > 0 else 1
    ratio = (value - low) / (high - low)
    return 1 + max(0, min(LEVELS - 1, int(ratio * (LEVELS - 0.001))))


def block_for(level, row):
    # Символ ячейки: row=0 — нижняя строка графика, 2 — верхняя.
    fill = max(0, min(len(BLOCKS), level - row * len(BLOCKS)))
    return BLOCKS[fill - 1] if fill else " "


def paint_columns(levels, colors, row):
    out, current = [], None
    for level, color in zip(levels, colors):
        if color != current:
            out.append(RESET + color if current is not None else color)
            current = color
        out.append(block_for(level, row))
    return "".join(out) + (RESET if current else "")


def bounds(values, ranged=False):
    # Границы оси: от нуля, если разброс большой, иначе от минимума ряда.
    #
    # ranged=True — всегда от минимума (RTT: ноль на оси ничего не говорит).
    high = max(values)
    low = min(values) if ranged or min(values) >= 0.5 * high else 0.0
    return low, high


def graph(title, values, fmt, axis, color_of=None, status_of=None, ranged=False):
    # Трёхстрочный график: заголовок и текущее значение, ось min/max слева.
    if len(values) < 2:
        return [
            "  " + BOLD + title + RESET,
            "  " + DIM + "\u0441\u043e\u0431\u0438\u0440\u0430\u044e \u0438\u0441\u0442\u043e\u0440\u0438\u044e\u2026" + RESET,
            "",
        ]
    low, high = bounds(values, ranged)
    columns = AVAIL - axis - 2
    series = resample(values, columns)
    levels = [level_of(v, low, high) for v in series]
    colors = [color_of(v) if color_of else ACCENT for v in series]

    current = fmt(values[-1])
    if status_of:
        current = badge(status_of(values[-1])) + " " + current
    head = spread(
        "  " + BOLD + title + RESET,
        GRAY + "\u0441\u0435\u0439\u0447\u0430\u0441 " + RESET + BOLD + current + RESET,
        AVAIL + 2,
    )
    labels = {2: fmt(high), 1: "", 0: fmt(low)}
    out = [head]
    for row in (2, 1, 0):
        mark = "\u2502" if row == 1 else "\u2524"
        out.append(
            "  " + GRAY + rpad(labels[row], axis) + " " + mark + RESET
            + paint_columns(levels, colors, row)
        )
    out.append("")
    return out


def axis_width(specs):
    # Общая ширина подписей оси, чтобы все графики начинались с одной колонки.
    size = 0
    for _, values, fmt, extra in specs:
        if len(values) >= 2:
            low, high = bounds(values, extra.get("ranged", False))
            size = max(size, width(fmt(low)), width(fmt(high)))
    return size


def dynamics(rows, live):
    # Секция графиков по истории измерений.
    if len(rows) < 2:
        return [section("\u0414\u0438\u043d\u0430\u043c\u0438\u043a\u0430")] + [
            note("\u0441\u043e\u0431\u0438\u0440\u0430\u044e \u0438\u0441\u0442\u043e\u0440\u0438\u044e\u2026 \u0442\u043e\u0447\u043a\u0430 \u0434\u043e\u0431\u0430\u0432\u043b\u044f\u0435\u0442\u0441\u044f \u043f\u0440\u0438 status/metrics (\u043d\u0435 \u0447\u0430\u0449\u0435 \u0440\u0430\u0437\u0430 \u0432 25 \u0441)"),
            note("\u0436\u0438\u0432\u043e\u0439 \u0440\u0435\u0436\u0438\u043c \u0441 \u0433\u0440\u0430\u0444\u0438\u043a\u0430\u043c\u0438: mtproxyl metrics engine live"),
        ]
    points = rows[-HISTORY_POINTS:]
    span = points[-1][0] - points[0][0]
    out = [section("\u0414\u0438\u043d\u0430\u043c\u0438\u043a\u0430 \u00b7 {} {} \u0437\u0430 {}".format(
        num(len(points)), plural(len(points), "\u0442\u043e\u0447\u043a\u0430", "\u0442\u043e\u0447\u043a\u0438", "\u0442\u043e\u0447\u0435\u043a"), human_duration(span)))]
    out.append("")
    rtts = [row[4] for row in points if row[4] > 0]
    # (заголовок, ряд, формат, расширенные параметры)
    specs = [
        ("\u0410\u043a\u0442\u0438\u0432\u043d\u044b\u0435 \u0441\u043e\u0435\u0434\u0438\u043d\u0435\u043d\u0438\u044f", [row[1] for row in points], num, {}),
        ("\u0423\u043d\u0438\u043a\u0430\u043b\u044c\u043d\u044b\u0435 IP", [row[2] for row in points], num, {}),
        ("\u0422\u0440\u0430\u0444\u0438\u043a \u0432 \u0441\u0435\u043a\u0443\u043d\u0434\u0443", rate_series(points), human_rate, {}),
        ("ME RTT", rtts, ms, {"color_of": rtt_color, "status_of": rtt_status, "ranged": True}),
    ]
    axis = axis_width(specs)
    for title, values, fmt, extra in specs:
        out += graph(title, values, fmt, axis, **extra)
    out.append(note("\u0441\u043b\u0435\u0432\u0430 \u2014 {} \u043d\u0430\u0437\u0430\u0434, \u0441\u043f\u0440\u0430\u0432\u0430 \u2014 \u0441\u0435\u0439\u0447\u0430\u0441".format(human_duration(span))))
    out += wrap_note(
        "q \u2014 \u0432\u044b\u0445\u043e\u0434 \u0438\u0437 \u0436\u0438\u0432\u043e\u0433\u043e \u0440\u0435\u0436\u0438\u043c\u0430" if live
        else "\u0442\u043e\u0447\u043a\u0430 \u043a\u0430\u0436\u0434\u044b\u0435 ~25 \u0441 \u00b7 \u0436\u0438\u0432\u043e\u0439 \u0440\u0435\u0436\u0438\u043c: mtproxyl metrics engine live"
    )
    return out


# --- Заголовок и общее состояние ----------------------------------------------

def overall(data, dcs):
    if not data.get("ready"):
        return "bad", "\u043d\u0435 \u0433\u043e\u0442\u043e\u0432"
    if dcs:
        up = sum(1 for dc in dcs if dc.get("connected"))
        if up == 0:
            return "bad", "\u043d\u0435\u0442 \u0441\u0432\u044f\u0437\u0438 \u0441 ME"
        if up < len(dcs):
            return "warn", "ME: {} \u0438\u0437 {} DC".format(up, len(dcs))
    return "ok", "\u0440\u0430\u0431\u043e\u0442\u0430\u0435\u0442"


def header(data, dcs, live):
    status, text = overall(data, dcs)
    right = status_text(status, text)
    if live:
        right += "  " + GREEN + "\u25cf live" + RESET
    right += "  " + GRAY + time.strftime("%H:%M:%S") + RESET
    out = ["\n" + spread("  " + VIOLET + "\u258c" + RESET + " " + BOLD + "\u041c\u0435\u0442\u0440\u0438\u043a\u0438" + RESET, right, WIDTH)]
    build = data.get("build") or {}
    out += wrap_items([
        "\u0430\u043f\u0442\u0430\u0439\u043c {}".format(human_duration(data.get("uptime_seconds"))),
        "\u043f\u043e\u043b\u044c\u0437\u043e\u0432\u0430\u0442\u0435\u043b\u0435\u0439 {} (\u0432\u043a\u043b. {})".format(num(data.get("users_total")), num(data.get("users_enabled"))),
        "\u0432\u0435\u0440\u0441\u0438\u044f {}".format(build.get("version", "?")),
        "\u0440\u0435\u0432\u0438\u0437\u0438\u044f {}".format(num(data.get("revision"))),
    ])
    return out


def ip_notes(data, history, prom):
    # Пояснения к карточке IP: что значит «активные» и откуда оценка.
    _, has_active = ip_rows(data, history)
    out = []
    if has_active:
        min_bytes = history.get("min_bytes", data.get("unique_ip_min_bytes"))
        if min_bytes is None:
            min_bytes = prom_scalar(prom, "mtdd_unique_ips_min_bytes")
        limit = " \u2265 " + human(min_bytes) if min_bytes else ""
        out += wrap_note("\u0430\u043a\u0442. \u2014 IP, \u043f\u0435\u0440\u0435\u0434\u0430\u0432\u0448\u0438\u0435{}; \u0432\u0438\u0434. \u2014 \u0432\u0441\u0435 \u0437\u0430\u043c\u0435\u0447\u0435\u043d\u043d\u044b\u0435 \u043f\u0440\u0438 \u0440\u0443\u043a\u043e\u043f\u043e\u0436\u0430\u0442\u0438\u0438".format(limit))
    period = ""
    started = (history.get("hour") or {}).get("started_at")
    if started:
        period = " \u00b7 \u0442\u0435\u043a\u0443\u0449\u0438\u0439 \u0447\u0430\u0441 \u0441 " + time.strftime("%H:%M UTC", time.gmtime(started))
    out += wrap_note("\u0447\u0430\u0441/\u0434\u0435\u043d\u044c/\u043d\u0435\u0434\u0435\u043b\u044f \u2014 \u043e\u0446\u0435\u043d\u043a\u0430 HyperLogLog, \u043e\u0448\u0438\u0431\u043a\u0430 \u00b1{:.1f}%{}".format(
        100.0 * float(history.get("relative_standard_error", 0.0325)), period))
    return out


# --- Таблицы и подробные секции -----------------------------------------------

# (ключ, заголовок, ширина, приоритет): при нехватке места уходят колонки
# с большим приоритетом; DC и состояние остаются всегда.
DC_COLUMNS = [
    ("dc", "DC", 5, 0),
    ("state", "\u0441\u043e\u0441\u0442\u043e\u044f\u043d\u0438\u0435", 10, 0),
    ("rtt", "RTT", 8, 1),
    ("ready", "ready/conn", 12, 2),
    ("clients", "\u043a\u043b\u0438\u0435\u043d\u0442\u044b", 9, 3),
    ("traffic", "\u0442\u0440\u0430\u0444\u0438\u043a", 11, 4),
    ("queue", "\u043e\u0447\u0435\u0440\u0435\u0434\u044c", 9, 5),
    ("target", "target", 8, 6),
]


def pick_columns():
    chosen, used = [], 0
    for column in sorted(DC_COLUMNS, key=lambda item: item[3]):
        if column[3] and used + column[2] > AVAIL:
            continue
        chosen.append(column)
        used += column[2]
    return [col for col in DC_COLUMNS if col in chosen]


def dc_values(dc):
    up = bool(dc.get("connected"))
    rtt = float(dc.get("ping_rtt_us", 0)) / 1000.0
    has_rtt = up and rtt > 0
    return {
        "dc": (str(dc.get("dc", "?")), GRAY),
        "state": (("\u2713 up" if up else "\u2717 down"), GREEN if up else RED),
        "rtt": ((ms(rtt) if has_rtt else "\u2014"), rtt_color(rtt) if has_rtt else ""),
        "ready": ("{}/{}".format(num(dc.get("ready_connections", 0)), num(dc.get("connections", 0))), ""),
        "clients": (num(dc.get("bound_clients", 0)), ""),
        "traffic": (human(float(dc.get("rx_bytes_total", 0)) + float(dc.get("tx_bytes_total", 0))), ""),
        "queue": ("{}/{}".format(num(dc.get("ready_queue_depth", 0)), num(dc.get("ready_queue_clients", 0))), ""),
        "target": (num(dc.get("pool_target", 0)), ""),
    }


def dc_order(dc):
    try:
        return (0, int(str(dc.get("dc", "other"))))
    except ValueError:
        return (1, 0)


def me_section(me, dcs):
    out = [section("ME / DC")]
    if not dcs:
        return out + [note("\u043d\u0435\u0442 \u0434\u0430\u043d\u043d\u044b\u0445: ME \u0435\u0449\u0451 \u043d\u0435 \u043f\u043e\u0434\u043a\u043b\u044e\u0447\u0430\u043b\u0441\u044f")]
    visible = [dc for dc in dcs if dc.get("connected") or dc.get("connections") or dc.get("pool_target")]
    visible = sorted(visible or dcs, key=dc_order)
    columns = pick_columns()
    out.append("  " + GRAY + "".join(cell(col[1], col[2]) for col in columns).rstrip() + RESET)
    for dc in visible:
        values = dc_values(dc)
        out.append("  " + "".join(cell(values[col[0]][0], col[2], values[col[0]][1]) for col in columns).rstrip())
    connected = sum(1 for dc in dcs if dc.get("connected"))
    out += wrap_items([
        "DC \u0432 \u0441\u0435\u0442\u0438: {} \u0438\u0437 {}".format(connected, len(dcs)),
        "\u0437\u0430\u043f\u0440\u043e\u0441\u043e\u0432 ME {}".format(num(me.get("requests_total"))),
        "\u043f\u0435\u0440\u0435\u043f\u043e\u0434\u043a\u043b\u044e\u0447\u0435\u043d\u0438\u0439 {}".format(num(me.get("reconnects_total"))),
        "\u043e\u0448\u0438\u0431\u043e\u043a \u0441\u043e\u0437\u0434\u0430\u043d\u0438\u044f {}".format(num(sum(int(dc.get("creation_failures_total", 0)) for dc in dcs))),
    ])
    answers = sum(int(dc.get("proxy_ans_received_total", 0)) for dc in dcs)
    if answers:
        delivered = sum(int(dc.get("proxy_ans_delivered_total", 0)) for dc in dcs)
        dropped = sum(
            int(dc.get("proxy_ans_dropped_unknown_total", 0)) + int(dc.get("proxy_ans_dropped_other_total", 0))
            for dc in dcs
        )
        age = max((int(dc.get("last_proxy_ans_age_seconds", 0)) for dc in dcs), default=0)
        out += wrap_items([
            "proxy-answer: \u043f\u043e\u043b\u0443\u0447\u0435\u043d\u043e {}".format(num(answers)),
            "\u0434\u043e\u0441\u0442\u0430\u0432\u043b\u0435\u043d\u043e {}".format(num(delivered)),
            "\u043f\u043e\u0442\u0435\u0440\u044f\u043d\u043e {}".format(num(dropped)),
            "\u043f\u043e\u0441\u043b\u0435\u0434\u043d\u0438\u0439 \u043e\u0442\u0432\u0435\u0442 {} \u043d\u0430\u0437\u0430\u0434".format(human_duration(age)),
        ])
    return out


def connections_section(data, prom):
    out = [section("\u0421\u043e\u0435\u0434\u0438\u043d\u0435\u043d\u0438\u044f")]
    backpressure = data.get("backpressure_events_total") or {}
    out += pairs([
        ("\u0432 \u0440\u0430\u0431\u043e\u0442\u0435", pnum(prom, "mtdd_handshakes_pending")),
        ("replay-\u043a\u044d\u0448", num(data.get("replay_cache_entries"))),
        ("backpressure c2s", num(backpressure.get("c2s"))),
        ("backpressure s2c", num(backpressure.get("s2c"))),
    ])
    handshakes = {}
    for labels, value in prom.get("mtdd_handshakes_total", []):
        handshakes[labels.get("result", "")] = int(value)
    parts = []
    for key, label in (("success", "\u0443\u0441\u043f\u0435\u0448\u043d\u043e"), ("failure", "\u043e\u0448\u0438\u0431\u043a\u0430"), ("timeout", "\u0442\u0430\u0439\u043c\u0430\u0443\u0442"), ("replay", "replay")):
        if key in handshakes:
            parts.append(num(handshakes[key]) + " " + label)
    if parts:
        out += wrap_items(["\u0440\u0443\u043a\u043e\u043f\u043e\u0436\u0430\u0442\u0438\u044f: " + parts[0]] + parts[1:])
    reasons = {}
    for labels, value in prom.get("mtdd_connections_rejected_total", []):
        if int(value):
            reasons[labels.get("reason", "other")] = int(value)
    if reasons:
        out += wrap_items(["\u043f\u0440\u0438\u0447\u0438\u043d\u044b \u043e\u0442\u043a\u0430\u0437\u0430: " + ", ".join(
            "{} {}".format(name, num(value)) for name, value in sorted(reasons.items()))])
    return out


def buffers_section(data, me, dcs, prom):
    buffers = data.get("buffer_bytes") or {}
    depth = sum(int(dc.get("ready_queue_depth", 0)) for dc in dcs)
    clients = sum(int(dc.get("ready_queue_clients", 0)) for dc in dcs)
    frames = sum(int(dc.get("frames_queued_bytes", 0)) for dc in dcs)
    outgoing = sum(int(dc.get("out_queued_bytes", 0)) for dc in dcs)
    return [section("\u0411\u0443\u0444\u0435\u0440\u044b \u0438 \u043e\u0447\u0435\u0440\u0435\u0434\u0438")] + pairs([
        ("relay", human(buffers.get("relay"))),
        ("pending write", human(buffers.get("pending_write"))),
        ("queued", human(buffers.get("queued"))),
        ("ME pending", human(me.get("pending_buffer_bytes"))),
        ("ready queue", "{} ({} \u043a\u043b.)".format(num(depth), num(clients))),
        ("frames / out", "{} / {}".format(human(frames), human(outgoing))),
        ("\u0431\u044e\u0434\u0436\u0435\u0442 \u0431\u0443\u0444\u0435\u0440\u043e\u0432", human(prom_scalar(prom, "mtdd_buffer_budget_bytes"))),
        ("\u043f\u0443\u043b \u043a\u043b\u0438\u0435\u043d\u0442\u043e\u0432", pnum(prom, "mtdd_client_pool_objects")),
    ])


def traffic_section(dcs):
    rx = sum(float(dc.get("rx_bytes_total", 0)) for dc in dcs)
    tx = sum(float(dc.get("tx_bytes_total", 0)) for dc in dcs)
    out = [section("\u0422\u0440\u0430\u0444\u0438\u043a")] + pairs([("\u043f\u0440\u0438\u043d\u044f\u0442\u043e", human(rx)), ("\u043e\u0442\u043f\u0440\u0430\u0432\u043b\u0435\u043d\u043e", human(tx))])
    direct_active = sum(int(dc.get("direct_active", 0)) for dc in dcs)
    direct_accepted = sum(int(dc.get("direct_accepted_total", 0)) for dc in dcs)
    if direct_active or direct_accepted:
        out += wrap_items([
            "\u043f\u0440\u044f\u043c\u044b\u0435 DC: {} \u0430\u043a\u0442\u0438\u0432\u043d\u044b\u0445".format(num(direct_active)),
            "{} \u0443\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043e".format(num(direct_accepted)),
            "{} \u043e\u0448\u0438\u0431\u043e\u043a \u043f\u043e\u0434\u043a\u043b\u044e\u0447\u0435\u043d\u0438\u044f".format(num(sum(int(dc.get("direct_connect_fail_total", 0)) for dc in dcs))),
        ])
    return out


def render(data, prom):
    live = os.environ.get("MTDD_LIVE") == "1"
    me = data.get("me") or {}
    dcs = me.get("dcs") or []
    history = data.get("unique_ip_history") or {}
    rows = history_load(history_path())
    rates = rate_series(rows[-HISTORY_POINTS:])

    out = header(data, dcs, live)
    out.append("")
    out += render_cards([
        connections_card(data),
        ips_card(data, history),
        traffic_card(dcs, rates),
        rtt_card(dcs),
    ])
    out += ip_notes(data, history, prom)
    out += dynamics(rows, live)
    out += connections_section(data, prom)
    out += buffers_section(data, me, dcs, prom)
    out += me_section(me, dcs)
    out += traffic_section(dcs)

    # Страховка: ни одна строка не должна переноситься терминалом.
    return "\n".join(clip(line, WIDTH) for line in "\n".join(out).split("\n"))


def main():
    path = os.environ.get("MTDD_JSON", "")
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh).get("data", {})
    except (OSError, ValueError):
        print("  \u043d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u0440\u0430\u0437\u043e\u0431\u0440\u0430\u0442\u044c \u043e\u0442\u0432\u0435\u0442 API")
        return 1

    force = os.environ.get("MTDD_METRICS_FORCE") == "1"
    sample(data, force=force)
    if os.environ.get("MTDD_RECORD_ONLY") == "1":
        return 0
    prom = load_prom(os.environ.get("MTDD_METRICS_TXT", ""))
    print(render(data, prom))
    return 0


if __name__ == "__main__":
    sys.exit(main())
MTDD_DASH_PY
}
