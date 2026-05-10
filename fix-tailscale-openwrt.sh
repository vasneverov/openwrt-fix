#!/bin/sh
# Tailscale + Podkop repair for OpenWrt
# Usage: sh <(wget -O - https://raw.githubusercontent.com/vasneverov/openwrt-fix/main/fix-tailscale-openwrt.sh)
#
# v3.0 — 2026-05-10 — ЖЕЛЕЗОБЕТОННАЯ ВЕРСИЯ
# - Единый ts-watchdog (rc.local + крон) — не конфликтует сам с собой
# - Lock-файл: защита от двойного запуска
# - Не убивает tailscale up если tailscale уже онлайн
# - Проверяет tailscaled процесс, tailscale онлайн, tailscale up не завис
# - podkop-fw4-fix после поднятия tailscale

echo ""; echo "╔══════════════════════════════════════╗"
echo "║   Tailscale + Podkop Repair Tool v3  ║"
echo "║   ЖЕЛЕЗОБЕТОННАЯ ВЕРСИЯ               ║"
echo "╚══════════════════════════════════════╝"; echo ""

echo "[1/6] fw_mode → none"
uci set tailscale.settings.fw_mode='none' 2>/dev/null
uci commit tailscale 2>/dev/null

echo "[2/6] podkop: exclude_ntp=1, mixed_proxy=0"
uci set podkop.settings.exclude_ntp='1' 2>/dev/null
uci set podkop.main.exclude_ntp='1' 2>/dev/null
uci set podkop.main.mixed_proxy_enabled='0' 2>/dev/null
uci set podkop.YT.mixed_proxy_enabled='0' 2>/dev/null
uci commit podkop 2>/dev/null

echo "[3/6] rc.local → минимальный + watchdog в фоне"
cat > /etc/rc.local << 'RCEOF'
#!/bin/sh

# === TAILSCALE STARTUP ===
tailscaled --statedir=/etc/tailscale/ --tun=userspace-networking >> /tmp/ts.log 2>&1 &
sleep 3
tailscale up --accept-dns=false --accept-routes &

# === WATCHDOG В ФОНЕ ===
# Ждёт tailscale до 120 сек, перезапускает если упал
/etc/ts-watchdog.sh &

logger -t rc.local 'rc.local complete'
exit 0
RCEOF
chmod +x /etc/rc.local; cp /etc/rc.local /etc/rc.local.bak

echo "[4/6] ts-watchdog v3.1 — единый, с lock-файлом + NoState fix"
cat > /etc/ts-watchdog.sh << 'WEOF'
#!/bin/sh

# === ts-watchdog v3.1 ===
# Единый watchdog: работает и из rc.local, и из крона
# Lock-файл: не запускается дважды
# Не убивает tailscale если он уже онлайн
# NoState fix: если tailscale status выдаёт NoState — killall tailscaled + запуск заново

LOCKFILE=/tmp/ts-watchdog.lock

# Lock-файл: если уже запущен — выходим
if [ -f "$LOCKFILE" ]; then
    LOCKPID=$(cat "$LOCKFILE" 2>/dev/null)
    if kill -0 "$LOCKPID" 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > "$LOCKFILE"

# 1. Проверка tailscaled процесс
if ! ps | grep -q "tailscaled --state="; then
    logger -t ts-watchdog "tailscaled not running, restarting..."
    tailscaled --statedir=/etc/tailscale/ --tun=userspace-networking >> /tmp/ts.log 2>&1 &
    sleep 5
    tailscale up --accept-dns=false --accept-routes &
    logger -t ts-watchdog "tailscaled restarted"
    rm -f "$LOCKFILE"
    exit 0
fi

# 2. Проверка что tailscale онлайн
TS_STATUS=$(tailscale status 2>&1)

# 2a. Если tailscaled в битом состоянии (NoState) — перезапускаем целиком
if echo "$TS_STATUS" | grep -q "NoState"; then
    logger -t ts-watchdog "tailscaled in NoState (DERP lost), full restart..."
    killall tailscale 2>/dev/null
    sleep 1
    killall tailscaled 2>/dev/null
    sleep 2
    tailscaled --statedir=/etc/tailscale/ --tun=userspace-networking >> /tmp/ts.log 2>&1 &
    sleep 5
    date +%s > /tmp/ts-up-start
    tailscale up --accept-dns=false --accept-routes &
    logger -t ts-watchdog "tailscaled fully restarted (NoState fix)"
    rm -f "$LOCKFILE"
    exit 0
fi

# 2b. Нормальный онлайн
if echo "$TS_STATUS" | grep -q '100\.'; then
    # ✅ Tailscale онлайн — ничего не делаем
    # Применяем podkop-fw4-fix если нужно
    if [ -x /root/podkop-fw4-fix.sh ]; then
        /root/podkop-fw4-fix.sh update 2>/dev/null
    fi
    rm -f "$LOCKFILE"
    exit 0
