"""Мелочи, общие для всех обработчиков."""

from __future__ import annotations

import logging

from aiogram.exceptions import TelegramBadRequest
from aiogram.types import CallbackQuery, InlineKeyboardMarkup, Message

from .cli import CliError
from .format import esc

log = logging.getLogger(__name__)


async def render(
    event: Message | CallbackQuery,
    text: str,
    markup: InlineKeyboardMarkup | None = None,
    force_new: bool = False,
) -> None:
    """Показать экран: правкой прежнего сообщения, если пришли по кнопке."""
    if isinstance(event, CallbackQuery) and event.message and not force_new:
        try:
            await event.message.edit_text(text, reply_markup=markup, disable_web_page_preview=True)
            return
        except TelegramBadRequest as exc:
            # «message is not modified» — обычное дело при повторном нажатии
            # «Обновить», когда с прошлого раза ничего не изменилось.
            if "message is not modified" in str(exc):
                return
            log.debug("не удалось отредактировать сообщение: %s", exc)
        await event.message.answer(text, reply_markup=markup, disable_web_page_preview=True)
        return

    message = event.message if isinstance(event, CallbackQuery) else event
    if message:
        await message.answer(text, reply_markup=markup, disable_web_page_preview=True)


async def report_error(event: Message | CallbackQuery, exc: Exception) -> None:
    """Ошибка CLI — это сообщение самого MTProxyL, его и показываем."""
    if isinstance(exc, CliError):
        text = f"⚠️ {esc(exc)}"
    else:
        log.exception("необработанная ошибка")
        text = f"⚠️ Внутренняя ошибка: {esc(type(exc).__name__)}"
    if isinstance(event, CallbackQuery):
        await event.answer("Не получилось", show_alert=False)
        if event.message:
            await event.message.answer(text)
    else:
        await event.answer(text)


def stale_button() -> str:
    return (
        "Кнопка из старого меню — бот с тех пор перезапускался.\n"
        "Откройте меню заново: /menu"
    )
