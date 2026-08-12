"""Пользователи, лимиты, ссылки и QR-коды."""

from __future__ import annotations

import asyncio
import logging
import re
import shutil

from aiogram import F, Router
from aiogram.filters import Command
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import CallbackQuery, Message

from . import cli, keyboards as kb
from .format import esc, human_bytes, link_text, user_card, users_page_text, web_link
from .ui import ack, notice, render, report_error, stale_button

log = logging.getLogger(__name__)
router = Router(name="users")

# Метка идёт в аргумент sudo-правила `secret add [A-Za-z0-9]*`, поэтому набор
# символов ограничен здесь же: иначе отказ придёт из sudo и будет непонятным.
LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


class UserForm(StatesGroup):
    add = State()
    rename = State()
    limit = State()


def _page_of(users: list[dict], label: str) -> int:
    for index, user in enumerate(users):
        if user.get("label") == label:
            return index // kb.USERS_PER_PAGE
    return 0


def _find(users: list[dict], label: str) -> dict | None:
    return next((u for u in users if u.get("label") == label), None)


async def _resolve(call: CallbackQuery) -> tuple[str, list[dict]] | None:
    """Метка из кнопки и свежий список. None — кнопка из старого меню."""
    key = call.data.rsplit(":", 1)[-1]
    label = kb.label_for(key)
    if label is None:
        await notice(call, stale_button())
        return None
    return label, await cli.secrets()


# ── Список и карточка ────────────────────────────────────────────────────────

async def show_users(event: Message | CallbackQuery, page: int = 0, note: str = "") -> None:
    users = await cli.secrets()
    await render(event, users_page_text(users, page, kb.USERS_PER_PAGE, note),
                 kb.users_page(users, page, "u"))


async def show_card(event: Message | CallbackQuery, label: str, note: str = "") -> None:
    users = await cli.secrets()
    user = _find(users, label)
    if user is None:
        await show_users(event, 0, "Пользователь исчез — список обновлён")
        return
    text = user_card(user)
    if note:
        text = f"{note}\n\n{text}"
    await render(event, text,
                 kb.user_card(kb.key_for(label), bool(user.get("enabled")), _page_of(users, label)))


@router.message(Command("users"))
async def cmd_users(message: Message) -> None:
    try:
        await show_users(message)
    except Exception as exc:
        await report_error(message, exc)


