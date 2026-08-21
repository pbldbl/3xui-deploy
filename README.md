# 3xui-deploy

Разворачивает VPN-сервер на **3x-ui + VLESS/Reality** одной командой: от чистой
Ubuntu до работающего inbound с сертификатом, BBR, файрволом и блокировкой
сканеров. В конце печатает JSON-паспорт сервера для интеграции с биллингом.

Скрипт собран из практики разворачивания флота серверов — все обходные пути
в нём появились после реальных сбоев, а не «на всякий случай».

## Что получится

- **3x-ui** (MHSanaei) с панелью на случайном порту, секретным base path и
  сертификатом Let's Encrypt
- **VLESS + Reality** на 443/tcp, flow `xtls-rprx-vision`, маскировка под
  `github.com`, `minClientVer 1.0.0`
- **BBR + fq** и тюнинг TCP-буферов
- **ufw**: открыты только 22, 443 и порт панели. Порт 80 закрыт постоянно и
  открывается лишь на секунды при выпуске и продлении сертификата
- **fail2ban** с джейлом 3x-ui (IP Limit)
- **TrafficGuard** — блокировка сканеров и сетей госорганов через ipset
- **torrent-block** — DPI-фильтр против BitTorrent-раздач, снимает DMCA-жалобы
- **JSON-паспорт** со всеми параметрами подключения

## Требования

- Ubuntu 22.04 или 24.04, root-доступ
- Домен с A-записью, указывающей на сервер (проверяется до выпуска сертификата)
- Ядро 4.9+ для BBR — у Ubuntu 22.04/24.04 это выполняется по умолчанию

Сервер должен быть чистым. Если на нём уже что-то крутится на 443 или 80,
разбирайся с этим до запуска.

## Установка

```bash
git clone https://github.com/<USER>/3xui-deploy.git
cd 3xui-deploy
chmod +x deploy.sh server-info.sh

./deploy.sh \
  --domain vpn.example.com \
  --name "Германия 1" \
  --code DE \
  --country "Германия" \
  --acme-email you@example.com
```

Занимает три-пять минут. Всё, что нельзя вывести из системы — отображаемое имя,
код страны, описание — передаётся флагами и попадает в паспорт.

### Опции

| Флаг | Назначение |
|---|---|
| `--domain FQDN` | **обязательный.** Домен сервера |
| `--name TEXT` | отображаемое имя, напр. `"Германия 1"` |
| `--code ISO2` | код страны, напр. `DE` — от него зависит флаг в интерфейсе |
| `--country TEXT` | страна по-русски |
| `--description TEXT` | описание, по умолчанию `VLESS Reality` |
| `--info TEXT` | доп. поле, опционально |
| `--acme-email MAIL` | e-mail аккаунта Let's Encrypt |
| `--dest HOST` | цель маскировки Reality, по умолчанию `github.com` |
| `--remark TEXT` | имя inbound'а, по умолчанию `<CODE>-Reality-443` |
| `--skip-trafficguard` | не ставить TrafficGuard |
| `--skip-torrent-block` | не ставить блокировку торрентов |
| `--harden-ssh` | отключить вход по паролю — только если найден SSH-ключ |
| `--skip-dns-check` | не проверять A-запись (например, при выпуске через DNS-01) |

## JSON-паспорт

Выводится в конце установки. Повторно — в любой момент:

```bash
NAME="Германия 1" CODE=DE COUNTRY="Германия" ./server-info.sh
```

Печатает в stdout, ничего не сохраняет.

```json
{
  "panel_type": "3x-ui-v3",
  "ip": "vpn.example.com",
  "ipv4": "203.0.113.10",
  "domain": "vpn.example.com",
  "port_panel": 32566,
  "uri_path": "/XXXXXXXXXXXXXXXXXX/",
  "panel_login": "REDACTED",
  "panel_password": "REDACTED",
  "panel_api_token": "REDACTED",
  "panel_version": "3.6.0",
  "xray_version": "26.7.28",
  "vless_inbound_id": 1,
  "port_key": 443,
  "security": "reality",
  "network": "tcp",
  "flow": "xtls-rprx-vision",
  "sni": "github.com",
  "public_key": "REDACTED",
  "short_id": "REDACTED",
  "fingerprint": "firefox",
  "cert_expires": "Nov 15 18:22:26 2026 GMT",
  "name": "Германия 1",
  "code": "DE",
  "country": "Германия",
  "description": "VLESS Reality",
  "info": null
}
```

Поле `ip` — публичный **домен**, а не адрес: именно его видят клиенты, и именно
он нужен, если сервер стоит за CDN. Фактический адрес лежит отдельно в `ipv4`.
Переопределяется через `IP_PUBLIC=front.example.com ./server-info.sh`.

**Вывод содержит пароль панели и API-токен открытым текстом.** Так задумано —
паспорт идёт в биллинг, — но помни, что он попадает в историю терминала.

## Проверка после установки

