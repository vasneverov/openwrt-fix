#!/bin/sh
# Tailscale + Podkop repair for OpenWrt — MINIMAL v4.0
# Usage: sh <(wget -O - https://raw.githubusercontent.com/vasneverov/openwrt-fix/main/fix-tailscale-openwrt.sh)
#
# v4.0 — 2026-05-20 — МИНИМАЛЬНАЯ версия. Только то что доказано:
#   - user_domain_list_type=disabled (защита @podkop_subnets от Tailscale IP)
#   - tcp_keepalive_time=7200 (чинит context canceled через 2 мин)
#   - fw_mode=none
#   - init.d/tailscale disable
#   - sync
# Ничего больше. Без rc.local, watchdog, nftables.d, direct_domains, ulimit.

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Tailscale MINIMAL Repair v4.0                     ║"
echo "║   Только то что доказано — ничего лишнего           ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# 1. fw_mode=none
uci set tailscale.settings.fw_mode='none' 2>/dev/null
uci commit tailscale 2>/dev/null
echo "  ✅ fw_mode = none"

# 2. tcp_keepalive_time=7200 (чинит context canceled каждые 2 мин)
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

# 3. user_domain_list_type=disabled (защита подписей от Tailscale IP)
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

# 5. sync
sync
echo ""
echo "  ✅ Готово. Дёргай питание, точка должна держаться зелёной."
echo ""
