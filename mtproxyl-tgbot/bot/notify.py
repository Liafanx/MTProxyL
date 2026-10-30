"""Наблюдатели: что бот сообщает сам, без нажатой кнопки.

Один тик в минуту решает, чему пришло время. Так настройки применяются сразу,
без перезапуска службы, и не приходится держать четыре независимых таймера.

Сообщение уходит на смене состояния, а не на каждой проверке: «прокси лежит»
раз в пять минут перестают читать через час.
"""

from __future__ import annotations

import asyncio
import logging
import time
from datetime import date, datetime, timedelta

from aiogram import Bot
from aiogram.exceptions import TelegramAPIError

from . import cli, config, ui
from .cli import CliError
from .format import LEVEL_ICON, esc, human_bytes

log = logging.getLogger(__name__)

TICK_SECONDS = 60


async def broadcast(bot: Bot, text: str) -> None:
    for admin in config.load().admins:
        try:
            await bot.send_message(admin, text, disable_web_page_preview=True)
            # Уведомление остаётся в истории, а меню съезжает под него: иначе
            # оно оказалось бы выше и человек листал бы вверх за кнопками.
            await ui.move_menu_down_in(bot, admin)
        except TelegramAPIError as exc:
            log.warning("не удалось написать %s: %s", admin, exc)


def _due(state: dict, key: str, minutes: int) -> bool:
    last = state.get("last_run", {}).get(key, 0)
    return time.time() - last >= minutes * 60


def _mark(state: dict, key: str) -> None:
    state.setdefault("last_run", {})[key] = time.time()


def _count(state: dict, key: str) -> None:
    """Событие для отчёта за неделю."""
    events = state.setdefault("weekly_events", {})
    events[key] = int(events.get(key) or 0) + 1


# ── Дата-центры Telegram ─────────────────────────────────────────────────────

async def check_dc(bot: Bot, state: dict) -> None:
    """Покрытие писателей к DC. Шлём не на каждой проверке, а на переходе
    через порог — как и по доступности из России."""
    try:
        report = await cli.dc_status()
    except CliError as exc:
        log.debug("состояние DC недоступно: %s", exc)
        return
    cfg = config.load()
    # Перезапуск движка сторожем MTProxyL — один раз на перезапуск. Прошлые,
    # случившиеся до запуска бота, новостью не считаем.
    auto = report.get("auto_restart") or {}
    last = int(auto.get("last_restart_at") or 0)
    if "dc_restart_at" not in state:
        state["dc_restart_at"] = last
    elif last > int(state.get("dc_restart_at") or 0):
        state["dc_restart_at"] = last
        _count(state, "dc_restart")
        if cfg.notify_on("dc"):
            await broadcast(
                bot,
                f"♻️ <b>Движок перезапущен</b>\n\nПокрытие DC "
                f"{auto.get('last_restart_coverage', '?')}% было ниже порога "
                f"{auto.get('threshold', '?')}%. Следующий перезапуск — не раньше чем "
                f"через {auto.get('pause_min', auto.get('cooldown_min', 5))} мин.\n\nПодробнее — /dc",
            )

    # Нет данных или middle proxy выключен — сказать нечего: писателей к DC
    # в прямом режиме не бывает, и это не поломка.
    if not report.get("available"):
        return

    zeros = sorted(str(d.get("dc")) for d in report.get("dcs", [])
                   if int(d.get("required_writers") or 0) > 0
                   and int(d.get("alive_writers") or 0) == 0)
    previous = state.get("dc_zero", [])
    state["dc_zero"] = zeros
    if cfg.notify_on("dc_zero") and zeros != previous:
        if zeros:
            await broadcast(bot, "🔴 <b>DC без писателей</b>\n\n"
                            + esc(", ".join(zeros))
                            + "\nMiddle proxy может отключиться. Подробнее — /dc")
        elif previous:
            await broadcast(bot, "🟢 Во всех DC снова есть писатели. Подробнее — /dc")

    # Общие уведомления покрытия и отдельная тревога о нулевом DC независимы.
    if not cfg.notify_on("dc"):
        state.pop("dc_bad", None)
        return

    # Нулевой порог выключает только общие предупреждения покрытия.
    # Забываем и прошлое состояние: иначе после включения прилетит «просело»
    # про давно прошедшую просадку.
    threshold = int(report.get("threshold") or 0)
    if threshold <= 0:
        state.pop("dc_bad", None)
        return

    coverage = int(report.get("coverage_pct") or 0)
    covered = report.get("covered_writers", report.get("alive_writers", 0))
    bad = coverage < threshold
    was_bad = state.get("dc_bad")

    if was_bad is None:
        state["dc_bad"] = bad
        if not bad:
            return
    elif was_bad == bad:
        return
    state["dc_bad"] = bad

    rows = report.get("dcs") or []
    weak = [d for d in rows if not d.get("ok")]
    if bad:
        listing = ", ".join(f"DC {d.get('dc')} — {int(d.get('coverage_pct') or 0)}%" for d in weak[:6])
        text = (
            f"🔴 <b>Связь с дата-центрами Telegram просела</b>\n\n"
            f"Покрытие {coverage}% при пороге {threshold}%: в зачёт "
            f"{covered} из {report.get('required_writers', 0)}, живых всего "
            f"{report.get('alive_writers', 0)}.\n"
        )
        if listing:
            text += f"Просели: {esc(listing)}\n"
        text += "\nПодробнее — /dc"
    else:
        text = (
            f"🟢 <b>Связь с дата-центрами восстановилась</b>\n\n"
            f"Покрытие {coverage}% — в зачёт {covered} "
            f"из {report.get('required_writers', 0)}, живых всего "
            f"{report.get('alive_writers', 0)}."
        )
    await broadcast(bot, text)


