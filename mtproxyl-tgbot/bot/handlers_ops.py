"""Меню, прокси, трафик, доступность, бэкапы, настройки."""

from __future__ import annotations

import logging
import re

from aiogram import F, Router
from aiogram.filters import Command, CommandStart
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import BufferedInputFile, CallbackQuery, Message

from . import cli, config, keyboards as kb
from .cli import CliError
from .format import (
    HELP_TEXT,
    availability_text,
    esc,
    settings_text,
    status_text,
    traffic_text,
)
from .ui import render, report_error

log = logging.getLogger(__name__)
router = Router(name="ops")

TIME_RE = re.compile(r"^([01]?\d|2[0-3]):([0-5]\d)$")


class Ask(StatesGroup):
    interval = State()
    threshold = State()
    notify_interval = State()
    backup_time = State()


# ── Главное меню ─────────────────────────────────────────────────────────────

async def show_root(event: Message | CallbackQuery) -> None:
    manager = await cli.is_manager()
    text = (
        "<b>MTProxyL</b>\n\nВыберите раздел. Все действия доступны и командами — /help."
    )
    await render(event, text, kb.main_menu(manager))


@router.message(CommandStart())
@router.message(Command("menu"))
async def cmd_start(message: Message, state: FSMContext) -> None:
    await state.clear()
    await show_root(message)


@router.message(Command("help"))
async def cmd_help(message: Message) -> None:
    await message.answer(HELP_TEXT)


