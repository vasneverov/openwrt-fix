# 🔧 OpenWrt Rescue Script — Полное восстановление Tailscale + Podkop

**One-liner для запуска:**
```bash
sh <(wget -O - https://raw.githubusercontent.com/vasneverov/openwrt-fix/main/fix-tailscale-openwrt.sh)
```

---

## 📋 Что делает этот скрипт

Этот скрипт полностью восстанавливает работоспособность роутера с OpenWrt после сбоев, обновлений или при первичной настройке. Он настраивает **Tailscale для удалённого доступа** и **Podkop (sing-box) для обхода блокировок**.

---

## 🎯 Шаги выполнения и тонкости

### Шаг 1: `fw_mode → none` (Tailscale)
```bash
uci set tailscale.settings.fw_mode='none'
```

**Что делает:** Отключает управление firewall со стороны Tailscale.

**Почему это важно:**
- Стандартный режим `fw_mode=nftables` перезаписывает nftables-правила Podkop
- Это приводит к потере VPN-трафика — sing-box перестаёт перехватывать пакеты
- `none` = Tailscale не трогает firewall, оставляя правила Podkop нетронутыми

**Что на что влияет:**
| fw_mode | Результат |
|---------|-----------|
| `nftables` | ❌ PodkopTable в nftables затирается, VPN не работает |
| `none` | ✅ PodkopTable сохраняется, VPN работает |

---

### Шаг 2: Настройки Podkop
```bash
uci set podkop.settings.exclude_ntp='1'
uci set podkop.main.exclude_ntp='1'
uci set podkop.main.mixed_proxy_enabled='0'
uci set podkop.YT.mixed_proxy_enabled='0'
```

**Что делает:**
- `exclude_ntp=1` — исключает NTP-трафик из VPN-туннеля
- `mixed_proxy_enabled=0` — отключает mixed proxy (используется только для скачивания списков при блокировке GitHub)

**Почему это важно:**

**NTP (exclude_ntp=1):**
- При `exclude_ntp=0` NTP-запросы идут через sing-box
- sing-box с fakeIP может кэшировать DNS-ответы с "завтрашним" временем
- Роутер получает неправильное время → сертификаты TLS становятся недействительными → HTTPS ломается везде

**mixed_proxy:**
- Включается только временно для скачивания .srs-списков с GitHub при блокировке
- Обычно должен быть `0`, иначе создаётся лишний прокси-порт

**Что на что влияет:**
| exclude_ntp | Результат |
|-------------|-----------|
| `0` | ❌ Часы дрейфуют, HTTPS ломается |
| `1` | ✅ NTP ходит напрямую, время стабильно |

---

### Шаг 3: rc.local — автозапуск Tailscale
```bash
cat > /etc/rc.local << 'RCEOF'
#!/bin/sh
(sleep 40
tailscaled --tun=userspace-networking --statedir=/etc/tailscale/
sleep 5
tailscale up --accept-dns=false --accept-routes) &
exit 0
```

**Что делает:** Создаёт скрипт автозапуска Tailscale при загрузке роутера.

**Ключевые параметры:**
- `--tun=userspace-networking` — userspace-режим (не требует TUN-модуль ядра)
- `--statedir=/etc/tailscale/` — директория для состояния
- `sleep 40` — ждёт инициализации системы (сеть, DNS)
- `--accept-dns=false` — не меняет DNS настройки роутера
- `--accept-routes` — принимать маршруты из Tailscale network

**Почему userspace-networking:**
- OpenWrt на многих роутерах не поддерживает TUN-модуль
- Userspace работает везде, но немного медленнее
- Без этого параметра Tailscale не запустится

**Бэкап rc.local:**
```bash
cp /etc/rc.local /etc/rc.local.bak
```
Создаёт резервную копию для восстановления watchdog-ом.

---

### Шаг 4: Три watchdog-скрипта (*/2 минуты)

#### 4.1 `/etc/ts-watchdog.sh` — защита Tailscale
```bash
#!/bin/sh
RC_BACKUP="/etc/rc.local.bak"
if [ ! -f "$RC_BACKUP" ]; then exit 1; fi

# Восстановление rc.local если он был повреждён
if ! grep -q "tailscaled" /etc/rc.local 2>/dev/null; then
    cp "$RC_BACKUP" /etc/rc.local
fi

# Перезапуск tailscaled если процесс упал
if ! ps | grep -q "tailscaled --state="; then
    (sleep 5; /usr/sbin/tailscaled --state=/etc/tailscale/tailscaled.state \
        --socket=/var/run/tailscale/tailscaled.sock & sleep 5; \
        tailscale up --accept-dns=false --accept-routes) &
fi
```

