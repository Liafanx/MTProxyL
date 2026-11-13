#!/bin/bash
# MTProxyL — цель Reanimator «mtdd» (https://github.com/ugDeDe/mtdd).
#
# mtdd — отдельный MTProto-прокси: конфиг в JSON, пользователи живут в его
# собственном хранилище и меняются только через HTTP API с Bearer-токеном.
# Поэтому здесь всё своё: обнаружение, работа с API, правка JSON-конфига.
# Конфиг TOML telemt к mtdd не относится — писатели TOML для такой цели
# отказывают (_target_toml_guard), иначе mtdd не стартует: неизвестный ключ
# для него ошибка.
#
# Ответы CLI (secret list --json, traffic, dc status) остаются в той же
# форме, что и для telemt: панель и бот читают их одинаково.

MTDD_UNIT="mtdd.service"
MTDD_BIN_DEFAULT="/usr/local/bin/mtdd"
MTDD_CONFIG_DEFAULT="/etc/mtdd/config.json"
MTDD_ENV_DEFAULT="/etc/mtdd/credentials.env"
MTDD_REPO="${MTDD_REPO:-ugDeDe/mtdd}"
MTDD_ENGINE_DIR="${INSTALL_DIR}/target-engine/mtdd"
MTDD_CHANNEL_FILE="${INSTALL_DIR}/mtdd.channel"

# Пункт telemt, которого у mtdd нет. Печатает причину и возвращает 1.
mtdd_unsupported() {
    log_error "У mtdd этого нет: ${1:-функция доступна только для telemt}"
    return 1
}

