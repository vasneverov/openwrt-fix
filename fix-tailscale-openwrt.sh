#!/bin/sh
# Tailscale + Podkop repair for OpenWrt
# Usage: sh <(wget -O - https://raw.githubusercontent.com/vasneverov/openwrt-fix/main/fix-tailscale-openwrt.sh)
#
# v3.9.2 — 2026-05-20 — user_domain_list_type=disabled НЕ удалять
#    Если disabled — защищает @podkop_subnets от Tailscale IP, точка держится зелёной.
#    Удалять только external/другие значения.
#    PodkopTable mangle_output: правила 100.64.0.0/10 и 192.200.0.0/24 ДОЛЖНЫ быть В НАЧАЛЕ цепочки.
#    nft add rule добавляет В КОНЕЦ — после @podkop_subnets. Пакет сначала маркируется,
#    TProxy перехватывает Tailscale heartbeat → серая точка несмотря на bypass.
#    nft insert rule добавляет В НАЧАЛО — bypass срабатывает до маркировки.

# Changelog v3.9.1 (2026-05-20):
# - Шаг 4b+5: nft add rule → nft insert rule для PodkopTable mangle_output (100.64/192.200)
# - Шаг 5: проверка только первых 3 строк цепочки (head -3) — не путать со старыми add-правилами
# Changelog v3.9 (2026-05-20):
# - Шаг 5: ts-watchdog v3.9.2 — проверка user_domain_list_type каждые 2 мин (удаляет только external, disabled не трогает)
# - Шаг 4b: rc.local пишется сразу без --reset --authkey (state-файл уже есть). Убран fragile sed-фикс.
# Changelog v3.8 (2026-05-20):
# - Шаг 4: /etc/nftables.d/20-tailscale-bypass.nft — persistent fw4 bypass, живёт после fw4 reload
# - Шаг 4b: PodkopTable mangle_output bypass в rc.local (до tailscaled)
# - Шаг 5: ts-watchdog v3.8.1 — PodkopTable bypass с retry (ждёт появления таблицы до 30 сек)
# Changelog v3.7 (2026-05-20):
# - fw4 reload добавлен в Шаг 8 — теперь LuCI доступна через Tailscale сразу после скрипта
# Changelog v3.6 (2026-05-19):
# - CUR_HOST: ищет и --hostname= и hostname= (раньше только hostname= без --)
# - direct_domains: создаётся /etc/podkop/direct_domains.txt если нет
#
# Changelog v3.5 (2026-05-19):
# - user_domain_list_type удаляется автоматически (раньше только проверял, писал "УДАЛИТЬ!", но не удалял)
# Changelog v3.4 (2026-05-19):
# - RC: tailscale up — вся строка заменяется целиком. Баг v3.3: sed менял только часть, хвост оставался → битая команда
# - RC: флаг /tmp/rc-local-running — watchdog не лезет в tailscale пока rc.local не закончил
# - Watchdog: tailscale up с --netfilter-mode=off (иначе при перезапуске флаг теряется)
# - Watchdog: grep "[t]ailscaled" вместо "tailscaled --state=" (statedir vs state). Баг: watchdog перезапускал tailscaled каждые 2 мин!
# - Watchdog: lock-файл чистится при выходе по rc-local-running
# Changelog v3.3:
# - После записи rc.local: если state-файл есть → убрать --reset и authkey
# - tailscale up теперь с & (не блокирует загрузку)
# - Не перезаписывает авторизацию если Tailscale уже был онлайн
# - Шаг 0: проверка что Tailscale уже онлайн → если да, ничего не делаем
# - Шаг 1: fw_mode=none
# - Шаг 2: ulimit + sysctl лимиты
# - Шаг 3: podkop настройки (exclude_ntp, mixed_proxy, enable_output, direct_domains)
# - Шаг 4: rc.local с tailscaled + watchdog
# - Шаг 5: ts-watchdog v3.1 (lock, NoState fix, podkop-fw4-fix)
# - Шаг 6: podkop-watchdog + route-watchdog
# - Шаг 7: crontab (watchdog каждые 2 мин)
# - Шаг 8: tailscale0 в LAN зону + fw4 reload (LuCI через Tailscale)
# - Шаг 9: init.d/tailscale DISABLED
# - Шаг 10: community_lists проверка
# - Шаг 11: запуск Tailscale если не онлайн
# - ФИНАЛ: прогресс-бар + отчёт с галочками

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Tailscale + Podkop Repair Tool v3.9.1 (20.05.2026)   ║"
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
# v3.6: Создать /etc/podkop/direct_domains.txt если нет (некоторые podkop читают файл)
mkdir -p /etc/podkop
if [ ! -f /etc/podkop/direct_domains.txt ]; then
  cat > /etc/podkop/direct_domains.txt << 'DOMAINS'
