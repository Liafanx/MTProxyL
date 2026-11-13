#!/usr/bin/env python3
"""Поддельный API mtdd для тестов tests/mtdd_*.sh — сам по себе не тест.

Запуск: mtdd_mock_api.py КАТАЛОГ ТОКЕН. Порт пишется в КАТАЛОГ/mock_port.
Режим сборки — в КАТАЛОГ/mock_mode: full (как dev, полный API) или old (как
main: только список, ссылки, создание и удаление, старый конверт без ok).
КАТАЛОГ/mock_fail_post — сколько ближайших POST /v1/users завершить ошибкой 500.
КАТАЛОГ/mock_count — счётчик запросов. Хранилище, как у mtdd, пишется в
КАТАЛОГ/users.json с ревизией (растёт на каждой правке пользователей).
Форма ответов снята с настоящих сборок.
"""
import json, os, sys, threading
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlsplit
if len(sys.argv) < 3:
    print(__doc__); sys.exit(0)
D, TOKEN = sys.argv[1], sys.argv[2]
DOM = "example.org".encode().hex()
lock = threading.Lock()
users = {"admin": {"name": "admin", "secret": "00112233445566778899aabbccddeeff", "enabled": True}}
FULL_FIELDS = {"name", "secret", "enabled", "max_connections", "max_unique_ips", "max_devices",
               "data_quota_bytes", "expires_at", "note", "rate_limit_up_bytes_per_sec",
               "rate_limit_down_bytes_per_sec", "tls_domain"}
OLD_FIELDS = {"name", "secret", "max_connections"}
rid = [0]
rev = [1]

def persist():
    rev[0] += 1
    doc = {"version": 1, "revision": rev[0],
           "users": [{"name": u["name"], "secret": u["secret"], "enabled": u.get("enabled", True)} for u in users.values()]}
    with open(os.path.join(D, "users.json.tmp"), "w") as f:
        json.dump(doc, f)
    os.replace(os.path.join(D, "users.json.tmp"), os.path.join(D, "users.json"))

def mode():
    with open(os.path.join(D, "mock_mode")) as f:
        return f.read().strip()

def bump(name):
    p = os.path.join(D, name)
    try:
        n = int(open(p).read())
    except (OSError, ValueError):
        n = 0
    open(p, "w").write(str(n + 1))
    return n + 1

def take_failure():
    p = os.path.join(D, "mock_fail_post")
    try:
        n = int(open(p).read())
    except (OSError, ValueError):
        return False
    if n <= 0:
        return False
    open(p, "w").write(str(n - 1))
    return True

