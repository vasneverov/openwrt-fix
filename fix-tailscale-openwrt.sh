#!/bin/sh
# OpenWrt Router Config Fix
# Usage: sh <(wget -O - https://raw.githubusercontent.com/vasneverov/openwrt-fix/main/fix-tailscale-openwrt.sh)
#
# v5.2 — 2026-05-22
#   БЕЗОПАСНЫЙ режим: никаких перезапусков сервисов!
#   Можно запускать удалённо через SSH (в т.ч. через Tailscale) — соединение не рвётся.
#   Всё что меняется — файлы конфигов и UCI. Эффект — после следующего ребута.
#
#   Что делает:
#   - Определяет версию OpenWrt (25.x / 24.x / другая)
#   - Определяет statedir tailscale (/etc/tailscale/ или /var/lib/tailscale/)
#   - Проверяет версию tailscale (предупреждает если не 1.96.5 OPX)
#   - Сохраняет state backup (если state > 1000 байт)
#   - UCI: fw_mode=none, autoupdate=false, exclude_ntp=1, dns=1.1.1.1 (если UCI есть)
#   - init.d/tailscale DISABLED (если существует — НЕ останавливает)
#   - Пишет правильный rc.local (без --reset, с state restore, с hostname, с правильным statedir)
#   - Пишет ts-watchdog v5.2 (pgrep, NoState fix, hostname, lock, правильный statedir)
#   - Создаёт podkop-watchdog (если нет)
#   - Создаёт podkop-fix-lists / листовой скрипт (если нет)
#   - Добавляет все 4 cron задачи (если нет)
#
#   Что НЕ делает:
#   - НЕ перезапускает tailscaled
#   - НЕ перезапускает podkop
#   - НЕ меняет бинарь tailscale
#   - НЕ делает reboot

HOSTNAME_VAL=$(uci get system.@system[0].hostname 2>/dev/null || hostname)

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   OpenWrt Config Fix v5.2 — 2026-05-22              ║"
printf "║   Роутер: %-43s║\n" "$HOSTNAME_VAL"
echo "║   Режим: БЕЗОПАСНЫЙ (без перезапусков)              ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

WARNINGS=0

# ── 0. Версия OpenWrt ──────────────────────────────────────────────────────
OPENWRT_VER=$(. /etc/openwrt_release 2>/dev/null && echo "$DISTRIB_RELEASE")
[ -z "$OPENWRT_VER" ] && OPENWRT_VER="unknown"

if echo "$OPENWRT_VER" | grep -q "^25\."; then
    OPENWRT_GEN="25"
    echo "  ✅ OpenWrt: $OPENWRT_VER (25.x — полная совместимость)"
elif echo "$OPENWRT_VER" | grep -q "^24\."; then
    OPENWRT_GEN="24"
    echo "  ℹ️  OpenWrt: $OPENWRT_VER (24.x — UCI и statedir проверяются автоматически)"
else
    OPENWRT_GEN="other"
    echo "  ⚠️  OpenWrt: $OPENWRT_VER (неизвестная версия — применяем базовые настройки)"
fi

# ── 1. Tailscale бинарь — только проверка, не трогаем ──────────────────────
TS_VER=$(tailscale version 2>/dev/null | head -1 | awk '{print $1}')
if [ "$TS_VER" = "1.96.5" ]; then
    echo "  ✅ tailscale: $TS_VER (OPX — правильная версия)"
elif [ -n "$TS_VER" ]; then
    echo "  ⚠️  tailscale: $TS_VER (нужна 1.96.5 OPX — после ребута может быть серая точка)"
    echo "     Замени бинарь с Мака (пока соединение живое):"
    echo "       scp /tmp/tailscaled-196 root@ROUTER_IP:/tmp/"
    echo "       ssh root@ROUTER_IP 'cp /tmp/tailscaled-196 /usr/sbin/tailscaled && chmod +x /usr/sbin/tailscaled'"
    WARNINGS=$((WARNINGS + 1))
