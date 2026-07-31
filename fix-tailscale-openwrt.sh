#!/bin/sh
# OpenWrt Router Config Fix — Universal Rescue Script
# Usage: sh <(wget -O - https://raw.githubusercontent.com/vasneverov/openwrt-fix/main/fix-tailscale-openwrt.sh)
#
# v6.2 — 2026-07-31
#   - ts-watchdog v6.3 (offline netmap timeout fix) — мигающая серая точка
#   Универсальный спасительный скрипт для роутеров с Podkop ИЛИ Forkop.
#   БЕЗОПАСНЫЙ режим: никаких перезапусков сервисов!
#   Можно запускать удалённо через SSH (в т.ч. через Tailscale) — соединение не рвётся.
#   Всё что меняется — файлы конфигов и UCI. Эффект — после следующего ребута.
#
#   Что делает:
#   - Определяет версию OpenWrt (25.x / 24.x / другая)
#   - Определяет тип VPN: podkop (itdog) ИЛИ forkop (ushan0v) — автодетект
#   - Определяет версию tailscale: 1.96.5 OPX ИЛИ 1.98.9+ GuNanOvO UPX — обе ОК
#   - Определяет statedir tailscale (/etc/tailscale/ или /var/lib/tailscale/)
#   - Сохраняет state backup (если state > 1000 байт)
#   - UCI: fw_mode=none, autoupdate=false, log_stderr/stdout=0
#   - UCI: exclude_ntp=1, dns_server (для podkop или forkop)
#   - init.d/tailscale DISABLED (если существует — НЕ останавливает)
#   - Пишет правильный rc.local (state restore, hostname, правильный statedir)
#   - Пишет ts-watchdog v6.3 (offline netmap timeout fix, NoState, state restore, lock)
#   - Создаёт VPN watchdog (podkop-watchdog.sh → /etc/init.d/podkop ИЛИ forkop)
#   - Создаёт листовой скрипт (GitHub CDN разблокировка → podkop ИЛИ forkop list_update)
#   - Создаёт hotplug: restart VPN при WAN up (30-podkop ИЛИ 30-forkop)
#   - Создаёт hotplug: restart VPN при tailscale0 up (99-vpn-tailscale)
#   - Добавляет все cron задачи (если нет)
#   - Запускает crond если не работает
#   - Урезает логи (log_size=64, conloglevel=3, cronloglevel=0)
#
#   Что НЕ делает:
#   - НЕ перезапускает tailscaled
#   - НЕ перезапускает podkop/forkop
#   - НЕ меняет бинарь tailscale
#   - НЕ делает reboot

HOSTNAME_VAL=$(uci get system.@system[0].hostname 2>/dev/null || hostname)

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   OpenWrt Config Fix v6.2 — 2026-07-31              ║"
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

# ── 0.5. Определение типа VPN: podkop ИЛИ forkop ─────────────────────────
VPN_TYPE=""
VPN_INITD=""
VPN_BIN=""
VPN_CONFIG=""

if [ -f /etc/init.d/forkop ] || [ -f /etc/config/forkop ]; then
    VPN_TYPE="forkop"
    VPN_INITD="/etc/init.d/forkop"
    VPN_BIN="/usr/bin/forkop"
    VPN_CONFIG="forkop"
    echo "  ✅ VPN: Forkop (ushan0v) — автодетект"
elif [ -f /etc/init.d/podkop ] || [ -f /etc/config/podkop ]; then
    VPN_TYPE="podkop"
    VPN_INITD="/etc/init.d/podkop"
    VPN_BIN="/usr/bin/podkop"
    VPN_CONFIG="podkop"
    echo "  ✅ VPN: Podkop (itdog) — автодетект"
else
    VPN_TYPE="none"
    echo "  ⚠️  VPN: ни podkop, ни forkop не найдены"
    WARNINGS=$((WARNINGS + 1))
fi

# ── 1. Tailscale бинарь — только проверка, не трогаем ──────────────────────
TS_VER=$(tailscale version 2>/dev/null | head -1 | awk '{print $1}')
TS_LONG=$(tailscale version 2>/dev/null | head -2 | tail -1)
if [ "$TS_VER" = "1.96.5" ]; then
    echo "  ✅ tailscale: $TS_VER (OPX — правильная версия)"
