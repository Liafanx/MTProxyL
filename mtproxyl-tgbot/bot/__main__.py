"""Точка входа службы mtproxyl-tgbot."""

from __future__ import annotations

import asyncio
import logging
import sys

from aiogram import BaseMiddleware, Bot, Dispatcher
from aiogram.client.default import DefaultBotProperties
from aiogram.enums import ParseMode
from aiogram.exceptions import (
    TelegramAPIError,
    TelegramBadRequest,
    TelegramUnauthorizedError,
)
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.types import BotCommand, CallbackQuery, ErrorEvent, Message, TelegramObject

from . import config, handlers_ops, handlers_users, notify

log = logging.getLogger("mtproxyl-tgbot")

COMMANDS = [
    BotCommand(command="menu", description="Главное меню"),
    BotCommand(command="status", description="Состояние прокси"),
    BotCommand(command="users", description="Пользователи"),
    BotCommand(command="link", description="Ссылка и QR-код"),
    BotCommand(command="traffic", description="Трафик"),
    BotCommand(command="availability", description="Доступность из России"),
    BotCommand(command="check", description="Проверить доступность сейчас"),
    BotCommand(command="backup", description="Бэкап в чат"),
    BotCommand(command="settings", description="Уведомления и таймеры"),
    BotCommand(command="help", description="Все команды"),
]


class AdminOnly(BaseMiddleware):
    """Список админов читается из конфига на каждом апдейте: добавленный в
    меню MTProxyL получает доступ сразу, без перезапуска службы."""

    async def __call__(self, handler, event: TelegramObject, data: dict):
        user = data.get("event_from_user")
        admins = config.load().admins
        if user is None or user.id not in admins:
            log.warning("отклонён апдейт от %s", getattr(user, "id", "?"))
            if isinstance(event, Message):
                await event.answer("Этот бот обслуживает только своего администратора.")
            elif isinstance(event, CallbackQuery):
                await event.answer("Нет доступа", show_alert=True)
            return None
        return await handler(event, data)


class CleanChat(BaseMiddleware):
    """В истории должны остаться только уведомления бота, а не переписка с ним.

    Внешняя, а не внутренняя: сообщение надо убрать и тогда, когда обработчика
    для него не нашлось — иначе «20», отправленное мимо диалога, так и висело
    бы в чате. Удаляем после обработки: до неё нельзя, обработчику нужен текст.
    """

    async def __call__(self, handler, event: TelegramObject, data: dict):
        try:
            return await handler(event, data)
        finally:
            user = data.get("event_from_user")
            if isinstance(event, Message) and user is not None \
                    and user.id in config.load().admins:
                try:
                    await event.delete()
                except TelegramBadRequest as exc:
                    # Право удалять входящие в личной переписке есть всегда, но
                    # сообщение могли убрать раньше — и это не повод шуметь.
                    log.debug("не удалось удалить сообщение: %s", exc)


async def on_error(event: ErrorEvent, bot: Bot) -> bool:
    """Последний рубеж: без него сбой в обработчике оставляет человека перед
    экраном «⏳ …» без объяснений."""
    log.exception("необработанный сбой: %s", event.exception)
    chat = None
    update = event.update
    if update.message is not None:
        chat = update.message.chat.id
    elif update.callback_query is not None and update.callback_query.message is not None:
        chat = update.callback_query.message.chat.id
    if chat is not None:
        try:
            # bot приходит аргументом: у ErrorEvent своего bot нет, и обращение
            # к нему роняло сам обработчик ошибок.
            await bot.send_message(
                chat, "⚠️ Что-то пошло не так. Откройте меню заново: /menu")
        except TelegramAPIError:
            pass
    return True


async def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    cfg = config.load(force=True)
    if not cfg.token:
        log.error("В %s нет токена. Настройте бота: mtproxyl tgbot setup", config.CONFIG_PATH)
        return 1
    if not cfg.admins:
        log.error("В %s нет ни одного администратора: бот никого не пустит. "
                  "Настройте: mtproxyl tgbot setup", config.CONFIG_PATH)
        return 1

    bot = Bot(cfg.token, default=DefaultBotProperties(parse_mode=ParseMode.HTML))
    dp = Dispatcher(storage=MemoryStorage())
    dp.message.middleware(AdminOnly())
    dp.callback_query.middleware(AdminOnly())
    dp.message.outer_middleware(CleanChat())
    dp.include_router(handlers_users.router)
    dp.include_router(handlers_ops.router)
    dp.errors.register(on_error)

    try:
        await bot.set_my_commands(COMMANDS)
    except Exception as exc:  # noqa: BLE001 — список команд не стоит падения
        log.warning("не удалось объявить команды: %s", exc)

    watcher = asyncio.create_task(notify.run(bot))
    try:
        # Пропускаем накопленное за время простоя: команды из прошлой недели
        # выполнять поздно, а «перезапусти прокси» — ещё и опасно.
        await bot.delete_webhook(drop_pending_updates=True)
        await dp.start_polling(bot, allowed_updates=dp.resolve_used_update_types())
    except TelegramUnauthorizedError:
        # Самая частая ошибка настройки. Трассировка на неё в журнале только
        # мешает: она не про код.
        log.error("Telegram не принял токен. Задайте заново: mtproxyl tgbot setup")
        return 1
    finally:
        watcher.cancel()
        await asyncio.gather(watcher, return_exceptions=True)
        await bot.session.close()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except KeyboardInterrupt:
        sys.exit(0)
