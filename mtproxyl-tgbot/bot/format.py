"""Тексты сообщений. Разметка HTML: её проще не сломать чужой строкой."""

from __future__ import annotations

import html
from datetime import datetime, timezone
from typing import Any
from urllib.parse import parse_qs, urlsplit

LEVEL_ICON = {"green": "🟢", "yellow": "🟡", "red": "🔴"}


def esc(value: Any) -> str:
    return html.escape(str(value), quote=False)


def human_bytes(num: Any) -> str:
    try:
        value = float(num or 0)
    except (TypeError, ValueError):
        return "0 Б"
    for unit in ("Б", "КБ", "МБ", "ГБ", "ТБ"):
        if value < 1024 or unit == "ТБ":
            return f"{value:.0f} {unit}" if unit == "Б" else f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} ТБ"


def human_duration(seconds: Any) -> str:
    try:
        total = int(seconds or 0)
    except (TypeError, ValueError):
        return "—"
    if total < 60:
        return f"{total} с"
    if total < 3600:
        return f"{total // 60} мин"
    if total < 86400:
        return f"{total // 3600} ч {total % 3600 // 60} мин"
    return f"{total // 86400} д {total % 86400 // 3600} ч"


def age_since(iso: str) -> str:
    """Сколько прошло с момента в RFC3339. Пусто — «—»."""
    if not iso:
        return "—"
    try:
        moment = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except ValueError:
        return "—"
    delta = (datetime.now(timezone.utc) - moment).total_seconds()
    return f"{human_duration(delta)} назад"


# ── Экраны ───────────────────────────────────────────────────────────────────

def status_text(st: dict, md: dict) -> str:
    running = st.get("status") == "running"
    icon = "🟢" if running else "🔴"
    mode_name = "Reanimator" if md.get("mode") == "reanimator" else "Manager"
    web = st.get("web") or {}
    web_only = web.get("proxy_mode") == "web"
    lines = [
        f"<b>MTProxyL v{esc(st.get('version', '?'))}</b> · {esc(mode_name)}",
        "",
        f"{icon} Прокси: <b>{'работает' if running else 'остановлен'}</b>",
        f"Режим: <code>{'Только WEB' if web_only else 'MTProto + WEB' if web.get('enabled') else 'MTProto'}</code>",
    ]
    if web_only:
        lines.append(f"WEB: <code>{esc(web.get('domain') or '—')}:443</code>")
    else:
        lines.append(f"Порт: <code>{esc(st.get('port', '?'))}</code>")
        lines.append(f"Домен (SNI): <code>{esc(st.get('domain') or '—')}</code>")
    if running:
        lines.append(f"Аптайм: {human_duration(st.get('uptime'))}")
    lines.append(f"Соединений: {esc(st.get('connections', 0))}")
    lines.append(f"Уникальных IP: {esc(st.get('unique_ips', 0))}")
    # traffic_total есть в обоих режимах; in/out — только у менеджера, у цели
    # API направления не разделяет.
    traffic = f"Трафик: {human_bytes(st.get('traffic_total'))}"
    if st.get("traffic_in") is not None or st.get("traffic_out") is not None:
        traffic += (
            f" (↓ {human_bytes(st.get('traffic_in'))}"
            f" ↑ {human_bytes(st.get('traffic_out'))})"
        )
    lines.append(traffic)
    if md.get("mode") == "reanimator":
        lines.append(f"Цель: <code>{esc(md.get('detected_mode') or 'неизвестна')}</code>")
    # WEB — отдельный тип прокси на том же порту, но со своим именем.
    if web.get("enabled") and not web_only:
        lines.append(f"WEB Proxy: <code>{esc(web.get('domain') or '—')}</code>"
                     f" ({esc(web.get('carrier') or '')})")
    if web.get("enabled") and web.get("frontend"):
        frontend = "HAProxy" if web.get("frontend") == "haproxy" else "nginx"
        lines.append(f"WEB frontend: <code>{frontend}</code>")
    return "\n".join(lines)


# ── Таблицы ──────────────────────────────────────────────────────────────────
# Telegram не умеет markdown-таблицы, зато умеет моноширинный блок — в нём
# колонки держатся сами. Ширина под узкий экран телефона: длиннее ~34 символов
# строка переносится и таблица рассыпается.