else
    echo "  ⚠️  tailscale: не установлен"
    WARNINGS=$((WARNINGS + 1))
fi

# ── 2. Statedir autodetect + State backup ──────────────────────────────────
# /etc/tailscale/ — persistent (overlay), переживает ребуты  ← правильно
# /var/lib/tailscale/ — tmpfs (RAM), стирается при ребуте    ← проблема
if [ -f /etc/tailscale/tailscaled.state ]; then
    TS_STATEDIR="/etc/tailscale/"
    echo "  ✅ statedir: /etc/tailscale/ (persistent)"
elif [ -f /var/lib/tailscale/tailscaled.state ]; then
    TS_STATEDIR="/var/lib/tailscale/"
    echo "  ⚠️  statedir: /var/lib/tailscale/ (RAM — state теряется при ребуте!)"
    echo "     Скрипт настроит rc.local с этим statedir, но авторизация нужна после каждого ребута."
    echo "     Лучшее решение: переустановить tailscale через GuNanOvO скрипт (использует /etc/tailscale/)."
    WARNINGS=$((WARNINGS + 1))
else
    TS_STATEDIR="/etc/tailscale/"
    echo "  ℹ️  statedir: /etc/tailscale/ (state не найден — будет создан при авторизации)"
fi

mkdir -p "$TS_STATEDIR" /var/run/tailscale

STATE_SIZE=$(wc -c < "${TS_STATEDIR}tailscaled.state" 2>/dev/null || echo 0)
if [ "$STATE_SIZE" -gt 1000 ]; then
    cp "${TS_STATEDIR}tailscaled.state" /root/tailscaled.state.backup
    echo "  ✅ state backup: $STATE_SIZE байт → /root/tailscaled.state.backup"
else
    BACKUP_SIZE=$(wc -c < /root/tailscaled.state.backup 2>/dev/null || echo 0)
    if [ "$BACKUP_SIZE" -gt 1000 ]; then
        echo "  ℹ️  state мал ($STATE_SIZE байт), backup есть: $BACKUP_SIZE байт"
    else
        echo "  ⚠️  state мал ($STATE_SIZE байт) — авторизуй tailscale и перезапусти скрипт"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# ── 3. UCI настройки ───────────────────────────────────────────────────────
# tailscale UCI — существует только если установлен GuNanOvO пакет с LuCI
if uci show tailscale 2>/dev/null | grep -q "tailscale"; then
    uci set tailscale.settings.fw_mode='none' 2>/dev/null
    uci set tailscale.settings.autoupdate='false' 2>/dev/null
    uci commit tailscale 2>/dev/null
    echo "  ✅ tailscale UCI: fw_mode=none, autoupdate=false"
else
    echo "  ℹ️  tailscale UCI: конфиг не найден (без LuCI пакета)"
    echo "     fw_mode не применяется — tailscale стартует с --netfilter-mode=off (то же самое)"
fi

uci set podkop.settings.exclude_ntp='1' 2>/dev/null
uci set podkop.settings.dns_server='1.1.1.1' 2>/dev/null
uci commit podkop 2>/dev/null
echo "  ✅ podkop UCI: exclude_ntp=1, dns=1.1.1.1"

# ── 4. init.d DISABLED (не останавливает, только убирает автостарт) ────────
if [ -f /etc/init.d/tailscale ]; then
    /etc/init.d/tailscale disable 2>/dev/null
    echo "  ✅ init.d/tailscale: DISABLED (текущий процесс не тронут)"
else
    echo "  ℹ️  init.d/tailscale: не найден (tailscale управляется через rc.local)"
fi

# ── 5. rc.local ────────────────────────────────────────────────────────────
cat > /etc/rc.local << RCEOF
#!/bin/sh
# rc.local v5.2 — 2026-05-22
# NO --reset, NO --authkey, state restore из backup
# statedir: $TS_STATEDIR (определено автоматически)

/etc/init.d/tailscale disable 2>/dev/null

