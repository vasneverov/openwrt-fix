#!/bin/sh
# Tailscale + Podkop repair for OpenWrt
# Usage: sh <(wget -O - https://raw.githubusercontent.com/vasneverov/openwrt-fix/main/fix-tailscale-openwrt.sh)

echo ""; echo "╔══════════════════════════════════════╗"
echo "║   Tailscale + Podkop Repair Tool     ║"
echo "╚══════════════════════════════════════╝"; echo ""

echo "[1/5] fw_mode → none"
uci set tailscale.settings.fw_mode='none' 2>/dev/null
uci commit tailscale 2>/dev/null

echo "[2/5] podkop: exclude_ntp=1, mixed_proxy=0"
uci set podkop.settings.exclude_ntp='1' 2>/dev/null
uci set podkop.main.exclude_ntp='1' 2>/dev/null
uci set podkop.main.mixed_proxy_enabled='0' 2>/dev/null
uci set podkop.YT.mixed_proxy_enabled='0' 2>/dev/null
uci commit podkop 2>/dev/null

echo "[3/5] rc.local → userspace-networking"
cat > /etc/rc.local << 'RCEOF'
#!/bin/sh
(sleep 40
tailscaled --tun=userspace-networking --statedir=/etc/tailscale/ >> /tmp/ts.log 2>&1 &
sleep 5
tailscale up --accept-dns=false --accept-routes
sleep 10
logger -t rc.local "tailscale up applied") &
exit 0
RCEOF
chmod +x /etc/rc.local; cp /etc/rc.local /etc/rc.local.bak

echo "[4/5] watchdog"
cat > /etc/ts-watchdog.sh << 'WEOF'
#!/bin/sh
grep -q tailscaled /etc/rc.local 2>/dev/null || cp /etc/rc.local.bak /etc/rc.local
ps | grep -q "tailscaled --tun" || (sleep 5; tailscaled --tun=userspace-networking --statedir=/etc/tailscale/ >> /tmp/ts.log 2>&1 & sleep 5; tailscale up --accept-dns=false --accept-routes) &
WEOF
chmod +x /etc/ts-watchdog.sh
cat > /etc/podkop-watchdog.sh << 'PEOF'
#!/bin/sh
ps | grep -q "sing-box" || /etc/init.d/podkop restart
PEOF
chmod +x /etc/podkop-watchdog.sh
(crontab -l 2>/dev/null | grep -v watchdog; echo "*/3 * * * * /etc/ts-watchdog.sh"; echo "*/5 * * * * /etc/podkop-watchdog.sh") | crontab -

echo "[5/5] Tailscale → перезапуск"
/etc/init.d/tailscale disable 2>/dev/null; true
OLD=$(pgrep tailscaled 2>/dev/null); [ -n "$OLD" ] && kill "$OLD" 2>/dev/null && sleep 3
tailscaled --tun=userspace-networking --statedir=/etc/tailscale/ >> /tmp/ts.log 2>&1 &
sleep 5; tailscale up --accept-dns=false --accept-routes 2>&1

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