# ── Python-помощник: API и JSON-конфиг ─────────────────────────
# Токен читается из EnvironmentFile службы и в аргументы процессов не попадает
# (curl -H был бы виден в ps). Коды возврата:
#   0 — успех, 2 — нет конфига, 3 — API не отвечает, 4 — токен отклонён,
#   5 — маршрута нет в этой сборке mtdd, 6 — ошибка запроса (тип и текст в stderr),
#   7 — проверка конфига не прошла.
_mtdd_py_src() {
    cat <<'PY'
import json, os, sys, time, shutil, subprocess, tempfile, urllib.request, urllib.error

CFG = os.environ.get("MTDD_CONFIG") or "/etc/mtdd/config.json"
ENVF = os.environ.get("MTDD_ENV_FILE") or "/etc/mtdd/credentials.env"
BIN = os.environ.get("MTDD_BIN") or "/usr/local/bin/mtdd"

def die(rc, msg=""):
    if msg:
        sys.stderr.write(msg + "\n")
    sys.exit(rc)

def load_cfg():
    try:
        with open(CFG, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        die(2, "config not found: " + CFG)
    except (OSError, ValueError) as e:
        die(2, "config unreadable: %s" % e)

def env_value(name):
    try:
        with open(ENVF, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                if k.strip() == name:
                    v = v.strip()
                    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                        v = v[1:-1]
                    return v
    except OSError:
        pass
    return ""

def base_url(cfg):
    host = cfg.get("control_host") or "127.0.0.1"
    if host in ("0.0.0.0", ""):
        host = "127.0.0.1"
    elif host == "::":
        host = "::1"
    if ":" in host:
        host = "[" + host + "]"
    return "http://%s:%s" % (host, cfg.get("control_port") or 9090)

def token(cfg):
    return env_value(cfg.get("api_token_env") or "MTDD_API_TOKEN")

class ApiError(Exception):
    def __init__(self, rc, status, etype, msg):
        Exception.__init__(self, msg)
        self.rc, self.status, self.etype, self.msg = rc, status, etype, msg

def call(cfg, method, path, body=None, tok=None):
    url = base_url(cfg) + path
    data = None
    headers = {"Authorization": "Bearer " + (tok if tok is not None else token(cfg))}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    for attempt in range(4):
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                raw = r.read()
                status = r.status
        except urllib.error.HTTPError as e:
            raw = e.read()
            status = e.code
        except (urllib.error.URLError, OSError) as e:
            # Чтение повторяем один раз: сеть моргнула или mtdd перезапускается.
            # Запись — нет: повторный POST создал бы дубль либо вернул ложный отказ.
            if method == "GET" and attempt == 0:
                time.sleep(0.5)
                continue
            raise ApiError(3, 0, "unreachable", "API mtdd не отвечает (%s): %s" % (base_url(cfg), e))
        if status == 429 and attempt < 3:
            time.sleep(1)
            continue
        break
    try:
        doc = json.loads(raw.decode() or "{}")
    except ValueError:
        doc = {}
    if 200 <= status < 300:
        return doc.get("data", {})
    err = doc.get("error") or {}
    etype = err.get("type") or str(status)
    msg = err.get("message") or ("HTTP %d" % status)
    if status in (401, 403):
        raise ApiError(4, status, etype, "API mtdd отклонил токен (%d): %s" % (status, msg))
    if status == 404 and etype == "not_found" and msg == "route not found":
        raise ApiError(5, status, etype, "эта сборка mtdd не знает маршрут %s" % path)
    raise ApiError(6, status, etype, msg)

def full_api(cfg):
    try:
        call(cfg, "GET", "/v1/system/info")
        return True
    except ApiError as e:
        if e.rc == 5:
            return False
        raise

def users_doc(cfg):
    # Список и ревизия хранилища (по ней сверяется users.json, см. local_links).
    out, offset, rev = [], 0, None
    while True:
        d = call(cfg, "GET", "/v1/users?limit=1000&offset=%d" % offset) if offset else call(cfg, "GET", "/v1/users")
        if rev is None:
            rev = d.get("revision")
        page = d.get("users") or []
        out.extend(page)
        total = d.get("total")
        if not page or total is None or len(out) >= total or d.get("limit") is None:
            return out, rev
        offset = len(out)

def users(cfg):
    return users_doc(cfg)[0]

def local_links(cfg, rows, revision):
    # Секрет есть в API только в ссылке — по запросу на пользователя. Под
    # root его можно взять из users.json, если ревизия файла та же, что у API,
    # и ссылка, собранная по нему, совпала с настоящей у первого пользователя.
    # Любое расхождение — пусто, и вызывающий идёт за ссылками в API.
    host = cfg.get("public_host") or ""
    port = cfg.get("public_port") or cfg.get("proxy_port")
    path = cfg.get("users_path") or ""
    if not host or ":" in host or not port or not path or revision is None or not rows:
        return {}
    if not os.path.isabs(path):
        path = os.path.join(os.path.dirname(os.path.abspath(CFG)), path)
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return {}
    if not isinstance(doc, dict) or doc.get("revision") != revision:
        return {}
    secrets = {}
    for u in doc.get("users") or []:
        if not isinstance(u, dict):
            continue
        s = str(u.get("secret") or "").lower()
        if isinstance(u.get("name"), str) and len(s) == 32 and all(c in "0123456789abcdef" for c in s):
            secrets[u["name"]] = s
    out = {}
    for u in rows:
        name = u.get("name") or ""
        if name not in secrets:
            return {}
        dom = (u.get("tls_domain") or cfg.get("tls_domain") or "").encode().hex()
        out[name] = "tg://proxy?server=%s&port=%s&secret=ee%s%s" % (host, port, secrets[name], dom)
    first = rows[0].get("name") or ""
    if (links(cfg, first).get("native") or "") != out.get(first):
        return {}
    return out

def links(cfg, name):
    # Пусто — только если пользователя уже нет (удалили между запросами).
    # Остальное, включая 429 после повторов, — ошибка: пустой секрет в
    # экспорте или переносе молча потерял бы пользователя.
    try:
        return (call(cfg, "GET", "/v1/users/%s/links" % name).get("links") or {})
    except ApiError as e:
        if e.status == 404 and e.rc == 6:
            return {}
        raise

def secret_of(link):
    # ee<32 hex секрет><hex домена> или dd<32 hex> — секрет в ссылке.
    q = link.split("secret=", 1)[-1].split("&", 1)[0].lower()
    if q[:2] in ("ee", "dd") and len(q) >= 34:
        return q[2:34]
    return q[:32] if len(q) >= 32 else ""

def devices_ips(cfg, name):
    try:
        keys = call(cfg, "GET", "/v1/users/%s/devices" % name).get("keys") or []
    except ApiError as e:
        if e.rc in (3, 4):
            raise
        return []
    ips = []
    for k in keys:
        ip = k.get("ip")
        if k.get("connected") and isinstance(ip, str) and ip and ip not in ips:
            ips.append(ip)
    return ips

def num(v):
    return v if isinstance(v, int) and not isinstance(v, bool) else None

def store_secrets(cfg, revision):
    # Секреты прямо из users.json (под root), если ревизия та же, что у API.
    path = cfg.get("users_path") or ""
    if not path or revision is None:
        return None
    if not os.path.isabs(path):
        path = os.path.join(os.path.dirname(os.path.abspath(CFG)), path)
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(doc, dict) or doc.get("revision") != revision:
        return None
    return {u["name"]: str(u.get("secret") or "").lower()
            for u in doc.get("users") or [] if isinstance(u, dict) and isinstance(u.get("name"), str)}

def utf8_cut(s, n):
    b = s.encode("utf-8")[:n]
    return b.decode("utf-8", "ignore")

def utc_rfc3339(v):
    # Срок из secrets.conf (RFC3339 с любым смещением или 0) → «…Z» для mtdd.
    if not v or v == "0":
        return None
    import datetime
    t = v.replace("Z", "+00:00")
    if "." in t:
        head, tail = t.split(".", 1)
        tz = tail[next((i for i, ch in enumerate(tail) if ch in "+-"), len(tail)):]
        t = head + tz
    import re
    t = re.sub(r"([+-]\d{2})(\d{2})$", r"\1:\2", t)   # +0300 → +03:00 (Python < 3.11)
    try:
        d = datetime.datetime.fromisoformat(t)
    except ValueError:
        sys.stderr.write("срок %r не разобран — пользователь без срока\n" % v)
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=datetime.timezone.utc)
    return d.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def desired_users(text):
    # Строки secrets.conf: LABEL|SECRET|CREATED|ENABLED|MAX_CONNS|MAX_IPS|QUOTA|EXPIRES|NOTES|AD_TAG|RATE
    out = []
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        f = (line.split("|") + [""] * 11)[:11]
        name, secret = f[0], f[1].lower()
        if not name or len(secret) != 32:
            continue
        def pos(x):
            try:
                x = int(x)
                return x if x > 0 else None
            except ValueError:
                return None
        up = down = None
        if ":" in f[10]:
            a, b = f[10].split(":", 1)
            up = pos(a) // 8 if pos(a) else None
            down = pos(b) // 8 if pos(b) else None
        out.append({"name": name, "secret": secret, "enabled": f[3] != "false",
                    "max_connections": pos(f[4]), "max_unique_ips": pos(f[5]),
                    "data_quota_bytes": pos(f[6]), "expires_at": utc_rfc3339(f[7]),
                    "note": utf8_cut(f[8], 256),   # mtdd: строка до 256 байт, null не принимает
                    "rate_limit_up_bytes_per_sec": up, "rate_limit_down_bytes_per_sec": down})
    return out

POLICY = ("max_connections", "max_unique_ips", "data_quota_bytes", "expires_at", "note",
          "rate_limit_up_bytes_per_sec", "rate_limit_down_bytes_per_sec")

def cmd_sync(cfg, text):
    # secrets.conf → mtdd: завести недостающих с их ключами, убрать лишних,
    # поправить ключ, политики и включённость. Без полного API (бинарник main
    # до пересборки) mtdd хранит только имя, ключ и лимит соединений: выключенный
    # не заводится вовсе — иначе он получил бы доступ.
    want = desired_users(text)
    full = full_api(cfg)
    cur, rev = users_doc(cfg)
    if not want and cur:
        die(6, "в secrets.conf нет пользователей — убирать всех из mtdd не будем")
    have = {u.get("name"): u for u in cur}
    sec = store_secrets(cfg, rev)
    def secret_now(name):
        if sec is not None and name in sec:
            return sec[name]
        return secret_of(links(cfg, name).get("native") or "")
    norm = lambda v: None if v in (None, "", 0) else v
    st = {"created": 0, "updated": 0, "deleted": 0, "skipped": [], "errors": []}
    def body_of(w):
        b = {"name": w["name"], "secret": w["secret"]}
        if full:
            b["enabled"] = w["enabled"]
            for k in POLICY:
                if w[k] not in (None, ""):
                    b[k] = w[k]
        elif w["max_connections"]:
            b["max_connections"] = w["max_connections"]
        return b
    def attempt(name, fn):
        try:
            fn()
            return True
        except ApiError as e:
            st["errors"].append("%s: %s" % (name, e))
            return False
    names = {w["name"] for w in want}
    for name in [n for n in have if n not in names]:
        if attempt(name, lambda n=name: call(cfg, "DELETE", "/v1/users/%s" % n)):
            st["deleted"] += 1
    for w in want:
        n = w["name"]
        if not full and not w["enabled"]:
            st["skipped"].append(n)
            if n in have and attempt(n, lambda: call(cfg, "DELETE", "/v1/users/%s" % n)):
                st["deleted"] += 1
            continue
        u = have.get(n)
        if u is None:
            if attempt(n, lambda: call(cfg, "POST", "/v1/users", body_of(w))):
                st["created"] += 1
            continue
        changed = False
        if full:
            if secret_now(n) != w["secret"]:
                if not attempt(n, lambda: call(cfg, "POST", "/v1/users/%s/rotate-secret" % n, {"secret": w["secret"]})):
                    continue
                changed = True
            patch = {k: w[k] for k in POLICY if norm(u.get(k)) != norm(w[k])}
            if patch:
                if not attempt(n, lambda: call(cfg, "PATCH", "/v1/users/%s" % n, patch)):
                    continue
                changed = True
            if bool(u.get("enabled", True)) != w["enabled"]:
                act = "enable" if w["enabled"] else "disable"
                if not attempt(n, lambda: call(cfg, "POST", "/v1/users/%s/%s" % (n, act), {})):
                    continue
                changed = True
        elif secret_now(n) != w["secret"] or norm(u.get("max_connections")) != norm(w["max_connections"]):
            # Без PATCH и rotate — пересоздать: такая сборка всё равно хранит только это.
            if attempt(n, lambda: call(cfg, "DELETE", "/v1/users/%s" % n)) \
                    and attempt(n, lambda: call(cfg, "POST", "/v1/users", body_of(w))):
                changed = True
        if changed:
            st["updated"] += 1
    st["full_api"] = full
    print(json.dumps(st, ensure_ascii=False))
    if st["errors"]:
        sys.exit(6)

def cmd_patch_noop(cfg, name, body):
    # Сборка без PATCH: правка, совпадающая с тем, что уже стоит, — не ошибка.
    # Панель после создания пользователя шлёт нулевые лимиты и пустую заметку.
    # null, 0 и "" — одно и то же «не задано».
    want = json.loads(body)
    lst, _ = users_doc(cfg)
    u = next((x for x in lst if x.get("name") == name), None)
    if u is None or not isinstance(want, dict):
        die(1)
    norm = lambda v: None if v in (None, "", 0) else v
    for k, v in want.items():
        if norm(u.get(k)) != norm(v):
            die(1)

def cmd_probe(cfg):
    st = {"api": "ok", "full": 0, "version": "", "ready": 0}
    try:
        h = call(cfg, "GET", "/v1/health")
        try:
            info = call(cfg, "GET", "/v1/system/info")
            st["full"] = 1
            st["version"] = info.get("version") or ""
            st["ready"] = 1 if info.get("ready") else 0
            st["uptime"] = info.get("uptime_seconds") or 0
        except ApiError as e:
            if e.rc != 5:
                raise
            s = call(cfg, "GET", "/v1/status")
            st["version"] = ((s.get("build") or {}).get("version")) or ""
            st["ready"] = 1 if s.get("ready") else 0
            st["uptime"] = s.get("uptime_seconds") or 0
    except ApiError as e:
        st["api"] = {3: "down", 4: "auth"}.get(e.rc, "error")
    for k in ("api", "full", "version", "ready", "uptime"):
        print("%s=%s" % (k, st.get(k, "")))

def users_telemt_rows(cfg, want_links=True, want_ips=True, full=None):
    # Пользователи в форме /v1/users telemt: их разбирают _target_user_stats,
    # _target_links_ipv4, _target_user_ip_lists и панель.
    if full is None:
        full = full_api(cfg)
    lst, rev = users_doc(cfg)
    fast = local_links(cfg, lst, rev) if want_links else {}
    rows = []
    for u in lst:
        name = u.get("name") or ""
        s = u.get("stats") or {}
        c2s = num(s.get("payload_bytes_c2s")) or 0
        s2c = num(s.get("payload_bytes_s2c")) or 0
        row = {
            "username": name,
            "enabled": bool(u.get("enabled", True)),
            "current_connections": num(s.get("active_connections")) or 0,
            "active_unique_ips": num(s.get("unique_ips_active")) or 0,
            "recent_unique_ips": num(s.get("unique_ips_seen")) or 0,
            "total_octets": c2s + s2c,
            "octets_from_client": c2s,
            "octets_to_client": s2c,
            "max_tcp_conns": num(u.get("max_connections")),
            "max_unique_ips": num(u.get("max_unique_ips")),
            "data_quota_bytes": num(u.get("data_quota_bytes")),
            "expiration_rfc3339": u.get("expires_at"),
            "quota_used_bytes": num(s.get("quota_used_bytes")) or 0,
        }
        up = num(u.get("rate_limit_up_bytes_per_sec"))
        down = num(u.get("rate_limit_down_bytes_per_sec"))
        row["rate_limit_up_bps"] = up * 8 if up else None
        row["rate_limit_down_bps"] = down * 8 if down else None
        if want_links:
            native = fast.get(name) or (links(cfg, name).get("native") or "")
            row["links"] = {"tls": [native] if native else [], "classic": [], "secure": []}
        if want_ips and full:
            # Устройства — запрос на пользователя; у кого нет активных IP, их
            # и спрашивать незачем.
            row["active_unique_ips_list"] = devices_ips(cfg, name) if row["active_unique_ips"] else []
            row["recent_unique_ips_list"] = []
        rows.append(row)
    return rows

def cmd_users_telemt(cfg, want_links=True, want_ips=True):
    print(json.dumps({"ok": True, "data": users_telemt_rows(cfg, want_links, want_ips)}, ensure_ascii=False))

def cmd_users_tsv(cfg, with_links=True):
    # Строка на пользователя для bash:
    # name|enabled|secret|max_conns|max_ips|quota|expires|note|rate_up_bps|rate_down_bps|conns|ips|c2s|s2c|quota_used|tls_domain
    # Секрет есть только в ссылке, это запрос на пользователя; --no-links
    # оставляет поле пустым и обходится одним запросом списка.
    lst, rev = users_doc(cfg)
    fast = local_links(cfg, lst, rev) if with_links else {}
    for u in lst:
        name = u.get("name") or ""
        s = u.get("stats") or {}
        sec = ""
        if with_links:
            l = {"native": fast[name]} if name in fast else links(cfg, name)
            if not l:
                continue  # удалён, пока читали список
            sec = secret_of(l.get("native") or "")
            if not sec:
                die(6, "не удалось прочитать секрет пользователя " + name)
        up = num(u.get("rate_limit_up_bytes_per_sec")) or 0
        down = num(u.get("rate_limit_down_bytes_per_sec")) or 0
        note = (u.get("note") or "").replace("|", "/").replace("\n", " ")
        f = [name, "true" if u.get("enabled", True) else "false", sec,
             num(u.get("max_connections")) or 0, num(u.get("max_unique_ips")) or 0,
             num(u.get("data_quota_bytes")) or 0, u.get("expires_at") or "", note,
             up * 8, down * 8,
             num(s.get("active_connections")) or 0, num(s.get("unique_ips_active")) or 0,
             num(s.get("payload_bytes_c2s")) or 0, num(s.get("payload_bytes_s2c")) or 0,
             num(s.get("quota_used_bytes")) or 0, u.get("tls_domain") or ""]
        print("|".join(str(x) for x in f))

def cmd_active_ips(cfg):
    # Форма /v1/stats/users/active-ips telemt — её ждёт шейпинг.
    if not full_api(cfg):
        die(5, "эта сборка mtdd не отдаёт устройства (/devices)")
    data = []
    for u in users(cfg):
        if not u.get("enabled", True) or not num((u.get("stats") or {}).get("unique_ips_active")):
            continue
        ips = devices_ips(cfg, u.get("name") or "")
        if ips:
            data.append({"username": u.get("name"), "active_ips": ips})
    print(json.dumps({"ok": True, "data": data}))

def dcs_telemt(me):
    # Форма /v1/stats/dcs telemt. У mtdd пул ME растёт от одного writer по
    # нагрузке: «нужно» — его текущая цель (pool_target), «живо» — готовые.
    d = me or {}
    out = []
    for dc in d.get("dcs") or []:
        try:
            n = int(str(dc.get("dc")))
        except ValueError:
            continue
        if n <= 0:
            continue  # медиа-DC (−1…−5) у telemt в этой таблице нет
        ready = num(dc.get("ready_connections"))
        if ready is None:
            ready = 1 if dc.get("connected") else 0
        target = num(dc.get("pool_target")) or 1
        rtt = (num(dc.get("ping_rtt_us")) or 0) / 1000.0
        pct = 100.0 if ready > 0 else 0.0
        out.append({"dc": n, "rtt_ms": round(rtt, 3), "alive_writers": ready,
                    "required_writers": max(target, 1),
                    "available_pct": pct, "coverage_pct": pct})
    out.sort(key=lambda x: x["dc"])
    return {"middle_proxy_enabled": True, "dcs": out}

def cmd_dcs_telemt(cfg):
    me = call(cfg, "GET", "/v1/stats/me") if full_api(cfg) else call(cfg, "GET", "/v1/status").get("me") or {}
    print(json.dumps({"ok": True, "data": dcs_telemt(me)}))

def cmd_snapshot(cfg):
    # Всё, что панель спрашивает у telemt, одним снимком в форме telemt:
    # один вызов CLI на все вкладки и recorder истории вместо запроса на каждую.
    full = full_api(cfg)
    st = call(cfg, "GET", "/v1/status")
    rows = users_telemt_rows(cfg, True, True, full)
    rej = st.get("connections_rejected_by_reason") or {}
    hs = st.get("handshakes_by_result") or {}
    version = ((st.get("build") or {}).get("version")) or ""
    summary = {
        "uptime_seconds": num(st.get("uptime_seconds")) or 0,
        "connections_total": num(st.get("connections_accepted_total")) or 0,
        "connections_bad_total": num(st.get("connections_rejected_total")) or 0,
        "connections_bad_by_class": [{"class": k, "total": v} for k, v in sorted(rej.items())],
        "handshake_timeouts_total": num(hs.get("timeout")) or 0,
        "handshake_failures_by_class": [{"class": k, "total": v} for k, v in sorted(hs.items())
                                        if k in ("failure", "replay")],
        "configured_users": num(st.get("users_total")) or len(rows),
    }
    quota = [{"username": r["username"], "data_quota_bytes": r["data_quota_bytes"],
              "used_bytes": r["quota_used_bytes"], "last_reset_epoch_secs": None}
             for r in rows if r.get("data_quota_bytes")]
    active = [{"username": r["username"], "active_ips": r.get("active_unique_ips_list") or []}
              for r in rows if r.get("active_unique_ips_list")]
    snap = {
        "engine": "mtdd", "version": version, "full_api": full, "taken_at": int(time.time()),
        "users": rows,
        "summary": summary,
        "system_info": {"version": version, "config_path": "", "config_hash": ""},
        "health": {"status": "ok", "read_only": False},
        "dcs": dcs_telemt(st.get("me") or {}),
        "active_ips": active,
        "quota": {"users": quota},
        "connections": {"current_connections": num(st.get("connections_active")) or 0,
                        "active_users": sum(1 for r in rows if r["current_connections"])},
    }
    print(json.dumps(snap, ensure_ascii=False))

def cmd_cfg_get(cfg, key):
    if key not in cfg:
        die(1)
    v = cfg[key]
    print(v if isinstance(v, str) else json.dumps(v))

def check_config(path):
    try:
        p = subprocess.run([BIN, "--config", path, "--check-config"], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError) as e:
        return False, "не удалось запустить %s: %s" % (BIN, e)
    if p.returncode != 0:
        return False, (p.stderr or p.stdout).strip() or "--check-config: код %d" % p.returncode
    return True, ""

def replace_config(new_text, backup_dir):
    # Кандидат лежит рядом с конфигом: относительные пути (users_path)
    # считаются от каталога конфига, проверка должна видеть то же самое.
    d = os.path.dirname(os.path.abspath(CFG))
    st = os.stat(CFG)
    fd, tmp = tempfile.mkstemp(prefix=".config.mtproxyl-", suffix=".json", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(new_text)
        ok, why = check_config(tmp)
        if not ok:
            die(7, why)
        bak = ""
        if backup_dir:
            os.makedirs(backup_dir, mode=0o700, exist_ok=True)
            bak = os.path.join(backup_dir, "mtdd-config.%s.json" % time.strftime("%Y%m%d-%H%M%S"))
            shutil.copy2(CFG, bak)
            os.chmod(bak, 0o600)
        os.chown(tmp, st.st_uid, st.st_gid)
        os.chmod(tmp, st.st_mode & 0o7777)
        os.replace(tmp, CFG)
        tmp = ""
        print(bak)
    finally:
        if tmp and os.path.exists(tmp):
            os.unlink(tmp)

def cmd_cfg_set(cfg, backup_dir, pairs):
    for p in pairs:
        if "=" not in p:
            die(6, "ожидалось ключ=значение: " + p)
        k, v = p.split("=", 1)
        if v == "@unset":
            cfg.pop(k, None)
            continue
        try:
            val = json.loads(v)
        except ValueError:
            val = v
        cfg[k] = val
    replace_config(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n", backup_dir)

def cmd_cfg_write(src, backup_dir):
    try:
        with open(src, encoding="utf-8") as f:
            text = f.read()
        json.loads(text)
    except (OSError, ValueError) as e:
        die(7, "не JSON: %s" % e)
    replace_config(text if text.endswith("\n") else text + "\n", backup_dir)

def main():
    a = sys.argv[1:]
    if not a:
        die(6, "нет команды")
    c = a[0]
    if c == "cfg-check":
        ok, why = check_config(a[1] if len(a) > 1 else CFG)
        die(0 if ok else 7, why)
    cfg = load_cfg()
    try:
        if c == "probe":
            cmd_probe(cfg)
        elif c == "get":
            print(json.dumps(call(cfg, "GET", a[1]), ensure_ascii=False))
        elif c == "call":
            # Тело — из окружения, а не из аргументов: в нём бывают секреты
            # пользователей, а /proc/<pid>/cmdline виден всем на сервере.
            raw = a[3] if len(a) > 3 else os.environ.get("MTDD_BODY", "")
            body = json.loads(raw) if raw != "" else None
            print(json.dumps(call(cfg, a[1], a[2], body), ensure_ascii=False))
        elif c == "full":
            die(0 if full_api(cfg) else 5)
        elif c == "sync":
            cmd_sync(cfg, sys.stdin.read())
        elif c == "patch-noop":
            cmd_patch_noop(cfg, a[1], a[2])
        elif c == "users-telemt":
            cmd_users_telemt(cfg, "--no-links" not in a, "--no-ips" not in a)
        elif c == "users-tsv":
            cmd_users_tsv(cfg, "--no-links" not in a)
        elif c == "active-ips":
            cmd_active_ips(cfg)
        elif c == "dcs-telemt":
            cmd_dcs_telemt(cfg)
        elif c == "snapshot":
            cmd_snapshot(cfg)
        elif c == "cfg-get":
            cmd_cfg_get(cfg, a[1])
        elif c == "cfg-set":
            cmd_cfg_set(cfg, a[1], a[2:])
        elif c == "cfg-write":
            cmd_cfg_write(a[1], a[2] if len(a) > 2 else "")
        elif c == "secret-of":
            print(secret_of(a[1] if len(a) > 1 else sys.stdin.read().strip()))
        else:
            die(6, "неизвестная команда: " + c)
    except ApiError as e:
        die(e.rc, e.msg if e.rc != 6 else "%s: %s" % (e.etype, e.msg))

main()
PY
}

_mtdd_py() {
    MTDD_CONFIG="${DETECTED_CONFIG_PATH:-$MTDD_CONFIG_DEFAULT}" \
    MTDD_ENV_FILE="$(mtdd_env_file)" MTDD_BIN="$(mtdd_bin)" \
        python3 -I -c "$(_mtdd_py_src)" "$@"
}

# ── Служба, бинарник, файлы ────────────────────────────────────
mtdd_unit_exists() {
    [ "$(systemctl show "$MTDD_UNIT" -p LoadState --value 2>/dev/null)" = "loaded" ] && return 0
    local _u
    for _u in /etc/systemd/system/$MTDD_UNIT /lib/systemd/system/$MTDD_UNIT /usr/lib/systemd/system/$MTDD_UNIT; do
        [ -f "$_u" ] && return 0
    done
    return 1
}

# ExecStart службы: «{ path=/usr/local/bin/mtdd ; argv[]=/usr/local/bin/mtdd --config … ; … }».
_mtdd_execstart_argv() {
    systemctl show "$MTDD_UNIT" -p ExecStart --value 2>/dev/null \
        | sed -nE 's/.*argv\[\]=([^;]*).*/\1/p' | head -1
}

mtdd_bin() {
    local _b; _b=$(_mtdd_execstart_argv | awk '{print $1}')
    [ -n "$_b" ] && [ -x "$_b" ] && { echo "$_b"; return; }
    echo "$MTDD_BIN_DEFAULT"
}

_mtdd_config_from_unit() {
    _mtdd_execstart_argv | awk '{ for (i = 1; i < NF; i++) if ($i == "--config") { print $(i + 1); exit } }'
}

mtdd_env_file() {
    local _f
    _f=$(systemctl show "$MTDD_UNIT" -p EnvironmentFiles --value 2>/dev/null | awk '{print $1}' | head -1)
    _f="${_f#-}"
    [ -n "$_f" ] && [ -f "$_f" ] && { echo "$_f"; return; }
    echo "$MTDD_ENV_DEFAULT"
}

mtdd_cfg_get() {
    _mtdd_py cfg-get "$1" 2>/dev/null
}

mtdd_running() {
    systemctl is-active --quiet "$MTDD_UNIT" 2>/dev/null
}

mtdd_uptime_seconds() {
    local _ts; _ts=$(systemctl show "$MTDD_UNIT" -p ActiveEnterTimestamp --value 2>/dev/null)
    [ -n "$_ts" ] || { echo 0; return; }
    local _start; _start=$(date -d "$_ts" +%s 2>/dev/null) || { echo 0; return; }
    echo $(( $(date +%s) - _start ))
}

# ── Обнаружение ────────────────────────────────────────────────
# Цель mtdd — служба mtdd.service либо бинарник с конфигом на штатном месте.
detect_mtdd() {
    local _cfg=""
    if mtdd_unit_exists; then
        _cfg=$(_mtdd_config_from_unit)
    elif [ -x "$MTDD_BIN_DEFAULT" ] && [ -f "$MTDD_CONFIG_DEFAULT" ]; then
        _cfg="$MTDD_CONFIG_DEFAULT"
    else
        return 1
    fi
    [ -n "$_cfg" ] || _cfg="$MTDD_CONFIG_DEFAULT"
    DETECTED_MODE="mtdd"
    DETECTED_CONTAINER=""
    DETECTED_NETWORK_MODE="host"
    DETECTED_CONFIG_PATH=""
    DETECTED_PORT=""
    DETECTED_IP=""
    [ -f "$_cfg" ] || return 0
    DETECTED_CONFIG_PATH="$_cfg"
    local _p _h
    _p=$(mtdd_cfg_get proxy_port); [[ "$_p" =~ ^[0-9]+$ ]] || _p=14443
    DETECTED_PORT="$_p"
    _h=$(mtdd_cfg_get public_host)
    [[ "$_h" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && DETECTED_IP="$_h"
    return 0
}

# Порт, который видят клиенты: public_port, иначе proxy_port.
# Порт в ссылках: public_port (за NAT), иначе тот, что слушает прокси.
mtdd_public_port() {
    local _p; _p=$(mtdd_cfg_get public_port)
    [[ "$_p" =~ ^[0-9]+$ ]] || _p=$(mtdd_cfg_get proxy_port)
    [[ "$_p" =~ ^[0-9]+$ ]] || _p="${DETECTED_PORT:-}"
    echo "$_p"
}

mtdd_api_port() {
    local _p; _p=$(mtdd_cfg_get control_port)
    [[ "$_p" =~ ^[0-9]+$ ]] || _p=9090
    echo "$_p"
}

mtdd_metrics_port() {
    local _p; _p=$(mtdd_cfg_get metrics_port)
    [[ "$_p" =~ ^[0-9]+$ ]] || _p=9091
    echo "$_p"
}

# Пользовательские функции API доступны только в сборках с полным API.
mtdd_require_full_api() {
    _mtdd_py full 2>/dev/null && return 0
    local _rc=$?
    case "$_rc" in
        5) log_error "Эта сборка mtdd не умеет ${1:-менять пользователей} через API"
           log_info "Обновите mtdd: mtproxyl engine update (свежий бинарник канала)" ;;
        *) log_error "$(mtdd_api_unavailable_reason)" ;;
    esac
    return 1
}

mtdd_api_unavailable_reason() {
    [ -n "${DETECTED_CONFIG_PATH:-}" ] && [ -f "${DETECTED_CONFIG_PATH}" ] || { echo "конфиг mtdd не найден"; return; }
    local _st; _st=$(_mtdd_py probe 2>/dev/null)
    case "$(sed -n 's/^api=//p' <<< "$_st")" in
        ok)   echo "API mtdd отвечает" ;;
        auth) echo "API mtdd отклонил токен — сверьте $(mtdd_env_file) с api_token_env в конфиге" ;;
        *)    mtdd_running || { echo "служба ${MTDD_UNIT} не запущена"; return; }
              echo "API mtdd не отвечает на 127.0.0.1:$(mtdd_api_port)" ;;
    esac
}

