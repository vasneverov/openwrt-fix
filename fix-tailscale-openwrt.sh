#!/bin/sh
# Tailscale + Podkop fix for OpenWrt
# Usage: sh <(wget -O - https://raw.githubusercontent.com/vasneverov/openwrt-fix/main/fix-tailscale-openwrt.sh)
#
# v5.0 — 2026-05-22
#   ПОЛНАЯ ПЕРЕРАБОТКА по урокам M56-26/27/28
#   - FIX: init.d DISABLED (не ENABLED!) — иначе 2 процесса → конфликт state → серая точка
#   - FIX: watchdog В CRON каждую минуту (раньше только в rc.local — недостаточно)
#   - FIX: убран DNS hack resolv.conf→127.0.0.42 (ломал DNS)
#   - FIX: убраны nftables bypass (не нужны с --netfilter-mode=off)
#   - NEW: state backup + restore логика в rc.local
#   - NEW: --hostname в tailscale up и watchdog
#   - NEW: проверка версии бинаря (нужна 1.96.5 OPX)
#   - NEW: podkop-watchdog + podkop-fix-lists в cron

HOSTNAME_VAL=$(uci get system.@system[0].hostname 2>/dev/null || hostname)

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Tailscale Fix v5.0 — 2026-05-22                   ║"
printf "║   Роутер: %-43s║\n" "$HOSTNAME_VAL"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# 1. Проверка версии бинаря
TS_VER=$(tailscale version 2>/dev/null | head -1 | awk '{print $1}')
if [ "$TS_VER" = "1.96.5" ]; then
    echo "  ✅ tailscale version: $TS_VER (OPX — правильная)"
else
    echo "  ⚠️  tailscale version: $TS_VER (нужна 1.96.5 OPX!)"
    echo "     После скрипта скопируй бинарь с Мака:"
    echo "       cat /tmp/tailscaled-196 | ssh root@192.168.5.1 'cat > /usr/sbin/tailscaled && chmod +x /usr/sbin/tailscaled'"
    echo "     Иначе после ребута точка будет серой!"
fi

# 2. fw_mode=none + autoupdate=false
uci set tailscale.settings.fw_mode='none' 2>/dev/null
uci set tailscale.settings.autoupdate='false' 2>/dev/null
uci commit tailscale 2>/dev/null
echo "  ✅ fw_mode=none, autoupdate=false"

# 3. init.d DISABLED (КРИТИЧНО — иначе 2 процесса tailscaled → конфликт state)
/etc/init.d/tailscale stop 2>/dev/null
/etc/init.d/tailscale disable 2>/dev/null
echo "  ✅ init.d/tailscale: DISABLED"

# 4. State backup
mkdir -p /etc/tailscale /var/run/tailscale
STATE_SIZE=$(wc -c < /etc/tailscale/tailscaled.state 2>/dev/null || echo 0)
if [ "$STATE_SIZE" -gt 1000 ]; then
    cp /etc/tailscale/tailscaled.state /root/tailscaled.state.backup
    echo "  ✅ state backup: $STATE_SIZE байт → /root/tailscaled.state.backup"
else
    echo "  ⚠️  state мал ($STATE_SIZE байт) — роутер не авторизован в Tailscale"
    if [ -f /root/tailscaled.state.backup ]; then
        echo "     Есть backup: $(wc -c < /root/tailscaled.state.backup) байт"
    fi
fi

# 5. rc.local — правильный (без --reset, без --authkey, с state restore)
cat > /etc/rc.local << RCEOF
#!/bin/sh
# rc.local v5.0 — 2026-05-22

# init.d disable (на случай если что-то включило)
/etc/init.d/tailscale disable 2>/dev/null

# Restore state from backup if current is small/corrupted
if [ -f /root/tailscaled.state.backup ]; then
    CURR=\$(wc -c < /etc/tailscale/tailscaled.state 2>/dev/null || echo 0)
    if [ "\$CURR" -lt 1000 ]; then
        cp /root/tailscaled.state.backup /etc/tailscale/tailscaled.state
        logger -t rc.local 'state restored from backup'
    fi
fi

# Start tailscaled (один процесс, userspace)
mkdir -p /var/run/tailscale
rm -f /var/run/tailscale/tailscaled.sock
tailscaled --statedir=/etc/tailscale/ --tun=userspace-networking >> /tmp/ts.log 2>&1 &
sleep 5

# Bring up Tailscale (saved state — NO --reset, NO --authkey)
tailscale up --accept-dns=false --accept-routes --netfilter-mode=off --hostname=$HOSTNAME_VAL &

logger -t rc.local 'Tailscale started'
exit 0
RCEOF
chmod +x /etc/rc.local
echo "  ✅ rc.local записан (hostname=$HOSTNAME_VAL, без --reset, с state restore)"

# 6. ts-watchdog v5.0
cat > /etc/ts-watchdog.sh << 'WEOF'
#!/bin/sh
# ts-watchdog v5.0 — 2026-05-22

HOSTNAME_VAL=$(uci get system.@system[0].hostname 2>/dev/null || hostname)
LOCKFILE=/tmp/ts-watchdog.lock

if [ -f "$LOCKFILE" ]; then
    LOCKPID=$(cat "$LOCKFILE" 2>/dev/null)
    if kill -0 "$LOCKPID" 2>/dev/null; then exit 0; fi
fi
echo $$ > "$LOCKFILE"