fi

# 3. Tailscale НЕ онлайн — пробуем перезапустить
logger -t ts-watchdog "tailscale not online, reconnecting..."

# Проверяем не висит ли tailscale up
TS_UP_PID=$(ps | grep "tailscale up" | grep -v grep | awk '{print $1}')
if [ -n "$TS_UP_PID" ]; then
    # Если tailscale up висит больше 90 сек — убиваем
    # 30 сек мало — tailscale up может висеть 40-50 сек при первом запуске
    if [ -f /tmp/ts-up-start ] && [ $(($(date +%s) - $(cat /tmp/ts-up-start))) -gt 90 ]; then
        logger -t ts-watchdog "tailscale up stuck (PID $TS_UP_PID), killing..."
        kill "$TS_UP_PID" 2>/dev/null
        sleep 2
        date +%s > /tmp/ts-up-start
        tailscale up --accept-dns=false --accept-routes &
        logger -t ts-watchdog "tailscale up restarted"
    fi
else
    # tailscale up не запущен — запускаем
    date +%s > /tmp/ts-up-start
    tailscale up --accept-dns=false --accept-routes &
    logger -t ts-watchdog "tailscale up started"
fi

rm -f "$LOCKFILE"
WEOF
chmod +x /etc/ts-watchdog.sh

cat > /etc/podkop-watchdog.sh << 'PEOF'
#!/bin/sh
ps | grep -q "sing-box" || /etc/init.d/podkop restart
PEOF
chmod +x /etc/podkop-watchdog.sh

echo "[5/6] crontab — watchdog каждые 2 мин"
(crontab -l 2>/dev/null | grep -v -E '(ts-watchdog|podkop-watchdog|route-watchdog)'
 echo "*/2 * * * * /etc/ts-watchdog.sh"
 echo "*/2 * * * * /etc/podkop-watchdog.sh"
 echo "*/2 * * * * /etc/route-watchdog.sh"
 echo "13 */3 * * * /usr/bin/podkop list_update"
) | crontab -

echo "[6/6] firewall → tailscale0 в LAN зону"
uci set firewall.@zone[0].device='br-lan tailscale0' 2>/dev/null
uci commit firewall 2>/dev/null
/etc/init.d/firewall reload 2>/dev/null

echo ""
echo "╔══════════════════════════════════════╗"
echo "║         РЕЗУЛЬТАТ УСТАНОВКИ          ║"
echo "╚══════════════════════════════════════╝"
echo ""

FW=$(uci get tailscale.settings.fw_mode 2>/dev/null)
if [ "$FW" = "none" ]; then
  echo "  ✅ fw_mode = none"
else
  echo "  ❌ fw_mode = $FW (должно быть none)"
fi

if grep -q tailscaled /etc/rc.local 2>/dev/null; then
  echo "  ✅ rc.local — автозапуск tailscaled"
else
  echo "  ❌ rc.local — tailscaled НЕ найден"
fi

if grep -q 'ts-watchdog.sh &' /etc/rc.local 2>/dev/null; then
  echo "  ✅ rc.local — watchdog в фоне (v3)"
else
  echo "  ⚠️ rc.local — watchdog не в фоне"
fi

if crontab -l 2>/dev/null | grep -q ts-watchdog; then
  echo "  ✅ ts-watchdog — watchdog в crontab"
else
  echo "  ❌ ts-watchdog — отсутствует"
fi

if crontab -l 2>/dev/null | grep -q podkop-watchdog; then
  echo "  ✅ podkop-watchdog — watchdog в crontab"
else
  echo "  ❌ podkop-watchdog — отсутствует"
fi

FW_DEV=$(uci get firewall.@zone[0].device 2>/dev/null)
if echo "$FW_DEV" | grep -q tailscale0; then
  echo "  ✅ firewall — tailscale0 в LAN зоне"
else
  echo "  ❌ firewall — tailscale0 НЕ в LAN зоне"
fi

NTP=$(uci get podkop.settings.exclude_ntp 2>/dev/null)
if [ "$NTP" = "1" ]; then
  echo "  ✅ exclude_ntp = 1"
else
  echo "  ❌ exclude_ntp = $NTP (должно быть 1)"
fi

TS=$(tailscale status 2>/dev/null | head -1)
if [ -n "$TS" ]; then
  echo "  ✅ Tailscale online: $TS"
  echo ""
  echo "╔══════════════════════════════════════╗"
  echo "║  🎉 Всё готово! SSH через Tailscale  ║"
  echo "║     ssh root@<tailscale-ip>          ║"
  echo "╚══════════════════════════════════════╝"
else
  echo "  ⏳ Tailscale поднимается... подождите 30-40 сек"
  echo "     Затем: tailscale status"
fi
echo ""
