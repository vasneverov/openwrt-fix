# 🔧 OpenWrt Rescue Script — Полное восстановление Tailscale + Podkop

**One-liner для запуска:**
```bash
sh <(wget -O - https://raw.githubusercontent.com/vasneverov/openwrt-fix/main/fix-tailscale-openwrt.sh)
```

---

## 📋 Что делает этот скрипт

Универсальное восстановление роутера OpenWrt после сбоев, обновлений или при первичной настройке. Настраивает **Tailscale для удалённого доступа** и **Podkop (sing-box) для обхода блокировок**.

**Железные правила скрипта:**
- ❌ Tailscale НЕ перезагружаем (оборвётся SSH)
- ❌ Podkop НЕ рестартим (может сломать маршрутизацию)
- ❌ firewall НЕ reload (сбросит правила Tailscale)
- ❌ reboot НЕ делаем

---

## 🎯 Порядок выполнения

### Принцип: сначала Tailscale, потом всё остальное

Первые 6 шагов полностью защищают Tailscale. Только после этого трогается Podkop.
Причина: `set -e` — при любой ошибке скрипт остановится. Если Podkop-команды упадут раньше, чем записан rc.local, роутер потеряет Tailscale после ребута навсегда.

---

### Шаг 1: `fw_mode → none`

```bash
uci set tailscale.settings.fw_mode='none'
```

Tailscale в режиме `nftables` перезаписывает таблицы firewall и уничтожает `PodkopTable`. Режим `none` запрещает Tailscale трогать firewall.

| fw_mode | Результат |
|---------|-----------|
| `nftables` | ❌ PodkopTable затирается, VPN не работает |
| `none` | ✅ PodkopTable сохраняется, VPN работает |

---

### Шаг 2: `init.d/tailscale → DISABLED`

```bash
/etc/init.d/tailscale disable
```

Системный init.d запускает Tailscale в kernel-mode, который при каждом старте сбрасывает `PodkopTable`. Отключаем навсегда — запуском управляет rc.local из шага 3.

---

### Шаг 3: `rc.local` — автозапуск Tailscale через ребут

```bash
cat > /etc/rc.local << 'EOF'
#!/bin/sh
(sleep 40
tailscaled --tun=userspace-networking --statedir=/etc/tailscale/ >> /tmp/ts.log 2>&1 &
sleep 5
tailscale up --accept-dns=false --accept-routes
sleep 10
logger -t rc.local 'tailscale up applied') &
exit 0
EOF
```

Записывает правильный запуск в `/etc/rc.local` и сохраняет бэкап в `/etc/rc.local.bak`.

**Ключевые параметры:**
- `--tun=userspace-networking` — работает без TUN-модуля ядра, совместим со всеми роутерами
- `--statedir=/etc/tailscale/` — персистентная папка (не `/var/lib`, которая в RAM и стирается при ребуте)
- `sleep 40` — ждёт пока система поднимет сеть и DNS
- `--accept-dns=false` — не меняет DNS роутера

---

### Шаг 4: `tailscale0 → LAN зона` (без reload!)

```bash
uci set firewall.@zone[0].device='br-lan tailscale0'
uci commit firewall
```

Без этого SSH и LuCI недоступны через Tailscale-IP. Добавляет `tailscale0` в LAN-зону только через UCI — без `fw reload`, который сбросил бы правила Podkop.

---

### Шаг 5: Три watchdog-скрипта

Все три запускаются cron каждые 2 минуты.

**`/etc/ts-watchdog.sh` — защита Tailscale:**
1. Если `/etc/rc.local` повреждён — восстанавливает из `/etc/rc.local.bak`
2. Если процесс `tailscaled` упал — перезапускает

**`/etc/podkop-watchdog.sh` — защита sing-box:**
- Если процесс `sing-box run` не виден — рестартит `/etc/init.d/podkop`
- Защищает от OOM-падений (sing-box занимает ~40MB)

**`/etc/route-watchdog.sh` — защита FakeIP-маршрутов:**
- Проверяет маршрут `198.18.0.0/15` (диапазон FakeIP-адресов sing-box)
- Проверяет что `PodkopTable` (nftables) жива
- Если что-то пропало — восстанавливает / рестартит podkop

