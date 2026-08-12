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
from datetime import date, datetime

from aiogram import Bot
from aiogram.exceptions import TelegramAPIError

from . import cli, config
from .cli import CliError
from .format import LEVEL_ICON, esc, human_bytes

log = logging.getLogger(__name__)

TICK_SECONDS = 60


async def broadcast(bot: Bot, text: str) -> None:
    for admin in config.load().admins:
        try:
            await bot.send_message(admin, text, disable_web_page_preview=True)
        except TelegramAPIError as exc:
            log.warning("не удалось написать %s: %s", admin, exc)


def _due(state: dict, key: str, minutes: int) -> bool:
    last = state.get("last_run", {}).get(key, 0)
    return time.time() - last >= minutes * 60


def _mark(state: dict, key: str) -> None:
    state.setdefault("last_run", {})[key] = time.time()


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

    lines = ["🎚 <b>Лимиты пользователей</b>", ""]
    lines += [f"• <b>{esc(label)}</b> — {esc(reason)}" for label, reason in fresh]
    lines += ["", "Изменить: /users"]
    await broadcast(bot, "\n".join(lines))


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

            if cfg.notify_on("availability") and _due(state, "availability", cfg.interval("availability")):
                _mark(state, "availability")
                await check_availability(bot, state)
            if cfg.notify_on("proxy") and _due(state, "proxy", cfg.interval("proxy")):
                _mark(state, "proxy")
                await check_proxy(bot, state)
            if cfg.notify_on("limits") and _due(state, "limits", cfg.interval("limits")):
                _mark(state, "limits")
                await check_limits(bot, state)
            await check_autobackup(bot, state)

            if state != before:
                config.save_state(state)
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("сбой наблюдателя, продолжаем")
        await asyncio.sleep(TICK_SECONDS)
