#!/bin/sh
# Tailscale + Podkop repair for OpenWrt
# Usage: sh <(wget -O - https://raw.githubusercontent.com/vasneverov/openwrt-fix/main/fix-tailscale-openwrt.sh)
#
# v3.2 — 2026-05-11 — IRON RULES COMPLIANT
# - Шаг 0: проверка что Tailscale уже онлайн → если да, ничего не делаем
# - Шаг 1: fw_mode=none
# - Шаг 2: ulimit + sysctl лимиты
# - Шаг 3: podkop настройки (exclude_ntp, mixed_proxy, enable_output, direct_domains)
# - Шаг 4: rc.local с tailscaled + watchdog
# - Шаг 5: ts-watchdog v3.1 (lock, NoState fix, podkop-fw4-fix)
# - Шаг 6: podkop-watchdog + route-watchdog
# - Шаг 7: crontab (watchdog каждые 2 мин)
# - Шаг 8: tailscale0 в LAN зону (БЕЗ firewall reload — только uci commit)
# - Шаг 9: init.d/tailscale DISABLED
# - Шаг 10: community_lists проверка
# - Шаг 11: запуск Tailscale если не онлайн
# - ФИНАЛ: прогресс-бар + отчёт с галочками

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Tailscale + Podkop Repair Tool v3.2               ║"
echo "║   IRON RULES COMPLIANT — не ломает работающий TS    ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ===== ШАГ 0: ПРОВЕРКА ЧТО НЕ НАВРЕДИМ =====
echo "━━━ [0/11] Проверка текущего состояния ━━━"
TS_ONLINE=$(tailscale status 2>/dev/null | grep -c '100\.')
if [ "$TS_ONLINE" -gt 0 ]; then
    echo "  ✅ Tailscale уже онлайн — пропускаем repair"
    echo "  ⚠️  Если нужно переустановить — сначала: killall tailscaled"
    echo ""
else
    echo "  ⏳ Tailscale не онлайн — запускаем полный repair"
fi
echo ""

# ===== ШАГ 1: fw_mode → none =====
echo "━━━ [1/11] fw_mode → none ━━━"
uci set tailscale.settings.fw_mode='none' 2>/dev/null
uci commit tailscale 2>/dev/null
echo "  ✅ fw_mode = none"
echo ""

# ===== ШАГ 2: ulimit + sysctl лимиты =====
echo "━━━ [2/11] ulimit + sysctl → увеличение лимитов ━━━"

if [ -f /etc/init.d/podkop ]; then
    if grep -q "ulimit -n" /etc/init.d/podkop; then
        echo "  ✅ ulimit уже есть в podkop init.d"
    else
        sed -i '2i ulimit -n 65535' /etc/init.d/podkop
        echo "  ✅ ulimit -n 65535 добавлен в /etc/init.d/podkop"
    fi
fi

if [ -f /etc/init.d/sing-box ]; then
    if grep -q "ulimit -n" /etc/init.d/sing-box; then
        echo "  ✅ ulimit уже есть в sing-box init.d"
    else
        sed -i '2i ulimit -n 65535' /etc/init.d/sing-box
        echo "  ✅ ulimit -n 65535 добавлен в /etc/init.d/sing-box"
    fi
fi

CURRENT_FM=$(sysctl -n fs.file-max 2>/dev/null)
if [ "$CURRENT_FM" -lt 65536 ] 2>/dev/null; then
    sysctl -w fs.file-max=65536 >/dev/null 2>&1
    if ! grep -q "fs.file-max" /etc/sysctl.conf 2>/dev/null; then
        echo "fs.file-max = 65536" >> /etc/sysctl.conf
    fi
    echo "  ✅ fs.file-max: $CURRENT_FM → 65536"
else
    echo "  ✅ fs.file-max уже $CURRENT_FM"
fi
echo ""

