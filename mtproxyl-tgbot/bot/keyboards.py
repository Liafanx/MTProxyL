"""Инлайн-клавиатуры.

Метка пользователя в callback_data не помещается надёжно: Telegram отводит
на неё 64 байта, а метка бывает длинной и в кириллице. Поэтому метки живут в
реестре, а в кнопку идёт короткий ключ. Реестр в памяти: после перезапуска
бота старые кнопки перестают работать, и обработчик честно просит открыть
меню заново — это лучше, чем действие не над тем пользователем.
"""

from __future__ import annotations

import hashlib

from aiogram.types import InlineKeyboardButton, InlineKeyboardMarkup
from aiogram.utils.keyboard import InlineKeyboardBuilder

USERS_PER_PAGE = 8

_labels: dict[str, str] = {}


def key_for(label: str) -> str:
    key = hashlib.blake2s(label.encode("utf-8"), digest_size=6).hexdigest()
    _labels[key] = label
    return key


def label_for(key: str) -> str | None:
    return _labels.get(key)


def main_menu(manager: bool) -> InlineKeyboardMarkup:
    kb = InlineKeyboardBuilder()
    kb.button(text="ℹ️ Статус", callback_data="m:status")
    kb.button(text="🚦 Прокси", callback_data="m:proxy")
    kb.button(text="👥 Пользователи", callback_data="u:list:0")
    kb.button(text="🔗 Ссылки", callback_data="l:list:0")
    kb.button(text="📊 Трафик", callback_data="m:traffic")
    kb.button(text="🇷🇺 Доступность", callback_data="a:show")
    if manager:
        kb.button(text="💾 Бэкапы", callback_data="b:show")
    kb.button(text="⚙️ Настройки", callback_data="s:show")
    kb.adjust(2, 2, 2, 2)
    return kb.as_markup()


def back_only(target: str = "m:root") -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        inline_keyboard=[[InlineKeyboardButton(text="⬅️ Меню", callback_data=target)]]
    )


def proxy_menu(running: bool) -> InlineKeyboardMarkup:
    kb = InlineKeyboardBuilder()
    if running:
        kb.button(text="🔄 Перезапустить", callback_data="px:restart")
        kb.button(text="⏹ Остановить", callback_data="px:stop")
    else:
        kb.button(text="▶️ Запустить", callback_data="px:start")
    kb.button(text="🔃 Обновить", callback_data="m:proxy")
    kb.button(text="⬅️ Меню", callback_data="m:root")
    kb.adjust(2, 1, 1)
    return kb.as_markup()