**Что проверяет:**
1. Наличие `rc.local.bak` — если нет, выходит (система не готова)
2. Целостность `/etc/rc.local` — если tailscaled пропал из файла, восстанавливает из бэкапа
3. Процесс `tailscaled` — если упал, перезапускает

**Задержка 5 секунд** перед запуском — даёт время системе стабилизироваться.

---

#### 4.2 `/etc/podkop-watchdog.sh` — защита Podkop/sing-box
```bash
#!/bin/sh
if ! ps | grep -q "sing-box run"; then
    logger -t podkop-watchdog "sing-box not running, restarting podkop"
    /etc/init.d/podkop restart
fi
```

**Что проверяет:**
- Процесс `sing-box run` — основной процесс VPN

**Что делает при падении:**
- Перезапускает весь `/etc/init.d/podkop` через init.d
- Это пересоздаёт nftables-правила и перезапускает sing-box

**Почему важен:**
- sing-box может упасть при OOM (нехватке памяти)
- После падения правила nftables остаются, но не работают без процесса
- Без watchdog трафик уходит в никуда (чёрная дыра)

---

#### 4.3 `/etc/route-watchdog.sh` — защита FakeIP-маршрутов
```bash
#!/bin/sh
if ! ip route | grep -q "198.18.0.0/15"; then
    logger -t route-watchdog "Restoring FakeIP routes"
    ip route add 198.18.0.0/15 dev br-lan 2>/dev/null || true
fi
```

**Что проверяет:**
- Наличие маршрута `198.18.0.0/15` в таблице маршрутизации

**Зачем нужен этот маршрут:**
- sing-box с `dns_type=fakeip` выдаёт клиентам IP из диапазона 198.18.0.0/15
- Это "фейковые" IP, которые sing-box затем перехватывает и проксирует
- Без маршрута пакеты к 198.18.x.x уходят через WAN и теряются

**Когда маршрут пропадает:**
- При рестарте сети (`/etc/init.d/network restart`)
- При изменении настроек LAN через LuCI
- При перезагрузке firewall

**Что на что влияет:**
| Маршрут 198.18.0.0/15 | Результат |
|-----------------------|-----------|
| Есть | ✅ FakeIP работает, сайты открываются |
| Нет | ❌ DNS резолвится, но сайты не грузятся |

---

#### Cron-записи (каждые 2 минуты)
```bash
*/2 * * * * /etc/ts-watchdog.sh
*/2 * * * * /etc/podkop-watchdog.sh
*/2 * * * * /etc/route-watchdog.sh
```

**Почему именно */2 (2 минуты):**
- `*/5` (5 минут) — слишком долго, роутер может остаться без связи на 5 минут
- `*/1` (1 минута) — слишком часто, лишняя нагрузка на CPU
- `*/2` — оптимальный баланс между скоростью восстановления и нагрузкой

---

### Шаг 5: Firewall — tailscale0 в LAN зоне
```bash
uci set firewall.@zone[0].device='br-lan tailscale0'
```

**Что делает:** Добавляет интерфейс `tailscale0` в LAN-зону firewall.

**Зачем нужно:**
- Без этого устройства в Tailscale-сети не могут достучаться до роутера
- SSH через Tailscale не работает
- LuCI через Tailscale-IP недоступен

**Что на что влияет:**
| tailscale0 в LAN | Результат |
|------------------|-----------|
| Есть | ✅ SSH и LuCI доступны через Tailscale-IP |
| Нет | ❌ Только локальный доступ, Tailscale = только исходящий |

---

### Шаг 6: Перезапуск Tailscale
```bash
/etc/init.d/tailscale disable  # Отключаем стандартный init.d
kill $(pgrep tailscaled)         # Убиваем старый процесс
sleep 3
/usr/sbin/tailscaled --state=/etc/tailscale/tailscaled.state \
    --socket=/var/run/tailscale/tailscaled.sock &
sleep 5
tailscale up --accept-dns=false --accept-routes
```

**Почему `disable` стандартного init.d:**
- Стандартный init.d запускает tailscaled в режиме, несовместимом с podkop
- Может перезаписать fw_mode и firewall-правила
- Наш rc.local даёт полный контроль над параметрами