# ── Доступность ──────────────────────────────────────────────────────────────

async def check_availability(bot: Bot, state: dict) -> None:
    try:
        report = await cli.availability_status()
    except CliError as exc:
        log.debug("доступность недоступна: %s", exc)
        return
    result = report.get("result") or {}
    # Ошибка проверки — это не приговор прокси: исчерпанная квота или молчащий
    # сервис ничего не говорят о том, доходят ли до нас пользователи.
    if not result or result.get("error"):
        return

    threshold = int(report.get("threshold") or 50)
    percentage = float(result.get("percentage") or 0)
    bad = percentage < threshold
    was_bad = state.get("availability_bad")

    if was_bad is None:
        state["availability_bad"] = bad
        if not bad:
            return
    elif was_bad == bad:
        return
    state["availability_bad"] = bad
    if bad:
        _count(state, "availability_drop")

    icon = LEVEL_ICON.get(result.get("level", "red"), "🔴")
    target = (report.get("target") or {}).get("host") or "?"
    if bad:
        text = (
            f"{icon} <b>Доступность из России упала</b>\n\n"
            f"{percentage:.0f}% — дошли {result.get('success_probes', 0)} из "
            f"{result.get('total_probes', 0)} зондов, порог {threshold}%.\n"
            f"Цель: <code>{esc(target)}</code>\n\n"
            f"Подробнее по зондам — /availability"
        )
    else:
        text = (
            f"🟢 <b>Доступность вернулась</b>\n\n"
            f"{percentage:.0f}% — дошли {result.get('success_probes', 0)} из "
            f"{result.get('total_probes', 0)} зондов."
        )
    await broadcast(bot, text)


# ── Прокси ───────────────────────────────────────────────────────────────────

async def check_proxy(bot: Bot, state: dict) -> None:
    try:
        cli.invalidate("status")
        status = await cli.status()
    except CliError as exc:
        log.debug("статус недоступен: %s", exc)
        return
    running = status.get("status") == "running"
    was = state.get("proxy_running")

    if was is None:
        state["proxy_running"] = running
        if running:
            return
    elif was == running:
        return
    state["proxy_running"] = running
    if not running:
        _count(state, "proxy_down")

    if running:
        text = (
            "🟢 <b>Прокси снова работает</b>\n\n"
            f"Порт <code>{esc(status.get('port', '?'))}</code>, "
            f"соединений {esc(status.get('connections', 0))}."
        )
    else:
        text = (
            "🔴 <b>Прокси не отвечает</b>\n\n"
            f"Порт <code>{esc(status.get('port', '?'))}</code> не слушает.\n"
            "Запустить: /start_proxy"
        )
    await broadcast(bot, text)


# ── Выход к Telegram ─────────────────────────────────────────────────────────

_VIA = {"direct": "напрямую", "warp": "WARP", "donor": "донор", "awg": "свой AWG"}


def _egress_name(report: dict) -> str:
    via = report.get("via") or "direct"
    name = report.get("name") or ""
    if via == "awg" and name:
        return f"AWG «{esc(name)}»"
    if via == "donor" and name:
        return f"донор {esc(name)}"
    return _VIA.get(via, esc(via))