# ===== ШАГ 3: podkop настройки =====
echo "━━━ [3/11] Podkop: exclude_ntp, mixed_proxy, enable_output, direct_domains ━━━"
uci set podkop.settings.exclude_ntp='1' 2>/dev/null
uci set podkop.main.exclude_ntp='1' 2>/dev/null
uci set podkop.main.mixed_proxy_enabled='0' 2>/dev/null
uci set podkop.YT.mixed_proxy_enabled='0' 2>/dev/null
uci set podkop.settings.enable_output_network_interface='1' 2>/dev/null

for DOMAIN in tailscale.com controlplane.tailscale.com login.tailscale.com; do
    if ! uci show podkop.settings.direct_domains 2>/dev/null | grep -q "$DOMAIN"; then
        uci add_list podkop.settings.direct_domains="$DOMAIN"
    fi
done

uci commit podkop 2>/dev/null
echo "  ✅ exclude_ntp = 1"
echo "  ✅ mixed_proxy_enabled = 0"
echo "  ✅ enable_output_network_interface = 1"
echo "  ✅ direct_domains = tailscale.com + controlplane + login"
echo ""

# ===== ШАГ 3.5: WAN ifname (podkop использует ifname, а не device) =====
echo "━━━ [3.5/11] WAN ifname → проверка ━━━"
WAN_IFNAME=$(uci get network.wan.ifname 2>/dev/null)
if [ -z "$WAN_IFNAME" ]; then
    WAN_DEVICE=$(uci get network.wan.device 2>/dev/null)
    if [ -n "$WAN_DEVICE" ]; then
        uci set network.wan.ifname="$WAN_DEVICE"
        uci commit network
        echo "  ✅ network.wan.ifname=$WAN_DEVICE (добавлен из device)"
    else
        echo "  ⚠️ WAN device не найден, пропускаем"
    fi
else
    echo "  ✅ network.wan.ifname=$WAN_IFNAME (уже есть)"
fi
echo ""

# ===== ШАГ 4: podkop-fw4-fix.sh — nftables fix для fw4 =====
echo "━━━ [4/11] podkop-fw4-fix.sh — nftables fix для fw4 ━━━"
cat > /root/podkop-fw4-fix.sh << 'FWEOF'
#!/bin/sh
# podkop-fw4-fix.sh — добавляет правила nftables для корректной работы podkop с fw4
# Запускается после старта podkop, чтобы mangle_forward не блокировал трафик

ACTION="${1:-update}"

case "$ACTION" in
  update|add)
    for MARK in 0x00100000 0x00010000 0x00020000 0x00040000; do
      if ! nft -a list chain inet fw4 mangle_forward 2>/dev/null | grep -q "meta mark $MARK accept"; then
        nft add rule inet fw4 mangle_forward meta mark $MARK accept 2>/dev/null || true
      fi
    done
    ;;
  check)
    COUNT=$(nft list chain inet fw4 mangle_forward 2>/dev/null | grep -c 'meta mark 0x00' || echo 0)
    echo "$COUNT"
    ;;
  *)
    echo "Usage: $0 {update|add|check}"
    exit 1
    ;;
esac
FWEOF
chmod +x /root/podkop-fw4-fix.sh
/root/podkop-fw4-fix.sh update
echo "  ✅ /root/podkop-fw4-fix.sh — создан и применён"
echo ""

# Извлекаем authkey и hostname из старого rc.local ДО перезаписи
TS_AUTH_KEY=$(grep 'authkey=' /etc/rc.local 2>/dev/null | grep -o 'authkey=[^ ]*' | cut -d= -f2)
ROUTER_HOSTNAME=$(uci get system.@system[0].hostname 2>/dev/null || echo "router")
# Если authkey не найден — используем текущие параметры
[ -z "$TS_AUTH_KEY" ] && TS_AUTH_KEY=""

# ===== ШАГ 4b: rc.local — с authkey + nftables + watchdog =====
echo "━━━ [4b/11] rc.local — timeout + fw4-fix + watchdog ━━━"
cat > /etc/rc.local << RCEOF
#!/bin/sh

