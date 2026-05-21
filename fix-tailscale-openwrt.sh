#!/bin/sh
# Tailscale + Podkop fix for OpenWrt
# Usage: sh <(wget -O - https://raw.githubusercontent.com/vasneverov/openwrt-fix/main/fix-tailscale-openwrt.sh)
#
# v4.2 — 2026-05-21
#   - NEW: resolv.conf → 127.0.0.42 (DNS fix: Podkop слушает на 127.0.0.42, не на 127.0.0.1)
#   - NEW: nftables.d/20-tailscale-bypass.nft (fw4 reload-safe bypass)
#   - FIX: проверка rc.local — не только "tailscale up", но и проверка отсутствия serve
#   - FIX: user_domain_list_type теперь УДАЛЯЕТСЯ (раньше ставился disabled, что давало серую точку)
#   - FIX: watchdog не плодит дубли nft правил (проверка перед insert + чистка при >5 копиях)
#   - fw_mode=none
#   - tcp_keepalive_time=7200
#   - nft bypass для 100.64.0.0/10 и 192.200.0.0/24 в PodkopTable
#   - rc.local с tailscaled + bypass + init.d ENABLED
#   - init.d/tailscale ENABLED (не отключать!)

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Tailscale Fix v4.2 — 2026-05-21                   ║"
echo "║   NEW: DNS fix (resolv.conf → 127.0.0.42)           ║"
echo "║   NEW: nftables.d/20-tailscale-bypass.nft           ║"
echo "║   FIX: rc.local проверка serve                      ║"
echo "║   FIX: user_domain_list_type УДАЛЯЕТСЯ               ║"
echo "║   FIX: watchdog без дублей nft                      ║"
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

# 3. user_domain_list_type — УДАЛИТЬ (не ставить disabled!)
# disabled = Podkop игнорирует direct_domains → трафик controlplane через TProxy
# пусто (отсутствует) = direct_domains работают напрямую → heartbeat стабилен
UDT=$(uci get podkop.main.user_domain_list_type 2>/dev/null)
if [ "$UDT" = "disabled" ]; then
    uci delete podkop.main.user_domain_list_type
    uci commit podkop
    echo "  ✅ user_domain_list_type: disabled → УДАЛЁН (был disabled, а надо пусто)"
elif [ -n "$UDT" ]; then
    uci delete podkop.main.user_domain_list_type
    uci commit podkop
    echo "  ✅ user_domain_list_type: $UDT → УДАЛЁН"
else
    echo "  ✅ user_domain_list_type: пусто (правильно)"
fi

# 3.5. DNS fix — Podkop слушает на 127.0.0.42, не на 127.0.0.1
# Без этого tailscaled не может резолвить controlplane.tailscale.com
# → long-poll timeout → серая точка в панели
CURRENT_DNS=$(head -1 /etc/resolv.conf 2>/dev/null)
if echo "$CURRENT_DNS" | grep -q "127.0.0.42"; then
    echo "  ✅ resolv.conf: 127.0.0.42 (уже)"
else
    echo 'nameserver 127.0.0.42' > /etc/resolv.conf
    echo 'search lan' >> /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true
    echo "  ✅ resolv.conf: $CURRENT_DNS → 127.0.0.42 (защищён chattr)"
fi

# 4. Bypass в PodkopTable (один раз)
nft insert rule inet PodkopTable mangle_output ip daddr 192.200.0.0/24 accept 2>/dev/null
nft insert rule inet PodkopTable mangle_output ip daddr 100.64.0.0/10 accept 2>/dev/null
echo "  ✅ Bypass: 192.200.0.0/24 + 100.64.0.0/10 в PodkopTable"

# 4.5. nftables.d/20-tailscale-bypass.nft (fw4 reload-safe bypass)
# Спасительный скрипт не меняет rc.local если он уже есть.
# А старый rc.local может содержать serve hook (26-ка).
# nftables.d файл переживает fw4 reload.
mkdir -p /etc/nftables.d
cat > /etc/nftables.d/20-tailscale-bypass.nft << 'NFTEOF'
## Tailscale bypass rules — survive fw4 reload
chain user_pre_forward {
    type filter hook forward priority -1; policy accept;
    ip daddr 100.64.0.0/10 accept
    ip daddr 192.200.0.0/24 accept
    ip saddr 100.64.0.0/10 accept
}
chain user_pre_output {
    type filter hook output priority -1; policy accept;
    ip daddr 100.64.0.0/10 accept
    ip daddr 192.200.0.0/24 accept
}
NFTEOF
fw4 reload 2>/dev/null
echo "  ✅ /etc/nftables.d/20-tailscale-bypass.nft создан (fw4 reload-safe)"

# 5. rc.local — усиленная проверка
if grep -q "tailscale serve\|tailscaled --state=" /etc/rc.local 2>/dev/null; then
    echo "  ⚠️ rc.local содержит serve или кривой tailscaled — ПЕРЕЗАПИСЬ"
    cat > /etc/rc.local << 'EOF'
#!/bin/sh
# DNS fix — Podkop слушает на 127.0.0.42, не на 127.0.0.1
echo "nameserver 127.0.0.42" > /etc/resolv.conf
echo "search lan" >> /etc/resolv.conf
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
    echo "  ✅ rc.local перезаписан (был serve или кривой)"