# ── Жизненный цикл ─────────────────────────────────────────────
mtdd_start() {
    mtdd_unit_exists || { log_warn "Служба ${MTDD_UNIT} не найдена — запустите mtdd вручную"; return 1; }
    log_info "Запуск ${MTDD_UNIT}..."
    if systemctl start "$MTDD_UNIT" &>/dev/null; then
        log_success "${MTDD_UNIT} запущен"
    else
        log_warn "Не удалось запустить ${MTDD_UNIT}"
        journalctl -u "$MTDD_UNIT" -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
        return 1
    fi
}

mtdd_stop() {
    mtdd_unit_exists || { log_warn "Служба ${MTDD_UNIT} не найдена"; return 1; }
    systemctl stop "$MTDD_UNIT" &>/dev/null && log_success "${MTDD_UNIT} остановлен" \
        || { log_warn "Не удалось остановить ${MTDD_UNIT}"; return 1; }
}

mtdd_restart() {
    mtdd_unit_exists || { log_warn "Служба ${MTDD_UNIT} не найдена — перезапустите mtdd вручную"; return 1; }
    log_info "Перезапуск ${MTDD_UNIT}..."
    if systemctl restart "$MTDD_UNIT" &>/dev/null; then
        log_success "${MTDD_UNIT} перезапущен"
    else
        log_warn "Не удалось перезапустить ${MTDD_UNIT}"
        journalctl -u "$MTDD_UNIT" -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
        return 1
    fi
}

# SIGHUP перечитывает только me_* и media_*; остальное требует рестарта.
# Движок Manager остановлен владельцем — правка ждёт запуска, а не будит его.
_mtdd_mgr_stopped() {
    mtdd_mgr_active && ! mtdd_running || return 1
    log_info "mtdd не запущен — изменения применятся при запуске"
}

mtdd_reload() {
    MTDD_RELOAD_HOT=false
    _mtdd_mgr_stopped && return 0
    mtdd_running || { mtdd_restart; return; }
    # SIGHUP ловит только сборка с полным API; старый main от него падает.
    _mtdd_py full 2>/dev/null || { mtdd_restart; return; }
    MTDD_RELOAD_HOT=true
    systemctl reload "$MTDD_UNIT" &>/dev/null || mtdd_restart
}

mtdd_logs() {
    mtdd_unit_exists || { log_warn "Логи недоступны: служба ${MTDD_UNIT} не найдена"; return 1; }
    journalctl -u "$MTDD_UNIT" -f -n "${1:-30}"
}

# Ждём, пока поднявшийся mtdd ответит на /v1/health.
mtdd_wait_api() {
    local _i
    for _i in $(seq 1 "${1:-20}"); do
        [ "$(_mtdd_py probe 2>/dev/null | sed -n 's/^api=//p')" = "ok" ] && return 0
        sleep 1
    done
    return 1
}

# ── JSON-конфиг ────────────────────────────────────────────────
# mtdd_config_set ключ=значение… — значение JSON (число, true, "строка") или
# @unset. Кандидат проверяется бинарником (--check-config), затем бэкап и
# замена с прежними правами. Перезапуск — забота вызывающего.
mtdd_config_set() {
    # Manager: конфиг собирает MTProxyL, свои ключи живут в tune.json.
    if declare -F mtdd_mgr_active >/dev/null && mtdd_mgr_active; then
        mtdd_mgr_tune_pairs "$@"; return
    fi
    [ -n "${DETECTED_CONFIG_PATH:-}" ] && [ -f "$DETECTED_CONFIG_PATH" ] || { log_error "Конфиг mtdd не найден"; return 1; }
    local _out _rc
    _out=$(_mtdd_py cfg-set "$BACKUP_DIR" "$@" 2>&1); _rc=$?
    if [ $_rc -ne 0 ]; then
        log_error "mtdd не принял конфиг: ${_out}"
        return 1
    fi
    [ -n "$_out" ] && TARGET_CONFIG_BACKUP="$_out" && log_info "Резервная копия: ${_out}"
    return 0
}

# Записать конфиг целиком (edit-config, панель). Проверка та же.
mtdd_config_write_file() {
    local _src="$1" _out _rc
    _out=$(_mtdd_py cfg-write "$_src" "$BACKUP_DIR" 2>&1); _rc=$?
    if [ $_rc -ne 0 ]; then
        log_error "mtdd не принял конфиг: ${_out}"
        return 1
    fi
    [ -n "$_out" ] && TARGET_CONFIG_BACKUP="$_out" && log_info "Резервная копия: ${_out}"
    return 0
}

# Ключи, которые применяются без рестарта (SIGHUP, main.cpp).
_mtdd_hot_key() {
    case "$1" in
        me_clients_per_writer|me_connections_per_dc|media_user_rate_kbps|media_total_rate_kbps) return 0 ;;
    esac
    return 1
}

# tune set для mtdd: один ключ верхнего уровня конфига JSON.
mtdd_tune_set() {
    local _key="$1" _value="$2"
    [[ "$_key" =~ ^[a-z_]+$ ]] || { log_error "Ключ mtdd: латиница в нижнем регистре и _"; return 1; }
    case "$_key" in
        api_token_env|api_read_token_env|metrics_token_env|users_path|usage_state_path|unique_ip_stats_path|me_config_path|me_secret_path)
            log_error "Ключ ${_key} меняет доступ или хранилище mtdd — правьте конфиг вручную (edit-config)"
            return 1 ;;
    esac
    local _json
    if [[ "$_value" =~ ^-?[0-9]+$ ]] || [ "$_value" = "true" ] || [ "$_value" = "false" ] || [ "$_value" = "null" ] \
       || [[ "$_value" =~ ^[\[\{\"] ]]; then
        _json="$_value"
    else
        _json=$(python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$_value")
    fi
    mtdd_config_set "${_key}=${_json}" || return 1
    log_success "${_key} = ${_value}"
    if _mtdd_hot_key "$_key"; then
        mtdd_reload || return 1
        [ "${MTDD_RELOAD_HOT:-false}" = true ] && log_info "Применено без обрыва клиентов (reload)"
        return 0
    else
        _mtdd_mgr_stopped || mtdd_restart
    fi
}

mtdd_tune_clear() {
    local _key="$1"
    mtdd_config_set "${_key}=@unset" || return 1
    log_success "${_key} снят (значение mtdd по умолчанию)"
    if _mtdd_hot_key "$_key"; then mtdd_reload; else _mtdd_mgr_stopped || mtdd_restart; fi
}

# ── Медиа-лимиты (media_user_rate_kbps / media_total_rate_kbps) ─
# Мбит/с на входе, кбит/с в конфиге. 0 — без лимита.
_mtdd_mbit_to_kbps() {
    local _v="${1:-0}"
    [[ "$_v" =~ ^[0-9]+([.,][0-9]{1,3})?$ ]] || return 1
    _v="${_v/,/.}"
    awk -v v="$_v" 'BEGIN { printf "%d\n", v * 1000 + 0.5 }'
}

_mtdd_kbps_human() {
    local _k="${1:-0}"
    [[ "$_k" =~ ^[0-9]+$ ]] || _k=0
    [ "$_k" -eq 0 ] && { echo "без лимита"; return; }
    awk -v k="$_k" 'BEGIN { m = k / 1000; if (m == int(m)) printf "%d Мбит/с\n", m; else printf "%.3g Мбит/с\n", m }'
}

mtdd_media_status_json() {
    local _u _t
    _u=$(mtdd_cfg_get media_user_rate_kbps); [[ "$_u" =~ ^[0-9]+$ ]] || _u=0
    _t=$(mtdd_cfg_get media_total_rate_kbps); [[ "$_t" =~ ^[0-9]+$ ]] || _t=0
    printf '{"available":true,"user_kbps":%s,"total_kbps":%s}\n' "$_u" "$_t"
}

mtdd_media_status() {
    local _u _t
    _u=$(mtdd_cfg_get media_user_rate_kbps); _t=$(mtdd_cfg_get media_total_rate_kbps)
    echo ""
    echo -e "  ${BOLD}Медиа-лимиты mtdd${NC} ${DIM}(загрузки файлов, медиа-DC)${NC}"
    echo -e "    На пользователя: $(_mtdd_kbps_human "$_u")"
    echo -e "    На весь сервер:  $(_mtdd_kbps_human "$_t")"
    echo -e "  ${DIM}Лимит делится между активными медиа-соединениями.${NC}"
    echo ""
}

mtdd_media_set() {
    local _u _t
    _u=$(_mtdd_mbit_to_kbps "${1:-}") || { log_error "На пользователя: Мбит/с, например 20 или 2.5; 0 — без лимита"; return 1; }
    _t=$(_mtdd_mbit_to_kbps "${2:-}") || { log_error "На сервер: Мбит/с, например 500; 0 — без лимита"; return 1; }
    [ "$_u" -le 100000000 ] && [ "$_t" -le 100000000 ] || { log_error "Не больше 100000 Мбит/с"; return 1; }
    mtdd_config_set "media_user_rate_kbps=${_u}" "media_total_rate_kbps=${_t}" || return 1
    mtdd_reload
    log_success "Медиа-лимиты: на пользователя $(_mtdd_kbps_human "$_u"), на сервер $(_mtdd_kbps_human "$_t")"
}

handle_media_command() {
    engine_is_mtdd || { log_error "Медиа-лимиты есть только у движка mtdd"; return 1; }
    case "${1:-status}" in
        status) if [ "${2:-}" = "--json" ]; then mtdd_media_status_json; else mtdd_media_status; fi ;;
        set)    check_root; mtdd_media_set "${2:-}" "${3:-}" ;;
        off)    check_root; mtdd_media_set 0 0 ;;
        *)
            echo -e "  ${BOLD}Медиа-лимиты mtdd:${NC}"
            echo -e "    ${GREEN}media status${NC} [--json]          Текущие значения"
            echo -e "    ${GREEN}media set${NC} <на польз.> <на сервер> Мбит/с, 0 — без лимита"
            echo -e "    ${GREEN}media off${NC}                       Снять оба лимита" ;;
    esac
}

tui_mtdd_media_menu() {
    while true; do
        clear_screen
        draw_header "МЕДИА-ЛИМИТЫ MTDD"
        mtdd_media_status
        echo -e "  ${DIM}Это встроенный лимит mtdd, он работает отдельно от шейпинга${NC}"
        echo -e "  ${DIM}MTProxyL (tc) и от лимита скорости пользователя (secret setrate).${NC}"
        echo ""
        echo -e "  ${DIM}[1]${NC} Задать лимиты"
        echo -e "  ${DIM}[2]${NC} Снять оба лимита"
        echo -e "  ${DIM}[0]${NC} Назад"
        local _c; _c=$(read_choice "выбор" "0")
        case "$_c" in
            1)
                local _u _t
                read_line _u "  ${BOLD}На пользователя, Мбит/с (0 — без лимита):${NC} "
                read_line _t "  ${BOLD}На весь сервер, Мбит/с (0 — без лимита):${NC} "
                handle_media_command set "${_u:-0}" "${_t:-0}" || true
                press_any_key ;;
            2) handle_media_command off || true; press_any_key ;;
            0|"") return ;;
        esac
    done
}