# === NFTABLES: Tailscale прямые маршруты ===
nft add rule inet fw4 forward ip daddr 100.64.0.0/10 counter accept 2>/dev/null
nft add rule inet fw4 forward ip daddr 192.200.0.0/24 counter accept 2>/dev/null
nft add rule inet fw4 forward ip saddr 100.64.0.0/10 counter accept 2>/dev/null

# === ОЧИСТКА СТАРОГО СОКЕТА ===
rm -f /var/run/tailscale/tailscaled.sock

# === TAILSCALE STARTUP (синхронно — без &) ===
tailscaled --statedir=/etc/tailscale/ --tun=userspace-networking >> /tmp/ts.log 2>&1 &
sleep 3
tailscale up --reset --authkey=$TS_AUTH_KEY --hostname=$ROUTER_HOSTNAME --accept-routes --accept-dns=false --netfilter-mode=off

# === fw4-fix ===
if [ -x /root/podkop-fw4-fix.sh ]; then
    /root/podkop-fw4-fix.sh update
    logger -t rc.local "podkop-fw4-fix applied"
fi

# === WATCHDOG В ФОНЕ ===
/etc/ts-watchdog.sh &

logger -t rc.local 'rc.local complete'
exit 0
RCEOF
chmod +x /etc/rc.local
cp /etc/rc.local /etc/rc.local.bak 2>/dev/null
echo "  ✅ rc.local — timeout 120s + fw4-fix + watchdog"
echo ""


# ===== ШАГ 5: ts-watchdog v3.1 =====
echo "━━━ [5/11] ts-watchdog v3.1 — единый, lock, NoState fix ━━━"
cat > /etc/ts-watchdog.sh << 'WEOF'
#!/bin/sh

# === ts-watchdog v3.1 ===
# Единый watchdog: работает и из rc.local, и из крона
# Lock-файл: не запускается дважды
# Не убивает tailscale если он уже онлайн
# NoState fix: если tailscale status выдаёт NoState — killall tailscaled + запуск заново

LOCKFILE=/tmp/ts-watchdog.lock

if [ -f "$LOCKFILE" ]; then
    LOCKPID=$(cat "$LOCKFILE" 2>/dev/null)
    if kill -0 "$LOCKPID" 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > "$LOCKFILE"

if ! ps | grep -q "tailscaled --state="; then
    logger -t ts-watchdog "tailscaled not running, restarting..."
    tailscaled --statedir=/etc/tailscale/ --tun=userspace-networking >> /tmp/ts.log 2>&1 &
    sleep 5
    tailscale up --accept-dns=false --accept-routes &
    logger -t ts-watchdog "tailscaled restarted"
    rm -f "$LOCKFILE"
    exit 0
fi

TS_STATUS=$(tailscale status 2>&1)

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

if echo "$TS_STATUS" | grep -q '100\.'; then
    if [ -x /root/podkop-fw4-fix.sh ]; then
        /root/podkop-fw4-fix.sh update 2>/dev/null
    fi
    rm -f "$LOCKFILE"
    exit 0
fi

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

# ===== ШАГ 6: podkop-watchdog + route-watchdog =====
echo "━━━ [6/11] Watchdog'ы: podkop + route ━━━"
cat > /etc/podkop-watchdog.sh << 'PEOF'
#!/bin/sh
ps | grep -q "sing-box" || /etc/init.d/podkop restart
PEOF
chmod +x /etc/podkop-watchdog.sh

cat > /etc/route-watchdog.sh << 'REOF'
#!/bin/sh
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

# ===== ШАГ 7: crontab =====
echo "━━━ [7/11] Crontab — watchdog каждые 2 мин ━━━"
(crontab -l 2>/dev/null | grep -v -E '(ts-watchdog|podkop-watchdog|route-watchdog)'
 echo "*/2 * * * * /etc/ts-watchdog.sh"
 echo "*/2 * * * * /etc/podkop-watchdog.sh"
 echo "*/2 * * * * /etc/route-watchdog.sh"
 echo "13 */3 * * * /usr/bin/podkop list_update"
) | crontab -
echo "  ✅ Crontab обновлён (3 watchdog + list_update)"
echo ""