| Маршрут 198.18.0.0/15 | Результат |
|-----------------------|-----------|
| Есть | ✅ FakeIP работает, сайты открываются |
| Нет | ❌ DNS резолвится, но сайты не грузятся |

---

### Шаг 6: Crontab

```
*/2 * * * * /etc/ts-watchdog.sh
*/2 * * * * /etc/podkop-watchdog.sh
*/2 * * * * /etc/route-watchdog.sh
13 */3 * * * /usr/bin/podkop list_update
```

Три watchdog'а каждые 2 минуты + обновление community lists раз в 3 часа.

---

**── После шага 6 Tailscale полностью защищён ──**

---

### Шаг 7: WAN ifname

```bash
uci set network.wan.ifname="$WAN_DEVICE"
```

Podkop использует `ifname`, а не `device`. На новых прошивках OpenWrt 25.12 WAN описывается через `device`. Копирует значение если `ifname` отсутствует.

---

### Шаг 8: Podkop настройки

```bash
uci set podkop.settings.exclude_ntp='1'
uci set podkop.settings.enable_output_network_interface='1'
uci set podkop.main.mixed_proxy_enabled='0'
uci set podkop.YT.mixed_proxy_enabled='0'
```

- `exclude_ntp=1` — NTP идёт напрямую, минуя туннель. Иначе sing-box с FakeIP может дать роутеру "завтрашнее" время → TLS-сертификаты невалидны → HTTPS ломается везде
- `enable_output_network_interface=1` — сам роутер ходит через туннель (не только LAN-клиенты)
- `mixed_proxy_enabled=0` — отключает смешанный прокси, конфликтующий с sing-box

---

### Шаг 9: `check-ip` — диагностический инструмент

Создаёт `/usr/bin/check-ip`. После применения скрипта запустить:
```bash
check-ip
```
Покажет внешний IP напрямую и через прокси, статус 10 сайтов (YouTube, Telegram, Instagram и др.).

---

### Шаг 10: `podkop-fw4-fix` (только OpenWrt 25.12+)

Для роутеров на nftables (fw4) устанавливает патч совместимости Podkop с `mangle_forward` chain. На fw3/iptables пропускается автоматически.

---

### Шаг 11: `podkop-fix-lists`

Исправляет community lists если они не скачались или устарели после применения основного скрипта.

---

### Шаг 12: Проверка firewall

Диагностика (не лечит):
- fw4: проверяет жива ли `inet PodkopTable` и есть ли `fw4-fix` правила
- fw3: проверяет наличие Podkop-правил в iptables mangle

---

### Шаг 13: Финальная диагностика

```
ping 1.1.1.1        — есть ли интернет
ping google.com     — работает ли DNS
nslookup google.com — резолвится ли домен
```

---

## ✅ Финальный вывод скрипта

```
╔══════════════════════════════════════════════════╗
║  ✅ СПАСЕНИЕ ПРИМЕНЕНО                           ║
╚══════════════════════════════════════════════════╝

  fw_mode:           none
  exclude_ntp:       1
  init.d/tailscale:  DISABLED
  watchdog'ов:       3 записи
  tailscaled:        running
  check-ip:          /usr/bin/check-ip
```

---

## 🔍 Типичные проблемы

### Tailscale не поднимается после ребута
```bash
cat /etc/rc.local          # должен содержать tailscaled
ls /etc/tailscale/         # должен быть state-файл
logread | grep tailscale   # смотреть ошибки
```

### FakeIP не работает (DNS ОК, сайты не грузятся)
```bash
ip route | grep 198.18    # должен быть маршрут
nft list table inet PodkopTable  # должна существовать
```

### SSH через Tailscale недоступен
```bash
uci get firewall.@zone[0].device  # должно содержать tailscale0
```

---

## 📝 История изменений

| Дата | Изменения |
|------|-----------|
| 2026-05-10 | Новый порядок: Tailscale (шаги 1–6) строго до Podkop (шаги 7–8). Причина: set -e — ошибка в Podkop не должна блокировать запись rc.local |
| 2026-05-06 | Первый релиз: 3 watchdog'а, userspace-networking, восстановление rc.local |