# ── Пользователи ───────────────────────────────────────────────
# Хранилище пользователей mtdd меняется только его API: users.json он держит
# в памяти и перезаписывает сам.

# JSON-строка (с кавычками) для тела запроса.
_mtdd_json_str() {
    python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"
}

# Запрос к API. Тело ответа (data) — в stdout; причина отказа — в
# MTDD_LAST_ERROR (вызывающий решает, как её показать).
_mtdd_call() {
    local _method="$1" _path="$2" _body="${3:-}" _res _rc
    # При успехе помощник пишет только ответ в stdout, при ошибке — только
    # причину в stderr, поэтому их можно слить в одну переменную.
    _res=$(MTDD_BODY="$_body" _mtdd_py call "$_method" "$_path" 2>&1); _rc=$?
    if [ $_rc -ne 0 ]; then
        MTDD_LAST_ERROR="$_res"
        return $_rc
    fi
    MTDD_LAST_ERROR=""
    printf '%s' "$_res"
}

# Строка users-tsv одного пользователя, без секрета (поле 3 пустое): так
# хватает одного запроса списка, а не запроса ссылки на каждого.
_mtdd_user_row() {
    _mtdd_py users-tsv --no-links 2>/dev/null | awk -F'|' -v u="$1" '$1 == u { print; exit }'
}

_mtdd_user_exists() {
    [ -n "$(_mtdd_user_row "$1")" ]
}

