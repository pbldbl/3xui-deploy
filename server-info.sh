#!/usr/bin/env bash
# Выводит JSON-паспорт сервера после установки 3x-ui.
# Витринные поля не выводятся из системы — задаются переменными окружения:
#   NAME="Польша 1" CODE=PL COUNTRY="Польша" DESCRIPTION="..." INFO="..." ./server-info.sh
# Домен для поля ip можно переопределить: IP_PUBLIC=front.example.com ./server-info.sh
set -euo pipefail

DB=/etc/x-ui/x-ui.db
ENV_FILE=/etc/x-ui/install-result.env

command -v sqlite3 >/dev/null || { echo "нет sqlite3" >&2; exit 1; }
[ -f "$DB" ] || { echo "не найден $DB" >&2; exit 1; }

setting() { sqlite3 "$DB" "select value from settings where key='$1';"; }

PANEL_VER=$(/usr/local/x-ui/x-ui -v 2>/dev/null | tr -d '[:space:]')
case "$PANEL_VER" in
  3.*) PANEL_TYPE="3x-ui-v3" ;;
  *)   PANEL_TYPE="3x-ui" ;;
esac

PORT_PANEL=$(setting webPort)
URI_PATH=$(setting webBasePath)
WEB_CERT=$(setting webCertFile)

# Домен: из CN сертификата панели, иначе hostname
DOMAIN=""
if [ -n "$WEB_CERT" ] && [ -f "$WEB_CERT" ]; then
  DOMAIN=$(openssl x509 -in "$WEB_CERT" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *//p')
fi
[ -z "$DOMAIN" ] && DOMAIN=$(hostname -f 2>/dev/null || hostname)
IP_PUBLIC="${IP_PUBLIC:-$DOMAIN}"
IPV4=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)

USERNAME=""; PASSWORD=""; API_TOKEN=""
if [ -f "$ENV_FILE" ]; then
  USERNAME=$(sed -n 's/^XUI_USERNAME=//p' "$ENV_FILE")
  PASSWORD=$(sed -n 's/^XUI_PASSWORD=//p' "$ENV_FILE")
  API_TOKEN=$(sed -n 's/^XUI_API_TOKEN=//p' "$ENV_FILE")
fi

# Первый включённый vless-инбаунд
read -r INBOUND_ID PORT_KEY < <(sqlite3 -separator ' ' "$DB" \
  "select id, port from inbounds where protocol='vless' and enable=1 order by id limit 1;")

CERT_EXPIRES=""
if [ -n "$WEB_CERT" ] && [ -f "$WEB_CERT" ]; then
  CERT_EXPIRES=$(openssl x509 -in "$WEB_CERT" -noout -enddate | sed 's/notAfter=//')
fi

export PANEL_TYPE PANEL_VER PORT_PANEL URI_PATH IP_PUBLIC IPV4 DOMAIN \
       USERNAME PASSWORD API_TOKEN INBOUND_ID PORT_KEY CERT_EXPIRES DB

python3 <<'PY'
import json, os, sqlite3, subprocess

db = sqlite3.connect(os.environ["DB"])
iid = os.environ["INBOUND_ID"]
stream = json.loads(db.execute("select stream_settings from inbounds where id=?", (iid,)).fetchone()[0])
settings = json.loads(db.execute("select settings from inbounds where id=?", (iid,)).fetchone()[0])

reality = stream.get("realitySettings", {}) or {}
sub = reality.get("settings", {}) or {}
client = (settings.get("clients") or [{}])[0]

try:
    xray_ver = subprocess.run(["/usr/local/x-ui/bin/xray-linux-amd64", "-version"],
                              capture_output=True, text=True).stdout.split()[1]
except Exception:
    xray_ver = None

out = {
    "panel_type": os.environ["PANEL_TYPE"],
    "ip": os.environ["IP_PUBLIC"],
    "ipv4": os.environ["IPV4"],
    "domain": os.environ["DOMAIN"],
    "port_panel": int(os.environ["PORT_PANEL"]),
    "uri_path": os.environ["URI_PATH"],
    "panel_login": os.environ["USERNAME"],
    "panel_password": os.environ["PASSWORD"],
    "panel_api_token": os.environ["API_TOKEN"],
    "panel_version": os.environ["PANEL_VER"],
    "xray_version": xray_ver,
    "vless_inbound_id": int(iid),
    "port_key": int(os.environ["PORT_KEY"]),
    "security": stream.get("security"),
    "network": stream.get("network"),
    "flow": client.get("flow"),
    "sni": (reality.get("serverNames") or [None])[0],
    "public_key": sub.get("publicKey"),
    "short_id": (reality.get("shortIds") or [None])[0],
    "fingerprint": sub.get("fingerprint"),
    "cert_expires": os.environ["CERT_EXPIRES"] or None,
    "name": os.environ.get("NAME") or None,
    "code": os.environ.get("CODE") or None,
    "country": os.environ.get("COUNTRY") or None,
    "description": os.environ.get("DESCRIPTION") or None,
    "info": os.environ.get("INFO") or None,
}
print(json.dumps(out, ensure_ascii=False, indent=2))
PY
