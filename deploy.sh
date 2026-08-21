#!/usr/bin/env bash
#
# 3x-ui deploy — разворачивает VLESS + Reality на чистой Ubuntu 22.04/24.04.
# Запускать НА СЕРВЕРЕ от root.
#
#   ./deploy.sh --domain vpn.example.com --name "Германия 1" --code DE --country "Германия"
#
# Идемпотентен на уровне шагов: повторный запуск не ломает уже настроенное,
# но inbound на 443 создаётся только если его ещё нет.
#
set -euo pipefail

DOMAIN=""
NAME=""
CODE=""
COUNTRY=""
DESCRIPTION="VLESS Reality"
INFO=""
ACME_EMAIL=""
DEST="github.com"
REMARK=""
CLIENT_EMAIL=""
SKIP_TRAFFICGUARD=0
SKIP_TORRENT_BLOCK=0
SKIP_DNS_CHECK=0
HARDEN_SSH=0

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'; NC=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$GRN" "$1" "$NC"; }
warn() { printf '%s[!] %s%s\n' "$YLW" "$1" "$NC"; }
die()  { printf '%s[x] %s%s\n' "$RED" "$1" "$NC" >&2; exit 1; }

usage() {
  cat <<USAGE
Использование: $0 --domain <FQDN> [опции]

Обязательное:
  --domain FQDN        домен сервера; A-запись должна указывать сюда

Витрина (попадает в JSON-паспорт):
  --name TEXT          отображаемое имя, напр. "Германия 1"
  --code ISO2          код страны, напр. DE
  --country TEXT       страна по-русски, напр. "Германия"
  --description TEXT   описание (по умолчанию: "VLESS Reality")
  --info TEXT          доп. поле, опционально

Прочее:
  --acme-email MAIL    e-mail для аккаунта Let's Encrypt
  --dest HOST          цель маскировки Reality (по умолчанию: github.com)
  --remark TEXT        имя inbound'а (по умолчанию: <CODE>-Reality-443)
  --skip-trafficguard  не ставить TrafficGuard
  --skip-torrent-block не ставить блокировку торрентов
  --harden-ssh         отключить вход по паролю (только при наличии SSH-ключа)
  --skip-dns-check     не проверять A-запись перед выпуском сертификата
  -h, --help           эта справка
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)            DOMAIN="$2"; shift 2 ;;
    --name)              NAME="$2"; shift 2 ;;
    --code)              CODE="$2"; shift 2 ;;
    --country)           COUNTRY="$2"; shift 2 ;;
    --description)       DESCRIPTION="$2"; shift 2 ;;
    --info)              INFO="$2"; shift 2 ;;
    --acme-email)        ACME_EMAIL="$2"; shift 2 ;;
    --dest)              DEST="$2"; shift 2 ;;
    --remark)            REMARK="$2"; shift 2 ;;
    --skip-trafficguard) SKIP_TRAFFICGUARD=1; shift ;;
    --skip-torrent-block) SKIP_TORRENT_BLOCK=1; shift ;;
    --harden-ssh)        HARDEN_SSH=1; shift ;;
    --skip-dns-check)    SKIP_DNS_CHECK=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "запускать от root"
