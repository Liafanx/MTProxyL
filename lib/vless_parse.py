#!/usr/bin/env python3
# MTProxyL — разбор ссылок VLESS в конфиг Xray-core.
#
# Часть разбора повторяет lib/outbound-parse.py из Liafanx/AZ-WARP (MIT):
# те же правила для Reality, ws/grpc/httpupgrade и early data. Отличие —
# вывод под Xray: VLESS Encryption, XHTTP, mKCP и pqv (ML-DSA-65), которых
# sing-box не умеет.
import base64
import ipaddress
import json
import os
import re
import sys
from urllib.parse import parse_qs, unquote, urlsplit

FINGERPRINTS = {
    "chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq",
    "random", "randomized",
}
PRIVATE_NETS = [
    "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
    "169.254.0.0/16", "::1/128", "fc00::/7", "fe80::/10",
]
HOST_RE = re.compile(r"^[A-Za-z0-9._:\[\]-]+$")
ENC_RE = re.compile(r"^[A-Za-z0-9._-]+$")


def fail(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(1)


def qget(q, *names):
    for n in names:
        if n in q and q[n]:
            return q[n][0]
    return ""


def truthy(v):
    return str(v).lower() in ("1", "true", "yes", "on")


def split_host_port(netloc):
    # userinfo уже отрезан: netloc — host:port или [v6]:port.
    if netloc.startswith("["):
        end = netloc.find("]")
        if end < 0:
            fail("адрес: незакрытая квадратная скобка")
        host = netloc[1:end]
        rest = netloc[end + 1:]
        if not rest.startswith(":"):
            fail("адрес: не указан порт")
        port = rest[1:]
    else:
        if ":" not in netloc:
            fail("адрес: нужен host:port")
        host, port = netloc.rsplit(":", 1)
    if not host or not HOST_RE.match(host):
        fail("адрес: недопустимые символы")
    if not port.isdigit() or not 1 <= int(port) <= 65535:
        fail("порт: 1..65535")
    return host, int(port)


def check_id(uid):
    # Xray: UUID (36 символов) либо произвольная строка до 30 байт.
    if re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", uid):
        return
    if not 1 <= len(uid.encode()) <= 30:
        fail("id: UUID или строка 1..30 байт (Xray)")
    if any(ord(c) < 0x21 or c == "/" for c in uid):
        fail("id: недопустимые символы")


def check_b64key(pbk):
    try:
        raw = base64.urlsafe_b64decode(pbk + "=" * (-len(pbk) % 4))
    except Exception:
        raw = b""
    if len(raw) != 32:
        fail("pbk (публичный ключ Reality): неверный формат")


def parse(uri):
    parts = urlsplit(uri.strip())
    if parts.scheme != "vless":
        fail("ожидается ссылка vless://")
    uid = unquote(parts.username or "")
    check_id(uid)
    host, port = split_host_port(parts.netloc.rsplit("@", 1)[-1])
    q = parse_qs(parts.query)
    name = unquote(parts.fragment) or host

    enc = qget(q, "encryption") or "none"
    if enc != "none":
        if not ENC_RE.match(enc) or not enc.startswith("mlkem768x25519plus"):
            fail("encryption: поддерживается none или mlkem768x25519plus.* (VLESS Encryption Xray)")
    flow = qget(q, "flow")
    if flow and flow != "xtls-rprx-vision":
        fail("flow: допустим только xtls-rprx-vision")

    security = (qget(q, "security") or "none").lower()
    if security not in ("tls", "reality", "none"):
        fail("security: tls, reality или none")

    net = (qget(q, "type") or "tcp").lower()
    header = (qget(q, "headerType") or "none").lower()
    if net == "raw":
        net = "tcp"
    if net == "http":
        net = "tcp"
        header = "http"
    if net not in ("tcp", "ws", "grpc", "httpupgrade", "xhttp", "kcp"):
        fail("транспорт type=%s не поддерживается Xray-сборкой MTProxyL" % net)
    if flow and net != "tcp":
        fail("flow=xtls-rprx-vision работает только с type=tcp")

    # Xray запрещает VLESS без внешнего TLS/Reality, если не включено
    # VLESS Encryption или адрес не приватный.
    if security == "none" and enc == "none":
        private = False
        try:
            private = ipaddress.ip_address(host).is_private
        except ValueError:
            private = host == "localhost" or host.endswith(".local")
        if not private:
            fail("VLESS без TLS/Reality/Encryption запрещён Xray для публичного адреса")

    sni = qget(q, "sni", "host") if security in ("tls", "reality") else qget(q, "sni")
    fp = qget(q, "fp")
    if fp and fp not in FINGERPRINTS:
        fail("fp: неизвестный отпечаток %s" % fp)

    out = {
        "tag": "vless-out",
        "protocol": "vless",
        "settings": {"vnext": [{
            "address": host,
            "port": port,
            "users": [{"id": uid, "encryption": enc}],
        }]},
    }
    if flow:
        out["settings"]["vnext"][0]["users"][0]["flow"] = flow

    stream = {"network": net}
    if security == "tls":
        tls = {"serverName": sni or host}
        if fp:
            tls["fingerprint"] = fp
        alpn = qget(q, "alpn")
        if alpn:
            tls["alpn"] = [a for a in alpn.split(",") if a]
        if truthy(qget(q, "allowInsecure", "insecure")):
            tls["allowInsecure"] = True
        stream["security"] = "tls"
        stream["tlsSettings"] = tls
    elif security == "reality":
        if not sni:
            fail("Reality: в ссылке нужен sni")
        pbk = qget(q, "pbk")
        if not pbk:
            fail("Reality: нет pbk (публичный ключ)")
        check_b64key(pbk)
        sid = qget(q, "sid")
        if sid and (not re.fullmatch(r"[0-9a-fA-F]*", sid) or len(sid) % 2 or len(sid) > 16):
            fail("Reality: sid — hex чётной длины, не длиннее 16 символов")
        reality = {
            "serverName": sni,
            "fingerprint": fp or "chrome",
            "publicKey": pbk,
            "shortId": sid,
            "spiderX": qget(q, "spx") or "/",
        }
        pqv = qget(q, "pqv", "mldsa65Verify")
        if pqv:
            reality["mldsa65Verify"] = pqv
        stream["security"] = "reality"
        stream["realitySettings"] = reality
    else:
        stream["security"] = "none"

    if net == "tcp":
        if header == "http":
            path = qget(q, "path") or "/"
            h = qget(q, "host")
            req = {"path": [path]}
            if h:
                req["headers"] = {"Host": [h]}
            stream["tcpSettings"] = {"header": {"type": "http", "request": req}}
        elif header not in ("", "none"):
            fail("tcp: headerType=%s не поддерживается" % header)
    elif net == "ws":
        path = qget(q, "path") or "/"
        ws = {"path": path}
        m = re.search(r"[?&]ed=(\d+)", path)
        if m:
            ws["path"] = re.sub(r"[?&]ed=\d+", "", path) or "/"
            ws["maxEarlyData"] = int(m.group(1))
            ws["earlyDataHeaderName"] = "Sec-WebSocket-Protocol"
        h = qget(q, "host")
        if h:
            ws["headers"] = {"Host": h}
        stream["wsSettings"] = ws
    elif net == "grpc":
        grpc = {"serviceName": qget(q, "serviceName")}
        authority = qget(q, "authority")
        if authority:
            grpc["authority"] = authority
        stream["grpcSettings"] = grpc
    elif net == "httpupgrade":
        up = {"path": qget(q, "path") or "/"}
        h = qget(q, "host")
        if h:
            up["host"] = h
        stream["httpupgradeSettings"] = up
    elif net == "xhttp":
        xh = {"path": qget(q, "path") or "/"}
        h = qget(q, "host")
        if h:
            xh["host"] = h
        mode = qget(q, "mode")
        if mode:
            if mode not in ("auto", "packet-up", "stream-up", "stream-one"):
                fail("xhttp: mode=%s не поддерживается" % mode)
            xh["mode"] = mode
        extra = qget(q, "extra")
        if extra:
            try:
                xh["extra"] = json.loads(extra)
            except ValueError:
                fail("xhttp: extra — не JSON")
        stream["xhttpSettings"] = xh
    elif net == "kcp":
        seed = qget(q, "seed")
        kcp = {"header": {"type": header if header not in ("", "none") else "none"}}
        if seed:
            kcp["seed"] = seed
        stream["kcpSettings"] = kcp

    out["streamSettings"] = stream
    meta = {
        "name": name,
        "host": host,
        "port": port,
        "security": security,
        "transport": net,
        "encryption": "none" if enc == "none" else "mlkem768x25519plus",
        "flow": flow or "",
        "sni": sni or "",
        "header": header if net == "tcp" else "",
    }
    return out, meta


def config(uri, port):
    out, _ = parse(uri)
    return {
        "log": {"loglevel": "warning", "access": "none"},
        "inbounds": [{
            "tag": "socks-in",
            "listen": "127.0.0.1",
            "port": port,
            "protocol": "socks",
            "settings": {"auth": "noauth", "udp": False},
        }],
        "outbounds": [out, {"tag": "direct", "protocol": "freedom"}],
        "routing": {
            "domainStrategy": "AsIs",
            "rules": [{
                "type": "field",
                "ip": PRIVATE_NETS,
                "outboundTag": "direct",
            }],
        },
    }


def cmd_check(uri):
    _, meta = parse(uri)
    print(json.dumps(meta, ensure_ascii=False))


def cmd_build(uri, port, path):
    if not port.isdigit() or not 1 <= int(port) <= 65535:
        fail("порт SOCKS: 1..65535")
    cfg = config(uri, int(port))
    text = json.dumps(cfg, ensure_ascii=False, indent=2) + "\n"
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)




def cmd_probe(port, host, tport, timeout="10"):
    import socket
    s = socket.create_connection(("127.0.0.1", int(port)), float(timeout))
    s.settimeout(float(timeout))
    s.sendall(b"\x05\x01\x00")
    if s.recv(2) != b"\x05\x00":
        sys.exit(2)
    h = host.encode()
    s.sendall(b"\x05\x01\x00\x03" + bytes([len(h)]) + h + int(tport).to_bytes(2, "big"))
    r = s.recv(4)
    if len(r) < 2 or r[1] != 0:
        sys.exit(3)
    s.close()

def main(argv):
    if len(argv) < 3:
        fail("использование: vless_parse.py check URI | build URI PORT FILE")
    cmd = argv[1]
    if cmd == "check":
        cmd_check(argv[2])
    elif cmd == "build":
        if len(argv) < 5:
            fail("использование: vless_parse.py build URI PORT FILE")
        cmd_build(argv[2], argv[3], argv[4])
    elif cmd == "probe":
        if len(argv) < 5:
            fail("использование: vless_parse.py probe PORT HOST TPORT")
        cmd_probe(argv[2], argv[3], argv[4])
    else:
        fail("неизвестная команда: %s" % cmd)


if __name__ == "__main__":
    main(sys.argv)