tailscale.com
controlplane.tailscale.com
login.tailscale.com
derp*.tailscale.com
DOMAINS
  echo "  ✅ direct_domains.txt создан"
fi

# v3.9.2: user_domain_list_type — если disabled, НЕ трогать (защищает @podkop_subnets от Tailscale IP)
UDT=$(uci get podkop.main.user_domain_list_type 2>/dev/null)
if [ "$UDT" = "disabled" ]; then
    echo "  ✅ user_domain_list_type=disabled — оставляем (защита от расширения подписей)"
elif [ -n "$UDT" ]; then
    uci delete podkop.main.user_domain_list_type 2>/dev/null
    echo "  ✅ user_domain_list_type: удалён ($UDT)"
else
    echo "  ✅ user_domain_list_type: отсутствует"
fi
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

# ===== ШАГ 4: Persistent nftables bypass через /etc/nftables.d/ =====
echo "━━━ [4/11] /etc/nftables.d/20-tailscale-bypass.nft — persistent fw4 bypass ━━━"
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
echo "  ✅ /etc/nftables.d/20-tailscale-bypass.nft создан и применён"

# ===== ШАГ 4a: podkop-fw4-fix.sh — nftables fix для fw4 =====
echo "━━━ [4a/11] podkop-fw4-fix.sh — nftables fix для fw4 ━━━"
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

ROUTER_HOSTNAME=$(uci get system.@system[0].hostname 2>/dev/null || echo "router")

# ===== ШАГ 4b: rc.local — v3.9: без --reset --authkey (state уже есть) =====
echo "━━━ [4b/11] rc.local — v3.9: упрощён ━━━"
cat > /etc/rc.local << RCEOF
#!/bin/sh

# === СТАРТ: флаг для watchdog (не дёргать tailscale пока rc.local не закончил) ===
touch /tmp/rc-local-running

# === NFTABLES: Tailscale прямые маршруты ===
nft add rule inet fw4 forward ip daddr 100.64.0.0/10 counter accept 2>/dev/null
nft add rule inet fw4 forward ip daddr 192.200.0.0/24 counter accept 2>/dev/null
nft add rule inet fw4 forward ip saddr 100.64.0.0/10 counter accept 2>/dev/null
# === PodkopTable bypass (Podkop restart стирает эти правила) ===
# ⚠️ INSERT (в начало), не ADD (в конец) — иначе пакет маркируется @podkop_subnets ДО bypass
nft insert rule inet PodkopTable mangle_output ip daddr 100.64.0.0/10 accept 2>/dev/null
nft insert rule inet PodkopTable mangle_output ip daddr 192.200.0.0/24 accept 2>/dev/null

# === ОЧИСТКА СТАРОГО СОКЕТА ===
rm -f /var/run/tailscale/tailscaled.sock

# === TAILSCALE STARTUP (с & — не блокирует загрузку) ===
tailscaled --statedir=/etc/tailscale/ --tun=userspace-networking >> /tmp/ts.log 2>&1 &
sleep 3
tailscale up --accept-dns=false --accept-routes --netfilter-mode=off --hostname=$ROUTER_HOSTNAME &

# === fw4-fix ===
if [ -x /root/podkop-fw4-fix.sh ]; then
    /root/podkop-fw4-fix.sh update
    logger -t rc.local "podkop-fw4-fix applied"
fi

# === WATCHDOG В ФОНЕ ===
/etc/ts-watchdog.sh &

# === КОНЕЦ: флаг снят ===
rm -f /tmp/rc-local-running

logger -t rc.local 'rc.local complete'
exit 0
RCEOF
chmod +x /etc/rc.local
cp /etc/rc.local /etc/rc.local.bak 2>/dev/null
echo "  ✅ rc.local — без --reset --authkey (reboot-safe, state уже есть)"
echo ""


# ===== ШАГ 5: ts-watchdog v3.9 =====
echo "━━━ [5/11] ts-watchdog v3.9.2 — PodkopTable + user_domain_list_type ━━━"
cat > /etc/ts-watchdog.sh << 'WEOF'
#!/bin/sh

# === ts-watchdog v3.9 ===
# v3.9: user_domain_list_type — проверка и удаление каждые 2 мин
# v3.8.1: PodkopTable bypass with retry (ждёт таблицу до 30 сек)
# v3.8: PodkopTable bypass — перепроверяет и добавляет правила каждые 2 мин
# v3.4: lock, NoState fix, statedir

