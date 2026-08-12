"""Вызовы MTProxyL. Бот — обёртка над CLI, своей логики управления у него нет.

Каждая команда — это запуск bash от root через sudo по поимённому списку в
/etc/sudoers.d/mtproxyl-tgbot. Отсюда две предосторожности: одновременных
запусков не больше двух (на однопроцессорном VPS десяток bash из нажатых
подряд кнопок заметен), а короткие ответы кэшируются на несколько секунд.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import time
from typing import Any

SCRIPT = os.environ.get("MTPROXYL_SCRIPT", "/opt/mtproxyl/mtproxyl.sh")
USE_SUDO = os.environ.get("MTPROXYL_TGBOT_SUDO", "1") != "0"

_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
_ENV = {
    "MTPROXYL_ASSUME_YES": "1",
    "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "LC_ALL": "C.UTF-8",
}

_slots = asyncio.Semaphore(2)


class CliError(Exception):
    """Команда завершилась ошибкой; текст — то, что сказал сам MTProxyL."""


def strip_ansi(text: str) -> str:
    return _ANSI.sub("", text)


def _last_meaningful(*streams: str) -> str:
    for stream in streams:
        lines = [ln.strip() for ln in strip_ansi(stream).splitlines() if ln.strip()]
        if lines:
            return lines[-1]
    return ""


def _sudo_hint(text: str) -> str:
    # Список подкоманд в sudoers поимённый, и бот, обновлённый отдельно от
    # правил, упирается именно в это. Общая формулировка тут бесполезна.
    markers = ("a password is required", "not allowed to execute", "may not run sudo")
    if any(m in text for m in markers):
        return "\n\nБоту не хватает прав sudo на эту команду. Обновите их: mtproxyl tgbot install"
    return ""


async def run(*args: str, timeout: int = 120) -> str:
    """Запустить mtproxyl и вернуть stdout. stderr — только для сообщений."""
    return strip_ansi((await run_bytes(*args, timeout=timeout)).decode("utf-8", "replace"))


async def run_bytes(*args: str, timeout: int = 120) -> bytes:
    """То же, но без декодирования: `backup cat` отдаёт архив как есть."""
    argv = ["sudo", "-n", SCRIPT, *args] if USE_SUDO else [SCRIPT, *args]
    async with _slots:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=_ENV,
        )
        try:
            raw_out, raw_err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            raise CliError(f"Команда не ответила за {timeout} с: mtproxyl {' '.join(args)}")

    if proc.returncode != 0:
        out = raw_out.decode("utf-8", "replace")
        err = raw_err.decode("utf-8", "replace")
        message = _last_meaningful(err, out) or f"код возврата {proc.returncode}"
        raise CliError(strip_ansi(message) + _sudo_hint(err + out))
    return raw_out


def _first_json(text: str) -> str:
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("{") or line.startswith("["):
            return line
    return ""


async def run_json(*args: str, timeout: int = 120) -> Any:
    out = await run(*args, timeout=timeout)
    line = _first_json(out)
    if not line:
        raise CliError(
            "MTProxyL ответил не JSON — возможно, установленная версия не знает "
            f"команду «{' '.join(args)}». Обновите его: mtproxyl update"
        )
    try:
        return json.loads(line)
    except ValueError as exc:
        raise CliError(f"Не удалось разобрать ответ MTProxyL: {exc}") from exc


# ── Кэш коротких ответов ─────────────────────────────────────────────────────

_cache: dict[str, tuple[float, Any]] = {}


async def _cached(key: str, ttl: float, factory) -> Any:
    hit = _cache.get(key)
    now = time.monotonic()
    if hit and now - hit[0] < ttl:
        return hit[1]
    value = await factory()
    _cache[key] = (now, value)
    return value


def invalidate(*keys: str) -> None:
    """После записи: следующий запрос должен увидеть новое состояние."""
    for key in keys or tuple(_cache):
        _cache.pop(key, None)


# ── Чтение ───────────────────────────────────────────────────────────────────

async def status() -> dict:
    return await _cached("status", 3.0, lambda: run_json("status", "--json", timeout=30))


async def mode() -> dict:
    return await _cached("mode", 30.0, lambda: run_json("mode", "--json", timeout=30))


async def is_manager() -> bool:
    try:
        return (await mode()).get("mode") != "reanimator"
    except CliError:
        return False


async def secrets() -> list[dict]:
    data = await _cached("secrets", 3.0, lambda: run_json("secret", "list", "--json", timeout=60))
    return data if isinstance(data, list) else []


async def traffic() -> dict:
    return await _cached("traffic", 5.0, lambda: run_json("traffic", "--json", timeout=60))


async def availability_status() -> dict:
    return await run_json("availability", "status", "--json", timeout=30)


async def availability_details() -> dict:
    return await run_json("availability", "details", timeout=30)


async def availability_check() -> dict:
    # Проверка идёт до минуты: зонды отвечают не мгновенно.
    return await run_json("availability", "check", "--json", timeout=150)


async def availability_autocheck(on: bool) -> None:
    await run("availability", "on" if on else "off", timeout=30)


async def backups() -> list[dict]:
    data = await run_json("backup", "list", "--json", timeout=30)
    return data if isinstance(data, list) else []


# ── Запись ───────────────────────────────────────────────────────────────────

async def proxy_action(action: str) -> str:
    out = await run(action, timeout=180)
    invalidate("status", "mode", "traffic")
    return out


async def secret_add(label: str) -> str:
    out = await run("secret", "add", label, timeout=90)
    invalidate("secrets", "traffic")
    return out


async def secret_remove(label: str) -> str:
    out = await run("secret", "remove", label, timeout=90)
    invalidate("secrets", "traffic")
    return out


async def secret_toggle(label: str, enable: bool) -> str:
    out = await run("secret", "enable" if enable else "disable", label, timeout=90)
    invalidate("secrets", "traffic")
    return out


async def secret_rename(old: str, new: str) -> str:
    out = await run("secret", "rename", old, new, timeout=90)
    invalidate("secrets", "traffic")
    return out


async def secret_limits(label: str, conns: int, ips: int, quota: int, expires: str) -> str:
    out = await run(
        "secret", "setlimits", label, str(conns), str(ips), str(quota), expires or "", timeout=90
    )
    invalidate("secrets")
    return out


async def secret_link(label: str) -> str:
    """tg://-ссылка одного пользователя. Печатается строкой, JSON тут нет."""
    out = await run("secret", "link", label, timeout=60)
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("tg://"):
            return line
    raise CliError(f"MTProxyL не вернул ссылку для «{label}»")


async def create_backup() -> str:
    out = await run("backup", timeout=300)
    return out


async def settings_set(key: str, value: str) -> str:
    out = await run("settings", "set", key, value, timeout=90)
    invalidate()
    return out


async def settings_list() -> list[dict]:
    data = await run_json("settings", "list", "--json", timeout=30)
    return data if isinstance(data, list) else []
