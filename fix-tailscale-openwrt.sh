#!/bin/sh
# Tailscale + Podkop repair for OpenWrt
# Usage: sh <(wget -O - https://raw.githubusercontent.com/USER/REPO/main/fix-tailscale-openwrt.sh)

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   Tailscale + Podkop Repair Tool     ║"
echo "╚══════════════════════════════════════╝"
echo ""

# 1. Tailscale fw_mode
echo "[1/6] fw_mode → none"
uci set tailscale.settings.fw_mode='none' 2>/dev/null
uci commit tailscale 2>/dev/null

# 2. Podkop exclude_ntp + mixed_proxy
echo "[2/6] podkop: exclude_ntp=1, mixed_proxy=0"
uci set podkop.settings.exclude_ntp='1' 2>/dev/null
uci set podkop.main.mixed_proxy_enabled='0' 2>/dev/null
uci set podkop.YT.mixed_proxy_enabled='0' 2>/dev/null
uci commit podkop 2>/dev/null

# 3. rc.local — userspace-networking + serve reset
echo "[3/6] rc.local → userspace-networking"
cat > /etc/rc.local << 'RCEOF'
#!/bin/sh
(sleep 40
  /usr/sbin/tailscaled --tun=userspace-networking --state=/etc/tailscale/tailscaled.state --statedir=/etc/tailscale/ >> /tmp/ts.log 2>&1 &
  sleep 5
  tailscale up --accept-dns=false --accept-routes
  sleep 2
  tailscale serve reset 2>/dev/null
  sleep 8
  logger -t rc.local "tailscale up applied") &
exit 0
RCEOF
chmod +x /etc/rc.local

# 4. Watchdog
echo "[4/6] watchdog → каждые 3 минуты"
cat > /etc/ts-watchdog.sh << 'WDEOF'
#!/bin/sh
RC_BACKUP="/etc/rc.local.bak"
[ -f "$RC_BACKUP" ] || cp /etc/rc.local "$RC_BACKUP"
if ! ps | grep -q "tailscaled --tun=userspace"; then
  (tailscaled --tun=userspace-networking --state=/etc/tailscale/tailscaled.state \
    --statedir=/etc/tailscale/ >> /tmp/ts.log 2>&1 &
  sleep 5
  tailscale up --accept-dns=false --accept-routes) &
fi
WDEOF
chmod +x /etc/ts-watchdog.sh
crontab -l 2>/dev/null | grep -v ts-watchdog > /tmp/ct_fix
echo "*/3 * * * * /etc/ts-watchdog.sh" >> /tmp/ct_fix
crontab /tmp/ct_fix

# 5. ttyd — rescue terminal через LuCI
echo "[5/6] ttyd → rescue terminal"
if command -v apk >/dev/null 2>&1; then
    apk add ttyd luci-app-ttyd 2>/dev/null | grep -E "Installing|already"
else
    opkg update 2>/dev/null | tail -1
    opkg install ttyd luci-app-ttyd 2>/dev/null | grep -E "Installing|already"
fi
uci delete ttyd.@ttyd[0].interface 2>/dev/null || true
uci commit ttyd 2>/dev/null
/etc/init.d/ttyd enable 2>/dev/null
/etc/init.d/ttyd restart 2>/dev/null

# 6. Перезапуск Tailscale
echo "[6/6] Tailscale → перезапуск"
/etc/init.d/tailscale disable 2>/dev/null || true
tailscale serve reset 2>/dev/null || true
OLD_PID=$(pgrep tailscaled 2>/dev/null)
[ -n "$OLD_PID" ] && tailscale down 2>/dev/null && kill "$OLD_PID" 2>/dev/null && sleep 3
tailscaled --tun=userspace-networking --state=/etc/tailscale/tailscaled.state \
  --statedir=/etc/tailscale/ >> /tmp/ts.log 2>&1 &
sleep 5
tailscale up --accept-dns=false --accept-routes 2>&1
sleep 2
tailscale serve reset 2>/dev/null

# Итог
echo ""
echo "══════════════ РЕЗУЛЬТАТ ══════════════"
echo "fw_mode:     $(uci get tailscale.settings.fw_mode 2>/dev/null || echo 'n/a')"
echo "exclude_ntp: $(uci get podkop.settings.exclude_ntp 2>/dev/null || echo 'n/a')"
echo "rc.local:    $(grep -q tailscaled /etc/rc.local && echo 'OK' || echo 'FAIL')"
echo "watchdog:    $(crontab -l 2>/dev/null | grep -q ts-watchdog && echo 'OK' || echo 'FAIL')"
echo "ttyd:        $(ps 2>/dev/null | grep -q ttyd && echo 'запущен' || echo 'не запущен')"
echo "tailscale:   $(tailscale status 2>/dev/null | head -1 || echo 'проверь вручную')"
echo "═══════════════════════════════════════"
echo ""
echo "Tailscale IP роутера:"
ip addr show tailscale0 2>/dev/null | grep "inet " | awk '{print $2}'
echo ""
echo "✅ Готово. SSH через Tailscale должен работать."