@router.callback_query(F.data.startswith("u:list:"))
async def cb_users_list(call: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await ack(call)
    try:
        await show_users(call, int(call.data.split(":")[2]))
    except Exception as exc:
        await report_error(call, exc)


@router.callback_query(F.data.startswith("u:show:"))
async def cb_user_show(call: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    resolved = await _resolve(call)
    if resolved is None:
        return
    label, _ = resolved
    await ack(call)
    try:
        await show_card(call, label)
    except Exception as exc:
        await report_error(call, exc)


# ── Добавление ───────────────────────────────────────────────────────────────

@router.callback_query(F.data == "u:add")
async def cb_user_add(call: CallbackQuery, state: FSMContext) -> None:
    await ack(call)
    await state.set_state(UserForm.add)
    await render(
        call,
        "<b>Новый пользователь</b>\n\nПришлите имя сообщением.\n"
        "Латиница, цифры, дефис и подчёркивание, до 32 символов.",
        kb.cancel("u:list:0"),
    )


@router.message(UserForm.add, ~F.text.startswith("/"))
async def do_user_add(message: Message, state: FSMContext) -> None:
    label = (message.text or "").strip()
    if not LABEL_RE.match(label):
        await render(
            message,
            "⚠️ Имя не подходит: латиница, цифры, дефис и подчёркивание, до 32 символов.\n\n"
            "Пришлите другое.",
            kb.cancel("u:list:0"),
        )
        return
    await state.clear()
    try:
        await cli.secret_add(label)
    except Exception as exc:
        await report_error(message, exc)
        return
    await send_link(message, label, move_menu=False)
    await show_card(message, label, f"✅ Добавлен <b>{esc(label)}</b>")


# ── Включение, переименование, удаление ──────────────────────────────────────

@router.callback_query(F.data.startswith("u:toggle:"))
async def cb_user_toggle(call: CallbackQuery) -> None:
    await ack(call)
    resolved = await _resolve(call)
    if resolved is None:
        return
    label, users = resolved
    user = _find(users, label) or {}
    enable = not user.get("enabled", True)
    await render(call, f"⏳ {'Включаю' if enable else 'Выключаю'} {esc(label)}…")
    try:
        await cli.secret_toggle(label, enable)
    except Exception as exc:
        await report_error(call, exc)
        await show_card(call, label)
        return
    await show_card(call, label, "✅ Включён" if enable else "⛔ Выключен")


@router.callback_query(F.data.startswith("u:rename:"))
async def cb_user_rename(call: CallbackQuery, state: FSMContext) -> None:
    resolved = await _resolve(call)
    if resolved is None:
        return
    label, _ = resolved
    await ack(call)
    await state.set_state(UserForm.rename)
    await state.update_data(label=label)
    await render(call, f"<b>Переименование · {esc(label)}</b>\n\nПришлите новое имя.",
                 kb.cancel(f"u:show:{kb.key_for(label)}"))


@router.message(UserForm.rename, ~F.text.startswith("/"))
async def do_user_rename(message: Message, state: FSMContext) -> None:
    new = (message.text or "").strip()
    data = await state.get_data()
    old = data.get("label", "")
    if not LABEL_RE.match(new):
        await render(message, "⚠️ Имя не подходит: латиница, цифры, дефис и подчёркивание.\n\n"
                              "Пришлите другое.",
                     kb.cancel(f"u:show:{kb.key_for(old)}"))
        return
    await state.clear()
    try:
        await cli.secret_rename(old, new)
    except Exception as exc:
        await report_error(message, exc)
        return
    await show_card(message, new, f"✅ <b>{esc(old)}</b> → <b>{esc(new)}</b>")


@router.callback_query(F.data.startswith("u:del:"))
async def cb_user_del(call: CallbackQuery) -> None:
    resolved = await _resolve(call)
    if resolved is None:
        return
    label, _ = resolved
    key = kb.key_for(label)
    await ack(call)
    await render(call, f"Удалить <b>{esc(label)}</b>?\n\nСсылка перестанет работать сразу.",
                 kb.confirm(f"u:delyes:{key}", f"u:show:{key}"))


@router.callback_query(F.data.startswith("u:delyes:"))
async def cb_user_del_yes(call: CallbackQuery) -> None:
    await ack(call)
    resolved = await _resolve(call)
    if resolved is None:
        return
    label, _ = resolved
    await render(call, f"⏳ Удаляю {esc(label)}…")
    try:
        await cli.secret_remove(label)
    except Exception as exc:
        await report_error(call, exc)
        await show_users(call, 0)
        return
    await show_users(call, 0, f"🗑 Удалён <b>{esc(label)}</b>")


# ── Лимиты ───────────────────────────────────────────────────────────────────

LIMIT_PROMPT = {
    "conns": ("Максимум одновременных соединений", "0 — без ограничения"),
    "ips": ("Максимум уникальных адресов", "0 — без ограничения"),
    "quota": ("Квота трафика в гигабайтах", "0 — без ограничения, дробное можно: 1.5"),
    "expires": ("Дата окончания", "формат ГГГГ-ММ-ДД, слово «нет» — снять срок"),
}


async def show_limits(event: Message | CallbackQuery, label: str, note: str = "") -> None:
    users = await cli.secrets()
    user = _find(users, label) or {}
    lines = []
    if note:
        lines += [note, ""]
    lines += [
        f"<b>Лимиты · {esc(label)}</b>",
        "",
        f"Соединения: {user.get('max_conns') or 'без ограничения'}",
        f"Адреса: {user.get('max_ips') or 'без ограничения'}",
        f"Квота: {human_bytes(user['quota_bytes']) if user.get('quota_bytes') else 'без ограничения'}",
        f"Срок: {esc(user.get('expires') or 'бессрочно')}",
    ]
    await render(event, "\n".join(lines), kb.limits_menu(kb.key_for(label)))


@router.callback_query(F.data.startswith("u:limits:"))
async def cb_limits(call: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    resolved = await _resolve(call)
    if resolved is None:
        return
    label, _ = resolved
    await ack(call)
    try:
        await show_limits(call, label)
    except Exception as exc:
        await report_error(call, exc)


@router.callback_query(F.data.startswith("u:lim:"))
async def cb_limit_edit(call: CallbackQuery, state: FSMContext) -> None:
    await ack(call)
    _, _, field, key = call.data.split(":", 3)
    label = kb.label_for(key)
    if label is None:
        await notice(call, stale_button())
        return

    if field == "clear":
        await render(call, "⏳ Снимаю лимиты…")
        try:
            await cli.secret_limits(label, 0, 0, 0, "")
        except Exception as exc:
            await report_error(call, exc)
            await show_limits(call, label)
            return
        await show_limits(call, label, "✅ Все лимиты сняты")
        return

    title, hint = LIMIT_PROMPT[field]
    await state.set_state(UserForm.limit)
    await state.update_data(label=label, field=field)
    await render(call, f"<b>{title}</b>\nПользователь: {esc(label)}\n\n{hint}\n\nПришлите значение.",
                 kb.cancel(f"u:limits:{key}"))


@router.message(UserForm.limit, ~F.text.startswith("/"))
async def do_limit_set(message: Message, state: FSMContext) -> None:
    data = await state.get_data()
    field, label = data.get("field", ""), data.get("label", "")
    value = (message.text or "").strip()
    back = kb.cancel(f"u:limits:{kb.key_for(label)}")

    users = await cli.secrets()
    user = _find(users, label)
    if user is None:
        await state.clear()
        await show_users(message, 0, "Пользователь исчез, пока мы разговаривали")
        return

    conns = int(user.get("max_conns") or 0)
    ips = int(user.get("max_ips") or 0)
    quota = int(user.get("quota_bytes") or 0)
    expires = str(user.get("expires") or "")

    if field in ("conns", "ips"):
        if not value.isdigit():
            await render(message, "⚠️ Нужно целое число, 0 — без ограничения.\n\nПришлите другое.", back)
            return
        if field == "conns":
            conns = int(value)
        else:
            ips = int(value)
    elif field == "quota":
        try:
            gigabytes = float(value.replace(",", "."))
        except ValueError:
            await render(message, "⚠️ Нужно число гигабайт, 0 — без ограничения.\n\nПришлите другое.", back)
            return
        if gigabytes < 0:
            await render(message, "⚠️ Отрицательной квоты не бывает.\n\nПришлите другое.", back)
            return
        quota = int(gigabytes * 1024 ** 3)
    elif field == "expires":
        if value.lower() in ("нет", "-", "0"):
            expires = ""
        elif DATE_RE.match(value):
            expires = value
        else:
            await render(message, "⚠️ Формат ГГГГ-ММ-ДД или слово «нет».\n\nПришлите другое.", back)
            return

    await state.clear()
    try:
        await cli.secret_limits(label, conns, ips, quota, expires)
    except Exception as exc:
        await report_error(message, exc)
        return
    await show_limits(message, label, "✅ Лимиты обновлены")


# ── Ссылки и QR ──────────────────────────────────────────────────────────────

async def make_qr(url: str) -> bytes | None:
    """QR рисует qrencode: тянуть ради картинки Pillow в venv незачем."""
    binary = shutil.which("qrencode")
    if not binary:
        return None
    proc = await asyncio.create_subprocess_exec(
        binary, "-o", "-", "-t", "PNG", "-s", "8", "-m", "2", url,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
    )
    out, _ = await proc.communicate()
    return out if proc.returncode == 0 and out else None


async def send_link(event: Message | CallbackQuery, label: str, move_menu: bool = True) -> None:
    """Ссылка — уведомление: её пересылают и к ней возвращаются, поэтому она
    остаётся в истории, а не подменяется следующим экраном."""
    try:
        tg_link = await cli.secret_link(label)
    except Exception as exc:
        await report_error(event, exc)
        return
    png = await make_qr(web_link(tg_link))
    await notice(event, link_text(label, tg_link), photo=png,
                 filename=f"{label}.png", move=move_menu)


@router.message(Command("link"))
async def cmd_link(message: Message) -> None:
    parts = (message.text or "").split(maxsplit=1)
    try:
        users = await cli.secrets()
    except Exception as exc:
        await report_error(message, exc)
        return
    if len(parts) == 2 and parts[1].strip():
        label = parts[1].strip()
        if _find(users, label) is None:
            await show_users(message, 0, f"Пользователя <b>{esc(label)}</b> нет")
            return
        await send_link(message, label, move_menu=False)
        await show_card(message, label)
        return
    await render(message, "<b>Ссылки на прокси</b>\n\nВыберите пользователя.",
                 kb.users_page(users, 0, "l"))


@router.callback_query(F.data.startswith("l:list:"))
async def cb_links_list(call: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await ack(call)
    try:
        users = await cli.secrets()
    except Exception as exc:
        await report_error(call, exc)
        return
    await render(call, "<b>Ссылки на прокси</b>\n\nВыберите пользователя.",
                 kb.users_page(users, int(call.data.split(":")[2]), "l"))


@router.callback_query(F.data.startswith("l:get:"))
async def cb_link_get(call: CallbackQuery) -> None:
    key = call.data.rsplit(":", 1)[-1]
    label = kb.label_for(key)
    if label is None:
        await ack(call)
        await notice(call, stale_button())
        return
    await ack(call)
    await send_link(call, label)