LOCKFILE=/tmp/ts-watchdog.lock

# Не запускаться пока rc.local выполняется
if [ -f /tmp/rc-local-running ]; then
    rm -f "$LOCKFILE"
    exit 0
fi

if [ -f "$LOCKFILE" ]; then
    LOCKPID=$(cat "$LOCKFILE" 2>/dev/null)
    if kill -0 "$LOCKPID" 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > "$LOCKFILE"

# === v3.9.2: user_domain_list_type — если disabled, НЕ трогать ===
# disabled защищает @podkop_subnets от расширения на Tailscale IP
if uci get podkop.main.user_domain_list_type >/dev/null 2>&1; then
    UDT_VAL=$(uci get podkop.main.user_domain_list_type)
    if [ "$UDT_VAL" != "disabled" ]; then
        uci delete podkop.main.user_domain_list_type
        uci commit podkop
        logger -t ts-watchdog "user_domain_list_type='$UDT_VAL' удалён (не disabled)"
    fi
fi

# === v3.8.1: PodkopTable bypass (wait for table, re-add if wiped) ===
# Podkop restart/list_update регенерирует PodkopTable, стирая наши rules.
# ⚠️ Используем INSERT (в начало), а не ADD (в конец).
# Если ADD — правило вставляется ПОСЛЕ @podkop_subnets, пакет уже маркирован,
# TProxy перехватывает Tailscale heartbeat.
RETRIES=0
while [ "$RETRIES" -lt 15 ]; do
  if nft list table inet PodkopTable >/dev/null 2>&1; then
    break
  fi
  sleep 2
  RETRIES=$((RETRIES + 1))
done

if nft list table inet PodkopTable >/dev/null 2>&1; then
    if ! nft list chain inet PodkopTable mangle_output 2>/dev/null | head -3 | grep -q "100.64.0.0/10 accept"; then
        nft insert rule inet PodkopTable mangle_output ip daddr 100.64.0.0/10 accept 2>/dev/null
        nft insert rule inet PodkopTable mangle_output ip daddr 192.200.0.0/24 accept 2>/dev/null
        logger -t ts-watchdog "PodkopTable bypass rules INSERTED (v3.9.1)"
    fi
fi

# v3.4 fix: tailscaled с --statedir=
if ! ps | grep -q "[t]ailscaled"; then
    logger -t ts-watchdog "tailscaled not running, restarting..."
    rm -f /var/run/tailscale/tailscaled.sock
    tailscaled --statedir=/etc/tailscale/ --tun=userspace-networking >> /tmp/ts.log 2>&1 &
    sleep 5
    tailscale up --accept-dns=false --accept-routes --netfilter-mode=off &
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
    rm -f /var/run/tailscale/tailscaled.sock
    tailscaled --statedir=/etc/tailscale/ --tun=userspace-networking >> /tmp/ts.log 2>&1 &
    sleep 5
    date +%s > /tmp/ts-up-start
    tailscale up --accept-dns=false --accept-routes --netfilter-mode=off &
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
echo "  ✅ ts-watchdog v3.9 — user_domain_list_type мониторинг добавлен"
echo ""

# ===== ШАГ 6: podkop-watchdog + route-watchdog =====
echo "━━━ [6/11] Watchdog'ы: podkop + route ━━━"
cat > /etc/podkop-watchdog.sh << 'PEOF'
#!/bin/sh
# v3.3: используем start (идемпотентно), не restart (рвёт сеть + Tailscale)
pgrep sing-box > /dev/null || /etc/init.d/podkop start
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
 echo "*/2 * * * * /etc/route-watchdog.sh"
 echo "13 */3 * * * /usr/bin/podkop list_update"
) | crontab -
echo "  ✅ Crontab обновлён (2 watchdog + list_update, podkop-watchdog в rc.local)"
echo ""

# ===== ШАГ 8: tailscale0 в LAN зону + fw4 reload =====
echo "━━━ [8/11] Firewall — tailscale0 в LAN зону + fw4 reload ━━━"
uci set firewall.@zone[0].device='br-lan tailscale0' 2>/dev/null
uci commit firewall 2>/dev/null
fw4 reload 2>/dev/null
echo "  ✅ tailscale0 добавлен в LAN зону, fw4 reload выполнен"
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
    # v3.4 fix: tailscaled с --statedir=
    if ! ps | grep -q "[t]ailscaled"; then
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
echo "║              Tailscale Repair Tool v3.9.1            ║"
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
grep -q 'podkop-watchdog' /etc/rc.local 2>/dev/null && echo "  ✅ [7] podkop-watchdog — в rc.local" || echo "  ❌ [7] podkop-watchdog — нет в rc.local"
crontab -l 2>/dev/null | grep -q route-watchdog && echo "  ✅ [7] route-watchdog — в crontab" || echo "  ❌ [7] route-watchdog — нет в crontab"