# Ширина колонки считается в символах, а эмодзи занимает две клетки. Поэтому
# в колонке-маркере эмодзи должно быть в каждой строке — иначе строки с ним
# окажутся на клетку шире соседних и таблица поедет.
def _cell(value: str, width: int, right: bool = False) -> str:
    text = str(value)
    if len(text) > width:
        text = text[: width - 1] + "…"
    return text.rjust(width) if right else text.ljust(width)


def _table(header: list[tuple[str, int, bool]], rows: list[list[str]]) -> str:
    """header — (заголовок, ширина, выравнивание вправо)."""
    lines = [" ".join(_cell(title, width, right) for title, width, right in header)]
    lines.append("─" * min(sum(w for _, w, _ in header) + len(header) - 1, 40))
    for row in rows:
        lines.append(" ".join(
            _cell(value, width, right) for value, (_, width, right) in zip(row, header)
        ))
    return "<pre>" + esc("\n".join(lines)) + "</pre>"


def users_page_text(users: list[dict], page: int, per_page: int, note: str = "") -> str:
    total = len(users)
    head = f"{note}\n\n" if note else ""
    if not total:
        return f"{head}<b>Пользователи</b>\n\nПока никого. Кнопка ниже добавит первого."
    pages = max(1, (total + per_page - 1) // per_page)
    page = max(0, min(page, pages - 1))
    active = sum(1 for u in users if u.get("enabled"))
    chunk = users[page * per_page:(page + 1) * per_page]

    rows = []
    for user in chunk:
        mark = "🟢" if user.get("enabled", True) else "⛔"
        limits = "".join([
            "с" if user.get("max_conns") else "",
            "а" if user.get("max_ips") else "",
            "к" if user.get("quota_bytes") else "",
            "д" if user.get("expires") else "",
        ])
        rows.append([mark, user.get("label", "?"), human_bytes(user.get("total_bytes")), limits])

    table = _table(
        [("", 1, False), ("Имя", 14, False), ("Трафик", 9, True), ("Лим", 4, False)],
        rows,
    )
    return (
        f"{head}<b>Пользователи</b> · {total} шт., активных {active}\n"
        f"Страница {page + 1} из {pages}\n{table}\n"
        "<i>Лим: с — соединения, а — адреса, к — квота, д — срок</i>"
    )


def user_card(user: dict) -> str:
    label = esc(user.get("label", "?"))
    on = user.get("enabled", True)
    lines = [
        f"<b>{label}</b> — {'🟢 включён' if on else '⛔ выключен'}",
        "",
        f"Трафик: {human_bytes(user.get('total_bytes'))}"
        f" (↓ {human_bytes(user.get('total_in'))} ↑ {human_bytes(user.get('total_out'))})",
    ]
    limits = []
    if user.get("max_conns"):
        limits.append(f"соединений ≤ {user['max_conns']}")
    if user.get("max_ips"):
        limits.append(f"адресов ≤ {user['max_ips']}")
    if user.get("quota_bytes"):
        limits.append(f"квота {human_bytes(user['quota_bytes'])}")
    if user.get("expires"):
        limits.append(f"до {esc(user['expires'])}")
    lines.append("Лимиты: " + (", ".join(limits) if limits else "не заданы"))
    if user.get("ip_history"):
        lines.append(f"Адресов в истории: {len(user['ip_history'])}")
    return "\n".join(lines)


def link_text(label: str, tg_links: str | list[str]) -> str:
    """Ссылка кнопкой и она же текстом — второе для копирования вручную.
    Ссылок может быть несколько: с выключенной маскировкой движок принимает и
    dd, и ee. Первая — основная, остальные идут следом подписанными."""
    links = [tg_links] if isinstance(tg_links, str) else list(tg_links)
    parts = [
        f"<b>{esc(label)}</b>",
        "",
        f'👉 <b><a href="{esc(links[0])}">Подключиться</a></b>',
        "",
        f"<code>{esc(web_link(links[0]))}</code>",
    ]
    for extra in links[1:]:
        # Кнопкой тоже: у WEB копия — это tg://webproxy, вручную её не набрать.
        parts += [
            "",
            f"<i>{esc(_link_kind(extra))}</i>",
            f'👉 <a href="{esc(extra)}">Подключиться</a>',
            f"<code>{esc(web_link(extra))}</code>",
        ]
    return "\n".join(parts)


def _link_kind(tg_link: str) -> str:
    """Вид ссылки виден по началу секрета: ee — TLS-маскировка, dd — secure.
    У WEB отдельная схема: там dd означает лишь представление секрета."""
    if _is_webproxy(tg_link):
        return "ещё одна ссылка (WEB)"
    secret = parse_qs(urlsplit(tg_link).query).get("secret", [""])[0]
    if secret.startswith("ee"):
        return "ещё одна ссылка (ee · TLS)"
    if secret.startswith("dd"):
        return "ещё одна ссылка (dd · secure)"
    return "ещё одна ссылка"


def _is_webproxy(tg_link: str) -> bool:
    return urlsplit(tg_link).netloc == "webproxy"


def web_link(tg_link: str) -> str:
    """tg://proxy?… → https://t.me/proxy?… — то же самое, но открывается везде.
    У tg://webproxy аналога на t.me нет, поэтому её отдаём как есть: подменённая
    ссылка вела бы в никуда."""
    if _is_webproxy(tg_link):
        return tg_link
    parts = urlsplit(tg_link)
    return f"https://t.me/proxy?{parts.query}" if parts.query else tg_link


def traffic_text(report: dict) -> str:
    users = report.get("users") or []
    rows = sorted(users, key=lambda u: u.get("total") or 0, reverse=True)
    if not rows:
        return "<b>Трафик по пользователям</b>\n\nДанных пока нет."

    shown = rows[:25]
    table = _table(
        [("", 1, False), ("Имя", 13, False), ("Трафик", 9, True), ("Соед", 4, True), ("IP", 3, True)],
        [
            [
                "🟢" if u.get("enabled", True) else "⛔",
                u.get("user", "?"),
                human_bytes(u.get("total")),
                str(u.get("connections") or 0),
                str(u.get("unique_ips") or 0),
            ]
            for u in shown
        ],
    )

    total_conns = sum(int(u.get("connections") or 0) for u in rows)
    total_ips = sum(int(u.get("unique_ips") or 0) for u in rows)
    total_bytes = sum(int(u.get("total") or 0) for u in rows)

    lines = ["<b>Трафик по пользователям</b>", table]
    lines.append(
        f"Всего: {human_bytes(total_bytes)} · соединений {total_conns} · адресов {total_ips}"
    )
    if len(rows) > len(shown):
        lines.append(f"Показаны {len(shown)} из {len(rows)} по объёму трафика.")
    if report.get("directional"):
        # Первой строкой может стоять сборная «удалённые пользователи» — она в
        # пример по направлениям не годится, это не один человек.
        top = next((u for u in shown if not u.get("deleted")), None)
        if top:
            lines.append(
                f"<i>{esc(top.get('user', '?'))}: ↓ {human_bytes(top.get('in'))}"
                f" ↑ {human_bytes(top.get('out'))}</i>"
            )
    else:
        lines.append("<i>Цель отдаёт только общую сумму, без деления на ↓/↑.</i>")
    if not report.get("persistent"):
        lines.append("<i>Счётчики цели обнуляются вместе с её перезапуском.</i>")
    return "\n".join(lines)


def availability_text(state: dict, with_probes: bool = False) -> str:
    result = state.get("result") or {}
    target = state.get("target") or {}
    quota = state.get("quota") or {}
    lines = ["<b>Доступность из России</b>", ""]

    error = result.get("error")
    if not result:
        lines.append("Проверок ещё не было.")
    elif error:
        lines.append(f"⚠️ Свежего результата нет: {esc(error)}")
    else:
        icon = LEVEL_ICON.get(result.get("level", "red"), "🔴")
        lines.append(
            f"{icon} <b>{result.get('percentage', 0):.0f}%</b> — "
            f"{result.get('success_probes', 0)} из {result.get('total_probes', 0)} зондов"
        )
        lines.append(f"Проверено: {age_since(result.get('checked_at', ''))}")

    host = target.get("host") or "не определён"
    sni = target.get("sni")
    lines.append(f"Цель: <code>{esc(host)}:{esc(target.get('port', 0))}</code>"
                 + (f" (SNI {esc(sni)})" if sni else ""))
    lines.append(
        f"Автопроверка: {'каждые ' + str(state.get('interval', 15)) + ' мин' if state.get('auto_check') else 'выключена'}"
        f" · порог {state.get('threshold', 50)}%"
    )
    lines.append(
        f"Квота: {quota.get('remaining', 0)} из {quota.get('budget', 0)} кредитов"
        + ("" if quota.get("has_token") else " (без токена)")
    )

    if with_probes and result.get("probes"):
        probes = sorted(result["probes"], key=lambda p: not p.get("tls_success"))
        lines.append(_table(
            [("", 1, False), ("Город", 13, False), ("Провайдер", 15, False)],
            [
                [
                    "✅" if p.get("tls_success") else "❌",
                    p.get("city") or "?",
                    p.get("network") or "?",
                ]
                for p in probes[:25]
            ],
        ))
        # Причины отказа одинаковы у большинства зондов — списком они бы
        # заняли экран, а сгруппированные читаются одной строкой.
        reasons: dict[str, int] = {}
        for probe in probes:
            if not probe.get("tls_success"):
                reason = (probe.get("error") or "нет ответа").rstrip(".")
                reasons[reason] = reasons.get(reason, 0) + 1
        if reasons:
            lines.append("<b>Почему не дошли:</b>")
            lines += [
                f"• {esc(reason)} — {count}"
                for reason, count in sorted(reasons.items(), key=lambda kv: -kv[1])
            ]
    return "\n".join(lines)


def settings_text(cfg, manager: bool) -> str:
    notify = cfg.notify
    def flag(key: str) -> str:
        return "включено" if notify.get(key, True) else "выключено"

    lines = [
        "<b>Настройки бота</b>",
        "",
        f"Доступность ниже порога: <b>{flag('availability')}</b>"
        f" · проверка каждые {cfg.interval('availability')} мин",
        f"Прокси упал / поднялся: <b>{flag('proxy')}</b>"
        f" · проверка каждые {cfg.interval('proxy')} мин",
        f"Лимиты пользователей: <b>{flag('limits')}</b>"
        f" · проверка каждые {cfg.interval('limits')} мин",
    ]
    if manager:
        auto = cfg.autobackup
        state = f"в {auto.get('time', '05:30')}" if auto.get("enabled") else "выключен"
        lines.append(f"Итог автобэкапа: <b>{flag('backup')}</b>")
        lines.append(f"Автобэкап: <b>{state}</b>"
                     + (" · файл в чат" if auto.get("send_file") else " · без файла"))
    lines += ["", f"Администраторов: {len(cfg.admins)}"]
    return "\n".join(lines)


HELP_TEXT = """<b>MTProxyL — команды</b>

/menu — главное меню кнопками
/status — состояние прокси
/users — список пользователей
/link — ссылка и QR-код
/traffic — трафик по пользователям
/availability — доступность из России
/dc — дата-центры Telegram: RTT, писатели, покрытие
/check — проверить доступность прямо сейчас
/start_proxy, /stop_proxy, /restart_proxy — управление прокси
/backup — сделать бэкап и прислать сюда (только Manager)
/settings — уведомления и таймеры
/help — эта справка

Всё то же самое есть кнопками — /menu."""


def dc_text(report: dict) -> str:
    """Таблица дата-центров: RTT, писатели, покрытие."""
    if not report.get("available"):
        why = report.get("error") or "данных нет"
        return f"<b>Дата-центры Telegram</b>\n\n{esc(why)}"
    rows = report.get("dcs") or []
    threshold = int(report.get("threshold") or 0)
    table = _table(
        [("", 1, False), ("DC", 6, False), ("RTT", 6, True), ("Писат.", 7, True), ("Покр.", 5, True)],
        [
            [
                "✅" if d.get("ok") else "⚠️",
                str(d.get("dc")),
                f"{int(d.get('rtt_ms') or 0)} мс",
                f"{int(d.get('alive_writers') or 0)}/{int(d.get('required_writers') or 0)}",
                f"{int(d.get('coverage_pct') or 0)}%",
            ]
            for d in rows
        ],
    )
    coverage = int(report.get("coverage_pct") or 0)
    # Порог 0 — предупреждения выключены: показываем цифры без приговора.
    icon = "🟢" if threshold <= 0 or coverage >= threshold else "🔴"
    limit = "порог выключен" if threshold <= 0 else f"порог {threshold}%"
    return (
        f"<b>Дата-центры Telegram</b>\n"
        f"{icon} Покрытие {coverage}%, {limit} — писателей "
        f"{report.get('alive_writers', 0)} из {report.get('required_writers', 0)}\n{table}\n"
        "<i>Писатели: живых / нужно. Это связь движка с Telegram, не доступность прокси.</i>"
    )
