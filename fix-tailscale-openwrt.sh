#!/bin/sh
# Tailscale + Podkop repair for OpenWrt
# Usage: sh <(wget -O - https://raw.githubusercontent.com/vasneverov/openwrt-fix/main/fix-tailscale-openwrt.sh)
#
# v3.1 — 2026-05-11 — IRON RULES COMPLIANT
# - Шаг 1: проверка что Tailscale уже онлайн → если да, ничего не делаем
# - Шаг 2: fw_mode=none, exclude_ntp=1, mixed_proxy=0
# - Шаг 3: rc.local с tailscaled + watchdog
# - Шаг 4: ts-watchdog v3.1 (lock, NoState fix, podkop-fw4-fix)
# - Шаг 5: podkop-watchdog + route-watchdog
# - Шаг 6: crontab (watchdog каждые 2 мин)
# - Шаг 7: tailscale0 в LAN зону (БЕЗ firewall reload — только uci commit)
# - Шаг 8: init.d/tailscale DISABLED
# - Шаг 9: enable_output_network_interface=1
# - Шаг 10: community_lists проверка
# - ФИНАЛ: прогресс-бар + отчёт с галочками

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Tailscale + Podkop Repair Tool v3.1               ║"
echo "║   IRON RULES COMPLIANT — не ломает работающий TS    ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ===== ШАГ 0: ПРОВЕРКА ЧТО НЕ НАВРЕДИМ =====
echo "━━━ [0/10] Проверка текущего состояния ━━━"
TS_ONLINE=$(tailscale status 2>/dev/null | grep -c '100\.')
if [ "$TS_ONLINE" -gt 0 ]; then
    echo "  ✅ Tailscale уже онлайн — пропускаем repair"
    echo "  ⚠️  Если нужно переустановить — сначала: killall tailscaled"
    echo ""
    # Всё равно проверяем watchdog'ы
else
    echo "  ⏳ Tailscale не онлайн — запускаем полный repair"
fi
echo ""

# ===== ШАГ 1: fw_mode → none =====
echo "━━━ [1/10] fw_mode → none ━━━"
uci set tailscale.settings.fw_mode='none' 2>/dev/null
uci commit tailscale 2>/dev/null
echo "  ✅ fw_mode = none"
echo ""

# ===== ШАГ 2: podkop настройки =====
echo "━━━ [2/10] Podkop: exclude_ntp, mixed_proxy, enable_output ━━━"
uci set podkop.settings.exclude_ntp='1' 2>/dev/null
uci set podkop.main.exclude_ntp='1' 2>/dev/null
uci set podkop.main.mixed_proxy_enabled='0' 2>/dev/null
uci set podkop.YT.mixed_proxy_enabled='0' 2>/dev/null
uci set podkop.settings.enable_output_network_interface='1' 2>/dev/null
uci commit podkop 2>/dev/null
echo "  ✅ exclude_ntp = 1"
echo "  ✅ mixed_proxy_enabled = 0"
echo "  ✅ enable_output_network_interface = 1"
echo ""

# ===== ШАГ 3: rc.local =====
echo "━━━ [3/10] rc.local — автозапуск tailscaled + watchdog ━━━"
cat > /etc/rc.local << 'RCEOF'
#!/bin/sh

# === TAILSCALE STARTUP ===
tailscaled --statedir=/etc/tailscale/ --tun=userspace-networking >> /tmp/ts.log 2>&1 &
sleep 3
tailscale up --accept-dns=false --accept-routes &

# === WATCHDOG В ФОНЕ ===
/etc/ts-watchdog.sh &

logger -t rc.local 'rc.local complete'
exit 0
RCEOF
chmod +x /etc/rc.local
cp /etc/rc.local /etc/rc.local.bak 2>/dev/null
echo "  ✅ rc.local — tailscaled + watchdog"
echo ""

# ===== ШАГ 4: ts-watchdog v3.1 =====
echo "━━━ [4/10] ts-watchdog v3.1 — единый, lock, NoState fix ━━━"
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

# 2a. NoState fix
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
    if [ -x /root/podkop-fw4-fix.sh ]; then
        /root/podkop-fw4-fix.sh update 2>/dev/null
    fi
    rm -f "$LOCKFILE"
    exit 0
fi

# 3. Tailscale НЕ онлайн — пробуем перезапустить
logger -t ts-watchdog "tailscale not online, reconnecting..."

TS_UP_PID=$(ps | grep "tailscale up" | grep -v grep | awk '{print $1}')
if [ -n "$TS_UP_PID" ]; then
    if [ -f /tmp/ts-up-start ] && [ $(($(date +%s) - $(cat /tmp/ts-up-start))) -gt 90 ]; then
        logger -t ts-watchdog "tailscale up stuck (PID $TS_UP_PID), killing..."
        kill "$TS_UP_PID" 2>/dev/null
        sleep 2
        date +%s > /tmp/ts-up-start
        tailscale up --accept-dns=false --accept-routes &
        logger -t ts-watchdog "tailscale up restarted"
    fi