elif echo "$TS_LONG" | grep -q "OpenWrt-UPX"; then
    echo "  ✅ tailscale: $TS_VER (GuNanOvO UPX — правильная версия)"
elif [ -n "$TS_VER" ]; then
    echo "  ⚠️  tailscale: $TS_VER (нужна 1.96.5 OPX или 1.98.9+ GuNanOvO UPX)"
    echo "     Установи через apk:"
    echo "       echo 'https://gunanovo.github.io/openwrt-tailscale/aarch64_cortex-a53/packages.adb' >> /etc/apk/repositories.d/customfeeds.list"
    echo "       apk update && apk add --allow-untrusted tailscale"
    WARNINGS=$((WARNINGS + 1))
else
    echo "  ⚠️  tailscale: не установлен"
    WARNINGS=$((WARNINGS + 1))
fi

# ── 2. Statedir autodetect + State backup ──────────────────────────────────
if [ -f /etc/tailscale/tailscaled.state ]; then
    TS_STATEDIR="/etc/tailscale/"
    echo "  ✅ statedir: /etc/tailscale/ (persistent)"
elif [ -f /var/lib/tailscale/tailscaled.state ]; then
    TS_STATEDIR="/var/lib/tailscale/"
    echo "  ⚠️  statedir: /var/lib/tailscale/ (RAM — state теряется при ребуте!)"
    echo "     Скрипт настроит rc.local с этим statedir, но авторизация нужна после каждого ребута."
    echo "     Лучшее решение: переустановить tailscale через GuNanOvO apk (использует /etc/tailscale/)."
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

# ── 3. UCI настройки — Tailscale ───────────────────────────────────────────
if uci show tailscale 2>/dev/null | grep -q "tailscale"; then
    uci set tailscale.settings.fw_mode='none' 2>/dev/null
    uci set tailscale.settings.autoupdate='false' 2>/dev/null
    uci set tailscale.settings.log_stderr='0' 2>/dev/null
    uci set tailscale.settings.log_stdout='0' 2>/dev/null
    uci commit tailscale 2>/dev/null
    echo "  ✅ tailscale UCI: fw_mode=none, autoupdate=false, logs=off"
else
    echo "  ℹ️  tailscale UCI: конфиг не найден (без LuCI пакета)"
    echo "     fw_mode не применяется — tailscale стартует с --netfilter-mode=off (то же самое)"
fi

# ── 3.5. UCI настройки — VPN (podkop ИЛИ forkop) ───────────────────────────
if [ "$VPN_TYPE" != "none" ]; then
    uci set ${VPN_CONFIG}.settings.exclude_ntp='1' 2>/dev/null
    uci set ${VPN_CONFIG}.settings.dns_server='1.1.1.1' 2>/dev/null
    uci commit ${VPN_CONFIG} 2>/dev/null
    echo "  ✅ ${VPN_TYPE} UCI: exclude_ntp=1, dns=1.1.1.1"
fi

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
# rc.local v6.1 — 2026-07-25
# touch /tmp/rc-local-running — watchdog не мешает rc.local
# statedir: $TS_STATEDIR (определено автоматически)
# VPN: $VPN_TYPE (автодетект)

touch /tmp/rc-local-running
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
rm -f /tmp/rc-local-running
exit 0
RCEOF
chmod +x /etc/rc.local
echo "  ✅ rc.local: записан (statedir=$TS_STATEDIR, hostname=$HOSTNAME_VAL, vpn=$VPN_TYPE)"

# ── 6. ts-watchdog v6.3 ────────────────────────────────────────────────────
cat > /etc/ts-watchdog.sh << 'WEOF'
#!/bin/sh
# ts-watchdog v6.3 — 2026-07-31
# v6.3: перезапуск при offline (интернет есть) — netmap timeout fix.
# Мигающая серая точка: long-poll к controlplane рвётся через sing-box → tailscale
# показывает 'offline' при живом интернете. v6.3 это ловит и перезапускает.
# + Grace period 90s uptime, rc-local-running флаг, state restore, lock.

# Grace period — не трогать первые 90 сек после загрузки
UPTIME_SEC=$(cat /proc/uptime 2>/dev/null | awk '{print int($1)}')
if [ "$UPTIME_SEC" -lt 90 ]; then
  exit 0
fi

