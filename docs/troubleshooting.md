# Грабли

Всё перечисленное встречалось на живых серверах. `deploy.sh` обходит это сам —
раздел нужен, если делаешь руками или разбираешься, почему что-то пошло не так.

## apt: `exit status 100` на свежей машине

На только что развёрнутом сервере `unattended-upgrades` захватывает dpkg и
держит его несколько минут. Любой `apt-get install` в это время падает:

```
E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process NNNN (unattended-upgr)
```

Особенно неприятно, что TrafficGuard ставит `ipset` сам и умирает с
`failed to install ipset: exit status 100`, не объясняя причины.

Обход — дождаться освобождения:

```bash
for _ in $(seq 1 60); do
  fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
  sleep 10
done
```

И ставить `ipset` с `rsyslog` заранее, вместе с остальными пакетами.

## SQLite: `ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint`

У таблицы `settings` в базе 3x-ui нет уникального индекса по `key`, поэтому
привычный upsert не работает:

```sql
-- не сработает
insert into settings (key,value) values ('webCertFile','...')
  on conflict(key) do update set value=excluded.value;
```

Правильно:

```sql
delete from settings where key='webCertFile';
insert into settings (key,value) values ('webCertFile','/etc/x-ui/cert/example.crt');
```

## SQLite: `database is locked (5)`

Панель держит базу открытой. Правки настроек проходят через раз — зависит от
того, что в этот момент делает x-ui. Перед записью панель надо гасить:

```bash
systemctl stop x-ui
sleep 2
# ... правки ...
systemctl start x-ui
```

Не полагайся на то, что «в прошлый раз прошло без остановки».

## TrafficGuard: повторный запуск молча ничего не делает

Установщик проверяет наличие `/usr/local/bin/traffic-guard` и, если бинарь уже
есть, пропускает установку — с нулевым выводом и кодом успеха. После любой
неудачной попытки бинарь остаётся на месте, поэтому повтор выглядит как
«всё прошло», хотя ipset пуст.

Проверяй результат, а не код возврата:

```bash
ipset list -t SCANNERS-BLOCK-V4 | grep 'Number of entries'
```

Чинится прямым вызовом:

```bash
/opt/trafficguard-manager.sh install </dev/null
```

## TrafficGuard: команда из README вешает SSH-сессию

Официальный `curl ... | bash` в конце запускает интерактивное меню. Без
терминала `read -r choice < /dev/tty` проваливается, `case` уходит в ветку
«неверный выбор», и скрипт крутится в бесконечном цикле.

Вырезать последнюю строку перед запуском:

```bash
sed -i '\|^/opt/trafficguard-manager.sh monitor$|d' install-trafficguard.sh
bash install-trafficguard.sh </dev/null
```

## TrafficGuard: может отрезать SSH

Цепочка `SCANNERS-BLOCK` встаёт **первой** в `ufw-before-input` — раньше
правила `allow 22`. Встроенная проверка `check_firewall_safety` останавливает
установку, только если ufw *выключен*; при активном ufw она пропускает всё и от
самоблокировки не спасает.

Поэтому бэкап перед установкой обязателен:

```bash
iptables-save  > /root/fw-backup/iptables.before
ip6tables-save > /root/fw-backup/ip6tables.before
cp /etc/ufw/before.rules /etc/ufw/before6.rules /root/fw-backup/
```

## Reality: старые клиенты не подключаются

3x-ui подставляет в `minClientVer` текущую версию ядра Xray, и клиенты постарше
отваливаются без внятной ошибки. Ставь `1.0.0`.

Xray при этом пишет в лог предупреждение — оно ожидаемо:

```
WARNING: Changing "minClientVer" will increase the likelihood of your server's IP being blocked by the GFW
```

## Reality: заезженный dest

Xray сам сигналит, если цель маскировки переиспользована:

```
REALITY: Choosing "<dest>" as the target will increase the likelihood of your server's IP being blocked
```

Проверять после установки:

```bash
journalctl -u x-ui | grep REALITY
```

Кандидатов на dest мерить с самого сервера — нужны HTTP/2, TLS 1.3 и близкий эдж:

```bash
curl -sI --tlsv1.3 --tls-max 1.3 https://$d -w '%{http_version} %{time_appconnect} %{remote_ip}'
```

## Let's Encrypt: валидация уходит не на тот сервер

Если у домена есть AAAA-запись, указывающая на другой хост, standalone-валидация
может пойти по IPv6 и провалиться, хотя A-запись верная. Проверяй обе записи до
выпуска.

Сертификат на голый IP брать не стоит: он живёт шесть дней и умирает вместе с
адресом.

## Смена IP сервера

Адрес VPN-сервера могут заблокировать, и провайдер выдаст новый. Что при этом
проверить:

```bash
# не зашит ли старый адрес в конфигурацию
sqlite3 /etc/x-ui/x-ui.db \
  "select count(*) from inbounds where settings like '%СТАРЫЙ_IP%' or stream_settings like '%СТАРЫЙ_IP%';"
sqlite3 /etc/x-ui/x-ui.db "select json_extract(stream_settings,'\$.externalProxy') from inbounds where id=1;"
```

Если `externalProxy` пуст, а `share_addr` не задан, ссылки строятся по Host
запроса подписки — клиенты получат новый адрес сами, перевыпускать ничего не
надо. Сертификат выпущен на домен, поэтому тоже переживает смену адреса.

Устаревшим останется только `XUI_ACCESS_URL` в `/etc/x-ui/install-result.env` —
поле справочное, ни на что не влияет.

## Диагностика блокировки по IP

ICMP при фильтрации по адресу назначения обычно проходит чисто, поэтому `ping`
и ICMP-MTR покажут «всё в порядке» на заблокированном сервере. Смотреть надо
TCP с узлов из нужной страны.

Замеры с собственной машины бесполезны, если на ней включён VPN: ICMP съедается
туннелем, а `nc -z` через прокси-клиент рапортует «open» даже на закрытом порту.