```bash
# Reality отдаёт настоящий сертификат цели маскировки — запускать с ДРУГОЙ машины
openssl s_client -connect <IP>:443 -servername github.com </dev/null 2>/dev/null \
  | grep -E 'subject=|Verify return code'
# ожидаем: subject=CN = github.com, Verify return code: 0 (ok)

sysctl -n net.ipv4.tcp_congestion_control   # bbr
ipset list -t SCANNERS-BLOCK-V4 | grep 'Number of entries'
systemctl is-active x-ui fail2ban
```

Если `openssl` вернул свой сертификат или оборвал соединение — маскировка не
работает. На macOS системный LibreSSL этого вывода не показывает, гоняй с Linux.

## Структура

```
deploy.sh          основной скрипт, запускать на сервере от root
server-info.sh     JSON-паспорт
lib/inbound.py     создание inbound'а VLESS+Reality в базе 3x-ui
docs/os-reinstall.md    переустановка ОС по сети, если приехал не Ubuntu
docs/troubleshooting.md грабли и как их обходить
```

## Если провайдер выдал не Ubuntu

Бывает, что вместо Ubuntu разворачивается CentOS 7 или переустановка из панели
молча не срабатывает. Лечится сетевой переустановкой прямо с живой системы —
[docs/os-reinstall.md](docs/os-reinstall.md).

## Известные грабли

Собраны в [docs/troubleshooting.md](docs/troubleshooting.md). Коротко:

- `unattended-upgrades` держит dpkg на свежей машине — скрипт ждёт освобождения
- у `settings.key` в базе 3x-ui нет уникального индекса, `ON CONFLICT` не работает
- панель держит SQLite открытой — перед правкой настроек её надо гасить
- установщик TrafficGuard после неудачи молча ничего не делает при повторе
- мёртвый хост может отвечать SYN-ACK через оборудование провайдера — `nc -z` врёт

## Блокировка торрентов

Ставится по умолчанию, отключается флагом `--skip-torrent-block`. Это
[3xui-torrent-block](https://github.com/pbldbl/3xui-torrent-block) — DPI-фильтр на
iptables, который режет обнаружение пиров: DHT, HTTP/HTTPS-трекеры по сигнатурам
и SNI, классические BitTorrent-порты, незашифрованный peer-wire handshake.

Он работает **в дополнение** к правилу Xray `bittorrent → blocked`, а не вместо
него: правило Xray отсекает торрент внутри туннеля, фильтр — исходящий поиск
пиров с самого сервера. Вместе они закрывают типовую причину DMCA-жалоб.

Проверка после установки:

```bash
systemctl is-active torrent-block
iptables -L TORRENT_BLOCK -v -n   # ненулевые pkts = фильтр реально срабатывает
```

## Смежные инструменты

Этот репозиторий закрывает установку и штатную эксплуатацию. Для реагирования на
инциденты есть отдельный — **[3xui-abuse-remediate](https://github.com/pbldbl/3xui-abuse-remediate)**:
если хостер прислал abuse-жалобу, потому что заражённое устройство клиента гоняет
трафик к C&C транзитом через твой прокси, тот скрипт блокирует связь с C&C на
уровне nftables и routing Xray, включает логи для поиска виновного клиента и
проверяет сервер на признаки компрометации.

Инструменты намеренно разделены: установка выполняется один раз на чистой машине,
реагирование — на боевой, с живыми клиентами и другим уровнем риска. К тому же в
abuse-скрипте зашиты индикаторы конкретного инцидента, которые со временем теряют
актуальность, — запускать его превентивно при установке смысла нет.

## Про SSH

По умолчанию вход по паролю остаётся включённым: на части провайдеров пароль —
единственный способ зайти через VNC, если что-то пойдёт не так.

Флаг `--harden-ssh` его отключает, но только когда найден непустой
`authorized_keys` — иначе шаг пропускается, чтобы не потерять доступ к серверу.
Перед перезагрузкой sshd конфиг проверяется через `sshd -t`, при ошибке правки
откатываются.

Отдельно скрипт обезвреживает чужие drop-in вроде `50-cloud-init.conf`. Это важно:
в OpenSSH выигрывает **первая** встреченная директива, а `50-` читается раньше
`99-`, поэтому без правки cloud-init пароль остался бы включённым, несмотря на
собственный файл.

## Безопасность

Скрипт правит файрвол и ставит стороннее ПО. Перед TrafficGuard делается бэкап
правил в `/root/fw-backup/`. Цепочка `SCANNERS-BLOCK` встаёт **перед** правилами
ufw, включая `allow 22` — если твоя сеть попадёт в блок-листы, доступ по SSH
пропадёт. Держи под рукой VNC или rescue-режим.

## Лицензия

MIT — см. [LICENSE](LICENSE).

Использует сторонние проекты: [3x-ui](https://github.com/MHSanaei/3x-ui),
[traffic-guard](https://github.com/dotX12/traffic-guard),
[TrafficGuard-auto](https://github.com/DonMatteoVPN/TrafficGuard-auto),
[reinstall](https://github.com/bin456789/reinstall), [acme.sh](https://github.com/acmesh-official/acme.sh).