# rc.local ещё работает — не мешать
if [ -f /tmp/rc-local-running ]; then
  exit 0
fi

HOSTNAME_VAL=$(uci get system.@system[0].hostname 2>/dev/null || hostname)
LOCKFILE=/tmp/ts-watchdog.lock
TS_STATEDIR="__TS_STATEDIR__"
RC_BACKUP="/etc/rc.local.bak"

if [ -f "$LOCKFILE" ]; then
    LOCKPID=$(cat "$LOCKFILE" 2>/dev/null)
    if kill -0 "$LOCKPID" 2>/dev/null; then exit 0; fi
fi
echo $$ > "$LOCKFILE"

# rc.local восстановление
if [ ! -f "$RC_BACKUP" ]; then
    logger -t ts-watchdog "rc.local.bak не найден!"
    rm -f "$LOCKFILE"; exit 1
fi
if ! grep -q "tailscaled" /etc/rc.local 2>/dev/null; then
    cp "$RC_BACKUP" /etc/rc.local
    logger -t ts-watchdog "rc.local восстановлен"
fi

# Restore state if corrupted
if [ -f /root/tailscaled.state.backup ]; then
    CURR=$(wc -c < "${TS_STATEDIR}tailscaled.state" 2>/dev/null || echo 0)
    if [ "$CURR" -lt 1000 ]; then
        cp /root/tailscaled.state.backup "${TS_STATEDIR}tailscaled.state"
        logger -t ts-watchdog "state restored (was $CURR bytes)"
    fi
fi

restart_ts() {
    logger -t ts-watchdog "$1"
    killall tailscale 2>/dev/null; sleep 1
    killall tailscaled 2>/dev/null; sleep 2
    rm -f /var/run/tailscale/tailscaled.sock
    tailscaled --statedir="$TS_STATEDIR" --tun=userspace-networking >> /tmp/ts.log 2>&1 &
    sleep 5
    tailscale up --accept-dns=false --accept-routes --netfilter-mode=off --hostname=$HOSTNAME_VAL &
    logger -t ts-watchdog "tailscaled restarted"
}

TS_STATUS=$(tailscale status 2>&1 | head -1)

# 1. tailscaled alive check
if ! pgrep tailscaled > /dev/null 2>&1; then
    restart_ts "tailscaled not running, restarting..."
    rm -f "$LOCKFILE"; exit 0
fi

# 2. NoState check
if echo "$TS_STATUS" | grep -q "NoState"; then
    restart_ts "NoState, full restart..."
    rm -f "$LOCKFILE"; exit 0
fi

# 3. offline при живом интернете — netmap timeout (v6.3)
if echo "$TS_STATUS" | grep -q "offline"; then
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        restart_ts "offline but internet OK (netmap timeout), restarting..."
        rm -f "$LOCKFILE"; exit 0
    fi
fi

rm -f "$LOCKFILE"
WEOF
sed -i "s|__TS_STATEDIR__|$TS_STATEDIR|g" /etc/ts-watchdog.sh
chmod +x /etc/ts-watchdog.sh
echo "  ✅ ts-watchdog: v6.3 записан (statedir=$TS_STATEDIR)"

# ── 7. VPN watchdog (podkop ИЛИ forkop) ────────────────────────────────────
# Файл называется podkop-watchdog.sh для совместимости со старыми установками
# Но внутри вызывает правильный init.d
VPN_WATCHDOG_INITD="$VPN_INITD"
if [ -z "$VPN_WATCHDOG_INITD" ]; then
    # Fallback: попробовать оба
    if [ -f /etc/init.d/forkop ]; then
        VPN_WATCHDOG_INITD="/etc/init.d/forkop"
    elif [ -f /etc/init.d/podkop ]; then
        VPN_WATCHDOG_INITD="/etc/init.d/podkop"
    else
        VPN_WATCHDOG_INITD="/etc/init.d/podkop"
    fi
fi

if [ ! -f /etc/podkop-watchdog.sh ]; then
    cat > /etc/podkop-watchdog.sh << EOF
#!/bin/sh
# VPN watchdog — restarts ${VPN_TYPE} (sing-box) if down
if ! pgrep sing-box > /dev/null 2>&1; then
    logger -t ${VPN_TYPE}-watchdog 'sing-box not running, restarting ${VPN_TYPE}'
    ${VPN_WATCHDOG_INITD} restart