# ===== ШАГ 8: tailscale0 в LAN зону (БЕЗ firewall reload!) =====
echo "━━━ [8/11] Firewall — tailscale0 в LAN зону ━━━"
uci set firewall.@zone[0].device='br-lan tailscale0' 2>/dev/null
uci commit firewall 2>/dev/null
echo "  ✅ tailscale0 добавлен в LAN зону (только uci commit, без reload)"
echo ""

# ===== ШАГ 9: init.d/tailscale DISABLED =====
echo "━━━ [9/11] init.d/tailscale — DISABLED ━━━"
if [ -f /etc/init.d/tailscale ]; then
    /etc/init.d/tailscale disable 2>/dev/null
    echo "  ✅ init.d/tailscale DISABLED (используем rc.local)"
else
    echo "  ✅ init.d/tailscale не найден — ОК"
fi
echo ""

# ===== ШАГ 10: community_lists проверка =====
echo "━━━ [10/11] Community lists — проверка ━━━"
PODKOP_VER=$(opkg list-installed 2>/dev/null | grep podkop | awk '{print $3}' | cut -d- -f1)
echo "  📦 Podkop версия: ${PODKOP_VER:-неизвестно}"

CURRENT_LISTS=$(uci get podkop.main.community_lists 2>/dev/null | wc -w)
echo "  📋 Текущих списков: $CURRENT_LISTS"

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

# ===== ШАГ 11: Запуск tailscale если не онлайн =====
echo "━━━ [11/11] Запуск Tailscale ━━━"
if [ "$TS_ONLINE" -eq 0 ]; then
    if ! ps | grep -q "tailscaled --state="; then
        echo "  🚀 Запуск tailscaled..."
        tailscaled --statedir=/etc/tailscale/ --tun=userspace-networking >> /tmp/ts.log 2>&1 &
        sleep 3
    fi
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

FW=$(uci get tailscale.settings.fw_mode 2>/dev/null)
[ "$FW" = "none" ] && echo "  ✅ [1] fw_mode = none" || echo "  ❌ [1] fw_mode = $FW"

NTP=$(uci get podkop.settings.exclude_ntp 2>/dev/null)
[ "$NTP" = "1" ] && echo "  ✅ [3] exclude_ntp = 1" || echo "  ❌ [3] exclude_ntp = $NTP"

MIXED=$(uci get podkop.main.mixed_proxy_enabled 2>/dev/null)
[ "$MIXED" = "0" ] && echo "  ✅ [3] mixed_proxy_enabled = 0" || echo "  ❌ [3] mixed_proxy_enabled = $MIXED"

OUTPUT=$(uci get podkop.settings.enable_output_network_interface 2>/dev/null)
[ "$OUTPUT" = "1" ] && echo "  ✅ [3] enable_output_network_interface = 1" || echo "  ❌ [3] enable_output_network_interface = $OUTPUT"

grep -q tailscaled /etc/rc.local 2>/dev/null && echo "  ✅ [4] rc.local — tailscaled" || echo "  ❌ [4] rc.local — нет tailscaled"
grep -q 'ts-watchdog.sh &' /etc/rc.local 2>/dev/null && echo "  ✅ [4] rc.local — watchdog в фоне" || echo "  ⚠️ [4] rc.local — watchdog не в фоне"

[ -x /etc/ts-watchdog.sh ] && echo "  ✅ [5] ts-watchdog.sh — установлен" || echo "  ❌ [5] ts-watchdog.sh — отсутствует"
[ -x /etc/podkop-watchdog.sh ] && echo "  ✅ [6] podkop-watchdog.sh — установлен" || echo "  ❌ [6] podkop-watchdog.sh — отсутствует"
[ -x /etc/route-watchdog.sh ] && echo "  ✅ [6] route-watchdog.sh — установлен" || echo "  ❌ [6] route-watchdog.sh — отсутствует"

