#!/bin/sh
# Tailscale + Podkop repair for OpenWrt
# Usage: sh <(wget -O - https://raw.githubusercontent.com/vasneverov/openwrt-fix/main/fix-tailscale-openwrt.sh)
#
# v4.0 — 2026-05-20 — Чистая версия: только доказанные фиксы + watchdog
#
# Фиксы:
#   - fw_mode=none
#   - tcp_keepalive_time=7200 (чинит context canceled каждые 2 мин)
#   - user_domain_list_type=disabled (защита @podkop_subnets от Tailscale IP)
#   - init.d/tailscale disable
#   - watchdog: только перезапуск tailscaled если упал (ничего не удаляет, не перезаписывает)
#   - sync
#
# НЕ делает: rc.local, nftables.d, direct_domains, ulimit, insert/add rule

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Tailscale Repair v4.0                             ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# 1. fw_mode=none
uci set tailscale.settings.fw_mode='none' 2>/dev/null
uci commit tailscale 2>/dev/null
echo "  ✅ fw_mode = none"

# 2. tcp_keepalive_time=7200
KEEP=$(sysctl net.ipv4.tcp_keepalive_time 2>/dev/null | awk '{print $NF}')
if [ "$KEEP" != "7200" ]; then
    sysctl -w net.ipv4.tcp_keepalive_time=7200 >/dev/null 2>&1
    grep -v "tcp_keepalive_time" /etc/sysctl.conf 2>/dev/null > /tmp/sysctl.tmp
    echo "net.ipv4.tcp_keepalive_time=7200" >> /tmp/sysctl.tmp
    cp /tmp/sysctl.tmp /etc/sysctl.conf
    echo "  ✅ tcp_keepalive_time: $KEEP → 7200"
else
    echo "  ✅ tcp_keepalive_time: 7200 (уже)"
fi

# 3. user_domain_list_type=disabled
UDT=$(uci get podkop.main.user_domain_list_type 2>/dev/null)
if [ "$UDT" = "disabled" ]; then
    echo "  ✅ user_domain_list_type=disabled — оставляем"
elif [ -n "$UDT" ]; then
    uci delete podkop.main.user_domain_list_type 2>/dev/null
    uci set podkop.main.user_domain_list_type=disabled
    uci commit podkop
    echo "  ✅ user_domain_list_type: $UDT → disabled"
else
    uci set podkop.main.user_domain_list_type=disabled
    uci commit podkop
    echo "  ✅ user_domain_list_type: NOT SET → disabled"
fi

# 4. init.d/tailscale disable
if /etc/init.d/tailscale enabled 2>/dev/null; then
    /etc/init.d/tailscale disable
    echo "  ✅ init.d/tailscale: DISABLED"
else
    echo "  ✅ init.d/tailscale: уже DISABLED"
fi

# 5. watchdog — минимальный, только перезапуск tailscaled
cat > /etc/ts-watchdog.sh << 'WEOF'
#!/bin/sh
# ts-watchdog v4.0 — только перезапуск tailscaled если упал
# НЕ удаляет user_domain_list_type, НЕ добавляет nft правила, НЕ трогает rc.local

LOCKFILE=/tmp/ts-watchdog.lock
if [ -f "$LOCKFILE" ]; then
    LOCKPID=$(cat "$LOCKFILE" 2>/dev/null)
    if kill -0 "$LOCKPID" 2>/dev/null; then exit 0; fi
fi
echo $$ > "$LOCKFILE"

# Если tailscaled не запущен — перезапустить
if ! ps | grep -q "[t]ailscaled"; then
    logger -t ts-watchdog "tailscaled не запущен, перезапуск..."
    rm -f /var/run/tailscale/tailscaled.sock
    tailscaled --statedir=/etc/tailscale/ --tun=userspace-networking >> /tmp/ts.log 2>&1 &
    sleep 3
    tailscale up --accept-dns=false --accept-routes --netfilter-mode=off &
    rm -f "$LOCKFILE"
    exit 0
fi

# Проверка: если в NoState больше 5 мин — перезапустить
TS_LINE=$(tailscale status --self 2>/dev/null | head -1)
if echo "$TS_LINE" | grep -q "NoState"; then
    logger -t ts-watchdog "tailscale в NoState, перезапуск..."
    killall tailscale 2>/dev/null
    killall tailscaled 2>/dev/null
    sleep 2
    rm -f /var/run/tailscale/tailscaled.sock
    tailscaled --statedir=/etc/tailscale/ --tun=userspace-networking >> /tmp/ts.log 2>&1 &
    sleep 3
    tailscale up --accept-dns=false --accept-routes --netfilter-mode=off &
fi

rm -f "$LOCKFILE"
WEOF
chmod +x /etc/ts-watchdog.sh
echo "  ✅ ts-watchdog v4.0 — только перезапуск tailscaled"

# 6. Crontab — watchdog каждые 2 мин
(crontab -l 2>/dev/null | grep -v "ts-watchdog"; echo "*/2 * * * * /etc/ts-watchdog.sh") | sort -u | crontab -
echo "  ✅ crontab: watchdog каждые 2 мин"

# 7. sync
sync
echo ""
echo "  ✅ Готово. Ребутни роутер — точка должна держаться зелёной."
echo ""
