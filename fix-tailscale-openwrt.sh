#!/bin/sh
# Tailscale + Podkop fix for OpenWrt
# Usage: sh <(wget -O - https://raw.githubusercontent.com/vasneverov/openwrt-fix/main/fix-tailscale-openwrt.sh)
#
# v4.0 — 2026-05-20 — СТАБИЛЬНАЯ версия
#   - fw_mode=none
#   - tcp_keepalive_time=7200
#   - user_domain_list_type=disabled
#   - nft bypass для 100.64.0.0/10 и 192.200.0.0/24 в PodkopTable
#   - rc.local с tailscaled + bypass + init.d ENABLED
#   - watchdog: перезапуск tailscaled + восстановление bypass
#   - init.d/tailscale ENABLED (не отключать!)
#   - sync

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Tailscale Fix v4.0                                ║"
echo "║   Для применения ДО установки Tailscale (шаг 5.5)   ║"
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

# 4. Bypass в PodkopTable
nft insert rule inet PodkopTable mangle_output ip daddr 192.200.0.0/24 accept 2>/dev/null
nft insert rule inet PodkopTable mangle_output ip daddr 100.64.0.0/10 accept 2>/dev/null
echo "  ✅ Bypass: 192.200.0.0/24 + 100.64.0.0/10 в PodkopTable"

# 5. rc.local — только если не содержит tailscale up
if grep -q "tailscale up" /etc/rc.local 2>/dev/null; then
    echo "  ✅ rc.local уже содержит tailscale up — оставляем"
else
    cat > /etc/rc.local << 'EOF'
#!/bin/sh
touch /tmp/rc-local-running
nft insert rule inet PodkopTable mangle_output ip daddr 192.200.0.0/24 accept 2>/dev/null
nft insert rule inet PodkopTable mangle_output ip daddr 100.64.0.0/10 accept 2>/dev/null
rm -f /var/run/tailscale/tailscaled.sock
tailscaled --statedir=/etc/tailscale/ --tun=userspace-networking >> /tmp/ts.log 2>&1 &
sleep 3
tailscale up --accept-dns=false --accept-routes --netfilter-mode=off --hostname=$(uci get system.@system[0].hostname) &
rm -f /tmp/rc-local-running
exit 0
EOF
    echo "  ✅ rc.local создан с tailscaled + bypass"
fi

# 6. init.d/tailscale ENABLED
if /etc/init.d/tailscale enabled 2>/dev/null; then
    echo "  ✅ init.d/tailscale: уже ENABLED"
else
    /etc/init.d/tailscale enable
    echo "  ✅ init.d/tailscale: включён"
fi

# 7. watchdog — перезапуск tailscaled + восстановление bypass
cat > /etc/ts-watchdog.sh << 'WEOF'
#!/bin/sh
LOCKFILE=/tmp/ts-watchdog.lock
if [ -f "$LOCKFILE" ]; then
    LOCKPID=$(cat "$LOCKFILE" 2>/dev/null)
    if kill -0 "$LOCKPID" 2>/dev/null; then exit 0; fi
fi
echo $$ > "$LOCKFILE"
if ! ps | grep -q "[t]ailscaled"; then
    rm -f /var/run/tailscale/tailscaled.sock
    tailscaled --statedir=/etc/tailscale/ --tun=userspace-networking >> /tmp/ts.log 2>&1 &
    sleep 3
    tailscale up --accept-dns=false --accept-routes --netfilter-mode=off &
fi
nft insert rule inet PodkopTable mangle_output ip daddr 192.200.0.0/24 accept 2>/dev/null
nft insert rule inet PodkopTable mangle_output ip daddr 100.64.0.0/10 accept 2>/dev/null
rm -f "$LOCKFILE"
WEOF
chmod +x /etc/ts-watchdog.sh
(crontab -l 2>/dev/null | grep -v "ts-watchdog"; echo "*/1 * * * * /etc/ts-watchdog.sh && /etc/ts-watchdog.sh") | sort -u | crontab -
echo "  ✅ watchdog: каждые 30 сек"

# 8. sync
sync
echo ""
echo "  ✅ Готово. Ребутни роутер."
echo ""