def users_page(users: list[dict], page: int, action: str = "u") -> InlineKeyboardMarkup:
    """action: u — карточка пользователя, l — сразу ссылка."""
    kb = InlineKeyboardBuilder()
    pages = max(1, (len(users) + USERS_PER_PAGE - 1) // USERS_PER_PAGE)
    page = max(0, min(page, pages - 1))
    chunk = users[page * USERS_PER_PAGE:(page + 1) * USERS_PER_PAGE]

    for user in chunk:
        label = user.get("label", "?")
        mark = "" if user.get("enabled", True) else "⛔ "
        verb = "show" if action == "u" else "get"
        kb.button(text=f"{mark}{label}", callback_data=f"{action}:{verb}:{key_for(label)}")
    kb.adjust(2)

    nav = InlineKeyboardBuilder()
    if pages > 1:
        nav.button(text="◀️", callback_data=f"{action}:list:{(page - 1) % pages}")
        nav.button(text=f"{page + 1}/{pages}", callback_data="noop")
        nav.button(text="▶️", callback_data=f"{action}:list:{(page + 1) % pages}")
        nav.adjust(3)
    kb.attach(nav)

    tail = InlineKeyboardBuilder()
    if action == "u":
        tail.button(text="➕ Добавить", callback_data="u:add")
    tail.button(text="⬅️ Меню", callback_data="m:root")
    tail.adjust(2 if action == "u" else 1)
    kb.attach(tail)
    return kb.as_markup()


def user_card(key: str, enabled: bool, page: int) -> InlineKeyboardMarkup:
    kb = InlineKeyboardBuilder()
    kb.button(text="🔗 Ссылка и QR", callback_data=f"l:get:{key}")
    kb.button(text="⛔ Выключить" if enabled else "✅ Включить", callback_data=f"u:toggle:{key}")
    kb.button(text="✏️ Переименовать", callback_data=f"u:rename:{key}")
    kb.button(text="🎚 Лимиты", callback_data=f"u:limits:{key}")
    kb.button(text="🗑 Удалить", callback_data=f"u:del:{key}")
    kb.button(text="⬅️ К списку", callback_data=f"u:list:{page}")
    kb.adjust(2, 2, 1, 1)
    return kb.as_markup()


def confirm(yes: str, no: str) -> InlineKeyboardMarkup:
    kb = InlineKeyboardBuilder()
    kb.button(text="✅ Да, удалить", callback_data=yes)
    kb.button(text="Отмена", callback_data=no)
    kb.adjust(2)
    return kb.as_markup()


def limits_menu(key: str) -> InlineKeyboardMarkup:
    kb = InlineKeyboardBuilder()
    kb.button(text="Соединения", callback_data=f"u:lim:conns:{key}")
    kb.button(text="Адреса", callback_data=f"u:lim:ips:{key}")
    kb.button(text="Квота трафика", callback_data=f"u:lim:quota:{key}")
    kb.button(text="Срок действия", callback_data=f"u:lim:expires:{key}")
    kb.button(text="Снять все", callback_data=f"u:lim:clear:{key}")
    kb.button(text="⬅️ Назад", callback_data=f"u:show:{key}")
    kb.adjust(2, 2, 1, 1)
    return kb.as_markup()


def link_card(key: str) -> InlineKeyboardMarkup:
    kb = InlineKeyboardBuilder()
    kb.button(text="👤 Пользователь", callback_data=f"u:show:{key}")
    kb.button(text="⬅️ К списку", callback_data="l:list:0")
    kb.adjust(2)
    return kb.as_markup()


def availability_menu(auto_on: bool) -> InlineKeyboardMarkup:
    kb = InlineKeyboardBuilder()
    kb.button(text="🔍 Проверить сейчас", callback_data="a:check")
    kb.button(text="📋 По зондам", callback_data="a:probes")
    kb.button(text="⏸ Выключить авто" if auto_on else "▶️ Включить авто", callback_data="a:auto")
    kb.button(text="⏱ Период", callback_data="a:interval")
    kb.button(text="📉 Порог", callback_data="a:threshold")
    kb.button(text="⬅️ Меню", callback_data="m:root")
    kb.adjust(2, 2, 1, 1)
    return kb.as_markup()


def backups_menu() -> InlineKeyboardMarkup:
    kb = InlineKeyboardBuilder()
    kb.button(text="💾 Создать и прислать", callback_data="b:make")
    kb.button(text="🕗 Автобэкап", callback_data="b:auto")
    kb.button(text="⬅️ Меню", callback_data="m:root")
    kb.adjust(1, 1, 1)
    return kb.as_markup()


def settings_menu(cfg, manager: bool) -> InlineKeyboardMarkup:
    kb = InlineKeyboardBuilder()
    for key, title in (
        ("availability", "Доступность"),
        ("proxy", "Прокси"),
        ("limits", "Лимиты"),
    ):
        mark = "🔔" if cfg.notify.get(key, True) else "🔕"
        kb.button(text=f"{mark} {title}", callback_data=f"s:toggle:{key}")
    if manager:
        mark = "🔔" if cfg.notify.get("backup", True) else "🔕"
        kb.button(text=f"{mark} Бэкапы", callback_data="s:toggle:backup")
    kb.button(text="⏱ Периоды проверок", callback_data="s:intervals")
    kb.button(text="⬅️ Меню", callback_data="m:root")
    kb.adjust(2, 2, 1, 1)
    return kb.as_markup()


def intervals_menu(cfg) -> InlineKeyboardMarkup:
    kb = InlineKeyboardBuilder()
    kb.button(text=f"Доступность: {cfg.interval('availability')} мин", callback_data="s:int:availability")
    kb.button(text=f"Прокси: {cfg.interval('proxy')} мин", callback_data="s:int:proxy")
    kb.button(text=f"Лимиты: {cfg.interval('limits')} мин", callback_data="s:int:limits")
    kb.button(text="⬅️ Назад", callback_data="s:show")
    kb.adjust(1, 1, 1, 1)
    return kb.as_markup()


def autobackup_menu(cfg) -> InlineKeyboardMarkup:
    auto = cfg.autobackup
    kb = InlineKeyboardBuilder()
    kb.button(
        text="⏸ Выключить" if auto.get("enabled") else "▶️ Включить",
        callback_data="b:auto:toggle",
    )
    kb.button(text=f"🕗 Время: {auto.get('time', '05:30')}", callback_data="b:auto:time")
    kb.button(
        text="📎 Файл в чат: да" if auto.get("send_file", True) else "📎 Файл в чат: нет",
        callback_data="b:auto:file",
    )
    kb.button(text="⬅️ Назад", callback_data="b:show")
    kb.adjust(1, 1, 1, 1)
    return kb.as_markup()