# Правило имён mtdd (UserStore::is_valid_name): латиница, цифры, _ . -, до 64.
# «.» и «..» отдельно: метка попадает в путь /v1/users/<метка>.
_mtdd_label_ok() {
    [[ "${1:-}" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] && [ "$1" != "." ] && [ "$1" != ".." ]
}

_mtdd_valid_label() {
    [ -n "$1" ] || { log_error "Требуется метка"; return 1; }
    _mtdd_label_ok "$1" || { log_error "Метка: латиница, цифры, _ . -, до 64 символов"; return 1; }
}

_mtdd_fail() {
    log_error "${1}: ${MTDD_LAST_ERROR:-$(mtdd_api_unavailable_reason)}"
    return 1
}

mtdd_user_link() {
    local _l
    _mtdd_label_ok "${1:-}" || return 1
    _l=$(_mtdd_call GET "/v1/users/${1}/links" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print((d.get("links") or {}).get("native") or "")' 2>/dev/null)
    [ -n "$_l" ] || return 1
    echo "$_l"
}

_mtdd_print_links() {
    local _link; _link=$(mtdd_user_link "$1") || return 0
    echo ""
    echo -e "  ${BOLD}Ссылки для Telegram:${NC}"
    _echo_links "$_link"
    _echo_links "https://t.me/proxy?${_link#tg://proxy?}"
    echo ""
}

mtdd_user_add() {
    local _label="$1" _key="${2:-}"
    _mtdd_valid_label "$_label" || return 1
    if [ -n "$_key" ]; then
        [[ "$_key" =~ ^[0-9a-fA-F]{32}$ ]] || { log_error "Секрет: ровно 32 hex-символа"; return 1; }
    fi
    _mtdd_user_exists "$_label" && { log_error "Пользователь '${_label}' уже есть у mtdd"; return 1; }
    local _body="{\"name\":\"${_label}\""
    [ -n "$_key" ] && _body+=",\"secret\":\"${_key,,}\""
    _body+="}"
    _mtdd_call POST /v1/users "$_body" >/dev/null || _mtdd_fail "Пользователь не создан" || return 1
    log_success "Пользователь '${_label}' добавлен в mtdd"
    _mtdd_print_links "$_label"
}

mtdd_user_remove() {
    local _label="$1"
    _mtdd_valid_label "$_label" || return 1
    _mtdd_call DELETE "/v1/users/${_label}" >/dev/null || _mtdd_fail "Не удалось удалить '${_label}'" || return 1
    log_success "Пользователь '${_label}' удалён, его сессии закрыты"
}

mtdd_user_rotate() {
    local _label="$1" _key="${2:-}" _body="{}"
    _mtdd_valid_label "$_label" || return 1
    mtdd_require_full_api "менять секрет" || return 1
    if [ -n "$_key" ]; then
        [[ "$_key" =~ ^[0-9a-fA-F]{32}$ ]] || { log_error "Секрет: ровно 32 hex-символа"; return 1; }
        _body="{\"secret\":\"${_key,,}\"}"
    fi
    _mtdd_call POST "/v1/users/${_label}/rotate-secret" "$_body" >/dev/null \
        || _mtdd_fail "Секрет '${_label}' не обновлён" || return 1
    log_success "Секрет '${_label}' обновлён, старая ссылка больше не работает"
    _mtdd_print_links "$_label"
}

mtdd_user_toggle() {
    local _label="$1" _action="$2"
    _mtdd_valid_label "$_label" || return 1
    mtdd_require_full_api "включать и выключать пользователей" || return 1
    _mtdd_call POST "/v1/users/${_label}/${_action}" "{}" >/dev/null \
        || _mtdd_fail "Не удалось изменить '${_label}'" || return 1
    if [ "$_action" = enable ]; then
        log_success "Пользователь '${_label}' включён"
    else
        log_success "Пользователь '${_label}' выключен, его сессии закрыты"
    fi
}

# Тело создания с политикой из строки users-tsv (для rename и отката).
_mtdd_body_from_row() {
    local _name="$1" _row="$2"
    # Строка с секретом — через окружение, не в аргументах процесса.
    MTDD_ROW="$_row" python3 -I - "$_name" <<'PY'
import json, os, sys
name, row = sys.argv[1], os.environ.get("MTDD_ROW", "").split("|")
def n(i):
    try:
        v = int(row[i])
        return v if v > 0 else None
    except (IndexError, ValueError):
        return None
b = {"name": name, "secret": row[2], "enabled": row[1] == "true"}
for k, i in (("max_connections", 3), ("max_unique_ips", 4), ("data_quota_bytes", 5)):
    if n(i): b[k] = n(i)
if len(row) > 6 and row[6]: b["expires_at"] = row[6]
if len(row) > 7 and row[7]: b["note"] = row[7]
for k, i in (("rate_limit_up_bytes_per_sec", 8), ("rate_limit_down_bytes_per_sec", 9)):
    if n(i): b[k] = n(i) // 8
if len(row) > 15 and row[15]: b["tls_domain"] = row[15]
print(json.dumps(b, ensure_ascii=False))
PY
}

# В API переименования нет. Секрет уникален, поэтому порядок только такой:
# запомнить → удалить → создать под новым именем. Не вышло — вернуть прежнего.
mtdd_user_rename() {
    local _from="$1" _to="$2"
    [ -n "$_from" ] && [ -n "$_to" ] || { log_error "Использование: secret rename <старая> <новая>"; return 1; }
    _mtdd_valid_label "$_from" || return 1
    _mtdd_valid_label "$_to" || return 1
    mtdd_require_full_api "переименовывать пользователей" || return 1
    local _row _sec; _row=$(_mtdd_user_row "$_from")
    [ -n "$_row" ] || { log_error "Пользователь '${_from}' не найден у mtdd"; return 1; }
    _mtdd_user_exists "$_to" && { log_error "Пользователь '${_to}' уже есть у mtdd"; return 1; }
    _sec=$(mtdd_user_link "$_from" | _mtdd_py secret-of 2>/dev/null)
    [[ "$_sec" =~ ^[0-9a-f]{32}$ ]] || { log_error "Не удалось прочитать секрет '${_from}'"; return 1; }
    _row=$(awk -F'|' -v OFS='|' -v s="$_sec" '{ $3 = s; print }' <<< "$_row")
    local _new_body _old_body
    _new_body=$(_mtdd_body_from_row "$_to" "$_row") || return 1
    _old_body=$(_mtdd_body_from_row "$_from" "$_row") || return 1
    _mtdd_call DELETE "/v1/users/${_from}" >/dev/null || _mtdd_fail "Не удалось переименовать" || return 1
    if ! _mtdd_call POST /v1/users "$_new_body" >/dev/null; then
        local _why="$MTDD_LAST_ERROR"
        if _mtdd_call POST /v1/users "$_old_body" >/dev/null; then
            log_error "Не удалось создать '${_to}' (${_why}) — '${_from}' восстановлен"
        else
            log_error "Не удалось создать '${_to}' (${_why}) и вернуть '${_from}': ${MTDD_LAST_ERROR}"
            log_error "Данные пользователя: ${_old_body}"
        fi
        return 1
    fi
    _rename_user_stats_files "$_from" "$_to" \
        "${INSTALL_DIR}/relay_stats/target_traffic_db" \
        "${INSTALL_DIR}/relay_stats/target_user_ips_db" \
        "${INSTALL_DIR}/relay_stats/target_session_snapshot" \
        || log_warn "Имя изменено, но накопленную статистику перенести не удалось"
    log_success "Пользователь переименован: ${_from} → ${_to} (сессии переподключатся)"
}

# PATCH с проверкой полного API.
_mtdd_patch() {
    local _label="$1" _body="$2" _what="$3"
    _mtdd_valid_label "$_label" || return 1
    if ! _mtdd_py full 2>/dev/null; then
        # Без PATCH правка, которая ничего не меняет, проходит молча: иначе
        # создание пользователя в панели (следом идут нулевые лимиты) падало бы.
        _mtdd_py patch-noop "$_label" "$_body" 2>/dev/null && return 0
        mtdd_require_full_api "$_what"
        return 1
    fi
    _mtdd_call PATCH "/v1/users/${_label}" "$_body" >/dev/null \
        || _mtdd_fail "Не удалось изменить '${_label}'" || return 1
}

# Числовой лимит: пусто — не трогать, 0 — снять, иначе значение.
_mtdd_limit_field() {
    local _k="$1" _v="$2"
    [ -n "$_v" ] || return 0
    [[ "$_v" =~ ^[0-9]+$ ]] || { log_error "${_k}: целое число"; return 1; }
    if [ "$_v" -eq 0 ]; then printf '"%s":null,' "$_k"; else printf '"%s":%s,' "$_k" "$_v"; fi
}

mtdd_user_setlimits() {
    local _label="$1" _conns="${2:-}" _ips="${3:-}" _quota="${4:-}" _expires="${5:-}" _b="" _f
    _f=$(_mtdd_limit_field max_connections "$_conns") || return 1; _b+="$_f"
    _f=$(_mtdd_limit_field max_unique_ips "$_ips") || return 1;    _b+="$_f"
    _f=$(_mtdd_limit_field data_quota_bytes "$_quota") || return 1; _b+="$_f"
    if [ -n "$_expires" ]; then
        local _ex; _ex=$(_normalize_expiry "$_expires") || return 1
        if [ "$_ex" = "0" ]; then _b+='"expires_at":null,'; else _b+="\"expires_at\":\"${_ex}\","; fi
    fi
    [ -n "$_b" ] || { log_error "Нечего менять"; return 1; }
    _mtdd_patch "$_label" "{${_b%,}}" "менять лимиты" || return 1
    log_success "Лимиты '${_label}' обновлены"
}

# Скорость в MTProxyL — бит/с, у mtdd — байт/с, не меньше 1024.
_mtdd_rate_bytes() {
    local _bits; _bits=$(_parse_rate_bps "${1:-0}") || { log_error "Скорость: число бит/с, можно 10M, 512k; не больше 100G"; return 1; }
    [ "$_bits" -eq 0 ] && { echo null; return 0; }
    local _bytes=$(( _bits / 8 ))
    [ "$_bytes" -ge 1024 ] || { log_error "mtdd принимает скорость от 8192 бит/с (1024 байт/с)"; return 1; }
    echo "$_bytes"
}

mtdd_user_setrate() {
    local _label="$1" _up _down
    _up=$(_mtdd_rate_bytes "${2:-0}") || return 1
    _down=$(_mtdd_rate_bytes "${3:-0}") || return 1
    _mtdd_patch "$_label" "{\"rate_limit_up_bytes_per_sec\":${_up},\"rate_limit_down_bytes_per_sec\":${_down}}" "ограничивать скорость" || return 1
    log_success "Скорость '${_label}' обновлена (действует сразу, на открытых сессиях тоже)"
}

mtdd_user_note() {
    local _label="$1"; shift 2>/dev/null || true
    local _text="$*"
    if [ -z "$_text" ]; then
        _mtdd_user_row "$_label" | cut -d'|' -f8
        return 0
    fi
    [ "$_text" = "-" ] && _text=""
    _text="${_text//[|[:cntrl:]]/ }"
    [ "${#_text}" -le 200 ] || { log_error "Заметка: не длиннее 200 символов"; return 1; }
    _mtdd_patch "$_label" "{\"note\":$(_mtdd_json_str "$_text")}" "хранить заметки" || return 1
    if [ -n "$_text" ]; then log_success "Заметка для '${_label}' сохранена"; else log_success "Заметка '${_label}' стёрта"; fi
}

mtdd_user_reset_quota() {
    local _label="$1"
    _mtdd_valid_label "$_label" || return 1
    mtdd_require_full_api "сбрасывать квоту" || return 1
    _mtdd_call POST "/v1/users/${_label}/reset-quota" "{}" >/dev/null \
        || _mtdd_fail "Квота '${_label}' не сброшена" || return 1
    log_success "Квота '${_label}' сброшена"
}

mtdd_users_list() {
    local _rows; _rows=$(_mtdd_py users-tsv --no-links 2>/dev/null) || { log_error "$(mtdd_api_unavailable_reason)"; return 1; }
    if [ -z "$_rows" ]; then
        log_info "У mtdd нет пользователей"
        echo -e "  ${DIM}Добавить: mtproxyl secret add <метка>${NC}"
        return 0
    fi
    echo ""
    draw_header "ПОЛЬЗОВАТЕЛИ MTDD"
    echo ""
    echo -e "  ${DIM}Источник: API mtdd (127.0.0.1:$(mtdd_api_port)/v1/users)${NC}"
    echo ""
    echo -e "  ${BOLD}$(_pad 'МЕТКА' 20) $(_pad 'СТАТУС' 10) $(_pad 'СОЕД.' 6) ЛИМИТЫ${NC}"
    echo -e "  ${DIM}$(_repeat '─' 66)${NC}"
    local _n _en _sec _mc _mi _q _ex _note _ru _rd _c _rest _lim
    while IFS='|' read -r _n _en _sec _mc _mi _q _ex _note _ru _rd _c _rest; do
        [ -n "$_n" ] || continue
        _lim=""
        [ "${_mc:-0}" != 0 ] && _lim="соед: ${_mc}"
        [ "${_mi:-0}" != 0 ] && _lim="${_lim}${_lim:+, }IP: ${_mi}"
        [ "${_q:-0}" != 0 ] && _lim="${_lim}${_lim:+, }квота: $(format_bytes "$_q" 2>/dev/null || echo "$_q")"
        [ -n "$_ex" ] && _lim="${_lim}${_lim:+, }до ${_ex%%T*}"
        [ "${_ru:-0}" != 0 ] || [ "${_rd:-0}" != 0 ] && _lim="${_lim}${_lim:+, }↑$(_rate_human "$_ru") ↓$(_rate_human "$_rd")"
        [ -n "$_lim" ] || _lim="—"
        if [ "$_en" = "true" ]; then
            echo -e "  $(_pad "$_n" 20) ${GREEN}$(_pad 'активен' 10)${NC} $(_pad "${_c:-0}" 6) ${DIM}${_lim}${NC}"
        else
            echo -e "  $(_pad "$_n" 20) ${RED}$(_pad 'выключен' 10)${NC} $(_pad "${_c:-0}" 6) ${DIM}${_lim}${NC}"
        fi
    done <<< "$_rows"
    echo ""
}

# Тот же документ, что secret list --json для telemt-цели: его читают панель и бот.
mtdd_users_list_json() {
    local _rows; _rows=$(_mtdd_py users-tsv 2>/dev/null) || { printf '[]\n'; return 1; }
    local _json
    # Для истории IP ссылки не нужны — лишний запрос на каждого пользователя.
    if _json=$(_mtdd_py users-telemt --no-links 2>/dev/null); then
        _target_user_ip_lists "$_json" | _flush_user_ip_history "$_TARGET_USER_IPS_DB"
    fi
    flush_target_traffic_to_disk 2>/dev/null || true
    declare -A _TDB_IN=() _TDB_OUT=() _TDB_TOTAL=()
    local _TDB_SRC=""
    _load_target_db

    declare -A _IP_HIST=()
    if [ -f "$_TARGET_USER_IPS_DB" ]; then
        local _ht _hu _hip _hfs _hls _entry
        while IFS='|' read -r _ht _hu _hip _hfs _hls; do
            [ "$_ht" = "USER" ] || continue
            [ -n "$_hu" ] && [ -n "$_hip" ] || continue
            json_escape_fast "$_hip"
            _entry="{\"ip\":\"${_JSON_ESCAPE_OUT}\",\"first_seen\":${_hfs:-0},\"last_seen\":${_hls:-0}}"
            if [ -z "${_IP_HIST[$_hu]+x}" ]; then _IP_HIST["$_hu"]="$_entry"; else _IP_HIST["$_hu"]="${_IP_HIST[$_hu]},$_entry"; fi
        done < "$_TARGET_USER_IPS_DB"
    fi

    local _first=1 _n _en _sec _mc _mi _q _ex _note _ru _rd _rest _ln _sn _nn _xn
    printf '['
    while IFS='|' read -r _n _en _sec _mc _mi _q _ex _note _ru _rd _rest; do
        [ -n "$_n" ] || continue
        [ $_first -eq 1 ] || printf ','
        _first=0
        json_escape_fast "$_n";    _ln="$_JSON_ESCAPE_OUT"
        json_escape_fast "$_sec";  _sn="$_JSON_ESCAPE_OUT"
        json_escape_fast "$_note"; _nn="$_JSON_ESCAPE_OUT"
        json_escape_fast "$_ex";   _xn="$_JSON_ESCAPE_OUT"
        printf '{"label":"%s","secret":"%s","created":0,"enabled":%s,"max_conns":%s,"max_ips":%s,"quota_bytes":%s,"expires":"%s","notes":"%s","ad_tag":"","rate_limit_up_bps":%s,"rate_limit_down_bps":%s,"total_in":%s,"total_out":%s,"total_bytes":%s,"ip_history":[%s]}' \
            "$_ln" "$_sn" "$_en" "${_mc:-0}" "${_mi:-0}" "${_q:-0}" "$_xn" "$_nn" "${_ru:-0}" "${_rd:-0}" \
            "${_TDB_IN[$_n]:-0}" "${_TDB_OUT[$_n]:-0}" "${_TDB_TOTAL[$_n]:-0}" "${_IP_HIST[$_n]:-}"
    done <<< "$_rows"
    printf ']\n'
}

mtdd_user_show_limits() {
    local _label="$1"
    [ -n "$_label" ] || { mtdd_users_list; return; }
    local _row; _row=$(_mtdd_user_row "$_label")
    [ -n "$_row" ] || { log_error "Пользователь '${_label}' не найден у mtdd"; return 1; }
    local _n _en _sec _mc _mi _q _ex _note _ru _rd _c _ips _c2s _s2c _qu _dom
    IFS='|' read -r _n _en _sec _mc _mi _q _ex _note _ru _rd _c _ips _c2s _s2c _qu _dom <<< "$_row"
    echo ""
    echo -e "  ${BOLD}Лимиты '${_label}':${NC}"
    echo -e "    Соединений   : $([ "${_mc:-0}" != 0 ] && echo "$_mc" || echo '—')"
    echo -e "    Уникальных IP: $([ "${_mi:-0}" != 0 ] && echo "$_mi" || echo '—')"
    echo -e "    Квота, байт  : $([ "${_q:-0}" != 0 ] && echo "$_q (израсходовано ${_qu:-0})" || echo '—')"
    echo -e "    Истекает     : ${_ex:-—}"
    echo -e "    Скорость     : $([ "${_ru:-0}" != 0 ] || [ "${_rd:-0}" != 0 ] && echo "↑$(_rate_human "$_ru") ↓$(_rate_human "$_rd")" || echo '—')"
    [ -n "$_note" ] && echo -e "    Заметка      : ${_note}"
    [ -n "$_dom" ] && echo -e "    Свой SNI     : ${_dom}"
    echo ""
}

mtdd_users_export() {
    local _rows _n=0 _out="" _name _en _sec _mc _mi _q _ex _note _ru _rd _rest
    _rows=$(_mtdd_py users-tsv 2>/dev/null) || { log_error "$(mtdd_api_unavailable_reason)"; return 1; }
    while IFS='|' read -r _name _en _sec _mc _mi _q _ex _note _ru _rd _rest; do
        [ -n "$_name" ] || continue
        local _rt=""
        { [ "${_ru:-0}" != 0 ] || [ "${_rd:-0}" != 0 ]; } && _rt="${_ru:-0}:${_rd:-0}"
        _out+="${_name}|${_sec}|${_en}|${_mc:-0}|${_mi:-0}|${_q:-0}|${_ex:-0}|${_note}||${_rt}"$'\n'
        _n=$((_n + 1))
    done <<< "$_rows"
    _secret_export_write "${1:-}" "$_out" "$_n"
}

mtdd_users_import() {
    local _file; _file=$(_secret_import_source "${1:-}") || return 1
    local _added=0 _dup=0 _bad=0 _line _ex _body _existing
    local _IMP_L _IMP_K _IMP_CR _IMP_EN _IMP_MC _IMP_MI _IMP_Q _IMP_EX _IMP_N _IMP_AT _IMP_RT
    _existing=$(_mtdd_py users-tsv --no-links 2>/dev/null) || { log_error "$(mtdd_api_unavailable_reason)"; return 1; }
    _existing=$(cut -d'|' -f1 <<< "$_existing")
    local MTDD_FULL_KNOWN=1
    _mtdd_py full 2>/dev/null || MTDD_FULL_KNOWN=0
    while IFS= read -r _line || [ -n "$_line" ]; do
        [[ "$_line" =~ ^[[:space:]]*# ]] && continue
        [[ "$_line" =~ ^[[:space:]]*$ ]] && continue
        _secret_parse_line "$_line" || { _bad=$((_bad + 1)); continue; }
        grep -qxF "$_IMP_L" <<< "$_existing" && { _dup=$((_dup + 1)); continue; }
        _ex=$(_normalize_expiry "$_IMP_EX" 2>/dev/null) || _ex="0"
        [ -n "$_IMP_AT" ] && log_warn "${_IMP_L}: свой ad-tag mtdd не поддерживает — пропущен"
        _body=$(mtdd_user_body "$_IMP_L" "$_IMP_K" "$_IMP_EN" "$_IMP_MC" "$_IMP_MI" "$_IMP_Q" "$_ex" "$_IMP_N" "$_IMP_RT") \
            || { _bad=$((_bad + 1)); continue; }
        if _mtdd_call POST /v1/users "$_body" >/dev/null; then
            _added=$((_added + 1)); _existing+=$'\n'"$_IMP_L"
        else
            log_warn "${_IMP_L}: ${MTDD_LAST_ERROR}"
            case "$MTDD_LAST_ERROR" in duplicate_*) _dup=$((_dup + 1)) ;; *) _bad=$((_bad + 1)) ;; esac
        fi
    done < "$_file"
    [ "${1:-}" != "-" ] || rm -f "$_file"
    log_success "Импортировано: ${_added}, пропущено дубликатов: ${_dup}, строк с ошибкой: ${_bad}"
}

# Тело POST /v1/users из полей формата secrets.conf. На старой сборке mtdd
# (без политик) отправляются только имя, секрет и лимит соединений.
# Аргументы: метка ключ вкл соед ip квота срок(RFC3339|0) заметка скорость(бит:бит)
mtdd_user_body() {
    # Импорт зовёт это на каждого пользователя: полнота API выясняется один раз
    # (MTDD_FULL_KNOWN=1|0), а не запросом на каждую строку.
    local _full="${MTDD_FULL_KNOWN:-}"
    if [ -z "$_full" ]; then _full=1; _mtdd_py full 2>/dev/null || _full=0; fi
    # Ключ (второй аргумент) — через окружение, не в аргументах процесса.
    local _lab="${1:-}" _key="${2:-}"
    shift 2 2>/dev/null || shift $#
    MTDD_KEY="$_key" python3 -I - "$_full" "$_lab" "" "$@" <<'PY'
import json, os, sys
full = sys.argv[1] == "1"
lab, key, en, mc, mi, q, ex, note, rt = (sys.argv[2:] + [""] * 9)[:9]
key = os.environ.get("MTDD_KEY", "")
def pos(v):
    try:
        v = int(v)
        return v if v > 0 else None
    except ValueError:
        return None
b = {"name": lab, "secret": key.lower()}
if pos(mc): b["max_connections"] = pos(mc)
if full:
    b["enabled"] = en != "false"
    if pos(mi): b["max_unique_ips"] = pos(mi)
    if pos(q): b["data_quota_bytes"] = pos(q)
    if ex and ex != "0": b["expires_at"] = ex
    if note: b["note"] = note[:200]
    if ":" in rt:
        up, down = rt.split(":", 1)
        for k, v in (("rate_limit_up_bytes_per_sec", up), ("rate_limit_down_bytes_per_sec", down)):
            if pos(v):
                byt = pos(v) // 8
                if byt < 1024:
                    sys.stderr.write("скорость меньше 8192 бит/с — mtdd её не примет\n"); sys.exit(1)
                b[k] = byt
else:
    # Выключенный пользователь на такой сборке стал бы включённым — то есть
    # получил бы доступ. Его не заводим, а говорим почему.
    if en == "false":
        sys.stderr.write("%s: выключен, а эта сборка mtdd не умеет выключать — не заведён (mtproxyl engine update dev)\n" % lab)
        sys.exit(1)
    lost = [n for n, v in (("IP", pos(mi)), ("квота", pos(q)), ("срок", ex not in ("", "0")),
                            ("заметка", note), ("скорость", ":" in rt)) if v]
    if lost:
        sys.stderr.write("%s: старая сборка mtdd не хранит — %s (mtproxyl engine update dev)\n" % (lab, ", ".join(lost)))
print(json.dumps(b, ensure_ascii=False))
PY
}

# Подкоманды 'mtproxyl secret …' для цели mtdd. Набор тот же, что у telemt.
handle_mtdd_user_command() {
    local subcmd="${1:-list}"; shift 2>/dev/null || true
    case "$subcmd" in
        add)       check_root; mtdd_user_add "${1:-}" "${2:-}" ;;
        remove)    check_root; mtdd_user_remove "${1:-}" ;;
        list)      if [ "${1:-}" = "--json" ]; then mtdd_users_list_json; else mtdd_users_list; fi ;;
        rotate)    check_root; mtdd_user_rotate "${1:-}" "${2:-}" ;;
        enable)    check_root; mtdd_user_toggle "${1:-}" enable ;;
        disable)   check_root; mtdd_user_toggle "${1:-}" disable ;;
        rename)    check_root; mtdd_user_rename "${1:-}" "${2:-}" ;;
        setlimits) check_root; local _l="${1:-}"; shift 2>/dev/null || true
                   mtdd_user_setlimits "$_l" "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
        limits)    mtdd_user_show_limits "${1:-}" ;;
        adtag)     mtdd_unsupported "свой ad-tag у пользователя (есть только общий ad_tag в конфиге)" ;;
        note)      check_root; mtdd_user_note "$@" ;;
        setrate)   check_root; mtdd_user_setrate "${1:-}" "${2:-0}" "${3:-0}" ;;
        reset-quota) check_root; mtdd_user_reset_quota "${1:-}" ;;
        api-view)  secret_api_view_json true "${1:-}" ;;
        export)    check_root; mtdd_users_export "${1:--}" ;;
        import)    check_root; mtdd_users_import "${1:-}" ;;
        link|qr)
            local _link; _link=$(mtdd_user_link "${1:-}") || { log_error "Пользователь '${1:-}' не найден у mtdd"; return 1; }
            _echo_links "$_link"
            echo "" ;;
        clone)     log_error "Клонирование недоступно в реаниматоре"; return 1 ;;
        *)
            echo -e "  ${BOLD}Пользователи mtdd (реаниматор):${NC}"
            echo -e "  ${DIM}Хранит сам mtdd, правки идут через его API и применяются сразу${NC}"
            echo ""
            echo -e "    ${GREEN}secret add${NC} <метка> [ключ]  Добавить"
            echo -e "    ${GREEN}secret remove${NC} <метка>      Удалить"
            echo -e "    ${GREEN}secret list${NC}                Список"
            echo -e "    ${GREEN}secret rotate${NC} <метка> [ключ] Обновить ключ"
            echo -e "    ${GREEN}secret enable|disable${NC} <метка>"
            echo -e "    ${GREEN}secret rename${NC} <из> <в>     Переименовать"
            echo -e "    ${GREEN}secret limits${NC} [метка]      Лимиты"
            echo -e "    ${GREEN}secret setlimits${NC} <метка> <соед> <ip> <квота> [срок]"
            echo -e "    ${GREEN}secret setrate${NC} <метка> <вверх> <вниз>  бит/с (10M, 512k, 0 — без)"
            echo -e "    ${GREEN}secret note${NC} <метка> [текст|-]"
            echo -e "    ${GREEN}secret reset-quota${NC} <метка>"
            echo -e "    ${GREEN}secret link${NC} <метка>"
            echo -e "    ${GREEN}secret export${NC} [файл|-] · ${GREEN}secret import${NC} <файл|->" ;;
    esac
}