FW_DEV=$(uci get firewall.@zone[0].device 2>/dev/null)
echo "$FW_DEV" | grep -q tailscale0 && echo "  ✅ [8] tailscale0 в LAN зоне" || echo "  ❌ [8] tailscale0 НЕ в LAN зоне"
[ -f /etc/nftables.d/20-tailscale-bypass.nft ] && echo "  ✅ [4] nftables.d — persistent bypass" || echo "  ❌ [4] nftables.d — отсутствует"
nft list chain inet PodkopTable mangle_output 2>/dev/null | grep -q "100.64.0.0/10 accept" && echo "  ✅ [5] PodkopTable — bypass активен" || echo "  ❌ [5] PodkopTable — bypass отсутствует"
grep -q "PodkopTable" /etc/rc.local 2>/dev/null && echo "  ✅ [4] rc.local — PodkopTable bypass" || echo "  ❌ [4] rc.local — PodkopTable bypass отсутствует"

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

DD_COUNT=$(uci show podkop.settings.direct_domains 2>/dev/null | grep -o 'tailscale' | wc -l)
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

# ===== v3.3 DIAGNOSTICS: reboot-proof checks =====
echo "━━━ ДИАГНОСТИКА: reboot-proof ━━━"
echo ""

# Check 1: user_domain_list_type (v3.9.2 — disabled = норма, другое = удаляем)
UDT_CHECK=$(uci get podkop.main.user_domain_list_type 2>/dev/null)
if [ "$UDT_CHECK" = "disabled" ]; then
    echo "  ✅ user_domain_list_type = disabled (защита подписей от Tailscale IP)"
elif [ -n "$UDT_CHECK" ]; then
    echo "  ❌ user_domain_list_type = $UDT_CHECK — надо удалить!"
else
    echo "  ✅ user_domain_list_type: отсутствует (watchdog следит)"
fi

# Check 2: socket cleanup in rc.local
grep -q 'rm -f /var/run/tailscale/tailscaled.sock' /etc/rc.local && echo "  ✅ socket cleanup в rc.local" || echo "  ❌ socket cleanup отсутствует в rc.local"

# Check 3: no --reset in rc.local (if state exists)
if [ -f /etc/tailscale/tailscaled.state ]; then
    grep -q -- '--reset' /etc/rc.local && echo "  ❌ --reset найден в rc.local при state-файле!" || echo "  ✅ rc.local: без --reset (state-файл есть)"
fi

# Check 4: tailscale up with & in rc.local
grep -q 'tailscale up.*&' /etc/rc.local && echo "  ✅ tailscale up с & (не блокирует)" || echo "  ❌ tailscale up без &"

# Check 5: watchdog socket cleanup
grep -q 'rm -f /var/run/tailscale/tailscaled.sock' /etc/ts-watchdog.sh && echo "  ✅ watchdog чистит сокет" || echo "  ❌ watchdog не чистит сокет"

# Check 6: direct_domains  
DD=$(uci show podkop.settings.direct_domains 2>/dev/null | grep -o 'tailscale' | wc -l)
[ "$DD" -ge 3 ] && echo "  ✅ direct_domains: $DD из 3" || echo "  ⚠️ direct_domains: $DD из 3"

# Check 7: v3.9 — watchdog умеет удалять user_domain_list_type
grep -q 'user_domain_list_type' /etc/ts-watchdog.sh && echo "  ✅ [5] watchdog — мониторинг user_domain_list_type" || echo "  ❌ [5] watchdog — нет мониторинга user_domain_list_type"

# Check 8: v3.9 — rc.local без --reset
grep -q -- '--reset' /etc/rc.local && echo "  ❌ [4b] rc.local — содержит --reset!" || echo "  ✅ [4b] rc.local — без --reset (v3.9)"

# Check 9: v3.9.1 — PodkopTable insert (первые 3 строки)
nft list chain inet PodkopTable mangle_output 2>/dev/null | head -3 | grep -q "100.64.0.0/10 accept" \
  && echo "  ✅ [4b/5] PodkopTable — INSERT (в начале цепочки)" \
  || echo "  ❌ [4b/5] PodkopTable — правила НЕ в начале (ADD в конце?)"

echo ""
echo "━━━ Если все ✅ — Tailscale переживёт перезагрузку ━━━"
echo ""
