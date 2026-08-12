"""Экран бота: одно меню на чат, всегда внизу.

Меню — не сообщение, а место. Каждый новый экран занимает то же сообщение, а
когда меню приходится подвинуть (пришло уведомление, человек написал команду),
старое удаляется и появляется новое — внизу. В истории остаётся только то,
ради чего в неё заглядывают: сообщения наблюдателей, сбои и файлы бэкапов.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

from aiogram.exceptions import TelegramBadRequest
from aiogram.types import (
    BufferedInputFile,
    CallbackQuery,
    InlineKeyboardMarkup,
    Message,
)

from .cli import CliError
from .format import esc

log = logging.getLogger(__name__)


@dataclass
class Menu:
    message_id: int
    text: str
    markup: InlineKeyboardMarkup | None
    # Экран со ссылкой — это фото с подписью. Правкой текста его не обновить,
    # поэтому такой меню-экран всегда пересоздаётся, а при переносе вниз
    # отправляется тем же file_id, а не заново загруженной картинкой.
    file_id: str | None = None


_menus: dict[int, Menu] = {}


def _chat_id(event: Message | CallbackQuery) -> int | None:
    message = event.message if isinstance(event, CallbackQuery) else event
    return message.chat.id if message else None


def _message_of(event: Message | CallbackQuery) -> Message | None:
    return event.message if isinstance(event, CallbackQuery) else event


async def _delete(bot, chat_id: int | None, message_id: int | None) -> None:
    """Удаление «по возможности»: сообщение могли убрать руками, и падать
    из-за этого экран не должен."""
    if bot is None or chat_id is None or message_id is None:
        return
    try:
        await bot.delete_message(chat_id, message_id)
    except TelegramBadRequest as exc:
        log.debug("не удалось удалить %s: %s", message_id, exc)


async def ack(call: CallbackQuery, text: str = "") -> None:
    """Ответить Telegram на нажатие. Делать это надо первым же действием: у
    ответа короткий срок годности, и если сперва выполнить команду, которая
    идёт десяток секунд, Telegram скажет «query is too old», а обработчик
    свалится с исключением — кнопка со стороны человека просто зависнет."""
    try:
        await call.answer(text)
    except TelegramBadRequest as exc:
        log.debug("подтверждение кнопки не прошло: %s", exc)


async def render(
    event: Message | CallbackQuery,
    text: str,
    markup: InlineKeyboardMarkup | None = None,
    force_new: bool = False,
    photo: bytes | None = None,
    filename: str = "qr.png",
) -> None:
    """Показать экран в меню чата."""
    chat_id = _chat_id(event)
    message = _message_of(event)
    if chat_id is None or message is None:
        return

    current = _menus.get(chat_id)

    if photo is not None:
        await _delete(message.bot, chat_id, current.message_id if current else None)
        sent = await message.answer_photo(
            BufferedInputFile(photo, filename=filename), caption=text, reply_markup=markup
        )
        file_id = sent.photo[-1].file_id if sent.photo else None
        _menus[chat_id] = Menu(sent.message_id, text, markup, file_id)
        return

    # Нажали кнопку на текущем меню — правим его на месте: так экран не прыгает
    # и не мигает, а меню и без того самое нижнее.
    if (
        not force_new
        and isinstance(event, CallbackQuery)
        and current is not None
        and current.file_id is None
        and event.message is not None
        and event.message.message_id == current.message_id
    ):
        try:
            await event.message.edit_text(text, reply_markup=markup, disable_web_page_preview=True)
            _menus[chat_id] = Menu(current.message_id, text, markup)
            return
        except TelegramBadRequest as exc:
            # «message is not modified» — обычное дело при повторном нажатии
            # «Обновить», когда с прошлого раза ничего не изменилось.
            if "message is not modified" in str(exc):
                _menus[chat_id] = Menu(current.message_id, text, markup)
                return
            log.debug("правка меню не удалась, шлём новое: %s", exc)

    await _delete(message.bot, chat_id, current.message_id if current else None)
    sent = await message.answer(text, reply_markup=markup, disable_web_page_preview=True)
    _menus[chat_id] = Menu(sent.message_id, text, markup)


async def notice(
    event: Message | CallbackQuery,
    text: str,
    *,
    markup: InlineKeyboardMarkup | None = None,
    move: bool = True,
) -> None:
    """Сообщение, которое остаётся в истории: то, к чему возвращаются, —
    сообщения наблюдателей и сбои. Меню после него съезжает вниз;
    move=False — когда вызывающий всё равно сейчас нарисует новый экран."""
    message = _message_of(event)
    chat_id = _chat_id(event)
    if message is None or chat_id is None:
        return
    await message.answer(text, reply_markup=markup, disable_web_page_preview=True)
    if move:
        await move_menu_down(event)


async def move_menu_down(event: Message | CallbackQuery) -> None:
    """Переложить меню под последнее сообщение, сохранив его содержимое."""
    message = _message_of(event)
    if message is None:
        return
    await move_menu_down_in(message.bot, _chat_id(event))


async def move_menu_down_in(bot, chat_id: int | None) -> None:
    """То же для наблюдателей: у них есть только bot и чат, без сообщения."""
    if chat_id is None:
        return
    current = _menus.get(chat_id)
    if current is None:
        return
    await _delete(bot, chat_id, current.message_id)
    if current.file_id:
        sent = await bot.send_photo(
            chat_id, current.file_id, caption=current.text, reply_markup=current.markup
        )
    else:
        sent = await bot.send_message(
            chat_id, current.text, reply_markup=current.markup, disable_web_page_preview=True
        )
    _menus[chat_id] = Menu(sent.message_id, current.text, current.markup, current.file_id)


def forget_menu(chat_id: int | None) -> None:
    """Забыть меню чата — например, когда его сообщение уже удалено."""
    if chat_id is not None:
        _menus.pop(chat_id, None)


async def report_error(event: Message | CallbackQuery, exc: Exception) -> None:
    """Ошибка CLI — это сообщение самого MTProxyL, его и показываем."""
    if isinstance(exc, CliError):
        text = f"⚠️ {esc(exc)}"
    else:
        log.exception("необработанная ошибка")
        text = f"⚠️ Внутренняя ошибка: {esc(type(exc).__name__)}"
    if isinstance(event, CallbackQuery):
        # Через ack, а не напрямую: подтверждение могло уже протухнуть, и
        # сообщать об ошибке падением поверх ошибки — плохая идея.
        await ack(event, "Не получилось")
    await notice(event, text)


def stale_button() -> str:
    return (
        "Кнопка из старого меню — бот с тех пор перезапускался.\n"
        "Откройте меню заново: /menu"
    )