# ── tune для mtdd ──────────────────────────────────────────────
# ключ:проверка. Доступ, токены и пути хранилищ сюда не входят — они меняют
# то, через что MTProxyL вообще разговаривает с mtdd.
_MTDD_TUNE_WHITELIST=(
    "workers:^[0-9]+$"
    "max_connections:^[0-9]+$"
    "max_handshakes:^[0-9]+$"
    "handshake_timeout_seconds:^[0-9]+$"
    "idle_timeout_seconds:^[0-9]+$"
    "client_keepalive_seconds:^[0-9]+$"
    "client_ack_timeout_seconds:^[0-9]+$"
    "shutdown_timeout_seconds:^[0-9]+$"
    "me_connections_per_dc:^[0-9]+$"
    "me_clients_per_writer:^[0-9]+$"
    "metadata_refresh_seconds:^[0-9]+$"
    "global_buffer_bytes:^[0-9]+$"
    "connection_queue_bytes:^[0-9]+$"
    "max_frame_bytes:^[0-9]+$"
    "cpu_affinity:^(true|false)$"
    "masking:^(true|false)$"
    "direct_fallback_enabled:^(true|false)$"
    "direct_fallback_dcs:^\\[[-0-9, ]*\\]$"
    "media_user_rate_kbps:^[0-9]+$"
    "media_total_rate_kbps:^[0-9]+$"
    "device_window_seconds:^[0-9]+$"
    "unique_ip_min_bytes:^[0-9]+$"
    "suspects:^(true|false)$"
    "fingerprint:^(true|false)$"
    "suspect_watch_score:^[0-9]+$"
    "suspect_ban_score:^[0-9]+$"
    "suspect_ttl_hours:^[0-9]+$"
)

_mtdd_tune_lookup() {
    local _e
    for _e in "${_MTDD_TUNE_WHITELIST[@]}"; do
        [ "${_e%%:*}" = "$1" ] && { echo "${_e#*:}"; return 0; }
    done
    return 1
}

mtdd_handle_tune() {
    local _sub="${1:-list}"; shift 2>/dev/null || true
    case "$_sub" in
        list)
            echo ""; draw_header "ПАРАМЕТРЫ ТЮНИНГА MTDD"; echo ""
            local _e _k _v
            for _e in "${_MTDD_TUNE_WHITELIST[@]}"; do
                _k="${_e%%:*}"; _v=$(mtdd_cfg_get "$_k")
                printf "  %-30s %s\n" "$_k" "${_v:-${DIM}по умолчанию${NC}}"
            done
            echo ""
            echo -e "  ${DIM}Без обрыва клиентов (reload): me_*, media_*. Остальное — с перезапуском.${NC}"
            echo "" ;;
        get)
            [ -n "${1:-}" ] || { mtdd_handle_tune list; return; }
            local _v; _v=$(mtdd_cfg_get "$1")
            [ -n "$_v" ] && echo "  ${1} = ${_v}" || echo -e "  ${DIM}${1}: по умолчанию${NC}" ;;
        set)
            check_root
            local _k="${1:-}" _v="${2:-}" _re
            [ -n "$_k" ] && [ -n "$_v" ] || { log_error "Использование: tune set <параметр> <значение>"; return 1; }
            _re=$(_mtdd_tune_lookup "$_k") || { log_error "Неизвестный параметр mtdd. Выполните: mtproxyl tune list"; return 1; }
            [[ "$_v" =~ $_re ]] || { log_error "Некорректное значение (ожидается: ${_re})"; return 1; }
            mtdd_tune_set "$_k" "$_v" ;;
        clear)
            check_root
            local _k="${1:-}"
            [ -n "$_k" ] && [ "$_k" != all ] || { log_error "Использование: tune clear <параметр>"; return 1; }
            _mtdd_tune_lookup "$_k" >/dev/null || { log_error "Неизвестный параметр mtdd"; return 1; }
            mtdd_tune_clear "$_k" ;;
        *) log_error "Использование: mtproxyl tune list|get|set|clear" ; return 1 ;;
    esac
}

# Правка конфига в редакторе: копия → редактор → проверка mtdd → замена.
# Неудачная проверка оставляет рабочий конфиг нетронутым, а правку — в копии.
mtdd_edit_config() {
    local _editor="$1" _tmp
    _tmp=$(_mktemp) || return 1
    cp "$DETECTED_CONFIG_PATH" "$_tmp" || return 1
    "$_editor" "$_tmp"
    if cmp -s "$_tmp" "$DETECTED_CONFIG_PATH"; then
        log_info "Изменений нет — перезапуск не требуется"
        rm -f "$_tmp"; return 0
    fi
    if ! mtdd_config_write_file "$_tmp"; then
        local _keep; _keep="${BACKUP_DIR}/mtdd-config.rejected-$(date +%Y%m%d-%H%M%S).json"
        mkdir -p "$BACKUP_DIR"; cp "$_tmp" "$_keep" 2>/dev/null && chmod 600 "$_keep"
        log_warn "Рабочий конфиг не изменён. Ваша правка сохранена: ${_keep}"
        rm -f "$_tmp"; return 1
    fi
    rm -f "$_tmp"
    log_success "Конфиг mtdd изменён"
    mtdd_running || { log_info "mtdd не запущен — изменения применятся при запуске"; return 0; }
    local _r; read_line _r "  ${BOLD}Перезапустить mtdd, чтобы применить изменения? [Y/n]:${NC} "
    [[ "$_r" =~ ^[nN] ]] && { log_info "Перезапуск отложен"; return 0; }
    mtdd_restart && mtdd_wait_api 15 && log_success "mtdd перезапущен и отвечает" \
        || log_error "mtdd не поднялся — откатить: mtproxyl target-config write < ${TARGET_CONFIG_BACKUP}"
}

# ── Selfmask ───────────────────────────────────────────────────
# Тот же смысл, что [censorship] telemt: неаутентифицированный ClientHello
# mtdd отправляет на fallback_host:fallback_port (заглушку на хосте), если
# fallback_port задан. unknown_sni_action у mtdd нет — чужой SNI тоже уходит
# в fallback. Снимок хранит прежние значения; пусто — ключа не было, и при
# откате он снимается (у mtdd «нет ключа» — это его значение по умолчанию).
# Снимок делается один раз: повторное применение (другой домен) записало бы в
# «прежние» значения самого Selfmask. masking лежит в SELFMASK_PREV_MASKING_ENABLED —
# файл настроек у каждого режима свой, в Reanimator эта переменная свободна.
mtdd_selfmask_snapshot() {
    [ "${SELFMASK_PREV_SAVED:-false}" = "true" ] && return 0
    SELFMASK_PREV_DOMAIN=$(mtdd_cfg_get tls_domain)
    SELFMASK_PREV_MASKING_ENABLED=$(mtdd_cfg_get masking)
    SELFMASK_PREV_MASK_HOST=$(mtdd_cfg_get fallback_host)
    SELFMASK_PREV_MASK_PORT=$(mtdd_cfg_get fallback_port)
    SELFMASK_PREV_UNKNOWN_SNI=""
    SELFMASK_PREV_PUBLIC_HOST=$(mtdd_cfg_get public_host)
    SELFMASK_PREV_SAVED="true"
    return 0
}

_mtdd_restore_pair() {
    local _k="$1" _v="$2"
    if [ -z "$_v" ]; then
        printf '%s=@unset\n' "$_k"
    elif [[ "$_v" =~ ^([0-9]+|true|false)$ ]]; then
        printf '%s=%s\n' "$_k" "$_v"
    else
        printf '%s=%s\n' "$_k" "$(_mtdd_json_str "$_v")"
    fi
}

mtdd_selfmask_restore() {
    local -a _pairs=()
    # tls_domain у mtdd обязателен: без прежнего значения оставляем текущий.
    [ -n "${SELFMASK_PREV_DOMAIN:-}" ] && _pairs+=("$(_mtdd_restore_pair tls_domain "$SELFMASK_PREV_DOMAIN")")
    _pairs+=("$(_mtdd_restore_pair fallback_host "${SELFMASK_PREV_MASK_HOST:-}")")
    _pairs+=("$(_mtdd_restore_pair fallback_port "${SELFMASK_PREV_MASK_PORT:-}")")
    _pairs+=("$(_mtdd_restore_pair public_host "${SELFMASK_PREV_PUBLIC_HOST:-}")")
    _pairs+=("$(_mtdd_restore_pair masking "${SELFMASK_PREV_MASKING_ENABLED:-}")")
    local _ok=true
    mtdd_config_set "${_pairs[@]}" || _ok=false
    SELFMASK_PREV_SAVED="false"
    SELFMASK_PREV_DOMAIN=""; SELFMASK_PREV_MASK_HOST=""; SELFMASK_PREV_MASK_PORT=""
    SELFMASK_PREV_UNKNOWN_SNI=""; SELFMASK_PREV_PUBLIC_HOST=""; SELFMASK_PREV_MASKING_ENABLED=""
    if [ "$_ok" = true ]; then
        log_success "Конфиг mtdd возвращён к состоянию до Selfmask"
        return 0
    fi
    log_warn "Не удалось вернуть прежние параметры — проверьте tls_domain/fallback_* в ${DETECTED_CONFIG_PATH}"
    return 1
}

mtdd_selfmask_apply() {
    local _old_domain; _old_domain=$(mtdd_cfg_get tls_domain)
    echo ""
    echo -e "  ${BOLD}Нужно применить в конфиге mtdd (${DETECTED_CONFIG_PATH:-—}):${NC}"
    echo -e "    \"tls_domain\": \"${SELFMASK_DOMAIN}\"${_old_domain:+  ${DIM}(было: ${_old_domain})${NC}}"
    echo -e "    \"masking\": true"
    echo -e "    \"fallback_host\": \"127.0.0.1\""
    echo -e "    \"fallback_port\": ${SELFMASK_NGINX_BACKEND_PORT}"
    echo -e "    \"public_host\": \"${SELFMASK_DOMAIN}\"  ${DIM}(иначе ссылки будут с IP, а не с доменом)${NC}"
    echo ""
    if [ -n "$_old_domain" ] && [ "$_old_domain" != "${SELFMASK_DOMAIN}" ]; then
        log_warn "Смена SNI-домена меняет FakeTLS-ссылки — старые ee-ссылки перестанут работать"
        echo ""
    fi
    [ -n "${DETECTED_CONFIG_PATH:-}" ] && [ -f "${DETECTED_CONFIG_PATH}" ] || {
        log_warn "Конфиг mtdd не найден — примените параметры выше вручную и перезапустите mtdd"
        return 1
    }
    local _yn; read_line _yn "  ${BOLD}Применить в ${DETECTED_CONFIG_PATH} и перезапустить mtdd? [Y/n]:${NC} "
    [[ "$_yn" =~ ^[nN] ]] && { log_info "Пропущено — примените параметры вручную и перезапустите mtdd"; return 0; }

    # Снимок уже был (повторное применение) — при сбое он остаётся как есть.
    local _had_snap="${SELFMASK_PREV_SAVED:-false}"
    mtdd_selfmask_snapshot
    if mtdd_config_set "tls_domain=$(_mtdd_json_str "$SELFMASK_DOMAIN")" "masking=true" \
        "fallback_host=\"127.0.0.1\"" "fallback_port=${SELFMASK_NGINX_BACKEND_PORT}" \
        "public_host=$(_mtdd_json_str "$SELFMASK_DOMAIN")"; then
        log_success "Параметры selfmask применены в конфиге mtdd"
    else
        [ "$_had_snap" = "true" ] || SELFMASK_PREV_SAVED="false"
        log_warn "mtdd не принял параметры selfmask — конфиг не изменён"
        return 1
    fi
    if mtdd_running; then
        mtdd_restart
        mtdd_wait_api 15 || log_warn "mtdd пока не отвечает — проверьте: journalctl -u ${MTDD_UNIT} -n 20"
    else
        log_info "mtdd не запущен — запустите его, чтобы изменения вступили в силу"
        return 0
    fi
    _SELFMASK_LINKS_PENDING="true"
}

# ── Версия mtdd: каналы main/dev ───────────────────────────────
# Нумерованных релизов у mtdd нет: CI перезаливает бинарник в релизы
# channel-main и channel-dev. Дата релиза при этом не меняется, поэтому
# показываем дату самого файла (updated_at ассета). «Версия» в --version
# одинакова у разных сборок — сборку узнаём по sha256.
MTDD_ASSET="mtdd-linux-x86_64"
MTDD_PREV_BIN="${MTDD_ENGINE_DIR}/mtdd.prev"
MTDD_PREV_LABEL="${MTDD_ENGINE_DIR}/mtdd.prev.label"