crontab -l 2>/dev/null | grep -q ts-watchdog && echo "  ✅ [7] ts-watchdog — в crontab" || echo "  ❌ [7] ts-watchdog — нет в crontab"
crontab -l 2>/dev/null | grep -q podkop-watchdog && echo "  ✅ [7] podkop-watchdog — в crontab" || echo "  ❌ [7] podkop-watchdog — нет в crontab"
crontab -l 2>/dev/null | grep -q route-watchdog && echo "  ✅ [7] route-watchdog — в crontab" || echo "  ❌ [7] route-watchdog — нет в crontab"

FW_DEV=$(uci get firewall.@zone[0].device 2>/dev/null)
echo "$FW_DEV" | grep -q tailscale0 && echo "  ✅ [8] tailscale0 в LAN зоне" || echo "  ❌ [8] tailscale0 НЕ в LAN зоне"

if [ -f /etc/init.d/tailscale ]; then
    [ -f /etc/rc.d/S*tailscale ] && echo "  ❌ [9] init.d/tailscale ВКЛЮЧЁН" || echo "  ✅ [9] init.d/tailscale DISABLED"
else
    echo "  ✅ [9] init.d/tailscale не установлен"
fi

TS=$(tailscale status 2>/dev/null | head -1)
echo "$TS" | grep -q '100\.' && echo "  ✅ [11] Tailscale ONLINE: $(echo "$TS" | awk '{print $1}')" || echo "  ⏳ [11] Tailscale поднимается..."

ps | grep -q "sing-box" && echo "  ✅ Podkop — запущен" || echo "  ⚠️ Podkop — НЕ запущен"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  🎉 Готово!                                        ║"
echo "║  SSH через Tailscale: ssh root@<tailscale-ip>      ║"
echo "║  Watchdog проверит Tailscale каждые 2 мин           ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ===== ТЕСТОВАЯ ПРОВЕРКА =====
echo "━━━ ТЕСТ: direct_domains + Tailscale ━━━"
echo ""

DD_COUNT=$(uci show podkop.settings.direct_domains 2>/dev/null | grep -c 'tailscale')
[ "$DD_COUNT" -ge 3 ] && echo "  ✅ direct_domains: $DD_COUNT доменов" || echo "  ⚠️ direct_domains: только $DD_COUNT из 3"

if [ -f /tmp/ts.log ]; then
    DERP=$(tail -20 /tmp/ts.log 2>/dev/null | grep 'derp.*connected' | tail -1)
    echo "$DERP" | grep -q 'derp-' && echo "  ✅ DERP: $(echo "$DERP" | grep -o 'derp-[0-9]* connected')" || echo "  ⏳ DERP: ещё не подключён"
fi

TS_LINE=$(tailscale status 2>/dev/null | head -1)
TS_IP=$(echo "$TS_LINE" | awk '{print $1}')
TS_STATUS=$(echo "$TS_LINE" | awk '{print $4}')
if echo "$TS_LINE" | grep -q '100\.'; then
    [ "$TS_STATUS" = "-" ] || [ "$TS_STATUS" = "online" ] && echo "  ✅ Tailscale: $TS_IP — ONLINE" || echo "  ⏳ Tailscale: $TS_IP — $TS_STATUS"
else
    echo "  ⏳ Tailscale: поднимается..."
fi

CANCEL_COUNT=$(tail -50 /tmp/ts.log 2>/dev/null | grep -c 'context canceled')
[ "$CANCEL_COUNT" -eq 0 ] && echo "  ✅ Long-poll: стабилен" || echo "  ⚠️ Long-poll: $CANCEL_COUNT обрывов"

echo ""
echo "━━━ Если все ✅ — Tailscale стабилен. Если ⏳ — подожди 2 мин, watchdog доделает. ━━━"
echo ""