[[ -n "$DOMAIN" ]] || { usage; die "не задан --domain"; }
[[ -n "$ACME_EMAIL" ]] || ACME_EMAIL="admin@${DOMAIN#*.}"
[[ -n "$REMARK" ]] || REMARK="${CODE:-VPN}-Reality-443"
[[ -n "$CLIENT_EMAIL" ]] || CLIENT_EMAIL="${DOMAIN%%.*}-user1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------- 0. DNS
step "Проверка DNS"
PUBLIC_IP="$(curl -fsS -m 15 https://api.ipify.org 2>/dev/null || true)"
[[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"
echo "внешний IP: $PUBLIC_IP"

if [[ $SKIP_DNS_CHECK -eq 0 ]]; then
  RESOLVED="$(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | head -1 || true)"
  echo "$DOMAIN → ${RESOLVED:-(не резолвится)}"
  [[ "$RESOLVED" == "$PUBLIC_IP" ]] || die "A-запись $DOMAIN не указывает на $PUBLIC_IP. Поправь DNS или запусти с --skip-dns-check"
  # AAAA, указывающая на другой хост, ломает валидацию Let's Encrypt
  AAAA="$(getent ahostsv6 "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1 || true)"
  if [[ -n "$AAAA" ]]; then
    ip -6 -o addr show scope global | grep -q "${AAAA%/*}" \
      || warn "AAAA-запись ($AAAA) не принадлежит этому серверу — Let's Encrypt может уйти валидироваться туда"
  fi
fi

# ---------------------------------------------------------------- 1. пакеты
step "Пакеты"
export DEBIAN_FRONTEND=noninteractive
# unattended-upgrades часто держит dpkg на свежей машине
for _ in $(seq 1 60); do
  fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
  echo "  dpkg занят, жду..."
  sleep 10
done
apt-get update -qq
# ipset и rsyslog ставим заранее: TrafficGuard тянет их сам и падает, если apt занят
apt-get install -y -qq curl socat sqlite3 ufw fail2ban ipset rsyslog python3 >/dev/null
echo "готово"

# ---------------------------------------------------------------- 2. sysctl
step "Сетевой тюнинг (BBR + fq)"
cat > /etc/sysctl.d/99-xray-tuning.conf <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.core.somaxconn=8192
SYSCTL
sysctl --system >/dev/null
CC="$(sysctl -n net.ipv4.tcp_congestion_control)"
QD="$(sysctl -n net.core.default_qdisc)"
echo "$CC / $QD"
[[ "$CC" == "bbr" ]] || warn "BBR не включился — ядро старше 4.9?"

# ---------------------------------------------------------------- 3. ufw
step "Файрвол"
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw allow 443/udp >/dev/null
ufw --force enable >/dev/null
echo "22, 443/tcp, 443/udp. Порт 80 закрыт — откроют хуки acme.sh"

# ---------------------------------------------------------------- 4. панель
step "Установка 3x-ui"
if [[ -f /etc/x-ui/install-result.env ]]; then
  echo "уже установлена, пропускаю"
else
  echo n | bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) \
    2>&1 | grep -E 'installation finished|ERROR' || true
fi
[[ -f /etc/x-ui/install-result.env ]] || die "установка 3x-ui не удалась"

PANEL_PORT="$(sed -n 's/^XUI_PANEL_PORT=//p' /etc/x-ui/install-result.env)"
ufw allow "${PANEL_PORT}/tcp" >/dev/null
echo "панель на порту $PANEL_PORT, порт открыт"

# ---------------------------------------------------------------- 5. сертификат
step "Сертификат Let's Encrypt"
if [[ ! -d ~/.acme.sh ]]; then
  curl -s https://get.acme.sh | sh -s "email=$ACME_EMAIL" >/dev/null 2>&1
fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
mkdir -p /etc/x-ui/cert

if [[ -f "/etc/x-ui/cert/${DOMAIN}.crt" ]]; then
  echo "сертификат уже есть, пропускаю выпуск"
else
  ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone \
    --pre-hook  "ufw allow 80/tcp >/dev/null" \
    --post-hook "ufw delete allow 80/tcp >/dev/null" 2>&1 | grep -E 'Cert success|error|Error' || true
  ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
    --key-file       "/etc/x-ui/cert/${DOMAIN}.key" \
    --fullchain-file "/etc/x-ui/cert/${DOMAIN}.crt" \
    --reloadcmd      "systemctl restart x-ui" 2>&1 | grep -E 'Installing full|Reload success' || true
fi
[[ -f "/etc/x-ui/cert/${DOMAIN}.crt" ]] || die "сертификат не выпустился"
openssl x509 -in "/etc/x-ui/cert/${DOMAIN}.crt" -noout -subject -enddate

# ---------------------------------------------------------------- 6. настройки панели
step "Пути к сертификату в настройках панели"
# Панель держит SQLite открытой — без остановки ловим "database is locked".
systemctl stop x-ui
sleep 2
for key in webCertFile webKeyFile subCertFile subKeyFile; do
  case "$key" in
    *CertFile) val="/etc/x-ui/cert/${DOMAIN}.crt" ;;
    *KeyFile)  val="/etc/x-ui/cert/${DOMAIN}.key" ;;
  esac
  # ON CONFLICT не работает: у settings.key нет уникального индекса
  sqlite3 /etc/x-ui/x-ui.db \
    "delete from settings where key='$key'; insert into settings (key,value) values ('$key','$val');"