# Строки «канал|дата ISO|размер|url бинарника|url SHA256SUMS» для main и dev.
# Ответ GitHub кэшируется на 10 минут: карточка движка в панели открывает
# его дважды, а без токена у API GitHub 60 запросов в час на адрес.
# Обновление движка берёт свежий (MTDD_CHANNELS_FRESH=1).
mtdd_channels() {
    local _cache="${INSTALL_DIR:-/opt/mtproxyl}/cache/mtdd_channels" _rows
    if [ "${MTDD_CHANNELS_FRESH:-0}" != 1 ] && [ -s "$_cache" ] \
        && [ $(( $(date +%s) - $(stat -c %Y "$_cache" 2>/dev/null || echo 0) )) -lt 600 ]; then
        cat "$_cache"; return 0
    fi
    _rows=$(_mtdd_channels_fetch)
    if [ -n "$_rows" ]; then
        { mkdir -p "${_cache%/*}" && printf '%s\n' "$_rows" > "${_cache}.tmp" && mv -f "${_cache}.tmp" "$_cache"; } 2>/dev/null || rm -f "${_cache}.tmp" 2>/dev/null
        printf '%s\n' "$_rows"
    fi
}

_mtdd_channels_fetch() {
    python3 -I - "$MTDD_REPO" "$MTDD_ASSET" <<'PY'
import json, sys, urllib.request
repo, asset = sys.argv[1], sys.argv[2]
for ch in ("main", "dev"):
    url = "https://api.github.com/repos/%s/releases/tags/channel-%s" % (repo, ch)
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "mtproxyl"})
        with urllib.request.urlopen(req, timeout=10) as r:
            rel = json.load(r)
    except Exception:
        continue
    bins = {a.get("name"): a for a in rel.get("assets") or []}
    b, s = bins.get(asset), bins.get("SHA256SUMS")
    if not b or not s:
        continue
    print("%s|%s|%s|%s|%s" % (ch, b.get("updated_at") or "", b.get("size") or 0,
                              b.get("browser_download_url") or "", s.get("browser_download_url") or ""))
PY
}

# «29.10.2026» из ISO-времени.
_mtdd_date_ru() {
    local _d="${1%%T*}"
    [[ "$_d" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]] || { echo "${1:-—}"; return; }
    echo "${BASH_REMATCH[3]}.${BASH_REMATCH[2]}.${BASH_REMATCH[1]}"
}

_mtdd_days_between() {
    local _a _b
    _a=$(date -d "$1" +%s 2>/dev/null) || return 1
    _b=$(date -d "$2" +%s 2>/dev/null) || return 1
    echo $(( (_b - _a) / 86400 ))
}

# Список каналов для человека, с пометками. Номер строки = номер выбора.
mtdd_print_channels() {
    local _rows="$1" _main_date _dev_date _n=0 _ch _date _size _u _s _note
    _main_date=$(awk -F'|' '$1 == "main" { print $2 }' <<< "$_rows")
    _dev_date=$(awk -F'|' '$1 == "dev" { print $2 }' <<< "$_rows")
    while IFS='|' read -r _ch _date _size _u _s; do
        [ -n "$_ch" ] || continue
        _n=$((_n + 1))
        _note=""
        if [ "$_ch" = "main" ]; then
            _note="основной"
        else
            _note="тестовый"
            if [ -n "$_main_date" ] && [ -n "$_dev_date" ]; then
                local _dd; _dd=$(_mtdd_days_between "$_main_date" "$_dev_date" 2>/dev/null)
                [ -n "$_dd" ] && [ "$_dd" -gt 0 ] && _note+=", свежее main на ${_dd} дн."
            fi
        fi
        printf "  ${DIM}[%d]${NC} ${BOLD}%-5s${NC} бинарник от %s  %s МБ  ${DIM}(%s)${NC}\n" \
            "$_n" "$_ch" "$(_mtdd_date_ru "$_date")" "$(awk -v b="$_size" 'BEGIN{printf "%.1f", b/1048576}')" "$_note"
    done <<< "$_rows"
}

# Интерактивный выбор канала. По умолчанию main. Печатает канал в stdout.
mtdd_pick_channel() {
    local _rows; _rows=$(mtdd_channels)
    if [ -z "$_rows" ]; then
        log_warn "GitHub не ответил — даты сборок неизвестны" >&2
        _rows=$'main||0||\ndev||0||'
    fi
    {
        echo ""
        echo -e "  ${BOLD}Канал сборки mtdd${NC}"
        mtdd_print_channels "$_rows"
    } >&2
    local _c; read_line _c "  ${BOLD}Выбор [1]:${NC} " >&2
    case "${_c:-1}" in
        2|dev) echo dev ;;
        *)     echo main ;;
    esac
}

_mtdd_sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# Какая сборка стоит: «main от 29.10.2026», если sha совпал с каналом.
mtdd_build_label() {
    local _bin="${1:-$(mtdd_bin)}" _sha _rows _ch _date _size _u _s _sums
    [ -x "$_bin" ] || { echo "не установлен"; return; }
    _sha=$(_mtdd_sha "$_bin")
    _rows=$(mtdd_channels 2>/dev/null)
    while IFS='|' read -r _ch _date _size _u _s; do
        [ -n "$_s" ] || continue
        _sums=$(curl -fsSL --max-time 10 "$_s" 2>/dev/null) || continue
        if grep -q "^${_sha}[[:space:]]" <<< "$_sums"; then
            echo "${_ch} от $(_mtdd_date_ru "$_date")"
            return
        fi
    done <<< "$_rows"
    echo "сборка ${_sha:0:12}"
}

mtdd_engine_unsupported_reason() {
    mtdd_unit_exists || { echo "Нет службы ${MTDD_UNIT} — запустить новую сборку нечем"; return; }
    [ "$(uname -m)" = "x86_64" ] || { echo "Сборки mtdd есть только для x86_64"; return; }
    local _b; _b=$(mtdd_bin)
    [ -x "$_b" ] || { echo "Не найден бинарник mtdd: ${_b}"; return; }
    [ "$(od -An -tx1 -N4 "$_b" 2>/dev/null | tr -d ' \n')" = "7f454c46" ] || echo "ExecStart службы — не бинарник mtdd: ${_b}"
}

# mtdd поднялся: служба активна с тем же PID 5 секунд подряд и API отвечает.
_mtdd_healthy() {
    local _i _pid _last="" _stable=0
    for _i in $(seq 1 30); do
        sleep 1
        if mtdd_running; then
            _pid=$(systemctl show "$MTDD_UNIT" -p MainPID --value 2>/dev/null)
            if [ -n "$_pid" ] && [ "$_pid" != 0 ] && [ "$_pid" = "$_last" ]; then _stable=$((_stable + 1)); else _stable=0; fi
            _last="$_pid"
            [ "$_stable" -ge 5 ] && break
        else
            _stable=0; _last=""
        fi
    done
    [ "$_stable" -ge 5 ] && mtdd_wait_api 20
}

# Manager: вернуть конфиг, собранный под прежнюю сборку.
_mtdd_mgr_config_back() {
    mtdd_mgr_active || return 0
    [ -f "${MTDD_ENGINE_DIR}/config.cur" ] && mv -f "${MTDD_ENGINE_DIR}/config.cur" "$MTDD_MGR_CONFIG"
    return 0
}

_mtdd_place() {
    local _src="$1" _bin="$2"
    install -m 0755 "$_src" "${_bin}.mtproxyl-new" || return 1
    chown --reference="$_bin" "${_bin}.mtproxyl-new" 2>/dev/null || true
    chmod --reference="$_bin" "${_bin}.mtproxyl-new" 2>/dev/null || true
    mv -f "${_bin}.mtproxyl-new" "$_bin"
}

# Ставит файл вместо бинарника mtdd и перезапускает службу. Не поднялся —
# прежний возвращается на место; заменённый уходит в «предыдущую» только при успехе.
_mtdd_switch() {
    local _src="$1" _label="$2" _bin _cur_label
    _bin=$(mtdd_bin)
    _cur_label=$(mtdd_build_label "$_bin")
    # Проверка до замены: свежий бинарник должен принять текущий конфиг
    # (у разных сборок разный набор ключей, неизвестный ключ — ошибка).
    local _chk _mgr=false
    mtdd_mgr_active && _mgr=true
    mkdir -p "$MTDD_ENGINE_DIR" && chmod 700 "$MTDD_ENGINE_DIR"
    if [ "$_mgr" = true ]; then
        # Manager сам собирает конфиг — под набор ключей новой сборки (у main
        # нет метрик и квот). Прежний конфиг вернётся вместе с бинарником.
        cp -p "$MTDD_MGR_CONFIG" "${MTDD_ENGINE_DIR}/config.cur" 2>/dev/null || true
        if ! MTDD_MGR_CHECK_BIN="$_src" generate_mtdd_config; then
            rm -f "${MTDD_ENGINE_DIR}/config.cur"
            log_error "Сборка ${_label} не принимает конфиг mtdd"
            log_info "Неизвестный ей ключ задан через tune или media: mtproxyl tune clear <ключ> / mtproxyl media off"
            log_info "Рабочий бинарник не тронут"
            return 1
        fi
    elif ! _chk=$(MTDD_BIN="$_src" MTDD_CONFIG="$DETECTED_CONFIG_PATH" python3 -I -c "$(_mtdd_py_src)" cfg-check "$DETECTED_CONFIG_PATH" 2>&1); then
        log_error "Сборка ${_label} не принимает текущий конфиг mtdd: ${_chk}"
        log_info "Рабочий бинарник не тронут"
        return 1
    fi
    cp -f "$_bin" "${MTDD_ENGINE_DIR}/mtdd.cur" || { _mtdd_mgr_config_back; log_error "Не удалось сохранить текущий бинарник"; return 1; }
    _mtdd_place "$_src" "$_bin" || { rm -f "${MTDD_ENGINE_DIR}/mtdd.cur" "${_bin}.mtproxyl-new"; _mtdd_mgr_config_back; log_error "Не удалось заменить ${_bin}"; return 1; }
    log_info "Перезапуск ${MTDD_UNIT}..."
    systemctl restart "$MTDD_UNIT" >/dev/null 2>&1 || true
    if _mtdd_healthy; then
        mv -f "${MTDD_ENGINE_DIR}/mtdd.cur" "$MTDD_PREV_BIN"
        printf '%s\n' "$_cur_label" > "$MTDD_PREV_LABEL"
        rm -f "${MTDD_ENGINE_DIR}/config.cur"
        # Набор возможностей сборки мог смениться (выключенные, лимиты).
        [ "$_mgr" = true ] && { mtdd_mgr_sync_users || log_warn "Пользователи доставлены в mtdd не полностью"; }
        log_success "mtdd ${_label} работает: ${_bin}. Конфиг и пользователи не менялись"
        return 0
    fi
    log_error "mtdd ${_label} не поднялся — возвращаем прежнюю сборку (${_cur_label})"
    journalctl -u "$MTDD_UNIT" -n 5 --no-pager -o cat 2>/dev/null | sed 's/^/    /'
    _mtdd_place "${MTDD_ENGINE_DIR}/mtdd.cur" "$_bin" || true
    rm -f "${MTDD_ENGINE_DIR}/mtdd.cur"
    _mtdd_mgr_config_back
    systemctl restart "$MTDD_UNIT" >/dev/null 2>&1 || true
    if _mtdd_healthy; then log_info "Прежняя сборка снова работает"; else log_warn "Прежняя сборка тоже не поднялась — journalctl -u ${MTDD_UNIT} -n 50"; fi
    return 1
}

# Скачать свежий бинарник канала и сверить sha256 с SHA256SUMS релиза.
_mtdd_fetch_channel() {
    local _ch="$1" _dir="$2" _rows _row _url _sums
    _rows=$(MTDD_CHANNELS_FRESH=1 mtdd_channels) || true
    _row=$(awk -F'|' -v c="$_ch" '$1 == c' <<< "$_rows")
    [ -n "$_row" ] || { log_error "Канал ${_ch}: сборка не найдена в релизах ${MTDD_REPO}"; return 1; }
    IFS='|' read -r _ _ _ _url _sums <<< "$_row"
    log_info "Скачивание mtdd (${_ch})..."
    curl -fsSL --max-time 120 -o "${_dir}/${MTDD_ASSET}" "$_url" || { log_error "Не удалось скачать бинарник"; return 1; }
    curl -fsSL --max-time 30 -o "${_dir}/SHA256SUMS" "$_sums" || { log_error "Не удалось скачать SHA256SUMS"; return 1; }
    ( cd "$_dir" && grep "  ${MTDD_ASSET}\$" SHA256SUMS | sha256sum -c --status - ) \
        || { log_error "sha256 бинарника не совпал с SHA256SUMS — файл не установлен"; return 1; }
    chmod 755 "${_dir}/${MTDD_ASSET}"
    "${_dir}/${MTDD_ASSET}" --version 2>/dev/null | grep -q '^mtdd ' \
        || { log_error "Скачанный mtdd не запускается на этом сервере"; return 1; }
    MTDD_FETCH_DATE=$(awk -F'|' -v c="$_ch" '$1 == c { print $2 }' <<< "$_rows")
}

mtdd_engine_update() {
    local _ch="${1:-}" _reason
    _reason=$(mtdd_engine_unsupported_reason)
    [ -z "$_reason" ] || { log_error "$_reason"; return 1; }
    check_root
    case "$_ch" in
        ""|latest) _ch=main ;;
        main|dev) ;;
        *) log_error "У mtdd каналы main и dev, а не номера версий"; return 1 ;;
    esac
    local _tmpd _date _rc=0
    # Не в /tmp: там бывает noexec, а новую сборку запускают для проверки.
    mkdir -p "$MTDD_ENGINE_DIR" && chmod 700 "$MTDD_ENGINE_DIR" || return 1
    _tmpd=$(mktemp -d "${MTDD_ENGINE_DIR}/.dl.XXXXXX") || return 1
    MTDD_FETCH_DATE=""
    _mtdd_fetch_channel "$_ch" "$_tmpd" || { rm -rf "$_tmpd"; return 1; }
    _date="$MTDD_FETCH_DATE"
    if [ "$(_mtdd_sha "${_tmpd}/${MTDD_ASSET}")" = "$(_mtdd_sha "$(mtdd_bin)")" ]; then
        log_info "Уже стоит свежая сборка ${_ch} от $(_mtdd_date_ru "$_date")"
        rm -rf "$_tmpd"; echo "$_ch" > "$MTDD_CHANNEL_FILE" 2>/dev/null; return 0
    fi
    _mtdd_switch "${_tmpd}/${MTDD_ASSET}" "${_ch} от $(_mtdd_date_ru "$_date")" || _rc=$?
    [ $_rc -eq 0 ] && echo "$_ch" > "$MTDD_CHANNEL_FILE" 2>/dev/null
    rm -rf "$_tmpd"
    return $_rc
}