fi
EOF
    chmod +x /etc/podkop-watchdog.sh
    echo "  ✅ VPN watchdog: создан (${VPN_TYPE} → ${VPN_WATCHDOG_INITD})"
else
    # Проверить что watchdog ссылается на правильный init.d
    if grep -q "$VPN_WATCHDOG_INITD" /etc/podkop-watchdog.sh 2>/dev/null; then
        echo "  ✅ VPN watchdog: уже правильный (${VPN_TYPE})"
    else
        # Переписать если ссылается на старый init.d (например podkop вместо forkop)
        cat > /etc/podkop-watchdog.sh << EOF
#!/bin/sh
# VPN watchdog — restarts ${VPN_TYPE} (sing-box) if down
if ! pgrep sing-box > /dev/null 2>&1; then
    logger -t ${VPN_TYPE}-watchdog 'sing-box not running, restarting ${VPN_TYPE}'
    ${VPN_WATCHDOG_INITD} restart
fi
EOF
        chmod +x /etc/podkop-watchdog.sh
        echo "  ✅ VPN watchdog: переписан (${VPN_TYPE} → ${VPN_WATCHDOG_INITD})"
    fi
fi

# ── 8. Листовой скрипт — GitHub CDN разблокировка ─────────────────────────
VPN_LIST_BIN="$VPN_BIN"
if [ -z "$VPN_LIST_BIN" ]; then
    if [ -f /usr/bin/forkop ]; then
        VPN_LIST_BIN="/usr/bin/forkop"
    elif [ -f /usr/bin/podkop ]; then
        VPN_LIST_BIN="/usr/bin/podkop"
    else
        VPN_LIST_BIN="/usr/bin/podkop"
    fi
fi

if [ ! -f /etc/podkop-fix-lists.sh ]; then
    cat > /etc/podkop-fix-lists.sh << EOF
#!/bin/sh
# Листовой скрипт — разблокировка GitHub CDN для ${VPN_TYPE} list_update
for ip in 185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133; do
    grep -q "\$ip raw.githubusercontent.com" /etc/hosts 2>/dev/null || \\
        echo "\$ip raw.githubusercontent.com" >> /etc/hosts
done
${VPN_LIST_BIN} list_update 2>/dev/null || true
EOF
    chmod +x /etc/podkop-fix-lists.sh
    echo "  ✅ листовой скрипт: создан (${VPN_TYPE} → ${VPN_LIST_BIN})"
else
    # Проверить что скрипт ссылается на правильный бинарь
    if grep -q "$VPN_LIST_BIN" /etc/podkop-fix-lists.sh 2>/dev/null; then
        echo "  ✅ листовой скрипт: уже правильный (${VPN_TYPE})"
    else
        cat > /etc/podkop-fix-lists.sh << EOF
#!/bin/sh
# Листовой скрипт — разблокировка GitHub CDN для ${VPN_TYPE} list_update
for ip in 185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133; do
    grep -q "\$ip raw.githubusercontent.com" /etc/hosts 2>/dev/null || \\
        echo "\$ip raw.githubusercontent.com" >> /etc/hosts
done
${VPN_LIST_BIN} list_update 2>/dev/null || true
EOF
        chmod +x /etc/podkop-fix-lists.sh
        echo "  ✅ листовой скрипт: переписан (${VPN_TYPE} → ${VPN_LIST_BIN})"
    fi
fi

# ── 8.5. Hotplug: restart VPN при WAN up ─────────────────────────────────
mkdir -p /etc/hotplug.d/iface

# Удалить старый 30-podkop если есть и заменить на универсальный
rm -f /etc/hotplug.d/iface/30-podkop 2>/dev/null
rm -f /etc/hotplug.d/iface/30-forkop 2>/dev/null

if [ "$VPN_TYPE" != "none" ]; then
    cat > /etc/hotplug.d/iface/30-vpn << HOTEOF
#!/bin/sh
# Hotplug: restart ${VPN_TYPE} при WAN up
[ "\$ACTION" = "ifup" ] && [ "\$INTERFACE" = "wan" ] && {
  logger -t hotplug 'WAN up — restarting ${VPN_TYPE}'
  sleep 5
  ${VPN_INITD} restart
}
HOTEOF
    chmod +x /etc/hotplug.d/iface/30-vpn
    echo "  ✅ hotplug 30-vpn: создан (${VPN_TYPE} → WAN up)"