if [ -f /root/tailscaled.state.backup ]; then
    CURR=\$(wc -c < ${TS_STATEDIR}tailscaled.state 2>/dev/null || echo 0)
    if [ "\$CURR" -lt 1000 ]; then
        cp /root/tailscaled.state.backup ${TS_STATEDIR}tailscaled.state
        logger -t rc.local 'state restored from backup'
    fi
fi

mkdir -p /var/run/tailscale $TS_STATEDIR
rm -f /var/run/tailscale/tailscaled.sock
tailscaled --statedir=$TS_STATEDIR --tun=userspace-networking >> /tmp/ts.log 2>&1 &
sleep 5
tailscale up --accept-dns=false --accept-routes --netfilter-mode=off --hostname=$HOSTNAME_VAL &

logger -t rc.local 'Tailscale started'
exit 0
RCEOF
chmod +x /etc/rc.local
echo "  ✅ rc.local: записан (statedir=$TS_STATEDIR, hostname=$HOSTNAME_VAL)"

# ── 6. ts-watchdog v5.2 ────────────────────────────────────────────────────
# Пишем с плейсхолдером __TS_STATEDIR__, потом sed заменяет на реальный путь
cat > /etc/ts-watchdog.sh << 'WEOF'
#!/bin/sh
# ts-watchdog v5.2 — 2026-05-22

HOSTNAME_VAL=$(uci get system.@system[0].hostname 2>/dev/null || hostname)
LOCKFILE=/tmp/ts-watchdog.lock
TS_STATEDIR="__TS_STATEDIR__"

if [ -f "$LOCKFILE" ]; then
    LOCKPID=$(cat "$LOCKFILE" 2>/dev/null)
    if kill -0 "$LOCKPID" 2>/dev/null; then exit 0; fi
fi
echo $$ > "$LOCKFILE"

# Restore state if corrupted
if [ -f /root/tailscaled.state.backup ]; then
    CURR=$(wc -c < "${TS_STATEDIR}tailscaled.state" 2>/dev/null || echo 0)
    if [ "$CURR" -lt 1000 ]; then
        cp /root/tailscaled.state.backup "${TS_STATEDIR}tailscaled.state"
        logger -t ts-watchdog "state restored (was $CURR bytes)"
    fi
fi

# tailscaled alive check
if ! pgrep tailscaled > /dev/null 2>&1; then
    logger -t ts-watchdog "tailscaled not running, restarting..."
    rm -f /var/run/tailscale/tailscaled.sock
    tailscaled --statedir="$TS_STATEDIR" --tun=userspace-networking >> /tmp/ts.log 2>&1 &
    sleep 5
    tailscale up --accept-dns=false --accept-routes --netfilter-mode=off --hostname=$HOSTNAME_VAL &
    logger -t ts-watchdog "tailscaled restarted"
    rm -f "$LOCKFILE"; exit 0
fi

# NoState check
if tailscale status 2>&1 | grep -q "NoState"; then
    logger -t ts-watchdog "NoState, full restart..."
    killall tailscale 2>/dev/null; sleep 1
    killall tailscaled 2>/dev/null; sleep 2
    rm -f /var/run/tailscale/tailscaled.sock
    tailscaled --statedir="$TS_STATEDIR" --tun=userspace-networking >> /tmp/ts.log 2>&1 &
    sleep 5
    tailscale up --accept-dns=false --accept-routes --netfilter-mode=off --hostname=$HOSTNAME_VAL &
    logger -t ts-watchdog "tailscaled restarted (NoState fix)"
fi

rm -f "$LOCKFILE"
WEOF
sed -i "s|__TS_STATEDIR__|$TS_STATEDIR|g" /etc/ts-watchdog.sh
chmod +x /etc/ts-watchdog.sh
echo "  ✅ ts-watchdog: v5.2 записан (statedir=$TS_STATEDIR)"

# ── 7. podkop-watchdog (если нет) ──────────────────────────────────────────
if [ ! -f /etc/podkop-watchdog.sh ]; then
    cat > /etc/podkop-watchdog.sh << 'EOF'