elif grep -q "tailscale up" /etc/rc.local 2>/dev/null; then
    # Проверяем, есть ли DNS fix в rc.local
    if grep -q "127.0.0.42" /etc/rc.local 2>/dev/null; then
        echo "  ✅ rc.local уже содержит tailscale up + DNS fix — оставляем"
    else
        echo "  ⚠️ rc.local есть, но без DNS fix — добавляем"
        sed -i '2i# DNS fix — Podkop слушает на 127.0.0.42, не на 127.0.0.1\necho "nameserver 127.0.0.42" > /etc/resolv.conf\necho "search lan" >> /etc/resolv.conf' /etc/rc.local
        sh -n /etc/rc.local 2>/dev/null && echo "  ✅ DNS fix добавлен в rc.local" || echo "  ❌ rc.local syntax error!"
    fi
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

# 7. watchdog
cat > /etc/ts-watchdog.sh << 'WEOF'
#!/bin/sh

# ts-watchdog v4.1 — 2026-05-21
# - UDLT-check: удаляет user_domain_list_type если Podkop восстановил
# - nft bypass: проверка наличия перед insert (не плодит дубли)
# - чистка дублей: если >5 копий правил — причесывает
# - lock, grace period, NoState fix

LOCKFILE=/tmp/ts-watchdog.lock

# Grace period — не трогать первые 3 минуты после старта
UPTIME_SEC=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)
if [ "$UPTIME_SEC" -lt 180 ] && [ -f /tmp/rc-local-running ]; then
    rm -f "$LOCKFILE"
    exit 0
fi

if [ -f "$LOCKFILE" ]; then
    LOCKPID=$(cat "$LOCKFILE" 2>/dev/null)
    if kill -0 "$LOCKPID" 2>/dev/null; then exit 0; fi
fi
echo $$ > "$LOCKFILE"

# === UDLT-check: Podkop может восстановить user_domain_list_type при list_update ===
if uci get podkop.main.user_domain_list_type >/dev/null 2>&1; then
    OLD_VAL=$(uci get podkop.main.user_domain_list_type)
    uci delete podkop.main.user_domain_list_type
    uci commit podkop
    /etc/init.d/podkop restart 2>/dev/null
    logger -t ts-watchdog "user_domain_list_type='$OLD_VAL' удалён (Podkop восстановил)"
fi

# === PodkopTable bypass — проверка + очистка дублей ===
if nft list table inet PodkopTable >/dev/null 2>&1; then
    COUNT_100=$(nft list chain inet PodkopTable mangle_output 2>/dev/null | grep -c "100.64.0.0/10 accept")
    COUNT_192=$(nft list chain inet PodkopTable mangle_output 2>/dev/null | grep -c "192.200.0.0/24 accept")

    if [ "$COUNT_100" -gt 5 ] || [ "$COUNT_192" -gt 5 ]; then
        # Слишком много дублей — почистить
        nft flush chain inet PodkopTable mangle_output 2>/dev/null
        # Восстановить оригинальные правила Podkop
        /etc/init.d/podkop restart 2>/dev/null
        sleep 2
        # Вставить поверх наши bypass
        nft insert rule inet PodkopTable mangle_output ip daddr 100.64.0.0/10 accept 2>/dev/null
        nft insert rule inet PodkopTable mangle_output ip daddr 192.200.0.0/24 accept 2>/dev/null
        logger -t ts-watchdog "PodkopTable очищен от дублей ($COUNT_100 + $COUNT_192 → 1+1)"
    elif [ "$COUNT_100" -eq 0 ]; then
        nft insert rule inet PodkopTable mangle_output ip daddr 100.64.0.0/10 accept 2>/dev/null
        nft insert rule inet PodkopTable mangle_output ip daddr 192.200.0.0/24 accept 2>/dev/null
        logger -t ts-watchdog "PodkopTable bypass rules INSERTED (были сброшены)"
    fi
fi

# === tailscaled alive check ===
if ! ps | grep -q "[t]ailscaled"; then
    logger -t ts-watchdog "tailscaled not running, restarting..."
    rm -f /var/run/tailscale/tailscaled.sock
    tailscaled --statedir=/etc/tailscale/ --tun=userspace-networking >> /tmp/ts.log 2>&1 &
    sleep 3
    tailscale up --accept-dns=false --accept-routes --netfilter-mode=off &
    logger -t ts-watchdog "tailscaled restarted"
    rm -f "$LOCKFILE"
    exit 0
fi

# === NoState check ===
TS_STATUS=$(tailscale status 2>&1)
if echo "$TS_STATUS" | grep -q "NoState"; then
    logger -t ts-watchdog "tailscaled in NoState, full restart..."
    killall tailscale 2>/dev/null
    sleep 1
    killall tailscaled 2>/dev/null
    sleep 2
    rm -f /var/run/tailscale/tailscaled.sock
    tailscaled --statedir=/etc/tailscale/ --tun=userspace-networking >> /tmp/ts.log 2>&1 &
    sleep 5
    tailscale up --accept-dns=false --accept-routes --netfilter-mode=off &
    logger -t ts-watchdog "tailscaled fully restarted (NoState fix)"
fi

rm -f "$LOCKFILE"
WEOF
chmod +x /etc/ts-watchdog.sh

(crontab -l 2>/dev/null | grep -v "ts-watchdog"; echo "*/1 * * * * /etc/ts-watchdog.sh") | sort -u | crontab -
echo "  ✅ watchdog v4.1: каждую минуту, UDLT-check + nft без дублей"

# 8. sync
sync
echo ""
echo "  ✅ Готово v4.1. Рекомендуется ребут."
echo ""