else
    echo "  ℹ️  hotplug 30-vpn: пропущен (VPN не найден)"
fi

# ── 8.6. Hotplug: restart VPN при tailscale0 up ───────────────────────────
mkdir -p /etc/hotplug.d/net

# Удалить старые hotplug скрипты
rm -f /etc/hotplug.d/net/99-podkop-tailscale 2>/dev/null
rm -f /etc/hotplug.d/net/99-forkop-tailscale 2>/dev/null

if [ "$VPN_TYPE" != "none" ]; then
    cat > /etc/hotplug.d/net/99-vpn-tailscale << HOTNET
#!/bin/sh
# Hotplug: restart ${VPN_TYPE} после tailscale0
[ "\$ACTION" = "add" ] || exit 0
[ "\$INTERFACE" = "tailscale0" ] || exit 0
(sleep 30; ${VPN_INITD} restart) &
HOTNET
    chmod +x /etc/hotplug.d/net/99-vpn-tailscale
    echo "  ✅ hotplug 99-vpn-tailscale: создан (${VPN_TYPE})"
else
    echo "  ℹ️  hotplug 99-vpn-tailscale: пропущен (VPN не найден)"
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

# Удалить stale cron entries (бинари которых не существует)
if [ -n "$CURRENT_CRON" ]; then
    CLEANED_CRON=""
    echo "$CURRENT_CRON" | while IFS= read -r line; do
        # Пропустить пустые строки
        [ -z "$line" ] && continue
        # Проверить бинарь в cron строке
        CRON_BIN=$(echo "$line" | grep -oE '/usr/bin/[a-z]+' | head -1)
        if [ -n "$CRON_BIN" ] && [ ! -f "$CRON_BIN" ]; then
            echo "  🧹 cron удалён (бинарь не найден): $line"
            continue
        fi
        echo "$line"
    done > /tmp/cron-cleaned
    CLEANED=$(cat /tmp/cron-cleaned)
    rm -f /tmp/cron-cleaned
    if [ "$CLEANED" != "$CURRENT_CRON" ]; then
        CURRENT_CRON="$CLEANED"
        NEW_CRON="$CLEANED"
        CRON_CHANGED=1
    fi
fi

add_cron "ts-watchdog"        "* * * * * /etc/ts-watchdog.sh"
add_cron "podkop-watchdog"    "*/2 * * * * /etc/podkop-watchdog.sh"
add_cron "podkop-fix-lists"   "0 * * * * /etc/podkop-fix-lists.sh --cron"

# VPN list_update — только если бинарь существует
if [ -n "$VPN_BIN" ] && [ -f "$VPN_BIN" ]; then
    add_cron "${VPN_TYPE} list_update" "13 */3 * * * ${VPN_BIN} list_update"
fi

if [ "$CRON_CHANGED" = "1" ]; then
    echo "$NEW_CRON" | grep -v "^$" | crontab -
fi

# ── 9.5. crond — запустить если не работает ────────────────────────────────
if ! pgrep crond > /dev/null 2>&1; then
    /etc/init.d/cron enable 2>/dev/null
    /etc/init.d/cron start 2>/dev/null
    sleep 1
    if ! pgrep crond > /dev/null 2>&1; then
        # Fallback: busybox crond напрямую
        crond -c /etc/crontabs 2>/dev/null &
        sleep 1
    fi
    if pgrep crond > /dev/null 2>&1; then
        echo "  ✅ crond: запущен"
    else
        echo "  ⚠️  crond: не удалось запустить"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo "  ✅ crond: уже работает"
fi

# ── 9.6. Урезать логи (экономия RAM) ─────────────────────────────────────
uci set system.@system[0].log_size='64' 2>/dev/null
uci set system.@system[0].conloglevel='3' 2>/dev/null
uci set system.@system[0].cronloglevel='0' 2>/dev/null
uci commit system 2>/dev/null
echo "  ✅ логи: log_size=64, conloglevel=3, cronloglevel=0"

