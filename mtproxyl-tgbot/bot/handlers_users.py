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
from aiogram.types import BufferedInputFile, CallbackQuery, Message

from . import cli, keyboards as kb
from .format import esc, human_bytes, link_text, user_card, users_page_text, web_link
from .ui import render, report_error, stale_button

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
        await call.answer()
        if call.message:
            await call.message.answer(stale_button())
        return None
    return label, await cli.secrets()


# ── Список ───────────────────────────────────────────────────────────────────

async def show_users(event: Message | CallbackQuery, page: int = 0) -> None:
    users = await cli.secrets()
    await render(event, users_page_text(users, page, kb.USERS_PER_PAGE),
                 kb.users_page(users, page, "u"))


@router.message(Command("users"))
async def cmd_users(message: Message) -> None:
    try:
        await show_users(message)
    except Exception as exc:
        await report_error(message, exc)


@router.callback_query(F.data.startswith("u:list:"))
async def cb_users_list(call: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await call.answer()
    try:
        await show_users(call, int(call.data.split(":")[2]))
    except Exception as exc:
        await report_error(call, exc)


@router.callback_query(F.data.startswith("u:show:"))
async def cb_user_show(call: CallbackQuery) -> None:
    resolved = await _resolve(call)
    if resolved is None:
        return
    label, users = resolved
    user = _find(users, label)
    if user is None:
        await call.answer("Пользователь исчез")
        await show_users(call)
        return
    await call.answer()
    await render(call, user_card(user),
                 kb.user_card(kb.key_for(label), bool(user.get("enabled")), _page_of(users, label)))


# ── Добавление ───────────────────────────────────────────────────────────────

@router.callback_query(F.data == "u:add")
async def cb_user_add(call: CallbackQuery, state: FSMContext) -> None:
    await call.answer()
    await state.set_state(UserForm.add)
    await call.message.answer(
        "Пришлите имя нового пользователя.\n"
        "Латиница, цифры, дефис и подчёркивание, до 32 символов.\n\nОтмена — /menu"
    )


@router.message(UserForm.add, ~F.text.startswith("/"))
async def do_user_add(message: Message, state: FSMContext) -> None:
    label = (message.text or "").strip()
    if not LABEL_RE.match(label):
        await message.answer("Имя не подходит: латиница, цифры, дефис и подчёркивание, "
                             "до 32 символов. Отмена — /menu")
        return
    await state.clear()
    try:
        await cli.secret_add(label)
    except Exception as exc:
        await report_error(message, exc)
        return
    await message.answer(f"Добавлен: <b>{esc(label)}</b>")
    await send_link(message, label)


# ── Включение, переименование, удаление ──────────────────────────────────────

@router.callback_query(F.data.startswith("u:toggle:"))
async def cb_user_toggle(call: CallbackQuery) -> None:
    resolved = await _resolve(call)
    if resolved is None:
        return
    label, users = resolved
    user = _find(users, label) or {}
    try:
        await cli.secret_toggle(label, not user.get("enabled", True))
    except Exception as exc:
        await report_error(call, exc)
        return
    await call.answer("Готово")
    users = await cli.secrets()
    user = _find(users, label) or {}
    await render(call, user_card(user),
                 kb.user_card(kb.key_for(label), bool(user.get("enabled")), _page_of(users, label)))


@router.callback_query(F.data.startswith("u:rename:"))
async def cb_user_rename(call: CallbackQuery, state: FSMContext) -> None:
    resolved = await _resolve(call)
    if resolved is None:
        return
    label, _ = resolved
    await call.answer()
    await state.set_state(UserForm.rename)
    await state.update_data(label=label)
    await call.message.answer(f"Новое имя для <b>{esc(label)}</b>?\n\nОтмена — /menu")


@router.message(UserForm.rename, ~F.text.startswith("/"))
async def do_user_rename(message: Message, state: FSMContext) -> None:
    new = (message.text or "").strip()
    if not LABEL_RE.match(new):
        await message.answer("Имя не подходит: латиница, цифры, дефис и подчёркивание. "
                             "Отмена — /menu")
        return
    data = await state.get_data()
    await state.clear()
    try:
        await cli.secret_rename(data.get("label", ""), new)
    except Exception as exc:
        await report_error(message, exc)
        return
    await message.answer(f"Теперь это <b>{esc(new)}</b>")
    await show_users(message, 0)


@router.callback_query(F.data.startswith("u:del:"))
async def cb_user_del(call: CallbackQuery) -> None:
    resolved = await _resolve(call)
    if resolved is None:
        return
    label, _ = resolved
    key = kb.key_for(label)
    await call.answer()
    await render(call, f"Удалить <b>{esc(label)}</b>? Ссылка перестанет работать сразу.",
                 kb.confirm(f"u:delyes:{key}", f"u:show:{key}"))


@router.callback_query(F.data.startswith("u:delyes:"))
async def cb_user_del_yes(call: CallbackQuery) -> None:
    resolved = await _resolve(call)
    if resolved is None:
        return
    label, _ = resolved
    try:
        await cli.secret_remove(label)
    except Exception as exc:
        await report_error(call, exc)
        return
    await call.answer("Удалён")
    await show_users(call, 0)


# ── Лимиты ───────────────────────────────────────────────────────────────────

LIMIT_PROMPT = {
    "conns": ("Максимум одновременных соединений", "0 — без ограничения"),
    "ips": ("Максимум уникальных адресов", "0 — без ограничения"),
    "quota": ("Квота трафика в гигабайтах", "0 — без ограничения, дробное можно: 1.5"),
    "expires": ("Дата окончания", "формат ГГГГ-ММ-ДД, слово «нет» — снять срок"),
}


@router.callback_query(F.data.startswith("u:limits:"))
async def cb_limits(call: CallbackQuery) -> None:
    resolved = await _resolve(call)
    if resolved is None:
        return
    label, users = resolved
    user = _find(users, label) or {}
    key = kb.key_for(label)
    lines = [
        f"<b>Лимиты · {esc(label)}</b>",
        "",
        f"Соединения: {user.get('max_conns') or 'без ограничения'}",
        f"Адреса: {user.get('max_ips') or 'без ограничения'}",
        f"Квота: {human_bytes(user['quota_bytes']) if user.get('quota_bytes') else 'без ограничения'}",
        f"Срок: {esc(user.get('expires') or 'бессрочно')}",
    ]
    await call.answer()
    await render(call, "\n".join(lines), kb.limits_menu(key))


@router.callback_query(F.data.startswith("u:lim:"))
async def cb_limit_edit(call: CallbackQuery, state: FSMContext) -> None:
    _, _, field, key = call.data.split(":", 3)
    label = kb.label_for(key)
    if label is None:
        await call.answer()
        await call.message.answer(stale_button())
        return

    if field == "clear":
        try:
            await cli.secret_limits(label, 0, 0, 0, "")
        except Exception as exc:
            await report_error(call, exc)
            return
        await call.answer("Лимиты сняты")
        await cb_limits(call)
        return

    title, hint = LIMIT_PROMPT[field]
    await call.answer()
    await state.set_state(UserForm.limit)
    await state.update_data(label=label, field=field)
    await call.message.answer(f"<b>{title}</b> для {esc(label)}\n{hint}\n\nОтмена — /menu")


@router.message(UserForm.limit, ~F.text.startswith("/"))
async def do_limit_set(message: Message, state: FSMContext) -> None:
    data = await state.get_data()
    field, label = data.get("field", ""), data.get("label", "")
    value = (message.text or "").strip()

    users = await cli.secrets()
    user = _find(users, label)
    if user is None:
        await state.clear()
        await message.answer("Пользователь исчез, пока мы разговаривали.")
        return

    conns = int(user.get("max_conns") or 0)
    ips = int(user.get("max_ips") or 0)
    quota = int(user.get("quota_bytes") or 0)
    expires = str(user.get("expires") or "")

    if field in ("conns", "ips"):
        if not value.isdigit():
            await message.answer("Нужно целое число, 0 — без ограничения. Отмена — /menu")
            return
        if field == "conns":
            conns = int(value)
        else:
            ips = int(value)
    elif field == "quota":
        try:
            gigabytes = float(value.replace(",", "."))
        except ValueError:
            await message.answer("Нужно число гигабайт, 0 — без ограничения. Отмена — /menu")
            return
        if gigabytes < 0:
            await message.answer("Отрицательной квоты не бывает. Отмена — /menu")
            return
        quota = int(gigabytes * 1024 ** 3)
    elif field == "expires":
        if value.lower() in ("нет", "-", "0"):
            expires = ""
        elif DATE_RE.match(value):
            expires = value
        else:
            await message.answer("Формат ГГГГ-ММ-ДД или слово «нет». Отмена — /menu")
            return

    await state.clear()
    try:
        await cli.secret_limits(label, conns, ips, quota, expires)
    except Exception as exc:
        await report_error(message, exc)
        return
    await message.answer(f"Лимиты <b>{esc(label)}</b> обновлены")
    users = await cli.secrets()
    user = _find(users, label) or {}
    await message.answer(user_card(user),
                         reply_markup=kb.user_card(kb.key_for(label),
                                                   bool(user.get("enabled")),
                                                   _page_of(users, label)))


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


async def send_link(event: Message | CallbackQuery, label: str) -> None:
    chat = event.message if isinstance(event, CallbackQuery) else event
    try:
        tg_link = await cli.secret_link(label)
    except Exception as exc:
        await report_error(event, exc)
        return

    text = link_text(label, tg_link)
    markup = kb.link_card(kb.key_for(label))
    png = await make_qr(web_link(tg_link))
    if png:
        await chat.answer_photo(
            BufferedInputFile(png, filename=f"{label}.png"),
            caption=text,
            reply_markup=markup,
        )
    else:
        await chat.answer(text, reply_markup=markup, disable_web_page_preview=True)


@router.message(Command("link"))
async def cmd_link(message: Message) -> None:
    parts = (message.text or "").split(maxsplit=1)
    if len(parts) == 2 and parts[1].strip():
        await send_link(message, parts[1].strip())
        return
    try:
        users = await cli.secrets()
    except Exception as exc:
        await report_error(message, exc)
        return
    await message.answer("Чья ссылка нужна?", reply_markup=kb.users_page(users, 0, "l"))


@router.callback_query(F.data.startswith("l:list:"))
async def cb_links_list(call: CallbackQuery) -> None:
    await call.answer()
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
        await call.answer()
        await call.message.answer(stale_button())
        return
    await call.answer()
    await send_link(call, label)