async def check_egress(bot: Bot, state: dict) -> None:
    """Смена выхода сторожем AWG и сбой текущего выхода — по одному разу."""
    try:
        report = await cli.egress()
    except CliError as exc:
        log.debug("выход недоступен: %s", exc)
        return
    awg = report.get("awg") or {}
    switch = awg.get("last_switch") or {}
    at = int(switch.get("at") or 0)
    # Переключения до запуска бота новостью не считаем.
    if "egress_switch_at" not in state:
        state["egress_switch_at"] = at
    elif at > int(state.get("egress_switch_at") or 0):
        state["egress_switch_at"] = at
        _count(state, "egress_switch")
        text = (f"🔀 <b>Выход к Telegram переключён</b>\n\n"
                f"«{esc(switch.get('from') or '?')}» → «{esc(switch.get('to') or '?')}»\n"
                f"Причина: {esc(switch.get('reason') or '—')}")
        if report.get("egress_ip"):
            text += f"\nАдрес выхода: <code>{esc(report['egress_ip'])}</code>"
        await broadcast(bot, text)
        # Переключились — значит, прежний сбой закрыт этим же сообщением.
        state["egress_bad"] = report.get("ok") is False
        return

    ok = report.get("ok")
    if ok is None:
        state.pop("egress_bad", None)
        return
    bad = ok is False
    was_bad = state.get("egress_bad")
    state["egress_bad"] = bad
    if was_bad is None or was_bad == bad:
        return
    if bad:
        text = f"🔴 <b>Выход к Telegram не отвечает</b>\n\n{_egress_name(report)}"
        if report.get("error"):
            text += f": {esc(report['error'])}"
        order = awg.get("order") or []
        if len(order) > 1:
            secs = int(awg.get("failover_after") or 180)
            wait = f"{secs // 60} мин" if secs % 60 == 0 else f"{secs} с"
            text += f"\nЗапасной включится после {wait} сбоя, если ответит."
    else:
        text = f"🟢 <b>Выход к Telegram снова работает</b>\n\n{_egress_name(report)}"
    await broadcast(bot, text)


# ── Лимиты пользователей ─────────────────────────────────────────────────────

def _limit_reason(user: dict) -> str | None:
    quota = int(user.get("quota_bytes") or 0)
    used = int(user.get("total_bytes") or 0)
    if quota and used >= quota:
        return f"израсходована квота {human_bytes(quota)}"
    expires = str(user.get("expires") or "")
    if expires:
        try:
            if datetime.fromisoformat(expires.replace("Z", "+00:00")).date() < date.today():
                return f"истёк срок ({expires})"
        except ValueError:
            pass
    # Просто выключенный секрет сюда не попадает: его выключили руками, и
    # уведомление о собственном же нажатии кнопки — шум.
    return None


async def check_limits(bot: Bot, state: dict) -> None:
    try:
        cli.invalidate("secrets")
        users = await cli.secrets()
    except CliError as exc:
        log.debug("список пользователей недоступен: %s", exc)
        return

    hit = {u.get("label", ""): reason for u in users if (reason := _limit_reason(u))}
    known = set(state.get("limited") or [])
    fresh = [(label, reason) for label, reason in hit.items() if label and label not in known]
    state["limited"] = sorted(hit)

    # Первый проход только запоминает: иначе сразу после установки бот вывалил
    # бы список всех, у кого лимит кончился давно.
    seeded = state.get("limits_seeded") is True
    state["limits_seeded"] = True
    if not seeded or not fresh:
        return
    for _ in fresh:
        _count(state, "limit_hit")

    lines = ["🎚 <b>Лимиты пользователей</b>", ""]
    lines += [f"• <b>{esc(label)}</b> — {esc(reason)}" for label, reason in fresh]
    lines += ["", "Изменить: /users"]
    await broadcast(bot, "\n".join(lines))


# ── Скоро лимит ──────────────────────────────────────────────────────────────

SOON_QUOTA_PCT = 80
SOON_DAYS = 3


def _expiry_date(user: dict) -> date | None:
    raw = str(user.get("expires") or "")
    if not raw or raw == "0":
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00")).date()
    except ValueError:
        return None


def _soon_reasons(user: dict, today: date) -> dict[str, str]:
    """Что подходит к концу, но ещё не кончилось: кончившееся — дело check_limits."""
    out: dict[str, str] = {}
    quota = int(user.get("quota_bytes") or 0)
    used = int(user.get("total_bytes") or 0)
    if quota and quota * SOON_QUOTA_PCT // 100 <= used < quota:
        out["quota"] = f"израсходовано {used * 100 // quota}% квоты {human_bytes(quota)}"
    exp = _expiry_date(user)
    if exp and today <= exp <= today + timedelta(days=SOON_DAYS):
        left = (exp - today).days
        out["expiry"] = "срок истекает сегодня" if left == 0 else f"срок истекает через {left} дн. ({exp.isoformat()})"
    return out