**Параметры запуска:**
- `--state=/etc/tailscale/tailscaled.state` — файл состояния (ключи, настройки)
- `--socket=/var/run/tailscale/tailscaled.sock` — сокет для tailscale CLI

**Важно:** Без `--socket` команда `tailscale status` может не работать.

---

## ✅ Финальная проверка

Скрипт выводит статус всех компонентов:

```
╔══════════════════════════════════════╗
║         РЕЗУЛЬТАТ УСТАНОВКИ          ║
╚══════════════════════════════════════╝

  ✅ fw_mode = none
  ✅ rc.local — автозапуск tailscaled
  ✅ ts-watchdog — в crontab (каждые 2 мин)
  ✅ podkop-watchdog — в crontab (каждые 2 мин)
  ✅ route-watchdog — в crontab (каждые 2 мин)
  ✅ firewall — tailscale0 в LAN зоне
  ✅ exclude_ntp = 1
  ✅ Tailscale online: 100.x.x.x hostname user@ linux online

╔══════════════════════════════════════╗
║  🎉 Всё готово! SSH через Tailscale  ║
║     ssh root@<tailscale-ip>          ║
╚══════════════════════════════════════╝
```

---

## 🔍 Типичные проблемы и решения

### Проблема: "❌ fw_mode не none"
**Решение:** Скрипт уже исправил, но Tailscale из init.d перезаписал. Проверить:
```bash
uci get tailscale.settings.fw_mode
/etc/init.d/tailscale disable
```

### Проблема: "❌ rc.local — tailscaled НЕ найден"
**Решение:** Возможно, /etc/rc.local был пустым. Проверить:
```bash
cat /etc/rc.local
# Если пустой — скрипт автоматически создаст из .bak
```

### Проблема: "❌ watchdog отсутствует"
**Решение:** Cron мог не примениться. Проверить:
```bash
crontab -l | grep watchdog
```

### Проблема: Tailscale не поднимается
**Возможные причины:**
1. **Нет интернета на WAN** — Tailscale не может авторизоваться
2. **Сертификаты слетели** — проверить `date`, должно быть актуальное время
3. **State-файл повреждён** — удалить `/etc/tailscale/tailscaled.state` и перезапустить

---

## 📊 Архитектура после применения

```
┌─────────────────────────────────────────┐
│           OpenWrt Router              │
├─────────────────────────────────────────┤
│  ┌──────────┐      ┌──────────────┐   │
│  │ Tailscale│◄────►│  tailscale0  │   │
│  │ userspace│      │  (в LAN zone)│   │
│  └──────────┘      └──────────────┘   │
│       │                                 │
│       ▼                                 │
│  100.x.x.x (Tailscale IP)               │
│       │                                 │
│  SSH ◄┘                                 │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │        Podkop / sing-box        │    │
│  │  ┌────────┐    ┌─────────────┐   │    │
│  │  │ FakeIP │───►│  sing-box   │   │    │
│  │  │  DNS   │    │   (gRPC)    │   │    │
│  │  └────────┘    └─────────────┘   │    │
│  │                    │            │    │
│  │             ┌──────┴──────┐       │    │
│  │             ▼             ▼       │    │
│  │        ┌────────┐    ┌────────┐   │    │
│  │        │  YT    │    │  Main  │   │    │
│  │        │ bMSK   │    │ relay  │   │    │
│  │        └────────┘    └────────┘   │    │
│  └─────────────────────────────────┘    │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │  Watchdogs (*/2 минуты)         │    │
│  │  • ts-watchdog.sh              │    │
│  │  • podkop-watchdog.sh          │    │
│  │  • route-watchdog.sh           │    │
│  └─────────────────────────────────┘    │
└─────────────────────────────────────────┘
```

---

## 📝 История изменений

| Версия | Дата | Изменения |
|--------|------|-----------|
| 1.0 | 2026-05-06 | Первый релиз с 3 watchdog'ами, правильный формат tailscaled, восстановление rc.local |

---

## ⚠️ Важные замечания

1. **Скрипт не создаёт ключи VLESS** — только настраивает инфраструктуру. Ключи устанавливаются отдельно через `uci set podkop.main.proxy_string=...`

2. **Скрипт не проверяет доступность интернета** — если WAN не работает, Tailscale не поднимется

3. **После применения проверить:**
   ```bash
   ssh root@<tailscale-ip>
   curl -s https://telegram.org | head -1  # должно вернуть HTML
   ```

4. **Если роутер далеко** — этот скрипт спасёт ситуацию, но убедитесь, что Tailscale был настроен ДО потери доступа