# ── 9.7. Московское время + NTP ───────────────────────────────────────
uci set system.@system[0].timezone='MSK-3' 2>/dev/null
uci set system.@system[0].zonename='Europe/Moscow' 2>/dev/null
uci set system.ntp=timeserver 2>/dev/null
uci delete system.ntp.server 2>/dev/null
uci add_list system.ntp.server='0.openwrt.pool.ntp.org' 2>/dev/null
uci add_list system.ntp.server='1.openwrt.pool.ntp.org' 2>/dev/null
uci add_list system.ntp.server='2.openwrt.pool.ntp.org' 2>/dev/null
uci add_list system.ntp.server='3.openwrt.pool.ntp.org' 2>/dev/null
uci set system.ntp.enabled='1' 2>/dev/null
uci set system.ntp.enable_server='0' 2>/dev/null
uci commit system 2>/dev/null
echo "  ✅ время: MSK-3, Europe/Moscow + NTP servers"

# ── 9.8. HTTPS→HTTP fix для apk (DPI режет HTTPS) ──────────────────────
sed -i 's|https://|http://|g' /etc/apk/repositories.d/distfeeds.list 2>/dev/null
sed -i 's|https://|http://|g' /etc/apk/repositories.d/customfeeds.list 2>/dev/null
cat > /etc/uci-defaults/99-apk-http-fix << 'APKFIX'
#!/bin/sh
sed -i 's|https://|http://|g' /etc/apk/repositories.d/distfeeds.list 2>/dev/null
sed -i 's|https://|http://|g' /etc/apk/repositories.d/customfeeds.list 2>/dev/null
exit 0
APKFIX
chmod +x /etc/uci-defaults/99-apk-http-fix
echo "  ✅ apk: HTTPS→HTTP (DPI fix + uci-defaults)"

# ── 10. Итог ───────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════"
echo "  ИТОГ ($(date '+%H:%M:%S')):"
echo "  hostname:    $HOSTNAME_VAL"
echo "  OpenWrt:     $OPENWRT_VER"
echo "  VPN:         ${VPN_TYPE:-none}"
echo "  statedir:    $TS_STATEDIR"
echo "  ts version:  $(tailscale version 2>/dev/null | head -1)"
echo "  ts status:   $(tailscale status 2>/dev/null | head -1 | cut -c1-40)"
echo "  fw_mode:     $(uci get tailscale.settings.fw_mode 2>/dev/null || echo 'N/A (нет UCI)')"
echo "  init.d:      $([ -f /etc/init.d/tailscale ] && (/etc/init.d/tailscale enabled 2>/dev/null && echo ENABLED || echo DISABLED) || echo 'N/A')"
echo "  rc.local:    $(grep -q tailscaled /etc/rc.local && echo OK || echo MISSING)"
echo "  rc.local.bak: $(ls /etc/rc.local.bak >/dev/null 2>&1 && echo OK || echo MISSING)"
echo "  ts-watchdog: $(crontab -l 2>/dev/null | grep -c ts-watchdog) cron"
echo "  vpn-watchdog:$(crontab -l 2>/dev/null | grep -c podkop-watchdog) cron"
echo "  fix-lists:   $(crontab -l 2>/dev/null | grep -c podkop-fix-lists) cron"
echo "  hotplug WAN: $(ls /etc/hotplug.d/iface/30-vpn >/dev/null 2>&1 && echo OK || echo MISSING)"
echo "  hotplug TS:  $(ls /etc/hotplug.d/net/99-vpn-tailscale >/dev/null 2>&1 && echo OK || echo MISSING)"
echo "  crond:       $(pgrep crond >/dev/null 2>&1 && echo running || echo NOT running)"
echo "  state:       $(wc -c < "${TS_STATEDIR}tailscaled.state" 2>/dev/null || echo 0) байт"
echo "  backup:      $(wc -c < /root/tailscaled.state.backup 2>/dev/null || echo 0) байт"
echo "  exclude_ntp: $(uci get ${VPN_CONFIG}.settings.exclude_ntp 2>/dev/null || echo 'N/A')"
echo "  sing-box:    $(pgrep sing-box >/dev/null 2>&1 && echo running || echo NOT running)"
echo "═══════════════════════════════════════════"
echo ""
if [ "$WARNINGS" -gt 0 ]; then
    echo "  ⚠️  Предупреждений: $WARNINGS — см. выше"
else
    echo "  ✅ Всё готово. Настройки применятся после: reboot"
fi
echo ""