async def check_limits_soon(bot: Bot, state: dict) -> None:
    try:
        users = await cli.secrets()
    except CliError as exc:
        log.debug("список пользователей недоступен: %s", exc)
        return
    today = date.today()
    warned: dict = state.get("soon_warned") or {}
    current: dict[str, list[str]] = {}
    fresh: list[tuple[str, str]] = []
    for user in users:
        label = user.get("label") or ""
        if not label or user.get("enabled") is False:
            continue
        reasons = _soon_reasons(user, today)
        if not reasons:
            continue
        current[label] = sorted(reasons)
        for kind, text in reasons.items():
            if kind not in (warned.get(label) or []):
                fresh.append((label, text))
    # Квоту сбросили или срок продлили — следующее приближение снова новость.
    state["soon_warned"] = current
    seeded = state.get("soon_seeded") is True
    state["soon_seeded"] = True
    if not seeded or not fresh:
        return
    lines = ["⏳ <b>Скоро кончится</b>", ""]
    lines += [f"• <b>{esc(label)}</b> — {esc(text)}" for label, text in fresh]
    lines += ["", "Продлить или поднять квоту: /users"]
    await broadcast(bot, "\n".join(lines))


# ── Отчёт за неделю ──────────────────────────────────────────────────────────

WEEKLY_WEEKDAY = 0      # понедельник
WEEKLY_TIME = (10, 0)

_EVENT_TITLES = (
    ("proxy_down", "прокси не отвечал"),
    ("availability_drop", "доступность падала ниже порога"),
    ("dc_restart", "движок перезапускался из-за DC"),
    ("egress_switch", "выход к Telegram переключался"),
    ("limit_hit", "пользователи упирались в лимит"),
)


def weekly_report_text(users: list[dict], base: dict, events: dict, since: float,
                       availability: dict | None = None) -> str:
    before = base or {}
    rows = []
    total = 0
    for user in users:
        label = user.get("label") or ""
        now_bytes = int(user.get("total_bytes") or 0)
        prev = int(before.get(label, 0) or 0)
        # Счётчик меньше прежнего — квоту сбросили: считаем с нуля.
        delta = now_bytes - prev if now_bytes >= prev else now_bytes
        total += delta
        if delta > 0:
            rows.append((delta, label))
    rows.sort(reverse=True)
    active = sum(1 for u in users if u.get("enabled") is not False)
    since_s = datetime.fromtimestamp(since).strftime("%d.%m") if since else "?"
    lines = [
        "📊 <b>Отчёт за неделю</b>",
        f"<i>с {since_s} по {datetime.now().strftime('%d.%m')}</i>",
        "",
        f"Трафик: <b>{human_bytes(total)}</b>",
        f"Пользователи: {len(users)}, включено {active}, с трафиком {len(rows)}",
    ]
    if rows:
        lines += ["", "<b>Больше всех:</b>"]
        lines += [f"{i}. {esc(label)} — {human_bytes(delta)}" for i, (delta, label) in enumerate(rows[:5], 1)]
    today = date.today()
    soon = [u.get("label") for u in users
            if (exp := _expiry_date(u)) and today <= exp <= today + timedelta(days=7)]
    if soon:
        lines += ["", f"Срок истекает в ближайшие 7 дней: {esc(', '.join(sorted(soon)))}"]
    result = (availability or {}).get("result") or {}
    if result and not result.get("error"):
        lines += ["", f"Доступность из России сейчас: {float(result.get('percentage') or 0):.0f}%"]
    happened = [(title, int(events.get(key) or 0)) for key, title in _EVENT_TITLES if events.get(key)]
    lines += [""]
    if happened:
        lines += ["<b>События:</b>"] + [f"• {title} — {n} раз" for title, n in happened]
    else:
        lines += ["Сбоев за неделю не было."]
    return "\n".join(lines)