@router.callback_query(F.data == "m:root")
async def cb_root(call: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await call.answer()
    await show_root(call)


@router.callback_query(F.data == "noop")
async def cb_noop(call: CallbackQuery) -> None:
    await call.answer()


# ── Статус и управление прокси ───────────────────────────────────────────────

async def show_status(event: Message | CallbackQuery) -> None:
    st = await cli.status()
    md = await cli.mode()
    await render(event, status_text(st, md), kb.back_only())


@router.message(Command("status"))
async def cmd_status(message: Message) -> None:
    try:
        await show_status(message)
    except Exception as exc:
        await report_error(message, exc)


@router.callback_query(F.data == "m:status")
async def cb_status(call: CallbackQuery) -> None:
    await call.answer()
    try:
        await show_status(call)
    except Exception as exc:
        await report_error(call, exc)


async def show_proxy(event: Message | CallbackQuery) -> None:
    st = await cli.status()
    md = await cli.mode()
    running = st.get("status") == "running"
    await render(event, status_text(st, md), kb.proxy_menu(running))


@router.callback_query(F.data == "m:proxy")
async def cb_proxy(call: CallbackQuery) -> None:
    await call.answer()
    try:
        await show_proxy(call)
    except Exception as exc:
        await report_error(call, exc)


async def do_proxy_action(event: Message | CallbackQuery, action: str) -> None:
    titles = {"start": "Запускаю", "stop": "Останавливаю", "restart": "Перезапускаю"}
    if isinstance(event, CallbackQuery):
        await event.answer(f"{titles[action]}…")
    else:
        await event.answer(f"{titles[action]} прокси…")
    try:
        await cli.proxy_action(action)
    except Exception as exc:
        await report_error(event, exc)
        return
    await show_proxy(event)


@router.callback_query(F.data.startswith("px:"))
async def cb_proxy_action(call: CallbackQuery) -> None:
    await do_proxy_action(call, call.data.split(":", 1)[1])


@router.message(Command("start_proxy"))
async def cmd_proxy_start(message: Message) -> None:
    await do_proxy_action(message, "start")


@router.message(Command("stop_proxy"))
async def cmd_proxy_stop(message: Message) -> None:
    await do_proxy_action(message, "stop")


@router.message(Command("restart_proxy"))
async def cmd_proxy_restart(message: Message) -> None:
    await do_proxy_action(message, "restart")


# ── Трафик ───────────────────────────────────────────────────────────────────

async def show_traffic(event: Message | CallbackQuery) -> None:
    report = await cli.traffic()
    await render(event, traffic_text(report), kb.back_only())


@router.message(Command("traffic"))
async def cmd_traffic(message: Message) -> None:
    try:
        await show_traffic(message)
    except Exception as exc:
        await report_error(message, exc)


@router.callback_query(F.data == "m:traffic")
async def cb_traffic(call: CallbackQuery) -> None:
    await call.answer()
    try:
        await show_traffic(call)
    except Exception as exc:
        await report_error(call, exc)


# ── Доступность из России ────────────────────────────────────────────────────

async def show_availability(event: Message | CallbackQuery, probes: bool = False) -> None:
    state = await (cli.availability_details() if probes else cli.availability_status())
    await render(event, availability_text(state, with_probes=probes),
                 kb.availability_menu(bool(state.get("auto_check"))))


@router.message(Command("availability"))
async def cmd_availability(message: Message) -> None:
    try:
        await show_availability(message)
    except Exception as exc:
        await report_error(message, exc)


@router.callback_query(F.data == "a:show")
async def cb_availability(call: CallbackQuery) -> None:
    await call.answer()
    try:
        await show_availability(call)
    except Exception as exc:
        await report_error(call, exc)


@router.callback_query(F.data == "a:probes")
async def cb_availability_probes(call: CallbackQuery) -> None:
    await call.answer()
    try:
        await show_availability(call, probes=True)
    except Exception as exc:
        await report_error(call, exc)


async def do_check(event: Message | CallbackQuery) -> None:
    note = "Опрашиваю российские зонды, это до минуты…"
    if isinstance(event, CallbackQuery):
        await event.answer(note, show_alert=False)
    else:
        await event.answer(note)
    try:
        await cli.availability_check()
    except CliError as exc:
        # Отказ по квоте или частоте — не ошибка: показываем причину и то,
        # что уже известно.
        await report_error(event, exc)
        return
    except Exception as exc:
        await report_error(event, exc)
        return
    await show_availability(event, probes=True)


@router.message(Command("check"))
async def cmd_check(message: Message) -> None:
    await do_check(message)


@router.callback_query(F.data == "a:check")
async def cb_check(call: CallbackQuery) -> None:
    await do_check(call)


@router.callback_query(F.data == "a:auto")
async def cb_autocheck(call: CallbackQuery) -> None:
    try:
        state = await cli.availability_status()
        await cli.availability_autocheck(not state.get("auto_check"))
        await call.answer("Готово")
        await show_availability(call)
    except Exception as exc:
        await report_error(call, exc)


@router.callback_query(F.data == "a:interval")
async def cb_interval(call: CallbackQuery, state: FSMContext) -> None:
    await call.answer()
    await state.set_state(Ask.interval)
    await call.message.answer(
        "Как часто проверять доступность? Пришлите число минут (1–1440).\n"
        "Каждая проверка тратит кредиты Globalping: 20 зондов раз в 15 минут — "
        "80 кредитов в час из 250.\n\nОтмена — /menu"
    )


@router.message(Ask.interval, ~F.text.startswith("/"))
async def set_interval(message: Message, state: FSMContext) -> None:
    value = (message.text or "").strip()
    if not value.isdigit() or not 1 <= int(value) <= 1440:
        await message.answer("Нужно целое число от 1 до 1440. Отмена — /menu")
        return
    await state.clear()
    try:
        await cli.settings_set("AVAILABILITY_INTERVAL", value)
    except Exception as exc:
        await report_error(message, exc)
        return
    await message.answer(f"Период проверки: {value} мин")
    await show_availability(message)


@router.callback_query(F.data == "a:threshold")
async def cb_threshold(call: CallbackQuery, state: FSMContext) -> None:
    await call.answer()
    await state.set_state(Ask.threshold)
    await call.message.answer(
        "Ниже какого процента доступности присылать предупреждение?\n"
        "Пришлите число от 0 до 100.\n\nОтмена — /menu"
    )


@router.message(Ask.threshold, ~F.text.startswith("/"))
async def set_threshold(message: Message, state: FSMContext) -> None:
    value = (message.text or "").strip()
    if not value.isdigit() or int(value) > 100:
        await message.answer("Нужно целое число от 0 до 100. Отмена — /menu")
        return
    await state.clear()
    try:
        await cli.settings_set("AVAILABILITY_THRESHOLD", value)
    except Exception as exc:
        await report_error(message, exc)
        return
    await message.answer(f"Порог уведомления: {value}%")
    await show_availability(message)


# ── Бэкапы (только режим менеджера) ──────────────────────────────────────────

async def show_backups(event: Message | CallbackQuery) -> None:
    if not await cli.is_manager():
        await render(event, "Бэкапы доступны только в режиме Manager: в реаниматоре "
                            "данные принадлежат чужой установке.", kb.back_only())
        return
    cfg = config.load()
    auto = cfg.autobackup
    state = f"каждый день в {auto.get('time', '05:30')}" if auto.get("enabled") else "выключен"
    try:
        items = await cli.backups()
        last = f"\nПоследний: <code>{esc(items[-1].get('name', '?'))}</code>" if items else ""
        count = f"\nВсего архивов: {len(items)}"
    except CliError:
        last, count = "", ""
    await render(event, f"<b>Бэкапы</b>\n\nАвтобэкап: <b>{state}</b>{count}{last}",
                 kb.backups_menu())


@router.callback_query(F.data == "b:show")
async def cb_backups(call: CallbackQuery) -> None:
    await call.answer()
    try:
        await show_backups(call)
    except Exception as exc:
        await report_error(call, exc)


async def do_backup(event: Message | CallbackQuery) -> None:
    if not await cli.is_manager():
        await report_error(event, CliError("Бэкапы доступны только в режиме Manager"))
        return
    note = "Собираю архив…"
    if isinstance(event, CallbackQuery):
        await event.answer(note)
        chat = event.message
    else:
        chat = event
        await event.answer(note)
    try:
        await cli.create_backup()
        items = await cli.backups()
    except Exception as exc:
        await report_error(event, exc)
        return
    if not items:
        await chat.answer("Бэкап создан, но список архивов пуст — проверьте mtproxyl backup")
        return
    newest = max(items, key=lambda i: i.get("mtime") or 0)
    await send_backup_file(chat, newest.get("name", ""))


async def send_backup_file(chat, name: str) -> None:
    """Архив едет через CLI: каталог бэкапов боту напрямую не доступен."""
    if not name:
        return
    try:
        data = await cli.run_bytes("backup", "cat", name, timeout=300)
    except Exception as exc:
        await chat.answer(f"⚠️ Не удалось прочитать архив: {esc(exc)}")
        return
    await chat.answer_document(BufferedInputFile(data, filename=name),
                               caption=f"Бэкап <code>{esc(name)}</code>")


@router.message(Command("backup"))
async def cmd_backup(message: Message) -> None:
    await do_backup(message)


@router.callback_query(F.data == "b:make")
async def cb_backup_make(call: CallbackQuery) -> None:
    await do_backup(call)


@router.callback_query(F.data == "b:auto")
async def cb_autobackup(call: CallbackQuery) -> None:
    await call.answer()
    cfg = config.load()
    await render(call, "<b>Автобэкап</b>\n\nАрхив собирается по расписанию и, если "
                       "включено, приходит сюда файлом.", kb.autobackup_menu(cfg))


@router.callback_query(F.data == "b:auto:toggle")
async def cb_autobackup_toggle(call: CallbackQuery) -> None:
    cfg = config.load()
    cfg.autobackup["enabled"] = not cfg.autobackup.get("enabled")
    config.save(cfg)
    await call.answer("Готово")
    await render(call, "<b>Автобэкап</b>", kb.autobackup_menu(cfg))


@router.callback_query(F.data == "b:auto:file")
async def cb_autobackup_file(call: CallbackQuery) -> None:
    cfg = config.load()
    cfg.autobackup["send_file"] = not cfg.autobackup.get("send_file", True)
    config.save(cfg)
    await call.answer("Готово")
    await render(call, "<b>Автобэкап</b>", kb.autobackup_menu(cfg))


@router.callback_query(F.data == "b:auto:time")
async def cb_autobackup_time(call: CallbackQuery, state: FSMContext) -> None:
    await call.answer()
    await state.set_state(Ask.backup_time)
    await call.message.answer(
        "Во сколько собирать бэкап? Пришлите время в формате ЧЧ:ММ "
        "по времени сервера.\n\nОтмена — /menu"
    )


@router.message(Ask.backup_time, ~F.text.startswith("/"))
async def set_backup_time(message: Message, state: FSMContext) -> None:
    value = (message.text or "").strip()
    if not TIME_RE.match(value):
        await message.answer("Формат ЧЧ:ММ, например 05:30. Отмена — /menu")
        return
    await state.clear()
    cfg = config.load()
    cfg.autobackup["time"] = value
    config.save(cfg)
    await message.answer(f"Автобэкап в {value}")


# ── Настройки бота ───────────────────────────────────────────────────────────

async def show_settings(event: Message | CallbackQuery) -> None:
    cfg = config.load()
    manager = await cli.is_manager()
    await render(event, settings_text(cfg, manager), kb.settings_menu(cfg, manager))


@router.message(Command("settings"))
async def cmd_settings(message: Message) -> None:
    try:
        await show_settings(message)
    except Exception as exc:
        await report_error(message, exc)


@router.callback_query(F.data == "s:show")
async def cb_settings(call: CallbackQuery) -> None:
    await call.answer()
    try:
        await show_settings(call)
    except Exception as exc:
        await report_error(call, exc)


@router.callback_query(F.data.startswith("s:toggle:"))
async def cb_settings_toggle(call: CallbackQuery) -> None:
    key = call.data.split(":")[2]
    cfg = config.load()
    cfg.notify[key] = not cfg.notify.get(key, True)
    config.save(cfg)
    await call.answer("Включено" if cfg.notify[key] else "Выключено")
    await show_settings(call)


@router.callback_query(F.data == "s:intervals")
async def cb_intervals(call: CallbackQuery) -> None:
    await call.answer()
    cfg = config.load()
    await render(call, "<b>Периоды проверок</b>\n\nКак часто бот сверяется с "
                       "состоянием сервера. На квоту Globalping это не влияет: "
                       "бот только читает готовый результат.", kb.intervals_menu(cfg))


@router.callback_query(F.data.startswith("s:int:"))
async def cb_interval_ask(call: CallbackQuery, state: FSMContext) -> None:
    key = call.data.split(":")[2]
    await call.answer()
    await state.set_state(Ask.notify_interval)
    await state.update_data(interval_key=key)
    await call.message.answer("Пришлите число минут (1–1440).\n\nОтмена — /menu")


@router.message(Ask.notify_interval, ~F.text.startswith("/"))
async def set_notify_interval(message: Message, state: FSMContext) -> None:
    value = (message.text or "").strip()
    if not value.isdigit() or not 1 <= int(value) <= 1440:
        await message.answer("Нужно целое число от 1 до 1440. Отмена — /menu")
        return
    data = await state.get_data()
    await state.clear()
    cfg = config.load()
    cfg.intervals[data.get("interval_key", "proxy")] = int(value)
    config.save(cfg)
    await message.answer(f"Период: {value} мин")
    await show_settings(message)