def view(u):
    full = mode() == "full"
    out = {"name": u["name"], "enabled": u.get("enabled", True), "generation": 1,
           "max_connections": u.get("max_connections"),
           "stats": {"active_connections": 1, "payload_bytes_c2s": 100, "payload_bytes_s2c": 200,
                     "unique_ips_active": 1}}
    if full:
        for k in ("max_unique_ips", "data_quota_bytes", "expires_at", "rate_limit_up_bytes_per_sec",
                  "rate_limit_down_bytes_per_sec", "tls_domain", "max_devices"):
            out[k] = u.get(k)
        out["note"] = u.get("note", "")
        out["stats"].update({"quota_used_bytes": u.get("used", 0), "unique_ips_seen": 2,
                             "devices": 0, "devices_connected": 0, "quota_reset_at": None})
    return out

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, status, data=None, etype=None, msg=None):
        rid[0] += 1
        full = mode() == "full"
        if etype:
            doc = {"error": {"code": status, "type": etype, "message": msg}}
            if full:
                doc.update({"ok": False, "request_id": rid[0]})
        else:
            doc = {"data": data}
            if full:
                doc.update({"ok": True, "request_id": rid[0]})
        raw = json.dumps(doc).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if not n:
            return {}
        try:
            return json.loads(self.rfile.read(n))
        except ValueError:
            return None

    def route(self, method):
        bump("mock_count")
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            return self.send(401, etype="unauthorized", msg="invalid token")
        path = urlsplit(self.path).path
        parts = [p for p in path.split("/") if p]
        full = mode() == "full"
        nf = lambda: self.send(404, etype="not_found", msg="route not found")
        with lock:
            if method == "GET" and path == "/v1/system/info":
                return self.send(200, {"version": "0.1.0"}) if full else nf()
            if method == "GET" and path == "/v1/health":
                return self.send(200, {"status": "ok"})
            if method == "GET" and path == "/v1/status":
                return self.send(200, {"ready": True, "uptime_seconds": 42, "build": {"version": "0.1.0"},
                                       "connections_accepted_total": 10, "connections_active": 2,
                                       "connections_rejected_total": 3,
                                       "connections_rejected_by_reason": {"auth_failed": 3} if full else None,
                                       "handshakes_by_result": {"success": 7, "timeout": 2, "replay": 1} if full else None,
                                       "users_total": len(users), "revision": rev[0],
                                       "me": {"connected_dcs": 1, "dcs": [
                                           {"dc": "2", "connected": True, "ping_rtt_us": 41000, "pool_target": 2, "ready_connections": 2},
                                           {"dc": "-2", "connected": True, "ping_rtt_us": 0, "pool_target": 1, "ready_connections": 1}]}})
            if method == "GET" and path == "/v1/users":
                lst = [view(u) for u in users.values()]
                return self.send(200, {"users": lst, "total": len(lst), "limit": None, "offset": 0, "revision": rev[0]})
            if len(parts) == 2 and parts == ["v1", "users"] and method == "POST":
                b = self.body()
                if b is None:
                    return self.send(400, etype="bad_json", msg="bad json")
                allowed = FULL_FIELDS if full else OLD_FIELDS
                for k in b:
                    if k not in allowed:
                        return self.send(400, etype="unknown_field", msg="unknown field '%s'" % k)
                if take_failure():
                    return self.send(500, etype="internal", msg="injected failure")
                name = b.get("name") or ""
                if name in users:
                    return self.send(409, etype="duplicate_name", msg="user exists")
                sec = (b.get("secret") or ("%032x" % (len(users) + 0xabc))).lower()
                if any(u["secret"] == sec for u in users.values()):
                    return self.send(409, etype="duplicate_secret", msg="secret is already assigned to another user")
                u = dict(b); u["secret"] = sec; u.setdefault("enabled", True)
                users[name] = u
                persist()
                return self.send(200, {"applied": True, "secret": sec, "user": view(u)})
            if len(parts) >= 3 and parts[:2] == ["v1", "users"]:
                name = parts[2]
                u = users.get(name)
                if len(parts) == 4 and parts[3] in ("devices", "enable", "disable", "rotate-secret", "reset-quota") and not full:
                    return nf()
                if len(parts) == 3 and method == "PATCH" and not full:
                    return nf()
                if u is None:
                    return self.send(404, etype="not_found", msg="user '%s' not found" % name)
                if len(parts) == 3 and method == "DELETE":
                    del users[name]
                    persist()
                    return self.send(200, {"applied": True, "deleted": True, "name": name})
                if len(parts) == 3 and method == "PATCH":
                    b = self.body() or {}
                    for k in b:
                        if k in ("name", "secret") or k not in FULL_FIELDS:
                            return self.send(400, etype="unknown_field", msg="unknown field '%s'" % k)
                    for k in ("rate_limit_up_bytes_per_sec", "rate_limit_down_bytes_per_sec"):
                        if b.get(k) is not None and b[k] < 1024:
                            return self.send(400, etype="invalid_value", msg=k + " must be >= 1024")
                    u.update(b)
                    persist()
                    return self.send(200, {"applied": True, "user": view(u)})
                if len(parts) == 4 and method == "GET" and parts[3] == "links":
                    l = "tg://proxy?server=203.0.113.10&port=8443&secret=ee" + u["secret"] + DOM
                    return self.send(200, {"links": {"native": l, "telegram": "https://t.me/proxy?" + l.split("?", 1)[1]}})
                if len(parts) == 4 and method == "GET" and parts[3] == "devices":
                    return self.send(200, {"keys": [{"id": "a1", "dc": 2, "connected": True, "ip": "198.51.100.7"}, {"id": "b2", "dc": 4, "connected": False, "ip": "192.0.2.9"}], "devices": 2, "devices_connected": 1})
                if len(parts) == 4 and method == "POST" and parts[3] in ("enable", "disable"):
                    u["enabled"] = parts[3] == "enable"
                    persist()
                    return self.send(200, {"applied": True})
                if len(parts) == 4 and method == "POST" and parts[3] == "rotate-secret":
                    b = self.body() or {}
                    u["secret"] = (b.get("secret") or "%032x" % 0xfeed).lower()
                    persist()
                    return self.send(200, {"applied": True, "secret": u["secret"]})
                if len(parts) == 4 and method == "POST" and parts[3] == "reset-quota":
                    u["used"] = 0
                    return self.send(200, {"applied": True})
            return nf()

    def do_GET(self): self.route("GET")
    def do_POST(self): self.route("POST")
    def do_PATCH(self): self.route("PATCH")
    def do_DELETE(self): self.route("DELETE")

persist()
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(os.path.join(D, "mock_port"), "w").write(str(srv.server_address[1]))
srv.serve_forever()