async def check_weekly(bot: Bot, state: dict) -> None:
    now = datetime.now()
    today = now.date().isoformat()
    weekly = state.get("weekly") or {}
    first = not weekly.get("base_at")
    due = (now.weekday() == WEEKLY_WEEKDAY and (now.hour, now.minute) >= WEEKLY_TIME
           and weekly.get("sent") != today)
    if not first and not due:
        return
    try:
        users = await cli.secrets()
    except CliError as exc:
        log.debug("список пользователей недоступен: %s", exc)
        return
    snapshot = {u.get("label"): int(u.get("total_bytes") or 0) for u in users if u.get("label")}
    # Первый запуск: точка отсчёта трафика, отчёт — в ближайший понедельник.
    if first:
        state["weekly"] = {"base_at": now.timestamp(), "base": snapshot, "sent": today if due else ""}
        state["weekly_events"] = {}
        return
    try:
        availability = await cli.availability_status()
    except CliError:
        availability = None
    text = weekly_report_text(users, weekly.get("base") or {}, state.get("weekly_events") or {},
                              float(weekly.get("base_at") or 0), availability)
    state["weekly"] = {"base_at": now.timestamp(), "base": snapshot, "sent": today}
    state["weekly_events"] = {}
    await broadcast(bot, text)


# ── Автобэкап ────────────────────────────────────────────────────────────────

async def check_autobackup(bot: Bot, state: dict) -> None:
    cfg = config.load()
    auto = cfg.autobackup
    if not auto.get("enabled"):
        return
    if not await cli.is_manager():
        return

    now = datetime.now()
    today = now.date().isoformat()
    if state.get("last_backup_date") == today:
        return
    target = str(auto.get("time") or "05:30")
    try:
        hour, minute = (int(part) for part in target.split(":", 1))
    except ValueError:
        return
    if (now.hour, now.minute) < (hour, minute):
        return
    # Пропущенное окно (сервер спал) наверстываем в тот же день один раз:
    # бэкап нужнее вовремя, чем ровно в срок.
    state["last_backup_date"] = today

    try:
        await cli.create_backup()
        items = await cli.backups()
    except CliError as exc:
        if cfg.notify_on("backup"):
            await broadcast(bot, f"⚠️ <b>Автобэкап не удался</b>\n\n{esc(exc)}")
        return

    newest = max(items, key=lambda i: i.get("mtime") or 0) if items else None
    if not newest:
        if cfg.notify_on("backup"):
            await broadcast(bot, "⚠️ <b>Автобэкап</b>: архив создан, но список пуст")
        return

    name = newest.get("name", "")
    size = human_bytes(newest.get("size"))
    if cfg.notify_on("backup"):
        await broadcast(bot, f"💾 <b>Автобэкап готов</b>\n\n<code>{esc(name)}</code> · {size}")
    if not auto.get("send_file", True):
        return

    try:
        data = await cli.run_bytes("backup", "cat", name, timeout=300)
    except CliError as exc:
        await broadcast(bot, f"⚠️ Архив собран, но прислать не вышло: {esc(exc)}")
        return

    from aiogram.types import BufferedInputFile

    for admin in cfg.admins:
        try:
            await bot.send_document(admin, BufferedInputFile(data, filename=name))
            # Файл лёг поверх меню — возвращаем меню вниз, как после broadcast.
            await ui.move_menu_down_in(bot, admin)
        except TelegramAPIError as exc:
            log.warning("не удалось отправить бэкап %s: %s", admin, exc)


# ── Цикл ─────────────────────────────────────────────────────────────────────

async def run(bot: Bot) -> None:
    state = config.load_state()
    log.info("наблюдатели запущены")
    while True:
        try:
            cfg = config.load()
            before = dict(state)

            if (cfg.notify_on("dc") or cfg.notify_on("dc_zero")) and _due(state, "dc", cfg.interval("dc")):
                _mark(state, "dc")
                await check_dc(bot, state)

            if cfg.notify_on("availability") and _due(state, "availability", cfg.interval("availability")):
                _mark(state, "availability")
                await check_availability(bot, state)
            if cfg.notify_on("proxy") and _due(state, "proxy", cfg.interval("proxy")):
                _mark(state, "proxy")
                await check_proxy(bot, state)
            if cfg.notify_on("egress"):
                await check_egress(bot, state)
            if cfg.notify_on("limits") and _due(state, "limits", cfg.interval("limits")):
                _mark(state, "limits")
                await check_limits(bot, state)
            if cfg.notify_on("limits_soon") and _due(state, "limits_soon", cfg.interval("limits")):
                _mark(state, "limits_soon")
                await check_limits_soon(bot, state)
            if cfg.notify_on("weekly"):
                await check_weekly(bot, state)
            await check_autobackup(bot, state)

            if state != before:
                config.save_state(state)
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("сбой наблюдателя, продолжаем")
        await asyncio.sleep(TICK_SECONDS)