#!/bin/sh
if ! pgrep sing-box > /dev/null 2>&1; then
    logger -t podkop-watchdog 'sing-box not running, restarting podkop'
    /etc/init.d/podkop restart
fi
EOF
    chmod +x /etc/podkop-watchdog.sh
    echo "  ✅ podkop-watchdog: создан"
else
    echo "  ✅ podkop-watchdog: уже есть"
fi

# ── 8. podkop-fix-lists / листовой скрипт (если нет) ──────────────────────
if [ ! -f /etc/podkop-fix-lists.sh ]; then
    cat > /etc/podkop-fix-lists.sh << 'EOF'
#!/bin/sh
# Листовой скрипт — разблокировка GitHub CDN для podkop list_update
for ip in 185.199.108.133 185.199.109.133; do
    grep -q "$ip raw.githubusercontent.com" /etc/hosts 2>/dev/null || \
        echo "$ip raw.githubusercontent.com" >> /etc/hosts
done
/usr/bin/podkop list_update 2>/dev/null || true
EOF
    chmod +x /etc/podkop-fix-lists.sh
    echo "  ✅ podkop-fix-lists: создан (листовой скрипт)"
else
    echo "  ✅ podkop-fix-lists: уже есть"
fi

# ── 9. Cron — добавляем только отсутствующие ───────────────────────────────
CRON_CHANGED=0
CURRENT_CRON=$(crontab -l 2>/dev/null)
NEW_CRON="$CURRENT_CRON"

add_cron() {
    PATTERN="$1"; ENTRY="$2"
    if ! echo "$CURRENT_CRON" | grep -q "$PATTERN"; then
        NEW_CRON="$NEW_CRON
$ENTRY"
        CRON_CHANGED=1
        echo "  ✅ cron добавлен: $ENTRY"
    else
        echo "  ✅ cron уже есть: $PATTERN"
    fi
}

add_cron "ts-watchdog"        "* * * * * /etc/ts-watchdog.sh"
add_cron "podkop-watchdog"    "*/2 * * * * /etc/podkop-watchdog.sh"
add_cron "podkop-fix-lists"   "0 * * * * /etc/podkop-fix-lists.sh --cron"
add_cron "podkop list_update" "13 */3 * * * /usr/bin/podkop list_update"

if [ "$CRON_CHANGED" = "1" ]; then
    echo "$NEW_CRON" | grep -v "^$" | crontab -
fi

# ── 10. Итог ───────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════"
echo "  ИТОГ ($(date '+%H:%M:%S')):"
echo "  hostname:    $HOSTNAME_VAL"
echo "  OpenWrt:     $OPENWRT_VER"
echo "  statedir:    $TS_STATEDIR"
echo "  ts version:  $(tailscale version 2>/dev/null | head -1)"
echo "  ts status:   $(tailscale status 2>/dev/null | head -1 | cut -c1-40)"
echo "  fw_mode:     $(uci get tailscale.settings.fw_mode 2>/dev/null || echo 'N/A (нет UCI)')"
echo "  init.d:      $([ -f /etc/init.d/tailscale ] && (/etc/init.d/tailscale enabled 2>/dev/null && echo ENABLED || echo DISABLED) || echo 'N/A')"
echo "  rc.local:    $(grep -q tailscaled /etc/rc.local && echo OK || echo MISSING)"
echo "  watchdogs:   $(crontab -l 2>/dev/null | grep -c watchdog)"
echo "  state:       $(wc -c < "${TS_STATEDIR}tailscaled.state" 2>/dev/null || echo 0) байт"
echo "  backup:      $(wc -c < /root/tailscaled.state.backup 2>/dev/null || echo 0) байт"
echo "  exclude_ntp: $(uci get podkop.settings.exclude_ntp 2>/dev/null)"
echo "═══════════════════════════════════════════"
echo ""
if [ "$WARNINGS" -gt 0 ]; then
    echo "  ⚠️  Предупреждений: $WARNINGS — см. выше"
else
    echo "  ✅ Всё готово. Настройки применятся после: reboot"
fi
echo ""