done
sqlite3 /etc/x-ui/x-ui.db \
  "select key from settings where key like '%CertFile' or key like '%KeyFile' order by key;" | tr '\n' ' '
echo

# ---------------------------------------------------------------- 7. inbound
step "Inbound VLESS + Reality на 443"
if sqlite3 /etc/x-ui/x-ui.db "select 1 from inbounds where port=443;" | grep -q 1; then
  echo "inbound на 443 уже есть, пропускаю"
else
  KEYS="$(/usr/local/x-ui/bin/xray-linux-amd64 x25519)"
  PRIVATE_KEY="$(echo "$KEYS" | grep -iE '^ *private' | awk '{print $NF}')"
  PUBLIC_KEY="$(echo "$KEYS" | grep -iE 'public' | awk '{print $NF}')"
  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || die "не удалось разобрать вывод x25519"

  REMARK="$REMARK" \
  EMAIL="$CLIENT_EMAIL" \
  PRIVATE_KEY="$PRIVATE_KEY" \
  PUBLIC_KEY="$PUBLIC_KEY" \
  SHORT_ID="$(openssl rand -hex 8)" \
  CLIENT_UUID="$(cat /proc/sys/kernel/random/uuid)" \
  SUB_ID="$(tr -dc a-z0-9 </dev/urandom | head -c 16)" \
  DEST_HOST="$DEST" \
    python3 "$SCRIPT_DIR/lib/inbound.py"
fi
systemctl start x-ui
sleep 5
systemctl is-active --quiet x-ui || die "x-ui не поднялся"
sqlite3 /etc/x-ui/x-ui.db "select id,remark,port,protocol,enable from inbounds;"

# ---------------------------------------------------------------- 8. TrafficGuard
if [[ $SKIP_TRAFFICGUARD -eq 0 ]]; then
  step "TrafficGuard (блокировка сканеров)"
  mkdir -p /root/fw-backup
  iptables-save  > /root/fw-backup/iptables.before
  ip6tables-save > /root/fw-backup/ip6tables.before
  cp /etc/ufw/before.rules /etc/ufw/before6.rules /root/fw-backup/ 2>/dev/null || true
  echo "бэкап файрвола: /root/fw-backup/"

  curl -fsSL -o /root/install-trafficguard.sh \
    https://raw.githubusercontent.com/DonMatteoVPN/TrafficGuard-auto/refs/heads/main/install-trafficguard.sh
  # последняя строка запускает интерактивное меню — по SSH без TTY оно зацикливается
  sed -i '\|^/opt/trafficguard-manager.sh monitor$|d' /root/install-trafficguard.sh
  bash /root/install-trafficguard.sh </dev/null >/dev/null 2>&1 || true

  # если бинарь остался от прошлой неудачной попытки, установщик молча ничего не делает
  if ! ipset list -t SCANNERS-BLOCK-V4 >/dev/null 2>&1; then
    warn "первый заход не сработал, повторяю напрямую"
    /opt/trafficguard-manager.sh install </dev/null >/dev/null 2>&1 || true
  fi

  V4="$(ipset list -t SCANNERS-BLOCK-V4 2>/dev/null | awk '/Number of entries/{print $4}')"
  if [[ -n "${V4:-}" && "$V4" -gt 0 ]]; then
    echo "ipset: $V4 подсетей, цепочка: $(iptables -S ufw-before-input | grep -c 'j SCANNERS-BLOCK')"
  else
    warn "TrafficGuard не установился — проверь вручную: /opt/trafficguard-manager.sh install"
  fi
fi

