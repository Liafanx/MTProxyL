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
from .ui import ack, render, report_error

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
    await render(message, HELP_TEXT, kb.back_only())


@router.callback_query(F.data == "m:root")
async def cb_root(call: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await ack(call)
    await show_root(call)


@router.callback_query(F.data == "noop")
async def cb_noop(call: CallbackQuery) -> None:
    await ack(call)


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
    await ack(call)
    try:
        await show_status(call)
    except Exception as exc:
        await report_error(call, exc)


async def show_proxy(event: Message | CallbackQuery, note: str = "") -> None:
    st = await cli.status()
    md = await cli.mode()
    running = st.get("status") == "running"
    text = status_text(st, md)
    if note:
        text = f"{note}\n\n{text}"
    await render(event, text, kb.proxy_menu(running))


@router.callback_query(F.data == "m:proxy")
async def cb_proxy(call: CallbackQuery) -> None:
    await ack(call)
    try:
        await show_proxy(call)
    except Exception as exc:
        await report_error(call, exc)


async def do_proxy_action(event: Message | CallbackQuery, action: str) -> None:
    titles = {"start": "Запускаю", "stop": "Останавливаю", "restart": "Перезапускаю"}
    done = {"start": "Запущен", "stop": "Остановлен", "restart": "Перезапущен"}
    # Пока команда идёт (перезапуск движка — это секунды), экран должен
    # говорить об этом, иначе кажется, что кнопка не сработала.
    await render(event, f"⏳ {titles[action]} прокси…")
    try:
        await cli.proxy_action(action)
    except Exception as exc:
        await report_error(event, exc)
        await show_proxy(event)
        return
    await show_proxy(event, f"✅ {done[action]}")


@router.callback_query(F.data.startswith("px:"))
async def cb_proxy_action(call: CallbackQuery) -> None:
    await ack(call)
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
    await ack(call)
    try:
        await show_traffic(call)
    except Exception as exc:
        await report_error(call, exc)


# ── Доступность из России ────────────────────────────────────────────────────

async def show_availability(event: Message | CallbackQuery, probes: bool = False,
                            note: str = "", force_new: bool = False) -> None:
    state = await (cli.availability_details() if probes else cli.availability_status())
    text = availability_text(state, with_probes=probes)
    if note:
        text = f"{note}\n\n{text}"
    await render(event, text, kb.availability_menu(bool(state.get("auto_check"))),
                 force_new=force_new)


@router.message(Command("availability"))
async def cmd_availability(message: Message) -> None:
    try:
        await show_availability(message)
    except Exception as exc:
        await report_error(message, exc)


@router.callback_query(F.data == "a:show")
async def cb_availability(call: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await ack(call)
    try:
        await show_availability(call)
    except Exception as exc:
        await report_error(call, exc)


@router.callback_query(F.data == "a:probes")
async def cb_availability_probes(call: CallbackQuery) -> None:
    await ack(call)
    try:
        await show_availability(call, probes=True)
    except Exception as exc:
        await report_error(call, exc)


async def do_check(event: Message | CallbackQuery) -> None:
    await render(event, "⏳ Опрашиваю российские зонды, это до минуты…")
    try:
        await cli.availability_check()
    except CliError as exc:
        # Отказ по квоте или частоте — не ошибка сервера, а просьба подождать:
        # показываем причину прямо на экране вместе с прошлым вердиктом.
        await show_availability(event, note=f"⚠️ {esc(exc)}")
        return
    except Exception as exc:
        await report_error(event, exc)
        await show_availability(event)
        return
    await show_availability(event, probes=True, note="✅ Проверка выполнена")


@router.message(Command("check"))
async def cmd_check(message: Message) -> None:
    await do_check(message)


@router.callback_query(F.data == "a:check")
async def cb_check(call: CallbackQuery) -> None:
    await ack(call)
    await do_check(call)


@router.callback_query(F.data == "a:auto")
async def cb_autocheck(call: CallbackQuery) -> None:
    # Ответить надо сразу: `availability on` переписывает юнит и дёргает
    # systemctl, а это на слабом сервере десяток секунд — за них подтверждение
    # успевает протухнуть.
    await ack(call)
    await render(call, "⏳ Меняю расписание проверок…")
    try:
        report = await cli.availability_status()
        on = not report.get("auto_check")
        await cli.availability_autocheck(on)
    except Exception as exc:
        await report_error(call, exc)
        await show_availability(call)
        return
    await show_availability(call, note="✅ Автопроверка включена" if on
                            else "⏸ Автопроверка выключена")


@router.callback_query(F.data == "a:interval")
async def cb_interval(call: CallbackQuery, state: FSMContext) -> None:
    await ack(call)
    await state.set_state(Ask.interval)
    await render(
        call,
        "<b>Период проверки доступности</b>\n\nПришлите число минут (1–1440).\n"
        "Каждая проверка тратит кредиты Globalping: 20 зондов раз в 15 минут — "
        "80 кредитов в час из 250.",
        kb.cancel("a:show"),
    )


@router.message(Ask.interval, ~F.text.startswith("/"))
async def set_interval(message: Message, state: FSMContext) -> None:
    value = (message.text or "").strip()
    if not value.isdigit() or not 1 <= int(value) <= 1440:
        await render(message, "⚠️ Нужно целое число от 1 до 1440.\n\nПришлите другое.",
                     kb.cancel("a:show"))
        return
    await state.clear()
    try:
        await cli.settings_set("AVAILABILITY_INTERVAL", value)
    except Exception as exc:
        await report_error(message, exc)
        return
    await show_availability(message, note=f"✅ Период проверки: {value} мин")


@router.callback_query(F.data == "a:threshold")
async def cb_threshold(call: CallbackQuery, state: FSMContext) -> None:
    await ack(call)
    await state.set_state(Ask.threshold)
    await render(
        call,
        "<b>Порог уведомления</b>\n\nНиже какого процента доступности присылать "
        "предупреждение? Пришлите число от 0 до 100.",
        kb.cancel("a:show"),
    )


@router.message(Ask.threshold, ~F.text.startswith("/"))
async def set_threshold(message: Message, state: FSMContext) -> None:
    value = (message.text or "").strip()
    if not value.isdigit() or int(value) > 100:
        await render(message, "⚠️ Нужно целое число от 0 до 100.\n\nПришлите другое.",
                     kb.cancel("a:show"))
        return
    await state.clear()
    try:
        await cli.settings_set("AVAILABILITY_THRESHOLD", value)
    except Exception as exc:
        await report_error(message, exc)
        return
    await show_availability(message, note=f"✅ Порог уведомления: {value}%")


# ── Бэкапы (только режим менеджера) ──────────────────────────────────────────

async def show_backups(event: Message | CallbackQuery, note: str = "") -> None:
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
    head = f"{note}\n\n" if note else ""
    await render(event, f"{head}<b>Бэкапы</b>\n\nАвтобэкап: <b>{state}</b>{count}{last}",
                 kb.backups_menu())


@router.callback_query(F.data == "b:show")
async def cb_backups(call: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await ack(call)
    try:
        await show_backups(call)
    except Exception as exc:
        await report_error(call, exc)


async def do_backup(event: Message | CallbackQuery) -> None:
    if not await cli.is_manager():
        await show_backups(event, "⚠️ Бэкапы доступны только в режиме Manager")
        return
    await render(event, "⏳ Собираю архив…")
    try:
        await cli.create_backup()
        items = await cli.backups()
    except Exception as exc:
        await report_error(event, exc)
        await show_backups(event)
        return
    if not items:
        await show_backups(event, "⚠️ Архив создан, но список пуст — проверьте mtproxyl backup")
        return

    newest = max(items, key=lambda i: i.get("mtime") or 0)
    name = newest.get("name", "")
    # Архив едет через CLI: каталог бэкапов боту напрямую не доступен.
    try:
        data = await cli.run_bytes("backup", "cat", name, timeout=300)
    except Exception as exc:
        await show_backups(event, f"⚠️ Не удалось прочитать архив: {esc(exc)}")
        return

    message = event.message if isinstance(event, CallbackQuery) else event
    await message.answer_document(
        BufferedInputFile(data, filename=name),
        caption=f"💾 Бэкап <code>{esc(name)}</code>",
    )
    await show_backups(event, "✅ Архив отправлен")


@router.message(Command("backup"))
async def cmd_backup(message: Message) -> None:
    await do_backup(message)


@router.callback_query(F.data == "b:make")
async def cb_backup_make(call: CallbackQuery) -> None:
    await ack(call)
    await do_backup(call)


async def show_autobackup(event: Message | CallbackQuery, note: str = "") -> None:
    cfg = config.load()
    head = f"{note}\n\n" if note else ""
    await render(event, f"{head}<b>Автобэкап</b>\n\nАрхив собирается по расписанию и, "
                        "если включено, приходит сюда файлом.", kb.autobackup_menu(cfg))


@router.callback_query(F.data == "b:auto")
async def cb_autobackup(call: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await ack(call)
    await show_autobackup(call)


@router.callback_query(F.data == "b:auto:toggle")
async def cb_autobackup_toggle(call: CallbackQuery) -> None:
    await ack(call)
    cfg = config.load()
    cfg.autobackup["enabled"] = not cfg.autobackup.get("enabled")
    config.save(cfg)
    await show_autobackup(call)


@router.callback_query(F.data == "b:auto:file")
async def cb_autobackup_file(call: CallbackQuery) -> None:
    await ack(call)
    cfg = config.load()
    cfg.autobackup["send_file"] = not cfg.autobackup.get("send_file", True)
    config.save(cfg)
    await show_autobackup(call)


@router.callback_query(F.data == "b:auto:time")
async def cb_autobackup_time(call: CallbackQuery, state: FSMContext) -> None:
    await ack(call)
    await state.set_state(Ask.backup_time)
    await render(call, "<b>Время автобэкапа</b>\n\nПришлите время в формате ЧЧ:ММ "
                       "по времени сервера.", kb.cancel("b:auto"))


@router.message(Ask.backup_time, ~F.text.startswith("/"))
async def set_backup_time(message: Message, state: FSMContext) -> None:
    value = (message.text or "").strip()
    if not TIME_RE.match(value):
        await render(message, "⚠️ Формат ЧЧ:ММ, например 05:30.\n\nПришлите другое.",
                     kb.cancel("b:auto"))
        return
    await state.clear()
    cfg = config.load()
    cfg.autobackup["time"] = value
    config.save(cfg)
    await show_autobackup(message, f"✅ Автобэкап в {value}")


# ── Настройки бота ───────────────────────────────────────────────────────────

async def show_settings(event: Message | CallbackQuery, note: str = "") -> None:
    cfg = config.load()
    manager = await cli.is_manager()
    text = settings_text(cfg, manager)
    if note:
        text = f"{note}\n\n{text}"
    await render(event, text, kb.settings_menu(cfg, manager))


@router.message(Command("settings"))
async def cmd_settings(message: Message) -> None:
    try:
        await show_settings(message)
    except Exception as exc:
        await report_error(message, exc)


@router.callback_query(F.data == "s:show")
async def cb_settings(call: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await ack(call)
    try:
        await show_settings(call)
    except Exception as exc:
        await report_error(call, exc)


@router.callback_query(F.data.startswith("s:toggle:"))
async def cb_settings_toggle(call: CallbackQuery) -> None:
    await ack(call)
    key = call.data.split(":")[2]
    cfg = config.load()
    cfg.notify[key] = not cfg.notify.get(key, True)
    config.save(cfg)
    await show_settings(call)


@router.callback_query(F.data == "s:intervals")
async def cb_intervals(call: CallbackQuery) -> None:
    await ack(call)
    cfg = config.load()
    await render(call, "<b>Периоды проверок</b>\n\nКак часто бот сверяется с "
                       "состоянием сервера. На квоту Globalping это не влияет: "
                       "бот только читает готовый результат.", kb.intervals_menu(cfg))


@router.callback_query(F.data.startswith("s:int:"))
async def cb_interval_ask(call: CallbackQuery, state: FSMContext) -> None:
    key = call.data.split(":")[2]
    await ack(call)
    await state.set_state(Ask.notify_interval)
    await state.update_data(interval_key=key)
    titles = {"availability": "доступности", "proxy": "прокси", "limits": "лимитов"}
    await render(call, f"<b>Период проверки {titles.get(key, key)}</b>\n\n"
                       "Пришлите число минут (1–1440).", kb.cancel("s:intervals"))


@router.message(Ask.notify_interval, ~F.text.startswith("/"))
async def set_notify_interval(message: Message, state: FSMContext) -> None:
    value = (message.text or "").strip()
    if not value.isdigit() or not 1 <= int(value) <= 1440:
        await render(message, "⚠️ Нужно целое число от 1 до 1440.\n\nПришлите другое.",
                     kb.cancel("s:intervals"))
        return
    data = await state.get_data()
    await state.clear()
    cfg = config.load()
    cfg.intervals[data.get("interval_key", "proxy")] = int(value)
    config.save(cfg)
    await show_settings(message, f"✅ Период: {value} мин")
