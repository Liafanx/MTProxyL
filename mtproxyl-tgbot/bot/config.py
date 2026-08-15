"""Настройки бота: файл config.json рядом с кодом.

Файл правят с двух сторон — из меню MTProxyL (от root) и из самого бота
(от своего пользователя), поэтому читаем его заново, когда меняется mtime,
а пишем через временный файл: оборванная запись оставила бы обрезанный JSON,
и бот не поднялся бы после перезапуска.
"""

from __future__ import annotations

import json
import os
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

CONFIG_PATH = Path(os.environ.get("MTPROXYL_TGBOT_CONFIG", "/opt/mtproxyl-tgbot/config.json"))
STATE_PATH = Path(os.environ.get("MTPROXYL_TGBOT_STATE", "/opt/mtproxyl-tgbot/state.json"))

# Периоды наблюдателей в минутах. Доступность своим таймером считает MTProxyL,
# бот только сверяется с результатом — поэтому здесь можно и почаще.
DEFAULT_NOTIFY = {
    "availability": True,
    "dc": True,
    "proxy": True,
    "backup": True,
    "limits": True,
}
DEFAULT_INTERVALS = {
    "availability": 15,
    "dc": 15,
    "proxy": 5,
    "limits": 60,
}
DEFAULT_AUTOBACKUP = {
    "enabled": False,
    "time": "05:30",
    "send_file": True,
}


@dataclass
class Config:
    token: str = ""
    admins: list[int] = field(default_factory=list)
    notify: dict[str, bool] = field(default_factory=lambda: dict(DEFAULT_NOTIFY))
    intervals: dict[str, int] = field(default_factory=lambda: dict(DEFAULT_INTERVALS))
    autobackup: dict[str, Any] = field(default_factory=lambda: dict(DEFAULT_AUTOBACKUP))

    def notify_on(self, key: str) -> bool:
        return bool(self.notify.get(key, DEFAULT_NOTIFY.get(key, True)))

    def interval(self, key: str) -> int:
        raw = self.intervals.get(key, DEFAULT_INTERVALS.get(key, 15))
        try:
            value = int(raw)
        except (TypeError, ValueError):
            value = DEFAULT_INTERVALS.get(key, 15)
        return max(1, min(1440, value))

    def as_dict(self) -> dict[str, Any]:
        return {
            "token": self.token,
            "admins": self.admins,
            "notify": self.notify,
            "intervals": self.intervals,
            "autobackup": self.autobackup,
        }


_cached: Config | None = None
_cached_mtime: float = -1.0


def load(force: bool = False) -> Config:
    """Текущие настройки. Перечитываются сами, когда файл изменился."""
    global _cached, _cached_mtime
    try:
        mtime = CONFIG_PATH.stat().st_mtime
    except OSError:
        mtime = -1.0
    if not force and _cached is not None and mtime == _cached_mtime:
        return _cached

    raw: dict[str, Any] = {}
    try:
        raw = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        # Битый или отсутствующий файл — не повод падать: без токена бот всё
        # равно не запустится и скажет об этом понятнее, чем трассировкой.
        raw = {}

    cfg = Config(
        token=str(raw.get("token") or "").strip(),
        admins=[int(a) for a in raw.get("admins", []) if str(a).lstrip("-").isdigit()],
        notify={**DEFAULT_NOTIFY, **(raw.get("notify") or {})},
        intervals={**DEFAULT_INTERVALS, **(raw.get("intervals") or {})},
        autobackup={**DEFAULT_AUTOBACKUP, **(raw.get("autobackup") or {})},
    )
    _cached, _cached_mtime = cfg, mtime
    return cfg


def save(cfg: Config) -> None:
    global _cached, _cached_mtime
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(CONFIG_PATH.parent), prefix=".config.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(cfg.as_dict(), fh, ensure_ascii=False, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, CONFIG_PATH)
    except BaseException:
        os.unlink(tmp)
        raise
    _cached, _cached_mtime = cfg, CONFIG_PATH.stat().st_mtime


def load_state() -> dict[str, Any]:
    """Что бот уже сообщал: чтобы не писать одно и то же каждый тик."""
    try:
        data = json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def save_state(state: dict[str, Any]) -> None:
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(STATE_PATH.parent), prefix=".state.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(state, fh, ensure_ascii=False)
        os.chmod(tmp, 0o600)
        os.replace(tmp, STATE_PATH)
    except BaseException:
        os.unlink(tmp)
        raise