# Restore state backup if corrupted
if [ -f /root/tailscaled.state.backup ]; then
    CURR=$(wc -c < /etc/tailscale/tailscaled.state 2>/dev/null || echo 0)
    if [ "$CURR" -lt 1000 ]; then
        cp /root/tailscaled.state.backup /etc/tailscale/tailscaled.state
        logger -t ts-watchdog "state restored from backup (was $CURR bytes)"
    fi
fi

# tailscaled alive check
if ! pgrep tailscaled > /dev/null 2>&1; then
    logger -t ts-watchdog "tailscaled not running, restarting..."
    rm -f /var/run/tailscale/tailscaled.sock
    tailscaled --statedir=/etc/tailscale/ --tun=userspace-networking >> /tmp/ts.log 2>&1 &
    sleep 5
    tailscale up --accept-dns=false --accept-routes --netfilter-mode=off --hostname=$HOSTNAME_VAL &
    logger -t ts-watchdog "tailscaled restarted"
    rm -f "$LOCKFILE"
    exit 0
fi

# NoState check
TS_STATUS=$(tailscale status 2>&1)
if echo "$TS_STATUS" | grep -q "NoState"; then
    logger -t ts-watchdog "NoState detected, full restart..."
    killall tailscale 2>/dev/null; sleep 1
    killall tailscaled 2>/dev/null; sleep 2
    rm -f /var/run/tailscale/tailscaled.sock
    tailscaled --statedir=/etc/tailscale/ --tun=userspace-networking >> /tmp/ts.log 2>&1 &
    sleep 5
    tailscale up --accept-dns=false --accept-routes --netfilter-mode=off --hostname=$HOSTNAME_VAL &
    logger -t ts-watchdog "tailscaled fully restarted (NoState fix)"
fi

rm -f "$LOCKFILE"
WEOF
chmod +x /etc/ts-watchdog.sh
echo "  ✅ ts-watchdog v5.0 (pgrep, --hostname, state restore, lock)"

# 7. podkop-watchdog
cat > /etc/podkop-watchdog.sh << 'EOF'
#!/bin/sh
if ! pgrep sing-box > /dev/null 2>&1; then
    logger -t podkop-watchdog 'sing-box not running, restarting podkop'
    /etc/init.d/podkop restart
fi
EOF
chmod +x /etc/podkop-watchdog.sh
echo "  ✅ podkop-watchdog создан"

# 8. podkop-fix-lists (разблокировка GitHub CDN)
cat > /etc/podkop-fix-lists.sh << 'EOF'
#!/bin/sh
for ip in 185.199.108.133 185.199.109.133; do
    grep -q "$ip raw.githubusercontent.com" /etc/hosts 2>/dev/null || \
        echo "$ip raw.githubusercontent.com" >> /etc/hosts
done
/usr/bin/podkop list_update 2>/dev/null || true
EOF
chmod +x /etc/podkop-fix-lists.sh
echo "  ✅ podkop-fix-lists создан"

# 9. Cron — 4 задачи
(crontab -l 2>/dev/null \
    | grep -v ts-watchdog \
    | grep -v podkop-watchdog \
    | grep -v podkop-fix-lists \
    | grep -v "podkop list_update"
echo "* * * * * /etc/ts-watchdog.sh"
echo "*/2 * * * * /etc/podkop-watchdog.sh"
echo "0 * * * * /etc/podkop-fix-lists.sh --cron"
echo "13 */3 * * * /usr/bin/podkop list_update") | crontab -
echo "  ✅ Cron: ts-watchdog(1m) + podkop-watchdog(2m) + fix-lists(1h) + list_update(3h)"

# 10. podkop settings
uci set podkop.settings.exclude_ntp='1' 2>/dev/null
uci set podkop.settings.dns_server='1.1.1.1' 2>/dev/null
uci commit podkop 2>/dev/null
echo "  ✅ podkop: exclude_ntp=1, dns=1.1.1.1"

# 11. Итоговая проверка
echo ""
echo "═══════════════════════════════════════"
echo "  ИТОГ:"
echo "  hostname:   $HOSTNAME_VAL"
echo "  ts version: $(tailscale version 2>/dev/null | head -1)"
echo "  fw_mode:    $(uci get tailscale.settings.fw_mode 2>/dev/null)"
echo "  autoupdate: $(uci get tailscale.settings.autoupdate 2>/dev/null)"
echo "  init.d:     $(/etc/init.d/tailscale enabled 2>/dev/null && echo ENABLED || echo DISABLED)"
echo "  rc.local:   $(grep -q tailscaled /etc/rc.local && echo OK || echo MISSING)"
echo "  watchdogs:  $(crontab -l 2>/dev/null | grep -c watchdog)"
echo "  state:      $(wc -c < /etc/tailscale/tailscaled.state 2>/dev/null || echo 0) байт"
echo "  backup:     $(wc -c < /root/tailscaled.state.backup 2>/dev/null || echo 0) байт"
echo "  exclude_ntp:$(uci get podkop.settings.exclude_ntp 2>/dev/null)"
echo "═══════════════════════════════════════"
echo ""
if [ "$TS_VER" != "1.96.5" ]; then
    echo "  ⚠️  ВНИМАНИЕ: бинарь $TS_VER — замени на 1.96.5 OPX перед ребутом!"
    echo "     cat /tmp/tailscaled-196 | ssh root@192.168.5.1 'killall tailscaled; cat > /usr/sbin/tailscaled && chmod +x /usr/sbin/tailscaled'"
    echo ""
fi
echo "  Готово v5.0. Перезагрузи: reboot"
echo ""
