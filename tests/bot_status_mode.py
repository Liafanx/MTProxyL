#!/usr/bin/env python3
import pathlib
import sys

repo = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(repo / "mtproxyl-tgbot"))

from bot.format import status_text


def rendered(proxy_mode: str | None, enabled: bool = True) -> str:
    web = {"enabled": True, "domain": "web.example.com"} if enabled else None
    if web is not None and proxy_mode is not None:
        web["proxy_mode"] = proxy_mode
    status = {
        "version": "test",
        "status": "running",
        "port": 443,
        "domain": "proxy.example.com",
        "web": web,
    }
    return status_text(status, {"mode": "manager"})


assert "Режим: <code>Только WEB</code>" in rendered("web")
assert "Режим: <code>MTProto + WEB</code>" in rendered("combined")
assert "Режим: <code>MTProto</code>" in rendered(None, enabled=False)

print("bot status mode: OK")
