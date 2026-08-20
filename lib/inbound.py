#!/usr/bin/env python3
"""
Создаёт inbound VLESS + Reality на 443 в базе 3x-ui.

Параметры — через переменные окружения:
  REMARK, EMAIL, PRIVATE_KEY, PUBLIC_KEY, SHORT_ID, CLIENT_UUID, SUB_ID
  DEST_HOST (опционально, по умолчанию github.com)
  DB        (опционально, по умолчанию /etc/x-ui/x-ui.db)

Панель должна быть остановлена — иначе SQLite отдаст "database is locked".
"""
import json
import os
import sqlite3
import sys
import time

DB = os.environ.get("DB", "/etc/x-ui/x-ui.db")
NOW = int(time.time() * 1000)

try:
    REMARK = os.environ["REMARK"]
    EMAIL = os.environ["EMAIL"]
    PRIVATE_KEY = os.environ["PRIVATE_KEY"]
    PUBLIC_KEY = os.environ["PUBLIC_KEY"]
    SHORT_ID = os.environ["SHORT_ID"]
    CLIENT_UUID = os.environ["CLIENT_UUID"]
    SUB_ID = os.environ["SUB_ID"]
except KeyError as e:
    sys.exit(f"не задана переменная окружения {e}")

DEST_HOST = os.environ.get("DEST_HOST", "github.com")
DEST = DEST_HOST if ":" in DEST_HOST else f"{DEST_HOST}:443"
BARE = DEST.split(":")[0]
SERVER_NAMES = [BARE] if BARE.startswith("www.") else [BARE, f"www.{BARE}"]

settings = {
    "clients": [{
        "comment": "",
        "created_at": NOW,
        "email": EMAIL,
        "enable": True,
        "expiryTime": 0,
        "flow": "xtls-rprx-vision",
        "id": CLIENT_UUID,
        "limitIp": 0,
        "reset": 0,
        "subId": SUB_ID,
        "tgId": 0,
        "totalGB": 0,
        "updated_at": NOW,
    }],
    "decryption": "none",
    "encryption": "none",
    "testseed": [900, 500, 900, 256],
}

stream = {
    "network": "tcp",
    "tcpSettings": {"acceptProxyProtocol": False, "header": {"type": "none"}},
    "security": "reality",
    "realitySettings": {
        "show": False,
        "xver": 0,
        "target": DEST,
        "serverNames": SERVER_NAMES,
        "privateKey": PRIVATE_KEY,
        # Дефолт 3x-ui подставляет сюда текущую версию ядра и отрубает старые
        # клиенты. 1.0.0 пускает всех.
        "minClientVer": "1.0.0",
        "maxClientVer": "",
        "maxTimediff": 0,
        "shortIds": [SHORT_ID],
        "mldsa65Seed": "",
        "settings": {
            "publicKey": PUBLIC_KEY,
            "fingerprint": "firefox",
            "serverName": "",
            "spiderX": "/",
            "mldsa65Verify": "",
        },
    },
    "externalProxy": [],
}

sniffing = {"enabled": True, "destOverride": ["http", "tls", "quic"]}

db = sqlite3.connect(DB)
if db.execute("select id from inbounds where port=443").fetchone():
    sys.exit("inbound на 443 уже существует")

# Схема новых 3x-ui (3.x). На старых версиях лишние колонки просто отсутствуют —
# тогда используем сокращённый набор.
full = """insert into inbounds
    (user_id, up, down, total, remark, sub_sort_index, enable, expiry_time,
     traffic_reset, traffic_reset_day, last_traffic_reset_time,
     listen, port, protocol, settings, stream_settings, tag, sniffing,
     node_id, share_addr_strategy, share_addr, origin_node_guid)
    values (1,0,0,0,?,1,1,0,'never',1,0,'',443,'vless',?,?,?,?,NULL,'listen','','')"""
short = """insert into inbounds
    (user_id, up, down, total, remark, enable, expiry_time,
     listen, port, protocol, settings, stream_settings, tag, sniffing)
    values (1,0,0,0,?,1,0,'',443,'vless',?,?,?,?)"""

params = (
    REMARK,
    json.dumps(settings, indent=2, sort_keys=True),
    json.dumps(stream, indent=2),
    "in-443-tcp",
    json.dumps(sniffing),
)

try:
    db.execute(full, params)
except sqlite3.OperationalError:
    db.execute(short, params)
db.commit()

print("inbound создан, id =", db.execute("select id from inbounds where port=443").fetchone()[0])