else
    date +%s > /tmp/ts-up-start
    tailscale up --accept-dns=false --accept-routes &
    logger -t ts-watchdog "tailscale up started"
fi

rm -f "$LOCKFILE"
WEOF
chmod +x /etc/ts-watchdog.sh
echo "  ✅ ts-watchdog v3.1 установлен"
echo ""

# ===== ШАГ 5: podkop-watchdog + route-watchdog =====
echo "━━━ [5/10] Watchdog'ы: podkop + route ━━━"
cat > /etc/podkop-watchdog.sh << 'PEOF'
#!/bin/sh
ps | grep -q "sing-box" || /etc/init.d/podkop restart
PEOF
chmod +x /etc/podkop-watchdog.sh

cat > /etc/route-watchdog.sh << 'REOF'
#!/bin/sh
# Проверка default route — если пропал, перезапускаем podkop
DEFAULT_ROUTE=$(ip route show default 2>/dev/null | head -1)
if [ -z "$DEFAULT_ROUTE" ]; then
    logger -t route-watchdog "No default route, restarting podkop..."
    /etc/init.d/podkop restart
fi
REOF
chmod +x /etc/route-watchdog.sh
echo "  ✅ podkop-watchdog.sh"
echo "  ✅ route-watchdog.sh"
echo ""

# ===== ШАГ 6: crontab =====
echo "━━━ [6/10] Crontab — watchdog каждые 2 мин ━━━"
(crontab -l 2>/dev/null | grep -v -E '(ts-watchdog|podkop-watchdog|route-watchdog)'
 echo "*/2 * * * * /etc/ts-watchdog.sh"
 echo "*/2 * * * * /etc/podkop-watchdog.sh"
 echo "*/2 * * * * /etc/route-watchdog.sh"
 echo "13 */3 * * * /usr/bin/podkop list_update"
) | crontab -
echo "  ✅ Crontab обновлён (3 watchdog + list_update)"
echo ""

# ===== ШАГ 7: tailscale0 в LAN зону (БЕЗ firewall reload!) =====
echo "━━━ [7/10] Firewall — tailscale0 в LAN зону ━━━"
uci set firewall.@zone[0].device='br-lan tailscale0' 2>/dev/null
uci commit firewall 2>/dev/null
echo "  ✅ tailscale0 добавлен в LAN зону (только uci commit, без reload)"
echo ""

# ===== ШАГ 8: init.d/tailscale DISABLED =====
echo "━━━ [8/10] init.d/tailscale — DISABLED ━━━"
if [ -f /etc/init.d/tailscale ]; then
    /etc/init.d/tailscale disable 2>/dev/null
    echo "  ✅ init.d/tailscale DISABLED (используем rc.local)"
else
    echo "  ✅ init.d/tailscale не найден — ОК"
fi
echo ""

# ===== ШАГ 9: community_lists проверка =====
echo "━━━ [9/10] Community lists — проверка ━━━"
PODKOP_VER=$(opkg list-installed 2>/dev/null | grep podkop | awk '{print $3}' | cut -d- -f1)
echo "  📦 Podkop версия: ${PODKOP_VER:-неизвестно}"

CURRENT_LISTS=$(uci get podkop.main.community_lists 2>/dev/null | wc -w)
echo "  📋 Текущих списков: $CURRENT_LISTS"

# Определяем правильное количество списков
if echo "$PODKOP_VER" | grep -q "0.7.14"; then
    EXPECTED_LISTS=21
elif echo "$PODKOP_VER" | grep -q "0.7.10"; then
    EXPECTED_LISTS=20
else
    EXPECTED_LISTS=0
fi

if [ "$EXPECTED_LISTS" -gt 0 ] && [ "$CURRENT_LISTS" -ne "$EXPECTED_LISTS" ]; then
    echo "  ⚠️  Ожидается $EXPECTED_LISTS списков, сейчас $CURRENT_LISTS"
    echo "  ⚠️  Запусти: /usr/bin/podkop list_update"
else
    echo "  ✅ Списки: $CURRENT_LISTS (норма)"
fi
echo ""

# ===== ШАГ 10: Запуск tailscale если не онлайн =====
echo "━━━ [10/10] Запуск Tailscale ━━━"
if [ "$TS_ONLINE" -eq 0 ]; then
    # Проверяем не запущен ли tailscaled
    if ! ps | grep -q "tailscaled --state="; then
        echo "  🚀 Запуск tailscaled..."
        tailscaled --statedir=/etc/tailscale/ --tun=userspace-networking >> /tmp/ts.log 2>&1 &
        sleep 3
    fi
    # Проверяем не висит ли tailscale up
    if ! ps | grep -q "tailscale up"; then
        echo "  🚀 Запуск tailscale up..."
        date +%s > /tmp/ts-up-start
        tailscale up --accept-dns=false --accept-routes &
    fi
    echo "  ⏳ Tailscale поднимается... watchdog проверит через 2 мин"