mtdd_engine_rollback() {
    local _want="${1:-}" _reason
    _reason=$(mtdd_engine_unsupported_reason)
    [ -z "$_reason" ] || { log_error "$_reason"; return 1; }
    check_root
    case "$_want" in main|dev) mtdd_engine_update "$_want"; return ;; esac
    [ -x "$MTDD_PREV_BIN" ] || { log_error "Предыдущей сборки на диске нет — откатывать не к чему"; return 1; }
    local _prev; _prev=$(cat "$MTDD_PREV_LABEL" 2>/dev/null)
    if [ "$_want" != "--yes" ]; then
        echo ""
        echo -e "  ${BOLD}Текущая:${NC}    $(mtdd_build_label)"
        echo -e "  ${BOLD}Предыдущая:${NC} ${_prev:-неизвестна}"
        local _yn; read_line _yn "  ${BOLD}Откатиться? [y/N]:${NC} "
        [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 0; }
    fi
    local _tmp _rc=0
    _tmp=$(mktemp "${MTDD_ENGINE_DIR}/.prev.XXXXXX") || return 1
    # mktemp создаёт 0600, cp права не меняет — проверка не смогла бы запустить копию.
    cp -f "$MTDD_PREV_BIN" "$_tmp" && chmod 755 "$_tmp" || { rm -f "$_tmp"; return 1; }
    _mtdd_switch "$_tmp" "${_prev:-предыдущая}" || _rc=$?
    rm -f "$_tmp"
    return $_rc
}

mtdd_engine_status() {
    local _reason; _reason=$(mtdd_engine_unsupported_reason)
    if mtdd_mgr_active; then
        echo -e "  ${BOLD}Движок mtdd${NC} ${DIM}(сменить на telemt: mtproxyl engine kind telemt)${NC}"
        echo -e "  ${DIM}Служба:${NC}      ${MTDD_UNIT}"
    else
        echo -e "  ${BOLD}Движок цели Reanimator: mtdd${NC}"
    fi
    [ -z "$_reason" ] || { echo -e "  ${DIM}${_reason}${NC}"; return 0; }
    echo -e "  ${DIM}Сборка:${NC}      $(mtdd_build_label)"
    echo -e "  ${DIM}Бинарник:${NC}    $(mtdd_bin)"
    echo -e "  ${DIM}Конфиг:${NC}      ${DETECTED_CONFIG_PATH:-—} ${DIM}(при смене сборки не меняется)${NC}"
    [ -x "$MTDD_PREV_BIN" ] && echo -e "  ${DIM}Для отката:${NC}  $(cat "$MTDD_PREV_LABEL" 2>/dev/null || echo предыдущая)"
    echo ""
    echo -e "  ${BOLD}Сборки в релизах:${NC}"
    mtdd_print_channels "$(mtdd_channels)"
}

# Документ для панели — та же форма, что target_engine_versions_json.
mtdd_engine_versions_json() {
    local _reason _bin="" _cur="" _rows
    _reason=$(mtdd_engine_unsupported_reason)
    if [ -z "$_reason" ]; then _bin=$(mtdd_bin); _cur=$(mtdd_build_label "$_bin"); fi
    # Manager: свой движок, не цель — панель показывает службу и смену движка.
    local _backend=target _target=true
    mtdd_mgr_active && { _backend=mtdd; _target=false; }
    printf '{"backend":"%s","engine_kind":"mtdd","target":%s,"service":"%s","supported":%s,"reason":"%s","bin_path":"%s","config_path":"%s","current":"%s","binary":true,"docker_available":false,"custom":false,"custom_url":"",' \
        "$_backend" "$_target" "$(json_escape "${MTDD_UNIT%.service}")" \
        "$([ -z "$_reason" ] && echo true || echo false)" "$(json_escape "$_reason")" \
        "$(json_escape "$_bin")" "$(json_escape "${DETECTED_CONFIG_PATH:-}")" "$(json_escape "$_cur")"
    printf '"local":['
    if [ -z "$_reason" ]; then
        printf '"%s"' "$(json_escape "$_cur")"
        [ -x "$MTDD_PREV_BIN" ] && printf ',"%s"' "$(json_escape "$(cat "$MTDD_PREV_LABEL" 2>/dev/null || echo previous)")"
    fi
    printf '],"releases":['
    local _f=1 _ch _date _size _u _s
    if [ -z "$_reason" ]; then
        _rows=$(mtdd_channels 2>/dev/null)
        while IFS='|' read -r _ch _date _size _u _s; do
            [ -n "$_ch" ] || continue
            [ $_f -eq 1 ] || printf ','
            _f=0
            printf '{"tag":"%s","name":"%s","date":"%s"}' "$_ch" \
                "$([ "$_ch" = main ] && echo "main — основной канал" || echo "dev — тестовый канал")" "${_date%%T*}"
        done <<< "$_rows"
    fi
    printf ']}\n'
}

mtdd_handle_engine() {
    local _sub="${1:-status}"; shift 2>/dev/null || true
    case "$_sub" in
        status)   if [ "${1:-}" = "--json" ]; then mtdd_engine_versions_json; else mtdd_engine_status; fi ;;
        versions) mtdd_engine_versions_json ;;
        list)
            echo ""; draw_header "СБОРКИ MTDD"; echo ""
            local _rows; _rows=$(mtdd_channels)
            [ -n "$_rows" ] || { log_error "Не удалось получить список с GitHub"; return 1; }
            mtdd_print_channels "$_rows"
            echo -e "  ${DIM}Сейчас: $(mtdd_build_label)${NC}"
            echo "" ;;
        update)
            if [ -n "${1:-}" ]; then mtdd_engine_update "$1"; else mtdd_engine_update "$(mtdd_pick_channel)"; fi ;;
        rollback) mtdd_engine_rollback "${1:-}" ;;
        *) log_error "Для mtdd: mtproxyl engine status|list|update [main|dev]|rollback$(mtdd_mgr_active && echo '|kind telemt')"; return 1 ;;
    esac
}

# ── Установка и удаление mtdd официальным установщиком ─────────
# Установщик берётся из ветки того же канала, что и бинарник: так их версии
# совпадают. Запускаем с чистым окружением — наши INSTALL_DIR, VERSION и
# прочие имена ему ни к чему.
_mtdd_installer_url() { echo "https://raw.githubusercontent.com/${MTDD_REPO}/${1:-main}/install.sh"; }

_mtdd_fetch_installer() {
    local _ch="$1" _tmp
    _tmp=$(mktemp "${TMPDIR:-/tmp}/mtdd-install.XXXXXX") || return 1
    log_info "Загрузка установщика mtdd ($(_mtdd_installer_url "$_ch"))..." >&2
    if ! curl -fsSL --max-time 60 -o "$_tmp" "$(_mtdd_installer_url "$_ch")" || [ ! -s "$_tmp" ]; then
        rm -f "$_tmp"; log_error "Не удалось загрузить установщик mtdd"; return 1
    fi
    head -1 "$_tmp" | grep -q '^#!.*bash' || { rm -f "$_tmp"; log_error "Загруженный файл не похож на установщик mtdd"; return 1; }
    echo "$_tmp"
}

_mtdd_run_installer() {
    local _script="$1"; shift
    local _rc=0
    echo ""
    echo -e "  ${DIM}$(_repeat '─' 60)${NC}"
    env -i PATH="${PATH:-/usr/sbin:/usr/bin:/sbin:/bin}" HOME="${HOME:-/root}" \
        TERM="${TERM:-xterm}" LANG="${LANG:-C.UTF-8}" USER=root LOGNAME=root \
        ${NO_COLOR:+NO_COLOR=1} bash "$_script" "$@" || _rc=$?
    echo -e "  ${DIM}$(_repeat '─' 60)${NC}"
    echo ""
    return $_rc
}

# install_original_mtdd [--channel main|dev] [--yes] [--no-tune] [-- аргументы установщика]
# Без аргументов установщика он сам спросит домен, ad-tag, порт, имя и адрес.
install_original_mtdd() {
    local _ch="" _yes=false
    local -a _args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --channel) _ch="${2:-}"; shift 2 ;;
            --yes)     _yes=true; shift ;;
            --no-tune) shift ;;
            --)        shift; _args=("$@"); break ;;
            *)         log_error "Неизвестный аргумент: $1"; return 1 ;;
        esac
    done
    if [ "${MTPROXYL_MODE:-manager}" != "reanimator" ]; then
        log_error "Установка mtdd доступна только в режиме reanimator: mtproxyl mode reanimator"
        return 1
    fi
    check_root
    if mtdd_unit_exists; then
        log_info "mtdd уже установлен (${MTDD_UNIT}). Свежая сборка: mtproxyl engine update"
        return 0
    fi
    [ "$(uname -m)" = "x86_64" ] || { log_error "Сборки mtdd есть только для Linux x86_64, здесь $(uname -m)"; return 1; }
    command -v systemctl &>/dev/null || { log_error "mtdd ставится службой systemd, а systemd здесь нет"; return 1; }
    local _need
    for _need in curl python3 sha256sum; do
        command -v "$_need" &>/dev/null || { log_error "Установщику mtdd нужен ${_need}"; return 1; }
    done

    if [ "$_yes" != true ]; then
        draw_header "УСТАНОВКА MTDD"
        echo ""
        echo -e "  Будет запущен официальный установщик проекта mtdd (${MTDD_REPO})."
        echo -e "  ${DIM}Он спросит домен FakeTLS, рекламный тег (32 hex, обязателен),${NC}"
        echo -e "  ${DIM}порт, имя первого пользователя и публичный адрес; поставит${NC}"
        echo -e "  ${DIM}/usr/local/bin/mtdd, /etc/mtdd/config.json и службу ${MTDD_UNIT}${NC}"
        echo -e "  ${DIM}с API на 127.0.0.1:9090. MTProxyL ничего в нём не подменяет.${NC}"
        echo ""
        echo -e "  ${DIM}У mtdd нет WEB Proxy и upstream-маршрутов (WARP, AWG, донор).${NC}"
        echo ""
    fi
    [ -n "$_ch" ] || { if [ "$_yes" = true ]; then _ch=main; else _ch=$(mtdd_pick_channel); fi; }
    case "$_ch" in main|dev) ;; *) log_error "Канал: main или dev"; return 1 ;; esac
    if [ "$_yes" != true ]; then
        local _yn; read_line _yn "  ${BOLD}Запустить установщик mtdd (канал ${_ch})? [y/N]:${NC} "
        [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 1; }
    fi

    local _script _rc=0
    _script=$(_mtdd_fetch_installer "$_ch") || return 1
    _mtdd_run_installer "$_script" --branch "$_ch" "${_args[@]}" || _rc=$?
    rm -f "$_script"
    [ "$_rc" -eq 0 ] || { log_warn "Установщик mtdd завершился с кодом ${_rc}"; return 1; }
    echo "$_ch" > "$MTDD_CHANNEL_FILE" 2>/dev/null || true

    log_info "Повторное обнаружение цели..."
    if ! run_target_detection || ! _target_is_mtdd; then
        log_warn "mtdd установлен, но цель не определилась — проверьте: systemctl status ${MTDD_UNIT}"
        save_detect_settings
        return 1
    fi
    save_detect_settings
    if [ "$_yes" = true ]; then
        PROXY_PORT="${DETECTED_PORT:-$PROXY_PORT}"; save_settings
    else
        sync_port_from_target || true
    fi
    mtdd_wait_api 15 >/dev/null 2>&1 || log_warn "API mtdd пока не отвечает — $(mtdd_api_unavailable_reason)"
    return 0
}

# Удаление штатной командой mtdd: служба и бинарники; данные — по вопросу
# установщика (или сразу с --yes).
uninstall_original_mtdd() {
    if [ "${MTPROXYL_MODE:-manager}" != "reanimator" ]; then
        log_error "Удаление mtdd доступно только в режиме reanimator"
        return 1
    fi
    check_root
    mtdd_unit_exists || [ -x "$MTDD_BIN_DEFAULT" ] || { log_info "mtdd на сервере не найден"; return 0; }
    draw_header "УДАЛЕНИЕ MTDD"
    echo ""
    echo -e "  ${DIM}Штатная команда mtdd остановит службу и удалит бинарники;${NC}"
    echo -e "  ${DIM}конфиг, токен и пользователей она удалит только с подтверждением.${NC}"
    echo -e "  ${RED}Ссылки пользователей перестанут работать сразу.${NC}"
    echo ""
    local _yn; read_line _yn "  ${BOLD}Удалить mtdd? [y/N]:${NC} "
    [[ "$_yn" =~ ^[yY] ]] || { log_info "Отменено"; return 1; }
    local _ctl="/usr/local/bin/mtdd-ctl" _tmp="" _rc=0
    if [ ! -x "$_ctl" ]; then
        _tmp=$(_mtdd_fetch_installer "$(cat "$MTDD_CHANNEL_FILE" 2>/dev/null || echo main)") || return 1
        _ctl="$_tmp"
    fi
    _mtdd_run_installer "$_ctl" uninstall "$@" || _rc=$?
    [ -n "$_tmp" ] && rm -f "$_tmp"
    [ "$_rc" -eq 0 ] || { log_warn "Удаление mtdd завершилось с кодом ${_rc}"; return 1; }
    rm -rf "$MTDD_ENGINE_DIR" "$MTDD_CHANNEL_FILE"
    run_target_detection >/dev/null 2>&1 || { DETECTED_MODE="unknown"; DETECTED_CONFIG_PATH=""; }
    save_detect_settings
    log_success "mtdd удалён"
}

# Лимиты CPU и памяти службы mtdd — drop-in, сам юнит установщика не трогаем.
# Пустые PROXY_CPUS и PROXY_MEMORY снимают drop-in.
MTDD_LIMITS_DROPIN="/etc/systemd/system/${MTDD_UNIT}.d/mtproxyl-limits.conf"
mtdd_apply_limits() {
    local _q="" _mm="" _body=""
    _q=$(_binengine_cpu_quota 2>/dev/null) && _body+="CPUQuota=${_q}"$'\n'
    _mm=$(_binengine_memory_max 2>/dev/null) && _body+="MemoryMax=${_mm}"$'\n'
    if [ -z "$_body" ]; then
        [ -f "$MTDD_LIMITS_DROPIN" ] || return 0
        rm -f "$MTDD_LIMITS_DROPIN"
    else
        mkdir -p "$(dirname "$MTDD_LIMITS_DROPIN")"
        printf '# MTProxyL: лимиты службы mtdd\n[Service]\n%s' "$_body" > "$MTDD_LIMITS_DROPIN"
    fi
    systemctl daemon-reload 2>/dev/null || true
    mtdd_restart >/dev/null 2>&1 || true
    [ -n "$_body" ] && log_success "Лимиты mtdd:${_q:+ CPU ${_q}}${_mm:+, память ${_mm}}"
    return 0
}
