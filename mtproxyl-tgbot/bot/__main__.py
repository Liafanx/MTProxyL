"""Точка входа службы mtproxyl-tgbot."""

from __future__ import annotations

import asyncio
import logging
import sys

from aiogram import BaseMiddleware, Bot, Dispatcher
from aiogram.client.default import DefaultBotProperties
from aiogram.enums import ParseMode
from aiogram.exceptions import TelegramUnauthorizedError
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.types import BotCommand, CallbackQuery, Message, TelegramObject

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
    dp.include_router(handlers_users.router)
    dp.include_router(handlers_ops.router)

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