else
    echo "  ✅ Tailscale уже работает — ничего не делаем"
fi
echo ""

# ===== ФИНАЛЬНЫЙ ОТЧЁТ =====
echo "╔══════════════════════════════════════════════════════╗"
echo "║              ФИНАЛЬНЫЙ ОТЧЁТ УСТАНОВКИ              ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# 1. fw_mode
FW=$(uci get tailscale.settings.fw_mode 2>/dev/null)
if [ "$FW" = "none" ]; then echo "  ✅ [1] fw_mode = none"; else echo "  ❌ [1] fw_mode = $FW"; fi

# 2. exclude_ntp
NTP=$(uci get podkop.settings.exclude_ntp 2>/dev/null)
if [ "$NTP" = "1" ]; then echo "  ✅ [2] exclude_ntp = 1"; else echo "  ❌ [2] exclude_ntp = $NTP"; fi

# 3. mixed_proxy
MIXED=$(uci get podkop.main.mixed_proxy_enabled 2>/dev/null)
if [ "$MIXED" = "0" ]; then echo "  ✅ [2] mixed_proxy_enabled = 0"; else echo "  ❌ [2] mixed_proxy_enabled = $MIXED"; fi

# 4. enable_output_network_interface
OUTPUT=$(uci get podkop.settings.enable_output_network_interface 2>/dev/null)
if [ "$OUTPUT" = "1" ]; then echo "  ✅ [2] enable_output_network_interface = 1"; else echo "  ❌ [2] enable_output_network_interface = $OUTPUT"; fi

# 5. rc.local
if grep -q tailscaled /etc/rc.local 2>/dev/null; then echo "  ✅ [3] rc.local — tailscaled"; else echo "  ❌ [3] rc.local — нет tailscaled"; fi
if grep -q 'ts-watchdog.sh &' /etc/rc.local 2>/dev/null; then echo "  ✅ [3] rc.local — watchdog в фоне"; else echo "  ⚠️ [3] rc.local — watchdog не в фоне"; fi

# 6. ts-watchdog
if [ -x /etc/ts-watchdog.sh ]; then echo "  ✅ [4] ts-watchdog.sh — установлен"; else echo "  ❌ [4] ts-watchdog.sh — отсутствует"; fi

# 7. podkop-watchdog
if [ -x /etc/podkop-watchdog.sh ]; then echo "  ✅ [5] podkop-watchdog.sh — установлен"; else echo "  ❌ [5] podkop-watchdog.sh — отсутствует"; fi

# 8. route-watchdog
if [ -x /etc/route-watchdog.sh ]; then echo "  ✅ [5] route-watchdog.sh — установлен"; else echo "  ❌ [5] route-watchdog.sh — отсутствует"; fi

# 9. crontab
if crontab -l 2>/dev/null | grep -q ts-watchdog; then echo "  ✅ [6] ts-watchdog — в crontab"; else echo "  ❌ [6] ts-watchdog — нет в crontab"; fi
if crontab -l 2>/dev/null | grep -q podkop-watchdog; then echo "  ✅ [6] podkop-watchdog — в crontab"; else echo "  ❌ [6] podkop-watchdog — нет в crontab"; fi
if crontab -l 2>/dev/null | grep -q route-watchdog; then echo "  ✅ [6] route-watchdog — в crontab"; else echo "  ❌ [6] route-watchdog — нет в crontab"; fi

# 10. firewall
FW_DEV=$(uci get firewall.@zone[0].device 2>/dev/null)
if echo "$FW_DEV" | grep -q tailscale0; then echo "  ✅ [7] tailscale0 в LAN зоне"; else echo "  ❌ [7] tailscale0 НЕ в LAN зоне"; fi

# 11. init.d/tailscale disabled
if [ -f /etc/init.d/tailscale ]; then
    if [ -f /etc/rc.d/S*tailscale ]; then echo "  ❌ [8] init.d/tailscale ВКЛЮЧЁН (должен быть DISABLED)"; else echo "  ✅ [8] init.d/tailscale DISABLED"; fi
else
    echo "  ✅ [8] init.d/tailscale не установлен"
fi

# 12. Tailscale статус
TS=$(tailscale status 2>/dev/null | head -1)
if echo "$TS" | grep -q '100\.'; then
    TS_IP=$(echo "$TS" | awk '{print $1}')
    echo "  ✅ [10] Tailscale ONLINE: $TS_IP"
else
    echo "  ⏳ [10] Tailscale поднимается..."
fi

# 13. Podkop статус
if ps | grep -q "sing-box"; then
    echo "  ✅ Podkop — запущен"
else
    echo "  ⚠️ Podkop — НЕ запущен"
fi

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  🎉 Готово!                                        ║"
echo "║  SSH через Tailscale: ssh root@<tailscale-ip>      ║"
echo "║  Watchdog проверит Tailscale каждые 2 мин           ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