# ---------------------------------------------------------------- 8b. торренты
if [[ $SKIP_TORRENT_BLOCK -eq 0 ]]; then
  step "Блокировка торрентов (DPI)"
  # Работает в дополнение к правилу Xray bittorrent -> blocked: то отсекает
  # торрент внутри туннеля, это — исходящий поиск пиров с самого сервера.
  TB_URL="https://raw.githubusercontent.com/pbldbl/3xui-torrent-block/main/torrent-block-install.sh"
  if curl -fsSL -o /root/torrent-block-install.sh "$TB_URL"; then
    bash /root/torrent-block-install.sh </dev/null >/dev/null 2>&1 || true
    if systemctl is-active --quiet torrent-block 2>/dev/null; then
      echo "torrent-block: активен, правил в цепочке $(iptables -S TORRENT_BLOCK 2>/dev/null | wc -l)"
    else
      warn "torrent-block не поднялся — проверь: bash /root/torrent-block-install.sh"
    fi
  else
    warn "не удалось скачать установщик torrent-block"
  fi
fi

# ---------------------------------------------------------------- 8a. SSH
if [[ $HARDEN_SSH -eq 1 ]]; then
  step "Отключение входа по паролю"
  # Без ключа не трогаем ничего — иначе гарантированный лок-аут.
  KEYFOUND=0
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [[ -s "$f" ]] && grep -qE '^(ssh|ecdsa)-' "$f" && KEYFOUND=1 && break
  done
  if [[ $KEYFOUND -eq 0 ]]; then
    warn "authorized_keys не найден — вход по паролю оставлен включённым"
  else
    cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"
    mkdir -p /etc/ssh/sshd_config.d
    printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' \
      > /etc/ssh/sshd_config.d/99-harden.conf

    # cloud-init и подобные кладут свои drop-in с PasswordAuthentication yes.
    # В OpenSSH выигрывает ПЕРВАЯ директива, а 50-/60- читаются раньше 99-.
    for d in /etc/ssh/sshd_config.d/*.conf; do
      [[ "$d" == */99-harden.conf ]] && continue
      grep -qiE '^[[:space:]]*PasswordAuthentication[[:space:]]+yes' "$d" 2>/dev/null \
        && sed -i -E 's/^[[:space:]]*(PasswordAuthentication[[:space:]]+yes)/# \1  # отключено deploy.sh/I' "$d" \
        && echo "  поправлен $d"
    done

    reload_sshd() { systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true; }
    sshd -t 2>/dev/null && reload_sshd

    # Часть образов вообще не подключает sshd_config.d (нет строки Include),
    # и тогда drop-in не читается. Проверяем результат, а не факт записи.
    if [[ "$(sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}')" == "yes" ]]; then
      echo "  drop-in не подействовал, правлю /etc/ssh/sshd_config"
      sed -i -E 's/^[[:space:]]*(PasswordAuthentication[[:space:]]+yes)/PasswordAuthentication no  # было: \1/I' \
        /etc/ssh/sshd_config
      sshd -t 2>/dev/null && reload_sshd
    fi

    RESULT="$(sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}')"
    if [[ "$RESULT" == "no" ]]; then
      echo "PasswordAuthentication: no"
    else
      warn "не удалось отключить вход по паролю (сейчас: ${RESULT:-?}) — проверь /etc/ssh/sshd_config вручную"
    fi
  fi
fi

# ---------------------------------------------------------------- 9. проверка
step "Проверка"
systemctl is-active x-ui fail2ban | tr '\n' ' '; echo
ss -tlnp | grep -qE ':443 ' && echo "443 слушается" || warn "на 443 никто не слушает"
if journalctl -u x-ui --since "5 min ago" --no-pager 2>/dev/null | grep -qi 'REALITY.*target.*likelihood'; then
  warn "Xray считает dest '$DEST' заезженным — стоит выбрать другой"
fi

# ---------------------------------------------------------------- 10. паспорт
step "JSON-паспорт"
NAME="$NAME" CODE="$CODE" COUNTRY="$COUNTRY" DESCRIPTION="$DESCRIPTION" INFO="$INFO" \
  bash "$SCRIPT_DIR/server-info.sh"

cat <<DONE

${GRN}Готово.${NC}
Панель:  https://${DOMAIN}:${PANEL_PORT}$(sed -n 's/^XUI_WEB_BASE_PATH=/\//p' /etc/x-ui/install-result.env)/
Логин и пароль — в /etc/x-ui/install-result.env и в паспорте выше.
DONE
