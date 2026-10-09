#!/bin/sh
# OpenWrt Router Config Fix — Universal Rescue Script
# Usage: sh <(wget -O - https://raw.githubusercontent.com/vasneverov/openwrt-fix/main/fix-tailscale-openwrt.sh)
#
# v7.6 — 2026-10-09: +3.8 БЕЗОПАСНОСТЬ ДОСТУПА (dropbear MaxAuthTries 3→6 + IdleTimeout 120 — бан на 3 опечатках
#        вырубал SSH/LuCI; нашёл при ночном разборе z56-68: «SSH и LuCI пропали и вернулись сами»);
#        +5.95 ЧИСТКА СЛЕДОВ (мои диагностические .log/w*.sh из /tmp, cron w*.sh — иначе диагностика копится);
#        +ПРОВЕРКА: недопустимый nft-перехват DNS на LAN (redirect :53/iifname br-lan) — рубит LuCI/rpcd.
#        ⚠️ СТОП-ФАКТ: НЕ импровизировать nft-перехват DNS + DoT/DoH-отказ (убивает доступ; QUIC-блок — ок).
# v7.5 — 2026-10-08: +5.9 «часы при загрузке» (P1 NTP по IP, P2 hotplug ntp 30-ts-sync, P3 rc.local ждёт NTP) — Tailscale на загрузке Running ~24 с вместо ~107 с (s78-39-karpin).
# v7.4 — 2026-10-03  «ЭТАЛОН 03.10» + ЩИТ TAILSCALE (v7.4: `opkg update`/`apk update` перед установкой zram — без него на opkg-роутерах zram не ставился) (всё, что накоплено с 07.09 по 03.10.2026)
#   Принцип: файлы эталона ставятся ТОЛЬКО если установленная версия СТАРШЕ (новее/равное не трогаем,
#   бэкап заменённого — /root/rescue-v7-<дата>/). Без перезапусков сервисов и без ребута.
#   Для вступления форкоп-правок в силу: RESTART=1 sh <(wget ...)  → ОДИН forkop restart в конце.
#   - ts-watchdog v6.6 (oom_score_adj -900, ловит «failed to connect to local tailscaled», autoupdate off после
#     рестарта, --hostname без «_»), forkop-watchdog v2.1 (грейс 180 с после загрузки, не рестартует при идущем
#     init.d, LAN из uci), hotplug 30-vpn v2 (рестарт форкопа на ifup wan только при аптайме >=150 с),
#     сторож доменов v3 (ИИ-домены ТОЛЬКО в секции ai, кино ТОЛЬКО в kino), безопасные fix-lists.
#   - ИИ (ChatGPT/Claude/Claude Code): секция ai ПЕРВОЙ в списке секций + ИИ-домены убираются из main
#     (иначе правило main с IP-диапазонами Cloudflare перехватывает claude.ai/chatgpt.com и Cloudflare
#     блокирует выход NL/PL: «Sorry, you have been blocked»). В конце — проверка выхода по cdn-cgi/trace.
#   - rc.local: НЕ переписывается целиком — точечно: userspace-networking, oom_score_adj -900, autoupdate off
#     после загрузки, hostname без «_» (свои строки роутера сохраняются).
#   - дубли: podkop-watchdog.sh/podkop-fix-lists.sh (forkop), hotplug 30-forkop и 99-vpn-tailscale, init.d/*.bak,
#     дубли cron, автозапуск S80tailscale — убираются (в бэкап, не удаляются).
#   - zram-swap (если нет и хватает места), пояс Europe/Moscow (zonename), filter_aaaa по версии sing-box
#     (>=1.13: 1, иначе удалить), единый список GitHub-CDN в hosts.
#   - ⛔ ЖЕЛЕЗНОЕ ПРАВИЛО (03.10.2026): Tailscale НЕ ломать НИКАКИМИ правками. Демон tailscaled не останавливается/не перезапускается,
#     `tailscale up/down`, `/etc/init.d/tailscale stop|restart`, kill — НЕ вызываются. «Щит Tailscale» в конце: если TS был Running, а потом нет —
#     через 80 с автооткат всех файлов этого запуска из бэкапа + вызов ts-watchdog. Ребут не делается никогда.
#   - НЕ делает: не создаёт секции ai/kino и подписки (нужны ключи/подписки владельца — см. подсказку в конце),
#     не трогает tailscaled/режим Tailscale на лету, не ребутит.
#
# v6.7 — 2026-09-07: эталон форкопа — urltest «Самый лучший», sort_by_latency, badwan, meta первый, domain WhatsApp.
# v6.6 — 2026-08-27: REBIND-ФИКС dnsmasq (fakeip 198.18.x режется). v6.5 — мёртвый dhcp_option (fakeip-DNS клиентам).
# v6.4 — все GitHub-CDN в hosts, update_interval 1h. v6.3 — jsDelivr-зеркало + DoH. v6.1 — apk HTTP, MSK, NTP.
#
#   Универсальный спасительный скрипт для роутеров с Podkop ИЛИ Forkop (автодетект).
#   БЕЗОПАСНЫЙ режим: никаких перезапусков сервисов! Можно запускать удалённо через SSH/Tailscale.
HOSTNAME_VAL=$(uci get system.@system[0].hostname 2>/dev/null || hostname)

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   OpenWrt Config Fix v7.6 — 2026-10-09              ║"
printf "║   Роутер: %-43s║\n" "$HOSTNAME_VAL"
echo "║   Режим: БЕЗОПАСНЫЙ (без перезапусков)              ║"
echo "╚══════════════════════════════════════════════════════╝"
TSNAME=$(tailscale status --self --peers=false 2>/dev/null | awk 'NR==1{print $2}')
echo "  🏷  Имя в панели Tailscale: ${TSNAME:-неизвестно}  (hostname OpenWrt: $HOSTNAME_VAL)"
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
    [ -z "$(uci -q get ${VPN_CONFIG}.settings.dns_server)" ] && uci set ${VPN_CONFIG}.settings.dns_server='1.1.1.1' 2>/dev/null
    uci set ${VPN_CONFIG}.settings.update_interval='1h' 2>/dev/null
    uci commit ${VPN_CONFIG} 2>/dev/null
    echo "  ✅ ${VPN_TYPE} UCI: exclude_ntp=1, dns_server (если не задан), update_interval=1h"
fi

# ── 3.6. ЭТАЛОН ФОРКОПА (07.09.2026) — вдохнуть жизнь в сервисы на старом роутере ──
# Дополняет базовый фикс наработками 29.08-07.09, без которых форкоп выглядит
# «всё 000 / не работает» даже при живом sing-box (уроки 66-smazilkina, tr30_22, S78-42):
#   - urltest «Самый лучший» + sort_by_latency=1 (галочка «сортировать по задержке»)
#     → форкоп выбирает лучший узел. БЕЗ НИХ «Самый лучший» не работает → «всё 000»,
#     а я ошибочно винил провайдера (корень был в неполном эталоне).
#   - badwan = мониторинг WAN-интерфейса (наработка 06.09) — перезапуск при флапе WAN.
#   - meta ПЕРВЫМ в community_lists (правило 29.08) — иначе Meta/WhatsApp падают.
#   - domain = WhatsApp+IG (если пусто/мусор expedia) — WhatsApp-улучшители.
#   - resolve_real_ip_for_routing=0.
#   - число подписок (эталон 2-3: pl6+play2nl5+pl3ip) — если 1, добавить (урок tr30_22).
if [ "$VPN_TYPE" = "forkop" ]; then
    echo "  ── Эталон форкопа (07.09) ──"
    # 1) urltest «Самый лучший» (если нет ни «Самый лучший», ни «Лучший»)
    URTEST_NAME="Самый лучший"
    HAS_MAIN_UT=$(uci show forkop 2>/dev/null | grep -cE "^forkop\.@urltest\[[0-9]+\]\.section='main'")
    if [ "$HAS_MAIN_UT" -eq 0 ]; then
        uci add forkop urltest
        uci set forkop.@urltest[-1].section='main'
        uci set forkop.@urltest[-1].name='Самый лучший'
        uci set forkop.@urltest[-1].check_interval='30s'
        uci set forkop.@urltest[-1].tolerance='100'
        uci set forkop.@urltest[-1].testing_url='https://captive.apple.com'
        uci set forkop.@urltest[-1].idle_timeout='30m'
        uci set forkop.@urltest[-1].interrupt_exist_connections='0'
        uci set forkop.@urltest[-1].pin_dashboard='1'
        uci set forkop.@urltest[-1].filter_mode='disabled'
        echo "  ✅ urltest «Самый лучший»: создан"
    else
        echo "  ✅ urltest main: уже есть ($HAS_MAIN_UT шт.)"
    fi
    # 2) sort_by_latency=1 (галочка «сортировать по задержке»)
    uci set forkop.main.sort_by_latency='1'
    echo "  ✅ sort_by_latency=1 (галочка «сортировать по задержке»)"
    # 3) badwan — мониторинг WAN-интерфейса (наработка 06.09)
    uci set forkop.settings.enable_badwan_interface_monitoring='1'
    uci -q delete forkop.settings.badwan_monitored_interfaces
    uci add_list forkop.settings.badwan_monitored_interfaces='wan'
    echo "  ✅ badwan: мониторинг WAN-интерфейса включён (wan)"
    # 4) resolve_real_ip_for_routing=0
    uci set forkop.settings.resolve_real_ip_for_routing='0'
    echo "  ✅ resolve_real_ip_for_routing=0"
    # 5) meta ПЕРВЫМ в community_lists (правило 29.08)
    FIRST=$(uci get forkop.main.community_lists 2>/dev/null | awk '{print $1}')
    if [ "$FIRST" != "meta" ]; then
        echo "  ⚠️ meta НЕ первый (был '$FIRST') — перестраиваю список с meta первым"
        uci -q delete forkop.main.community_lists
        for l in meta geoblock block telegram youtube discord porn news anime twitter hdrezka tiktok cloudflare google_ai google_play hodca roblox supercell github hetzner ovh digitalocean cloudfront; do
            uci add_list forkop.main.community_lists=$l
        done
        echo "  ✅ meta первый, списки перестроены (23)"
    else
        echo "  ✅ meta первый (правильно)"
    fi
    # 6) domain = WhatsApp+IG (если пусто/нет whatsapp; клиентские домены сохраняются)
    DOM=$(uci get forkop.main.domain 2>/dev/null)
    if ! echo "$DOM" | grep -q whatsapp; then
        uci set forkop.main.domain='whatsapp.com whatsapp.net whatsapp.org wa.me instagram.com cdninstagram.com fbcdn.net'
        echo "  ✅ domain: WhatsApp+IG установлены (был: '${DOM:-пусто}')"
    else
        echo "  ✅ domain: WhatsApp есть (сохранён, клиентские домены не тронуты)"
    fi
    # 7) число подписок (эталон 2-3: pl6+play2nl5+pl3ip)
    SUBCOUNT=$(uci show forkop 2>/dev/null | grep -c '\.url=')
    if [ "$SUBCOUNT" -lt 2 ]; then
        echo "  ⚠️ подписок $SUBCOUNT (эталон 2-3) — мало узлов, добавь pl6+play2nl5 (см. скилл)"
    else
        echo "  ✅ подписок: $SUBCOUNT"
    fi
    uci commit forkop 2>/dev/null
fi

# ── 3.7. AutoUpdate tailscale OFF (Check:false + update-check) ──────────────
AUC=$(tailscale debug prefs 2>/dev/null | grep -A2 AutoUpdate | grep Check | tr -d ' \t"' 2>/dev/null)
if [ "$AUC" != "false" ]; then
    tailscale set --auto-update=false --update-check=false 2>/dev/null
    echo "  ✅ tailscale AutoUpdate: выключен (Check:false)"
else
    echo "  ✅ tailscale AutoUpdate: Check:false (уже)"
fi

# ── 3.8. БЕЗОПАСНОСТЬ ДОСТУПА: dropbear MaxAuthTries 3→6 + IdleTimeout 120 (09.10.2026, z56-68) ──
#   Причина «SSH и LuCI пропали и вернулись сами»: dropbear рубит соединение на 3-й неудачной попытке
#   («Max auth tries reached»). При плотной работе/медленном пути (DERP-релей) заходы обрывались на 3 фейлах
#   → доступ пропадал на 20-30с. Ставим 6 попыток и IdleTimeout 120 (сессия не рвётся). Идемпотентно.
if [ -f /etc/config/dropbear ] && uci -q show dropbear.main >/dev/null 2>&1; then
    _mt=$(uci -q get dropbear.main.MaxAuthTries); _it=$(uci -q get dropbear.main.IdleTimeout)
    if [ "$_mt" != "6" ] || [ "$_it" != "120" ]; then
        uci set dropbear.main.MaxAuthTries='6' 2>/dev/null
        uci set dropbear.main.IdleTimeout='120' 2>/dev/null
        uci commit dropbear 2>/dev/null
        /etc/init.d/dropbear restart >/dev/null 2>&1
        _i=0; while [ $_i -lt 10 ]; do _i=$((_i+1)); nc -z -w2 127.0.0.1 22 2>/dev/null && break; done
        fixed "dropbear: MaxAuthTries=6, IdleTimeout=120 (бан на 3 опечатках больше не вырубит SSH/LuCI)"
    else
        echo "  ✅ dropbear: MaxAuthTries=6, IdleTimeout=120 (уже эталон)"
    fi
else
    echo "  ℹ️  dropbear UCI не найден — пропущено"
fi

# ── 4. init.d/tailscale: НЕ отключаем здесь (v7.4, железное №1) ───────────────────────────
#   Автозапуск init.d снимается ТОЛЬКО в 5.1 и ТОЛЬКО если в rc.local есть настоящая строка запуска tailscaled
#   (иначе после перезагрузки Tailscale не поднимется). Ребут-тест на удалённых запрещён — способ запуска не меняем вслепую.
if [ -f /etc/init.d/tailscale ]; then
    echo "  ℹ️  init.d/tailscale: $(/etc/init.d/tailscale enabled 2>/dev/null && echo 'enabled' || echo 'disabled') (решение — в 5.1)"
else
    echo "  ℹ️  init.d/tailscale: не найден (tailscale управляется через rc.local)"
fi

# ── 4.9. Помощники отчёта и снимок «ДО» ───────────────────────────────────────────
rm -f /tmp/v7.fixed /tmp/v7.issues
fixed() { echo "$1" >> /tmp/v7.fixed; echo "  ✅ $1"; }
warn()  { WARNINGS=$((WARNINGS + 1)); echo "$1" >> /tmp/v7.issues; echo "  ⚠️  $1"; }
mk() { [ "$1" = "1" ] && printf '✅' || printf '❌'; }
snapshot() { # $1 = метка
    echo ""
    echo "  ┌── $1 ──────────────────────────────────────────────"
    _BR=opkg; command -v apk >/dev/null 2>&1 && _BR=apk
    _SB=$(sing-box version 2>/dev/null | head -1 | awk '{print $3}')
    echo "  │ OpenWrt $OPENWRT_VER · пакеты: $_BR · аптайм $(( $(cut -d. -f1 /proc/uptime) / 86400 ))д · LAN $(uci -q get network.lan.ipaddr) · пояс $(uci -q get system.@system[0].zonename)"
    echo "  │ sing-box ${_SB:-нет} · tailscale $(tailscale version 2>/dev/null | head -1) · $(tailscale status --json 2>/dev/null | grep -m1 BackendState | cut -d'"' -f4)"
    _TUN=$(ps 2>/dev/null | grep '[t]ailscaled' | grep -o 'tun=[a-z0-9-]*' | head -1)
    echo "  │ режим Tailscale (запущенный демон): ${_TUN:-?} · в rc.local: $(grep -o 'tun=[a-z0-9-]*' /etc/rc.local 2>/dev/null | head -1)"
    if [ "$VPN_TYPE" = "forkop" ]; then
        _SEC=$(uci show forkop 2>/dev/null | grep -E '=section$' | cut -d. -f2 | cut -d= -f1 | tr '
' ' ')
        _FIRST=$(uci show forkop 2>/dev/null | grep -E '=section$' | head -1 | cut -d= -f1)
        echo "  │ forkop: $(/etc/init.d/forkop status 2>&1 | head -1) · секции по порядку: ${_SEC}"
        for _S in main kino ai; do echo "  │   подписок $_S: $(uci show forkop 2>/dev/null | grep -cE "subscription_url\[[0-9]+\]\.section='$_S'")  urltest: $(uci show forkop 2>/dev/null | grep -cE "^forkop\.@urltest\[[0-9]+\]\.section='$_S'")"; done
        echo "  │ $(mk $([ "$(uci -q get forkop.ai)" = section ] && echo 1 || echo 0)) секция ai есть   $(mk $([ "$_FIRST" = forkop.ai ] && echo 1 || echo 0)) ai ПЕРВАЯ   $(mk $([ "$(uci -q get forkop.kino)" = section ] && echo 1 || echo 0)) секция kino есть"
        echo "  │ $(mk $([ "$(uci -q get forkop.main.domain | tr ' ' '
' | grep -cE 'anthropic|claude|openai|chatgpt|sora')" = 0 ] && echo 1 || echo 0)) ИИ-доменов в main нет   $(mk $(grep -q 'guard.sh v3' /etc/forkop-domain-guard.sh 2>/dev/null && echo 1 || echo 0)) сторож доменов v3   $(mk $(grep -q 'boot grace' /etc/forkop-watchdog.sh 2>/dev/null && echo 1 || echo 0)) сторож форкопа v2.1"
    fi
    echo "  │ $(mk $(grep -q 'ts-watchdog v6.6' /etc/ts-watchdog.sh 2>/dev/null && echo 1 || echo 0)) ts-watchdog v6.6   $(mk $(grep -q uptime /etc/hotplug.d/iface/30-vpn 2>/dev/null && echo 1 || echo 0)) hotplug 30-vpn v2   $(mk $([ "$(ls /etc/hotplug.d/iface 2>/dev/null | grep -c '^30-')" = 1 ] && echo 1 || echo 0)) один hotplug 30-*   $(mk $(grep -q zram /proc/swaps 2>/dev/null && echo 1 || echo 0)) zram"
    _RS=$(grep -v '^[[:space:]]*#' /etc/rc.local 2>/dev/null | grep -cE 'tailscaled[[:space:]].*--(state|statedir|tun)|init\.d/tailscale[[:space:]]+(start|restart)'); _IE=0; /etc/init.d/tailscale enabled 2>/dev/null && _IE=1
    if [ "$_RS" = "0" ]; then echo "  │ запуск Tailscale: в rc.local строки нет · init.d enabled: $(mk $_IE) $([ "$_IE" = 1 ] && echo '(запуск через init.d — норма, способ не меняем)' || echo '(НИКТО не запускает при загрузке — см. 5.1)')   $(mk $(tailscale debug prefs 2>/dev/null | grep -A2 AutoUpdate | tr -d ' \t\n' | grep -q '"Check":false' && echo 1 || echo 0)) TS autoupdate выключен"
    else echo "  │ $(mk $(grep -q userspace-networking /etc/rc.local 2>/dev/null && echo 1 || echo 0)) rc.local: userspace   $(mk $(grep -q oom_score_adj /etc/rc.local 2>/dev/null && echo 1 || echo 0)) oom -900   $(mk $(grep -q 'auto-update=false' /etc/rc.local 2>/dev/null && echo 1 || echo 0)) autoupdate off   $(mk $(tailscale debug prefs 2>/dev/null | grep -A2 AutoUpdate | tr -d ' \t\n' | grep -q '"Check":false' && echo 1 || echo 0)) TS autoupdate выключен"; fi
    echo "  │ cron: ts-watchdog $(crontab -l 2>/dev/null | grep -c ts-watchdog) · сторож форкопа $(crontab -l 2>/dev/null | grep -cE 'forkop-watchdog|podkop-watchdog') · guard $(crontab -l 2>/dev/null | grep -c forkop-domain-guard) · fix-lists $(crontab -l 2>/dev/null | grep -cE 'forkop-fix-lists|podkop-fix-lists')   (по 1 — норма)"
    echo "  └──────────────────────────────────────────────────────────"
}
snapshot "СОСТОЯНИЕ ДО"
TS_BEFORE=$(tailscale status --json 2>/dev/null | grep -m1 BackendState | cut -d'"' -f4)
TS_PID0=$(pgrep tailscaled | tr '
' ' ')
echo "  🛡  ЩИТ TAILSCALE: до правок статус=${TS_BEFORE:-?} pid=${TS_PID0:-нет} (демон не трогаем; при провале — автооткат)"
ts_shield_restore() { # вернуть файлы этого запуска из $BAK
    for f in "$BAK"/_*; do
        [ -e "$f" ] || continue
        n=$(basename "$f"); case "$n" in *.removed) dest=$(echo "${n%.removed}" | tr _ /);; *) dest=$(echo "$n" | tr _ /);; esac
        cp -p "$f" "$dest" 2>/dev/null && echo "     ↩ $dest"
    done
    [ -f "$BAK/rc.local" ] && cp -p "$BAK/rc.local" /etc/rc.local && echo "     ↩ /etc/rc.local"
    [ -s "$BAK/crontab.before" ] && crontab "$BAK/crontab.before" && echo "     ↩ crontab"
}

# ── 5. ЭТАЛОН-ФАЙЛЫ v7.0 (03.10.2026): ставим ТОЛЬКО если версия старее ───────────────
BAK=/root/rescue-v7-$(date +%Y%m%d-%H%M%S); mkdir -p "$BAK"
FK_CHANGED=0
put() { # put DEST SRC MARKER — установить эталон, если в DEST нет MARKER (бэкап старого)
    DEST="$1"; SRC="$2"; MARK="$3"
    if [ -f "$DEST" ] && grep -q "$MARK" "$DEST" 2>/dev/null; then
        echo "  ✅ $DEST: уже эталон ($MARK)"; rm -f "$SRC"; return
    fi
    if ! sh -n "$SRC" 2>/dev/null; then
        warn "$DEST: синтаксис эталона не прошёл — файл НЕ тронут"; rm -f "$SRC"; return
    fi
    [ -f "$DEST" ] && cp -p "$DEST" "$BAK/$(echo "$DEST" | tr / _)"
    cat "$SRC" > "$DEST" && chmod +x "$DEST" && fixed "$DEST: обновлён до эталона ($MARK)"
    rm -f "$SRC"
}
stash() { # stash FILE — убрать лишний файл в бэкап (не удалять)
    [ -e "$1" ] || return
    mv "$1" "$BAK/$(echo "$1" | tr / _).removed" 2>/dev/null && fixed "убран дубль: $1 (в $BAK)"
}

# 5.1 rc.local — ТОЧЕЧНО, правка считается сделанной ТОЛЬКО если файл реально изменился (v7.4)
RC=${V7_RC:-/etc/rc.local}
HN=$(uci get system.@system[0].hostname 2>/dev/null || hostname)
HN=$(echo "$HN" | tr '_' '-' | tr 'A-Z' 'a-z')
real_start() { grep -v '^[[:space:]]*#' "$1" 2>/dev/null | grep -cE 'tailscaled[[:space:]].*--(state|statedir|tun)'; }
rc_fix() {
    [ -f "$RC" ] || printf '#!/bin/sh\nexit 0\n' > "$RC"
    REALSTART=$(real_start "$RC")
    INITD_EN=0; /etc/init.d/tailscale enabled 2>/dev/null && INITD_EN=1
    cp -p "$RC" "$BAK/rc.local" 2>/dev/null
    if [ "$REALSTART" = "0" ]; then
        if [ "$(grep -v '^[[:space:]]*#' "$RC" | grep -cE 'init\.d/tailscale[[:space:]]+(start|restart)')" -gt 0 ]; then
            echo "  ✅ rc.local: запускает Tailscale командой init.d/tailscale start — НЕ трогаю (второй стартер не добавляю)"
            return
        fi
        if [ "$INITD_EN" = "1" ]; then
            echo "  ✅ rc.local: запуск Tailscale идёт через init.d (enabled) — rc.local и автозапуск НЕ трогаю (способ запуска вслепую не меняем)"
            return
        fi
        # ни rc.local, ни init.d не запускают Tailscale → добавляем эталонный блок перед первым exit 0; чужие строки сохраняются
        cat > /tmp/rc.blk << RCEOF
# --- Tailscale (v7.4, эталон: userspace, oom -900, autoupdate off, hostname без "_") ---
touch /tmp/rc-local-running
(
for i in 1 2 3 4 5 6 7 8 9 10; do
  ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && break
  sleep 3
done
mkdir -p /var/run/tailscale ${TS_STATEDIR}
tailscaled --state=${TS_STATEDIR}tailscaled.state --tun=userspace-networking --statedir=${TS_STATEDIR} >> /tmp/ts.log 2>&1 &
sleep 5
for p in \$(pgrep tailscaled); do echo -900 > /proc/\$p/oom_score_adj 2>/dev/null; done   # OOM protection
tailscale up --accept-dns=false --accept-routes --netfilter-mode=off --hostname=$HN &
( sleep 25; tailscale set --auto-update=false --update-check=false >/dev/null 2>&1 ) &   # autoupdate off after boot
sleep 10
rm -f /tmp/rc-local-running
) &
RCEOF
        if grep -q '^exit 0' "$RC"; then awk 'FNR==NR{blk=blk $0 "\n"; next} !d && /^exit 0/ {printf "%s", blk; d=1} {print}' /tmp/rc.blk "$RC" > /tmp/rc.new; else { cat "$RC"; cat /tmp/rc.blk; echo "exit 0"; } > /tmp/rc.new; fi
        if sh -n /tmp/rc.new && [ "$(real_start /tmp/rc.new)" -gt 0 ]; then cat /tmp/rc.new > "$RC"; chmod +x "$RC"; fixed "rc.local: добавлен запуск Tailscale (не было ни в rc.local, ни в init.d), свои строки сохранены"; else warn "rc.local: блок запуска не прошёл проверку — НЕ записан"; fi
        rm -f /tmp/rc.blk /tmp/rc.new; return
    fi
    # есть настоящая строка запуска — точечные правки
    cp "$RC" /tmp/rc.new
    sed -i 's/--tun=tailscale0/--tun=userspace-networking/g' /tmp/rc.new
    if ! grep -q 'oom_score_adj' /tmp/rc.new; then
        awk '{print} !d && /tailscaled/ && /--(state|statedir|tun)/ && !/^[[:space:]]*#/ {print "sleep 1; for p in $(pgrep tailscaled); do echo -900 > /proc/$p/oom_score_adj 2>/dev/null; done   # OOM protection"; d=1}' /tmp/rc.new > /tmp/rc.new2 && cat /tmp/rc.new2 > /tmp/rc.new; rm -f /tmp/rc.new2
    fi
    if ! grep -q 'auto-update=false' /tmp/rc.new; then
        awk '{print} !d && /tailscale up / && !/tailscaled/ && !/^[[:space:]]*#/ {print "( sleep 25; tailscale set --auto-update=false --update-check=false >/dev/null 2>&1 ) &   # autoupdate off after boot"; d=1}' /tmp/rc.new > /tmp/rc.new2 && cat /tmp/rc.new2 > /tmp/rc.new; rm -f /tmp/rc.new2
    fi
    HNOLD=$(grep -o -e '--hostname=[^ ]*' /tmp/rc.new | head -1)
    if echo "$HNOLD" | grep -q '[_A-Z]'; then HNNEW=$(echo "$HNOLD" | tr '_' '-' | tr 'A-Z' 'a-z'); sed -i "s|$HNOLD|$HNNEW|g" /tmp/rc.new; fi
    if cmp -s /tmp/rc.new "$RC"; then
        echo "  ✅ rc.local: уже эталон (userspace, oom, autoupdate off)"
        grep -q 'oom_score_adj' "$RC" || warn "rc.local: нет защиты от OOM, а строку запуска автоматически вставить не удалось (нестандартный формат) — поправить вручную"
    else
        if sh -n /tmp/rc.new && [ "$(real_start /tmp/rc.new)" -gt 0 ]; then
            DIFFTXT=""
            grep -q 'oom_score_adj' "$RC" || { grep -q 'oom_score_adj' /tmp/rc.new && DIFFTXT="$DIFFTXT +oom_score_adj"; }
            grep -q 'auto-update=false' "$RC" || { grep -q 'auto-update=false' /tmp/rc.new && DIFFTXT="$DIFFTXT +autoupdate_off"; }
            grep -q 'tun=tailscale0' "$RC" && DIFFTXT="$DIFFTXT tun0→userspace"
            cat /tmp/rc.new > "$RC"; chmod +x "$RC"; fixed "rc.local: точечно исправлен:${DIFFTXT:- hostname}"
        else warn "rc.local: после правки проверка не прошла — НЕ записан"; fi
    fi
    rm -f /tmp/rc.new
}
rc_fix
# rc.local.bak нужен сторожу ts-watchdog v6.6 (иначе он выходит с «rc.local.bak не найден»)
if [ "$(real_start "$RC")" -gt 0 ]; then
    if [ ! -f /etc/rc.local.bak ] || [ "$(real_start /etc/rc.local.bak)" = "0" ]; then cp -p "$RC" /etc/rc.local.bak && fixed "rc.local.bak создан/обновлён (нужен сторожу Tailscale)"; fi
else
    [ -f /etc/rc.local.bak ] || { cp -p "$RC" /etc/rc.local.bak 2>/dev/null; echo "  ℹ️  rc.local.bak создан (запуск Tailscale — через init.d)"; }
fi

# 5.2 ts-watchdog v6.6
cat > /tmp/v7.tswd << 'V7_TSWD'
#!/bin/sh
# ts-watchdog v6.6 — 02.10.2026: tailscale up --hostname sanitized (tailscale 1.102.x rejects "_" in DNS labels: VasyaOnline_NN)
# ts-watchdog v6.5 — 02.10.2026: +oom_score_adj=-900 for tailscaled (boot memory peak OOM-killed tailscaled on 233 MB routers)
# ts-watchdog v6.4 — 02.10.2026: +wedged-daemon check, +AutoUpdate re-off after restart (CLI cannot reach tailscaled after network reload / forkop restart)
# ts-watchdog v6.3 — 2026-07-31 · restart_ts per etalon (setsid+socket) 01.10.2026
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
TS_STATEDIR="/etc/tailscale/"
RC_BACKUP="/etc/rc.local.bak"

if [ -f "$LOCKFILE" ]; then
    LOCKPID=$(cat "$LOCKFILE" 2>/dev/null)
    if kill -0 "$LOCKPID" 2>/dev/null; then exit 0; fi
fi
echo $$ > "$LOCKFILE"
# v6.5: keep tailscaled away from the OOM killer (idempotent, every run)
for p in $(pgrep tailscaled 2>/dev/null); do echo -900 > /proc/$p/oom_score_adj 2>/dev/null; done

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
    mkdir -p /var/run/tailscale
    rm -f /var/run/tailscale/tailscaled.sock
    setsid tailscaled --state="${TS_STATEDIR}tailscaled.state" --statedir="$TS_STATEDIR" \
      --tun=userspace-networking --socket=/var/run/tailscale/tailscaled.sock >> /tmp/ts.log 2>&1 &
    sleep 8
    tailscale up --accept-dns=false --accept-routes --netfilter-mode=off --hostname=$(echo "$HOSTNAME_VAL" | tr "_" "-" | tr "A-Z" "a-z") >> /tmp/ts.log 2>&1 &
    ( sleep 20; tailscale set --auto-update=false --update-check=false >/dev/null 2>&1 ) &   # v6.4: tailscale up resets AutoUpdate to default
    for p in $(pgrep tailscaled 2>/dev/null); do echo -900 > /proc/$p/oom_score_adj 2>/dev/null; done
    logger -t ts-watchdog "tailscaled restarted"
}

TS_STATUS=$(tailscale status --self=true --peers=false 2>&1 | head -1)

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

# 2b. v6.4: tailscaled process alive but CLI cannot reach it (wedged after wifi/network reload or forkop restart)
if echo "$TS_STATUS" | grep -q "failed to connect to local tailscaled"; then
    restart_ts "daemon wedged (CLI cannot connect), restarting..."
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
V7_TSWD
put /etc/ts-watchdog.sh /tmp/v7.tswd 'ts-watchdog v6.6'

# 5.3 forkop-часть (для podkop — только предупреждение: podkop устарел, мигрировать на forkop)
if [ "$VPN_TYPE" = "forkop" ]; then
cat > /tmp/v7.fkwd << 'V7_FKWD'
#!/bin/sh
# forkop-watchdog v2.1 — СТОРОЖ-ДИАГНОСТ «зелёный форкоп, но клиенты мимо туннеля»
# Проверяет ГЛАВНУЮ болезнь x46-29 (30.09.2026): клиенты получают РЕАЛЬНЫЙ IP вместо fakeip.
# Ставить: /etc/forkop-watchdog.sh + cron */5
# Логика: тихо, если всё ок. Кричит — если клиентский DNS не отдаёт fakeip.
# v2.1 (02.10.2026): LAN IP from uci (the 192.168.5.1 default made the watchdog misfire on routers with another LAN: it "healed" by cutting inet6_range out of the generator -> AAAA hang on sing-box 1.12)
LAN_IP="${1:-$(uci -q get network.lan.ipaddr | cut -d/ -f1)}"; [ -z "$LAN_IP" ] && LAN_IP=192.168.5.1
LOG="/tmp/forkop-watchdog.log"

# v2 (02.10.2026): boot grace + no overlapping restarts + restart cooldown.
# A forkop start takes 50-60 s (running=0 / dns_configured=0 meanwhile): the old watchdog restarted it DURING its own start
# (restart cascade after reboot, 2-3 min to stable; 36 stuck init.d restarts seen on s78-18).
UP=$(cut -d. -f1 /proc/uptime 2>/dev/null)
[ "${UP:-0}" -lt 180 ] && exit 0                       # boot grace
ps 2>/dev/null | grep -q "[i]nit.d/forkop" && exit 0   # a start/restart is already in progress
CD=/tmp/forkop-wd.last; NOW=$(date +%s)
wd_restart(){ if [ -f $CD ] && [ $((NOW-$(cat $CD 2>/dev/null || echo 0))) -lt 180 ]; then exit 0; fi; echo $NOW > $CD; /etc/init.d/forkop restart >/dev/null 2>&1 & }

# 1) форкоп жив?
ST=$(/usr/bin/forkop get_status 2>/dev/null)
RUN=$(echo "$ST" | grep -o '"running": [0-9]*' | grep -o '[0-9]')
DNS=$(echo "$ST" | grep -o '"dns_configured": [0-9]*' | grep -o '[0-9]')
if [ "$RUN" != "1" ] || [ "$DNS" != "1" ]; then
  logger -t forkop-watchdog "ФОРКОП НЕ РАБОТАЕТ: running=$RUN dns=$DNS — restarting"
  wd_restart
  exit 0
fi

# 2) ГЛАВНОЕ: клиент получает fakeip? (это была причина 5 часов мучений)
FIP=$(dig +short +time=3 +tries=1 www.youtube.com @$LAN_IP 2>/dev/null | head -1)
case "$FIP" in
  198.18.*|198.19.*)
    : # ОК — fakeip раздаётся клиентам
    ;;
  *)
    # 🔴 БОЛЕЗНЬ: клиенты получают реальный IP → мимо туннеля
    logger -t forkop-watchdog "🔴 КЛИЕНТЫ ПОЛУЧАЮТ РЕАЛЬНЫЙ IP ($FIP) — не fakeip! ЛЕЧУ"
    echo "$(date '+%F %T') БОЛЕЗНЬ: $LAN_IP отдал $FIP вместо fakeip" >> $LOG
    # ЛЕЧЕНИЕ №1: конфликт /etc/dnsmasq.conf (главная причина!)
    if grep -qE "^server=" /etc/dnsmasq.conf 2>/dev/null; then
      echo "$(date '+%F %T') ЛЕЧУ: чищу server= из /etc/dnsmasq.conf" >> $LOG
      sed -i "/^server=/d; /^no-resolv/d" /etc/dnsmasq.conf
      /etc/init.d/dnsmasq restart >/dev/null 2>&1
    fi
    # ЛЕЧЕНИЕ №2: uci-настройка dnsmasq
    SRV=$(uci get dhcp.@dnsmasq[0].server 2>/dev/null | tr -d ' ')
    if [ "$SRV" != "127.0.0.42" ]; then
      echo "$(date '+%F %T') ЛЕЧУ: uci server → 127.0.0.42" >> $LOG
      uci set dhcp.@dnsmasq[0].server='127.0.0.42'
      uci set dhcp.@dnsmasq[0].noresolv='1'
      uci commit dhcp
      /etc/init.d/dnsmasq restart >/dev/null 2>&1
    fi
    # ЛЕЧЕНИЕ №3: sing-box не отвечает на 42
    if ! dig +short +time=3 kino.watch @127.0.0.42 >/dev/null 2>&1; then
      echo "$(date '+%F %T') ЛЕЧУ: sing-box не отвечает на 42 — forkop restart" >> $LOG
      wd_restart
    fi
    ;;
esac

SBM=$(sing-box version 2>/dev/null | head -1 | awk '{print $3}' | cut -d. -f2)   # generator surgery only on sing-box >= 1.13
# 3) IPv6-fakeip вернулся? (ломает браузер, возвращается после reinstall)
AAAA=$(nslookup -type=AAAA -timeout=4 kino.watch 127.0.0.42 2>/dev/null | grep -c 'fc00')
if [ "$AAAA" -gt 0 ] && [ "${SBM:-0}" -ge 13 ]; then
  logger -t forkop-watchdog "🔴 IPv6-fakeip fc00 ВЕРНУЛСЯ — правлю генератор"
  echo "$(date '+%F %T') БОЛЕЗНЬ: AAAA отдаёт fc00 ($AAAA) — правлю" >> $LOG
  G=/usr/lib/forkop/singbox/generator.uc
  LN=$(grep -n "inet6_range" $G 2>/dev/null | head -1 | cut -d: -f1)
  if [ -n "$LN" ]; then
    cp $G /root/generator.uc.wd-bak.$(date +%H%M) 2>/dev/null
    sed -i "$((LN-1))s/, *$//" $G && sed -i "${LN}d" $G
  fi
  sed -i 's/, *"inet6_range": *"fc00::\/18"//' /etc/sing-box/config.json 2>/dev/null
  wd_restart
fi

# 4) конфликт /etc/dnsmasq.conf (проверка независимо от резолва)
if grep -qE "^server=" /etc/dnsmasq.conf 2>/dev/null; then
  logger -t forkop-watchdog "⚠️ /etc/dnsmasq.conf содержит server= — чистка"
  sed -i "/^server=/d; /^no-resolv/d" /etc/dnsmasq.conf
  /etc/init.d/dnsmasq restart >/dev/null 2>&1
fi

# 5) sort_by_latency (без него «Самый лучший» не выбирает узел → всё 000)
SL=$(uci get forkop.main.sort_by_latency 2>/dev/null)
[ "$SL" != "1" ] && { uci set forkop.main.sort_by_latency='1'; uci commit forkop; logger -t forkop-watchdog "sort_by_latency → 1"; }

# 6) tproxy-модуль (без него форкоп не стартует)
lsmod 2>/dev/null | grep -q nft_tproxy || { modprobe nft_tproxy 2>/dev/null; logger -t forkop-watchdog "nft_tproxy загружен"; }

exit 0
V7_FKWD
put /etc/forkop-watchdog.sh /tmp/v7.fkwd 'boot grace'
cat > /tmp/v7.hp << 'V7_HP'
#!/bin/sh
# 30-vpn v2 (02.10.2026): restart forkop when WAN comes back UP while running, but NOT during boot
# (S99forkop already starts forkop; the boot-time restart doubled the start: 4 starts, 2-3 min to stable).
[ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "wan" ] || exit 0
[ "$(cut -d. -f1 /proc/uptime 2>/dev/null)" -lt 150 ] && exit 0
/etc/init.d/forkop restart >/dev/null 2>&1 &
exit 0
V7_HP
put /etc/hotplug.d/iface/30-vpn /tmp/v7.hp 'uptime'
cat > /tmp/v7.guard << 'V7_GUARD'
#!/bin/sh
# forkop-domain-guard.sh v3 (03.10.2026): with section 'ai' (forkop-ai-section.sh) the AI domains live ONLY in ai, never in main
#   (v2 re-added anthropic/claude/chatgpt/openai/sora into main every hour; main's route rule precedes ai -> AI left via main exit (NL), not US2).
# forkop-domain-guard.sh v2 (01.10.2026) — keeps required domains in place, hourly via cron:
#   17 * * * * /etc/forkop-domain-guard.sh
# v1 merged ALL required domains (incl. kinopub) into main. With section 'kino' present
# (tools/forkop-kino-section.sh) that pulled kinopub back into main -> PL6 -> black screen.
# v2: if forkop.kino exists, kinopub domains live ONLY in kino; main keeps the rest.
# uci set as ONE string (add_list breaks fakeip). forkop is never restarted here.

REQUIRED="whatsapp.com whatsapp.net whatsapp.org wa.me instagram.com cdninstagram.com fbcdn.net \
anthropic.com claude.ai claude.com chatgpt.com openai.com sora.com \
kino.pub kino.watch kinozor.com protorrent.org kinopub.online api.srvkp.com \
media.service-kp.com cdn.service-kp.com cdn4t.xyz pushbr.com api.alador.space \
api.ios-kp.store cdn2cdn.com digital-cdn.net uafix.net uakino.best \
sharavoz.space tv.team ssiptvpro.com smart-iptv-player.com"

KINO="api.alador.space api.ios-kp.store api.kino.pub api.srvkp.com cdn.service-kp.com cdn2cdn.com \
cdn4t.xyz digital-cdn.net kino.pub kino.watch kinopub.online kinozor.com m.staticpop.net \
media.service-kp.com protorrent.org pushbr.com s.staticpop.net service-kp.com srvkp.com \
staticpop.net www.kino.pub"

AI="openai.com chatgpt.com oaistatic.com oaiusercontent.com sora.com anthropic.com claude.ai claude.com claudeusercontent.com \
statsig.com statsigapi.net featuregates.org featureassets.org prodregistryv2.org"

norm() { printf '%s\n' $* | grep -v '^$' | sort -u | tr '\n' ' '; }
without() { # $1=list $2=exclude
  for d in $1; do case " $2 " in *" $d "*) ;; *) printf '%s ' "$d";; esac; done
}

if [ -f /etc/config/forkop ]; then ENG=forkop; FIELD=forkop.main.domain
elif [ -f /etc/config/podkop ]; then ENG=podkop; FIELD=podkop.main.domain_list
else exit 0; fi

CUR=$(uci -q get $FIELD)
[ -z "$CUR" ] && exit 0
CHANGED=0

EXCL=""
[ "$ENG" = forkop ] && [ "$(uci -q get forkop.kino)" = "section" ] && EXCL="$KINO"
[ "$ENG" = forkop ] && [ "$(uci -q get forkop.ai)" = "section" ] && EXCL="$EXCL $AI"
if [ "$ENG" = forkop ] && [ -n "$EXCL" ]; then
  NEW_MAIN=$(norm $(without "$CUR $REQUIRED" "$EXCL"))
  if [ "$(uci -q get forkop.kino)" = "section" ]; then
    KCUR=$(uci -q get forkop.kino.domain)
    NEW_KINO=$(norm $KCUR $KINO)
    if [ "$(norm $KCUR)" != "$NEW_KINO" ]; then
      uci set forkop.kino.domain="$NEW_KINO"; CHANGED=1
    fi
  fi
else
  NEW_MAIN=$(norm $CUR $REQUIRED)
fi

if [ "$(norm $CUR)" != "$NEW_MAIN" ]; then
  uci set $FIELD="$NEW_MAIN"; CHANGED=1
fi

[ $CHANGED = 0 ] && exit 0
logger -t forkop-domain-guard "domains restored (main $(echo $CUR | wc -w) -> $(echo $NEW_MAIN | wc -w))"
uci commit $ENG
/etc/init.d/dnsmasq restart >/dev/null 2>&1
exit 0
V7_GUARD
put /etc/forkop-domain-guard.sh /tmp/v7.guard 'guard.sh v3'
cat > /tmp/v7.fl << 'V7_FL'
#!/bin/sh
# forkop-fix-lists.sh — БЕЗОПАСНОЕ обновление списков (замена 62-байтной заглушки)
#
# ⛔ ПРОБЛЕМА старого скрипта (62 б): он делал `forkop list_update` БЕЗ ПРОВЕРКИ.
#    Если GitHub недоступен/отдал мусор → sing-box ВЫКИДЫВАЕТ рабочие правила
#    → маркировка nft = 0 → трафик идёт DIRECT → кинопаб/ютуб режутся.
#    Это и есть «сутки работает → потом ломается» (cache.db истекает).
#
# ✅ РЕШЕНИЕ: перед обновлением — БЭКАП правил и кэша. После обновления — ПРОВЕРКА
#    маркировки. Если маркировка упала в 0 → ОТКАТ на бэкап + forkop reload.
#
# Установка: cp → /etc/forkop-fix-lists.sh; chmod +x
# Проверка:  logread | grep fix-lists

RD=/etc/forkop/rulesets
BK=/root/forkop-lists-backup
CACHE=/tmp/sing-box/cache.db

# ── 1. Проверка: GitHub вообще доступен? ──
GH=$(curl -sI -o /dev/null -w '%{http_code}' --max-time 10 https://github.com 2>/dev/null)
if [ "$GH" != "200" ]; then
    logger -t forkop-fix-lists "GitHub недоступен ($GH) — обновление ПРОПУЩЕНО (защита списков)"
    exit 0
fi

# ── 2. БЭКАП текущих рабочих правил и кэша ──
mkdir -p "$BK"
cp -a "$RD"/*.srs "$BK/" 2>/dev/null
[ -f "$CACHE" ] && cp -a "$CACHE" "$BK/cache.db.bak" 2>/dev/null
logger -t forkop-fix-lists "бэкап сделан: $(ls "$BK"/*.srs 2>/dev/null | wc -l) .srs"

# ── 3. Обновление ──
/usr/bin/forkop list_update > /dev/null 2>&1
sleep 8

# ── 4. ПРОВЕРКА МАРКИРОВКИ: растёт ли трафик через VPN? ──
M=$(nft list table inet ForkopTable 2>/dev/null | grep -oE 'packets [0-9]+' | awk '{print $2}' | sort -rn | head -1)
M=${M:-0}

if [ "$M" -lt 10 ]; then
    # ⛔ маркировка мертва — ОТКАТ
    logger -t forkop-fix-lists "⛔ маркировка упала ($M) — ОТКАТ на бэкап"
    cp -a "$BK"/*.srs "$RD/" 2>/dev/null
    [ -f "$BK/cache.db.bak" ] && cp -a "$BK/cache.db.bak" "$CACHE" 2>/dev/null
    /etc/init.d/forkop restart >/dev/null 2>&1
    sleep 20
    M2=$(nft list table inet ForkopTable 2>/dev/null | grep -oE 'packets [0-9]+' | awk '{print $2}' | sort -rn | head -1)
    logger -t forkop-fix-lists "откат завершён, маркировка: $M2"
else
    logger -t forkop-fix-lists "✅ обновление ОК, маркировка: $M"
    # ротация бэкапов: хранить последние 3
    ls -1t "$BK"/*.srs 2>/dev/null | tail -n +100 | xargs rm -f 2>/dev/null
fi
exit 0
V7_FL
put /etc/forkop-fix-lists.sh /tmp/v7.fl 'logger -t forkop-fix-lists'

# 5.4 убрать дубли и старые имена (в бэкап)
stash /etc/podkop-watchdog.sh
stash /etc/podkop-fix-lists.sh
stash /etc/hotplug.d/iface/30-forkop
stash /etc/hotplug.d/iface/30-podkop
stash /etc/hotplug.d/net/99-vpn-tailscale
stash /etc/hotplug.d/net/99-forkop-tailscale
for f in /etc/init.d/forkop.bak* /etc/init.d/*.bak /etc/init.d/forkop.orig; do [ -e "$f" ] && stash "$f"; done
if [ "$(real_start "$RC")" -gt 0 ] && [ "$(ls /etc/rc.d 2>/dev/null | grep -ic tailscale)" -gt 0 ]; then /etc/init.d/tailscale disable 2>/dev/null; fixed "дубль запуска: автозапуск init.d/tailscale снят (запуск — из rc.local; демон не тронут)"; fi

# 5.5 cron: канонические строки, дубли убраны (чужие строки сохраняются)
CUR=$(crontab -l 2>/dev/null)
CLEAN=$(echo "$CUR" | grep -vE 'podkop-watchdog|podkop-fix-lists|ts-watchdog|forkop-watchdog|forkop-domain-guard|forkop-fix-lists' | grep -v '^$')
NEWC="$CLEAN
*/2 * * * * /etc/ts-watchdog.sh
*/2 * * * * /etc/forkop-watchdog.sh
17 * * * * /etc/forkop-domain-guard.sh
0 * * * * /etc/forkop-fix-lists.sh --cron"
if [ "$(echo "$CUR" | sort)" != "$(echo "$NEWC" | grep -v '^$' | sort)" ]; then
    cp /dev/null "$BAK/crontab.before"; echo "$CUR" > "$BAK/crontab.before"
    echo "$NEWC" | grep -v '^$' | crontab - && fixed "cron: приведён к каноническому (ts-wd и forkop-wd каждые 2 мин, guard :17, fix-lists :00)"
else echo "  ✅ cron: уже канонический"; fi

# 5.6 форкоп UCI-правки (вступят в силу после ОДНОГО forkop restart: RESTART=1)
SBM=$(sing-box version 2>/dev/null | head -1 | awk '{print $3}' | cut -d. -f2 | grep -o '^[0-9]*'); SBM=${SBM:-0}
for S in main kino ai stream; do
    [ "$(uci -q get forkop.$S)" = "section" ] || continue
    CURFA=$(uci -q get forkop.$S.filter_aaaa)
    if [ "$SBM" -ge 13 ]; then
        [ "$CURFA" = "1" ] || { uci set forkop.$S.filter_aaaa='1'; FK_CHANGED=1; fixed "forkop.$S.filter_aaaa=1 (sing-box 1.$SBM)"; }
    else
        [ -n "$CURFA" ] && { uci -q delete forkop.$S.filter_aaaa; FK_CHANGED=1; fixed "forkop.$S.filter_aaaa удалён (sing-box 1.$SBM < 1.13: иначе AAAA висят)"; }
    fi
done
if [ "$(uci -q get forkop.ai)" = "section" ]; then
    FIRSTSEC=$(uci show forkop 2>/dev/null | grep -E '=section$' | head -1 | cut -d= -f1)
    if [ "$FIRSTSEC" != "forkop.ai" ]; then uci reorder forkop.ai=0; FK_CHANGED=1; fixed "секция ai поставлена ПЕРВОЙ (правило main с Cloudflare-диапазонами больше не перехватит ИИ)"; fi
    _MD=$(uci -q get forkop.main.domain | tr -d "\047\042"); _ND=""   # 07.10.2026: strip quotes (a one-element uci list prints as 'a b c' -> literal quotes broke the forkop validator, z56-55-murashkin)
    for _d in $_MD; do case " openai.com chatgpt.com oaistatic.com oaiusercontent.com sora.com anthropic.com claude.ai claude.com claudeusercontent.com statsig.com statsigapi.net featuregates.org featureassets.org prodregistryv2.org " in *" $_d "*) ;; *) _ND="$_ND $_d";; esac; done
    _ND=$(echo $_ND)
    if [ "$_ND" != "$(echo $_MD)" ]; then uci set forkop.main.domain="$_ND"; FK_CHANGED=1; fixed "main.domain: ИИ-домены убраны ($(echo $_MD | wc -w) → $(echo $_ND | wc -w))"; fi
fi
[ "$FK_CHANGED" = 1 ] && uci commit forkop
else
    warn "VPN: ${VPN_TYPE} — эталонные forkop-сторожа не ставятся. Podkop устарел: мигрировать на forkop (скилл replace-podkop-with-forkop)"
fi

# 5.7 hosts: все GitHub-CDN (forkop качает .srs через github.com → 302 → CDN)
HF=/etc/hosts
addh() { grep -q "$2 $1" "$HF" 2>/dev/null || echo "$2 $1" >> "$HF"; }
addh github.com 140.82.121.4; addh api.github.com 140.82.121.6; addh codeload.github.com 140.82.121.10
addh raw.githubusercontent.com 185.199.108.133; addh raw.githubusercontent.com 185.199.109.133
addh raw.githubusercontent.com 185.199.110.133; addh raw.githubusercontent.com 185.199.111.133
addh objects.githubusercontent.com 185.199.108.133; addh release-assets.githubusercontent.com 185.199.109.133
addh github-releases.githubusercontent.com 185.199.109.154; addh github.githubassets.com 185.199.108.215
addh avatars.githubusercontent.com 185.199.110.133
for H in controlplane.tailscale.com derp.tailscale.com login.tailscale.com; do :; done
echo "  ✅ hosts: GitHub-CDN на месте"

# 5.8 zram-swap (подушка памяти: без неё OOM убивает sing-box/tailscaled на 233 МБ)
# 07.10.2026 (механизм memory, эталон MEMORY-ZRAM-SWAP-MECHANISM-2026-10-07.md): если zram ЕСТЬ,
# но размером по дефолту (ram/2048) — увеличить до 256 МБ + алгоритм zstd (сжатие ~3× вместо lzo 2.2×)
# + vm.overcommit_memory=1 (не даёт ядру убивать sing-box при всплеске). TS не трогаем, ребута нет.
if ! grep -q zram /proc/swaps 2>/dev/null; then
    FREEKB=$(df -k /overlay 2>/dev/null | awk 'NR==2{print $4}'); FREEKB=${FREEKB:-0}
    if [ "$FREEKB" -gt 4096 ]; then
        if command -v apk >/dev/null 2>&1; then apk update >/dev/null 2>&1; apk add zram-swap >/dev/null 2>&1; else opkg update >/dev/null 2>&1; opkg install zram-swap kmod-zram >/dev/null 2>&1; fi
        /etc/init.d/zram enable 2>/dev/null; /etc/init.d/zram start 2>/dev/null; sleep 2
        grep -q zram /proc/swaps && fixed "zram-swap: включён" || warn "zram-swap: не включился (пакет/место) — проверь вручную"
    else warn "zram-swap: мало места на overlay ($FREEKB КБ) — пропуск"; fi
else echo "  ✅ zram-swap: уже есть"; fi
# 5.8b РАЗМЕР zram + алгоритм + overcommit (07.10.2026): дефолт ram/2048 мал при 3 секциях → OOM.
_ZSZ=$(uci -q get system.@system[0].zram_size_mb); _ZAL=$(uci -q get system.@system[0].zram_comp_algo)
if grep -q zram /proc/swaps 2>/dev/null; then
    if [ -z "$_ZSZ" ] || [ "$_ZSZ" -lt 256 ] 2>/dev/null; then
        cp /etc/config/system /root/system.bak-zram-$(date +%s) 2>/dev/null
        uci set system.@system[0].zram_size_mb='256'
        case "$(cat /sys/block/zram0/comp_algorithm 2>/dev/null)" in *zstd*) uci set system.@system[0].zram_comp_algo='zstd';; esac
        uci commit system
        swapoff /dev/zram0 2>/dev/null; /etc/init.d/zram stop 2>/dev/null; sleep 1; echo 1 > /sys/block/zram0/reset 2>/dev/null; sleep 1; /etc/init.d/zram start 2>/dev/null; sleep 3
        fixed "zram: размер $(cat /sys/block/zram0/disksize 2>/dev/null | awk '{print int($1/1048576)}') МБ, algo $(cat /sys/block/zram0/comp_algorithm 2>/dev/null | tr ' ' '\n' | grep '[' | tr -d '[]')"
    else echo "  ✅ zram размер задан: ${_ZSZ} МБ"; fi
fi
if [ "$(cat /proc/sys/vm/overcommit_memory 2>/dev/null)" != "1" ]; then
    echo 1 > /proc/sys/vm/overcommit_memory 2>/dev/null
    printf 'vm.overcommit_memory=1\n' > /etc/sysctl.d/99-forkop-mem.conf 2>/dev/null
    fixed "vm.overcommit_memory=1 (+/etc/sysctl.d/99-forkop-mem.conf)"
else echo "  ✅ vm.overcommit_memory=1"; fi

# 5.9 ЧАСЫ ПРИ ЗАГРУЗКЕ (08.10.2026, s78-39-karpin: Tailscale Running 107 с → ~24 с): P1 NTP по IP, P2 hotplug ntp 30-ts-sync, P3 rc.local ждёт NTP.
#     Только файлы/uci, без перезапуска Tailscale/форкопа/сети; вступает при следующей загрузке. Подробно: references/TAILSCALE-ETALON-HELPERS-AND-BOOT-CLOCK-2026-10-08.md
cat > /tmp/ts-boot-clock-fix.sh <<'TSBCF_EOF'
#!/bin/sh
# ts-boot-clock-fix.sh [--check] — лечение «нестабильного старта Tailscale из-за часов» (08.10.2026, проверено на s78-39-karpin: TS Running 107 с → ~24–35 с).
# Запуск на роутере:  ssh root@R 'sh -s -- --check' < ts-boot-clock-fix.sh    (чтение)     ·    ssh root@R 'sh -s' < ts-boot-clock-fix.sh   (применить)
# Причина: у роутера нет RTC, sysfixtime ставит часы на mtime самого свежего файла /etc, rc.local стартует tailscaled до WAN/NTP → NoState до сторожа.
# Что делает (идемпотентно, файлами, БЕЗ перезапуска Tailscale/форкопа/сети, с бэкапом, sh -n до замены, щит TS до/после):
#   P1  NTP-серверы по IP первыми (162.159.200.1, 216.239.35.0), пул — запасной (вступает при следующей загрузке);
#   P2  /etc/hotplug.d/ntp/30-ts-sync — по событию ntpd (step/stratum): метка /tmp/ntp-synced + пинок ts-watchdog, если TS не Running;
#   P3  rc.local: перед запуском tailscaled ждать метку до 100 с (в фоне: если блок rc.local не в подпроцессе — оборачиваю, чтобы не задерживать S99forkop).
# Известные формы rc.local: (a) эталон v7.4 — блок в «( … ) &» с «mkdir -p /var/run/tailscale»; (b) legacy v5.2 — те же строки без подпроцесса, заканчиваются
#   «logger -t rc.local 'Tailscale started'». Прочие формы НЕ трогаю (пишу «править вручную»). Переменные для тестов: RC=путь, HP_DIR=каталог hotplug.
MODE=${1:-apply}; RC=${RC:-/etc/rc.local}; HP_DIR=${HP_DIR:-/etc/hotplug.d/ntp}; DRYUCI=${DRYUCI:-0}
p1() { [ "$(uci -q get system.ntp.server 2>/dev/null | awk '{print ($1 ~ /^[0-9][0-9.]*$/)?1:0}')" = 1 ]; }
p2() { [ -x "$HP_DIR/30-ts-sync" ]; }
p3() { grep -q 'ntp-synced' "$RC" 2>/dev/null; }
TSP() { for d in /proc/[0-9]*; do [ "$(cat $d/comm 2>/dev/null)" = tailscaled ] && basename $d; done | tr '\n' ' '; }
shield() { echo "  щит $1: tailscaled=[$(TSP)] Running=$(tailscale status --json 2>/dev/null | grep -c '"BackendState": "Running"') sing-box=$(pgrep sing-box | head -1)"; }
echo "ts-boot-clock-fix: P1 NTP по IP=$(p1 && echo есть || echo НЕТ)  P2 hotplug=$(p2 && echo есть || echo НЕТ)  P3 rc.local-ожидание=$(p3 && echo есть || echo НЕТ)"
[ "$MODE" = "--check" ] && { p1 && p2 && p3 && echo "ИТОГ: всё применено" || echo "ИТОГ: нужно применить (запусти без --check)"; exit 0; }
[ "$(TSP | wc -w)" -le 1 ] || { echo "⛔ несколько tailscaled — сначала разобраться"; exit 2; }
BK=/root/ts-clock-$(date +%Y%m%d_%H%M%S); mkdir -p $BK; cp -p "$RC" /etc/rc.local.bak /etc/config/system $BK/ 2>/dev/null; echo "  бэкап: $BK"; shield ДО
# ── P1
if ! p1; then
  OLD=$(uci -q get system.ntp.server); uci -q delete system.ntp.server
  for s in 162.159.200.1 216.239.35.0; do uci add_list system.ntp.server="$s"; done
  for s in $OLD; do case "$s" in 162.159.200.1|216.239.35.0) ;; *) uci add_list system.ntp.server="$s";; esac; done
  [ -z "$OLD" ] && for s in 0.openwrt.pool.ntp.org 1.openwrt.pool.ntp.org; do uci add_list system.ntp.server="$s"; done
  uci commit system; echo "  P1 ✅ NTP: $(uci get system.ntp.server | tr '\n' ' ')"
else echo "  P1 уже есть"; fi
# ── P2
if ! p2; then
  mkdir -p "$HP_DIR"; cat > "$HP_DIR/30-ts-sync" <<'EOF'
#!/bin/sh
# 30-ts-sync (08.10.2026, P2): событие ntpd (step/stratum) = часы синхронизированы.
# 1) метка /tmp/ntp-synced (её ждёт rc.local перед стартом Tailscale);
# 2) если Tailscale не Running (стартовал при отстающих часах) — сразу вызвать ts-watchdog, не ждать cron.
case "$ACTION" in step|stratum) ;; *) exit 0;; esac
touch /tmp/ntp-synced
logger -t ts-sync "ntp $ACTION: время синхронизировано"
(
  U=$(cut -d. -f1 /proc/uptime); [ "$U" -lt 92 ] && sleep $((92-U))   # у ts-watchdog грейс 90 с после загрузки
  BS=$(tailscale status --json 2>/dev/null | grep -m1 BackendState | cut -d'"' -f4)
  [ "$BS" = "Running" ] || { logger -t ts-sync "Tailscale=$BS после NTP — запускаю ts-watchdog"; /etc/ts-watchdog.sh; }
) >/dev/null 2>&1 &
exit 0
EOF
  chmod +x "$HP_DIR/30-ts-sync"; sh -n "$HP_DIR/30-ts-sync" && echo "  P2 ✅ hotplug: $HP_DIR/30-ts-sync" || echo "  P2 ⛔ синтаксис hotplug"
else echo "  P2 уже есть"; fi
# ── P3
if ! p3; then
  N=$(grep -nE '^[^#]*tailscaled[[:space:]].*--(state|statedir|tun)' "$RC" | head -1 | cut -d: -f1)
  if [ -z "$N" ]; then echo "  P3 ⚠️ в $RC нет запуска tailscaled (запуск через init.d?) — править вручную"
  else
    M=$(grep -n '^mkdir -p /var/run/tailscale' "$RC" | head -1 | cut -d: -f1); S=${M:-$N}; [ "$S" -gt "$N" ] && S=$N
    SUB=$(awk -v n="$S" 'NR<n && ($0=="(" || $0 ~ /^\([[:space:]]*#/){f=1} END{print f+0}' "$RC")   # есть ли «(» до блока → уже в подпроцессе
    cp "$RC" /tmp/rc.fix
    if [ "$SUB" = 1 ]; then
      awk -v n="$S" 'NR==n{print "# 08.10.2026 P3: ждать NTP до 100 с перед запуском TS (часы отстают после ребута → NoState)"; print "i=0; while [ ! -f /tmp/ntp-synced ] && [ $i -lt 50 ]; do sleep 2; i=$((i+1)); done"; print "logger -t rc.local \"ntp-wait: $((i*2)) с, synced=$([ -f /tmp/ntp-synced ] && echo yes || echo no)\""} {print}' "$RC" > /tmp/rc.fix
      FORM="(a) уже в подпроцессе"
    else
      E=$(grep -n "logger -t rc.local 'Tailscale started'" "$RC" | head -1 | cut -d: -f1)
      if [ -z "$E" ]; then echo "  P3 ⚠️ неизвестная форма rc.local (нет «Tailscale started») — править вручную"; rm -f /tmp/rc.fix; E=""; fi
      if [ -n "$E" ]; then
        awk -v s="$S" -v e="$E" 'NR==s{print "("; print "# 08.10.2026 P3: ждать NTP до 100 с перед запуском TS; в подпроцессе, чтобы не задерживать S99forkop"; print "i=0; while [ ! -f /tmp/ntp-synced ] && [ $i -lt 50 ]; do sleep 2; i=$((i+1)); done"; print "logger -t rc.local \"ntp-wait: $((i*2)) с, synced=$([ -f /tmp/ntp-synced ] && echo yes || echo no)\""} {print} NR==e{print ") &"}' "$RC" > /tmp/rc.fix
        FORM="(b) legacy — обёрнуто в подпроцесс"
      fi
    fi
    if [ -s /tmp/rc.fix ]; then
      if sh -n /tmp/rc.fix && grep -q 'ntp-synced' /tmp/rc.fix && grep -q 'tailscaled' /tmp/rc.fix; then cp /tmp/rc.fix "$RC.n" && chmod +x "$RC.n" && mv "$RC.n" "$RC" && [ "$RC" = /etc/rc.local ] && cp -p "$RC" /etc/rc.local.bak; echo "  P3 ✅ rc.local: $FORM; sh -n ok; bak==rc: $(cmp -s "$RC" /etc/rc.local.bak && echo да || echo НЕТ)"
      else echo "  P3 ⛔ проверка нового rc.local не прошла — НЕ тронут"; fi
    fi
  fi
else echo "  P3 уже есть"; fi
shield ПОСЛЕ
echo "ИТОГ: P1=$(p1 && echo ок || echo НЕТ) P2=$(p2 && echo ок || echo НЕТ) P3=$(p3 && echo ок || echo НЕТ) (вступает при следующей загрузке; Tailscale/форкоп не перезапускались)"
TSBCF_EOF
_CLK=$(sh /tmp/ts-boot-clock-fix.sh 2>&1); rm -f /tmp/ts-boot-clock-fix.sh
echo "$_CLK" | grep -E "P[123]|ИТОГ" | sed 's/^/  /'
echo "$_CLK" | grep -q "✅" && echo "часы при загрузке (P1–P3): применено" >> /tmp/v7.fixed
echo "$_CLK" | grep -q "⚠️\|⛔" && warn "часы при загрузке: нестандартный rc.local — править вручную (см. ts-boot-clock-fix.sh)"

# ── 8.4. Мёртвый dhcp_option (fakeip-DNS клиентам) — ГЛАВНЫЙ корень «ничего не открывается» ─
# 24.08.2026 (49-puzikov): dhcp_option='6,198.18.0.2' раздавал клиентам DNS 198.18.0.2,
# на котором НИКТО не слушает (sing-box на 127.0.0.42, dnsmasq на <lan_ip>) → DNS клиентов
# мёртв → «ни один сайт не открывается», Telegram работает. Норма: dhcp_option ОТСУТСТВУЕТ
# (эталон TR-Boss-00, клиенты идут через роутер → dnsmasq → sing-box).
DHCP_OPT="$(uci get dhcp.lan.dhcp_option 2>/dev/null)"
if [ -n "$DHCP_OPT" ] && echo "$DHCP_OPT" | grep -qE '198\.18\.|fakeip'; then
    echo "  ⚠️ dhcp_option раздаёт fakeip-DNS ($DHCP_OPT) — на этом IP никто не слушает, DNS клиентов мёртв!"
    uci -q delete dhcp.lan.dhcp_option
    uci commit dhcp
    echo "  ✅ dhcp_option удалён — клиенты получат DNS роутера (dnsmasq → sing-box)"
    /etc/init.d/dnsmasq restart 2>/dev/null
elif [ -n "$DHCP_OPT" ]; then
    echo "  ℹ️ dhcp_option: $DHCP_OPT (не fakeip — оставляю)"
else
    echo "  ✅ dhcp_option отсутствует — клиенты идут через роутер (правильно)"
fi

# ── 8.4a. REBIND-ФИКС: dnsmasq rebind-защита режет fakeip (198.18.x) ────────
# 27.08.2026 (x46-04, tr56-14): dnsmasq с rebind_protection=1 + rebind_localhost=1
# считает fakeip-ответы sing-box (198.18.x) rebind-атакой и РЕЖЕТ их →
# «только WhatsApp/Telegram не работает у части клиентов, у остальных работает»
# (logread: possible DNS-rebind attack detected: web.whatsapp.com каждые ~90с).
# Лечение: выключить защиту — это БЕЗОПАСНО (роутер за NAT, клиенты локальные).
# Норма эталона: rebind_protection=0, rebind_localhost=0.
REBIND_P=$(uci get dhcp.@dnsmasq[0].rebind_protection 2>/dev/null)
REBIND_L=$(uci get dhcp.@dnsmasq[0].rebind_localhost 2>/dev/null)
if [ "$REBIND_P" = "1" ] || [ "$REBIND_L" = "1" ]; then
    uci set dhcp.@dnsmasq[0].rebind_protection='0'
    uci set dhcp.@dnsmasq[0].rebind_localhost='0'
    uci commit dhcp
    echo "  ⚠️ rebind-защита была ВКЛЮЧЕНА (protection=$REBIND_P, localhost=$REBIND_L) — резала fakeip WhatsApp/Telegram!"
    echo "  ✅ rebind_protection=0 + rebind_localhost=0 — защита выключена, fakeip работает"
    /etc/init.d/dnsmasq restart 2>/dev/null
elif [ "$REBIND_P" = "0" ] && [ "$REBIND_L" = "0" ]; then
    echo "  ✅ rebind: protection=0, localhost=0 (fakeip не режется — правильно)"
else
    echo "  ℹ️  rebind: protection='$REBIND_P', localhost='$REBIND_L' — проверьте"
fi


# ── 9.0. ИТОГ ЭТАЛОНА 03.10: выход ИИ + опциональный ОДИН рестарт форкопа ─────────────
if [ "$VPN_TYPE" = "forkop" ]; then
    HAS_AI=0; [ "$(uci -q get forkop.ai)" = "section" ] && HAS_AI=1
    HAS_KINO=0; [ "$(uci -q get forkop.kino)" = "section" ] && HAS_KINO=1
    UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126 Safari/537.36'
    aix() { curl -s -m 10 -A "$UA" https://claude.ai/cdn-cgi/trace 2>/dev/null | grep -E '^loc=' | cut -d= -f2; }
    AIX=""; MNX=""
    [ "$(/etc/init.d/forkop status 2>&1 | head -1)" = "running" ] && { AIX=$(aix); MNX=$(curl -s -m 10 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -E '^loc=' | cut -d= -f2); }
    # рестарт нужен, если записаны новые правки ИЛИ секция ai есть, а выход ИИ ещё не US (правки прошлого запуска не применены)
    NEEDRST=0; [ "$FK_CHANGED" = 1 ] && NEEDRST=1; [ "$HAS_AI" = 1 ] && [ "$AIX" != "US" ] && NEEDRST=1
    if [ "$NEEDRST" = 1 ]; then
        if [ "$RESTART" = "1" ]; then
            echo "  ⏳ RESTART=1: один forkop restart (20 с)..."; /etc/init.d/forkop restart >/dev/null 2>&1; sleep 20
            echo "  ✅ forkop после рестарта: $(/etc/init.d/forkop status 2>&1 | head -1)"; echo "forkop: ОДИН рестарт выполнен (RESTART=1)" >> /tmp/v7.fixed
            AIX=$(aix); MNX=$(curl -s -m 10 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -E '^loc=' | cut -d= -f2)
        else
            echo "  ℹ️  forkop-правки записаны/ждут применения (безопасный режим — без рестарта). Применить ОДНИМ рестартом:"
            echo "       RESTART=1 sh <(wget -O - https://raw.githubusercontent.com/vasneverov/openwrt-fix/main/fix-tailscale-openwrt.sh)   или   /etc/init.d/forkop restart"
        fi
    fi
    echo "  ℹ️  выход ИИ (claude.ai по Cloudflare): ${AIX:-?}   выход main: ${MNX:-?}"
    if [ "$HAS_AI" = 1 ] && [ "$AIX" = "US" ] && [ "$AIX" != "$MNX" ]; then echo "  ✅ ИИ идёт через США"
    elif [ "$HAS_AI" = 1 ] && [ "$NEEDRST" = 1 ] && [ "$RESTART" != "1" ]; then warn "ИИ пока идёт как раньше (${AIX:-?}) — нужен рестарт форкопа (RESTART=1)"
    elif [ "$HAS_AI" = 1 ]; then warn "секция ai есть, но выход ИИ не US (${AIX:-?}) — проверь подписку ai (us2) и порядок секций"
    else warn "секции ai НЕТ: ChatGPT/Claude идут через выход main (${MNX:-?}) — Cloudflare его блокирует (Sorry, you have been blocked)"; fi
    [ "$HAS_AI" = 0 ] && warn "добавить секцию ai (США; нужны подписки владельца): с Mac  forkop-repair-run.sh forkop-ai-section.sh  (скилл replace-podkop-with-forkop)"
    [ "$HAS_KINO" = 0 ] && warn "добавить секцию kino (кинопаб → kino.watch): с Mac  forkop-repair-run.sh  (скилл replace-podkop-with-forkop)"
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
uci add_list system.ntp.server='162.159.200.1' 2>/dev/null   # 08.10.2026 P1: NTP по IP первыми (без ожидания DNS), пул — запасной
uci add_list system.ntp.server='216.239.35.0' 2>/dev/null
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

# ── 9.9. GitHub raw зеркало (jsDelivr) + DNS DoH (Ростелеком и др.) ───────
# Провайдер может резать raw.githubusercontent.com (429/000) → forkop не качает
# subnet-списки → 'Failed to download telegram/meta subnet list' → Telegram/WhatsApp
# не работают при рабочем YouTube. Также может резаться UDP 53 (DNS).
# Зеркало jsDelivr (cdn.jsdelivr.net/gh/...) обходит raw-блокировку.
# ВАЖНО: применяется ТОЛЬКО если raw недоступен и зеркало доступно. НЕ трогает
# роутеры, где raw работает (Москва и др.) — там качается напрямую, это надёжнее.
if [ -f /usr/bin/forkop ]; then
    GITHUB_MIRROR_URL="https://cdn.jsdelivr.net/gh/itdoginfo/allow-domains@main"
    GITHUB_RAW_TEST="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/telegram.lst"
    GITHUB_RAW_OK=""
    GITHUB_MIRROR_OK=""

    # Проверить доступность raw.githubusercontent (не режется ли)
    if command -v curl >/dev/null 2>&1; then
        code=$(curl -s -4 -o /dev/null -w '%{http_code}' --max-time 10 "$GITHUB_RAW_TEST" 2>/dev/null || echo 000)
        if [ "$code" = "200" ]; then GITHUB_RAW_OK=1; fi
    fi

    if [ -n "$GITHUB_RAW_OK" ]; then
        echo "  ✅ GitHub raw: доступен (200) — зеркало НЕ нужно, качаем напрямую"
    else
        echo "  ⚠️ GitHub raw: недоступен (код $code) — провайдер режет, проверяю зеркало jsDelivr..."
        if command -v curl >/dev/null 2>&1; then
            mcode=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$GITHUB_MIRROR_URL/Subnets/IPv4/telegram.lst" 2>/dev/null || echo 000)
            if [ "$mcode" = "200" ]; then GITHUB_MIRROR_OK=1; fi
        fi
        if [ -n "$GITHUB_MIRROR_OK" ]; then
            # Прописать зеркало в /etc/init.d/forkop
            INITD_FORKOP=/etc/init.d/forkop
            if grep -q 'GITHUB_RAW_URL' "$INITD_FORKOP" 2>/dev/null; then
                echo "  ✅ GitHub зеркало: уже прописано в init.d/forkop"
            else
                cp "$INITD_FORKOP" "$INITD_FORKOP.bak-mirror" 2>/dev/null || true
                sed -i "s|FORKOP_INITD_UC=.*|&\n\nexport GITHUB_RAW_URL=\"$GITHUB_MIRROR_URL\"|" "$INITD_FORKOP"
                if ! grep -q 'GITHUB_RAW_URL="\$GITHUB_RAW_URL"' "$INITD_FORKOP"; then
                    sed -i 's|        FORKOP_SERVICE_NAME="\$NAME" \\|        FORKOP_SERVICE_NAME="$NAME" \\\n        GITHUB_RAW_URL="$GITHUB_RAW_URL" \\|' "$INITD_FORKOP"
                fi
                if sh -n "$INITD_FORKOP" 2>/dev/null; then
                    echo "  ✅ GitHub зеркало: jsDelivr ПРОПИСАНО в init.d/forkop (после ребута forkop списки пойдут через зеркало)"
                else
                    echo "  ❌ GitHub зеркало: ошибка синтаксиса — ОТКАТ бэкапа"
                    cp "$INITD_FORKOP.bak-mirror" "$INITD_FORKOP" 2>/dev/null || true
                fi
            fi
        else
            echo "  ❌ GitHub зеркало: jsDelivr тоже недоступен ($mcode) — нужно ручное вмешательство"
        fi
    fi

    # DNS через DoH, если UDP 53 режется
    if command -v nslookup >/dev/null 2>&1; then
        dns_udp_ok=$(nslookup example.com 8.8.8.8 2>&1 | grep -cE 'Address' || true)
        if [ "$dns_udp_ok" -lt 1 ]; then
            cur_dns=$(uci get forkop.settings.dns_type 2>/dev/null || echo "")
            if [ "$cur_dns" != "doh" ]; then
                uci set forkop.settings.dns_type='doh'
                uci commit forkop
                echo "  ✅ DNS DoH: UDP 53 режется — dns_type переключён на 'doh' (было '$cur_dns')"
            else
                echo "  ✅ DNS DoH: уже 'doh'"
            fi
        else
            echo "  ✅ DNS: UDP 53 работает — DoH не нужен"
        fi
    fi
fi

# ── 5.95. ЧИСТКА СЛЕДОВ + ПРОВЕРКА ОПАСНЫХ ПРАВОК (09.10.2026, z56-68) ─────────────
#   Диагностика копится на роутере: .log/.sh из /tmp, cron-строки w*.sh. Убираем ТОЛЬКО свой мусор,
#   полезные бэкапы в /root НЕ трогаем. Плюс проверка: не остался ли недопустимый nft-перехват DNS
#   (redirect :53 / iifname br-lan) — он рубит LuCI/rpcd (наш урок ночи 09.10).
echo "  ── 5.95. Чистка следов + проверка опасных правок ──"
for _f in /tmp/w.log /tmp/w2.log /tmp/w3.log /tmp/ts.log /tmp/repair.log /tmp/repair-restart.log /tmp/w.sh /tmp/w2.sh /tmp/w3.sh; do
    [ -e "$_f" ] && { rm -f "$_f" && fixed "убран диагностический след: $_f"; }
done
if crontab -l 2>/dev/null | grep -qE '/tmp/w[0-9]*\.sh'; then
    crontab -l 2>/dev/null | grep -vE '/tmp/w[0-9]*\.sh' > /tmp/v76.cron
    if [ "$(grep -c 'ts-watchdog' /tmp/v76.cron)" -ge 1 ]; then crontab /tmp/v76.cron && fixed "cron: убраны диагностические w*.sh (сторожа сохранены)"; fi
    rm -f /tmp/v76.cron
fi
_nft_dns=$(nft list ruleset 2>/dev/null | grep -cE 'force-DNS-to-router|redirect to :53')
if [ "$_nft_dns" -gt 0 ]; then
    warn "nft: ПЕРЕХВАТ DNS на LAN ($_nft_dns правил) — рубит LuCI/SSH! Снять redirect :53, затем firewall reload"
else
    echo "  ✅ nft: опасного перехвата DNS нет"
fi

# ── 10. Итог ───────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════"

# ── ЩИТ TAILSCALE: проверка после правок ──────────────────────────────────────────
TS_AFTER=$(tailscale status --json 2>/dev/null | grep -m1 BackendState | cut -d'"' -f4)
if [ "$TS_BEFORE" = "Running" ] && [ "$TS_AFTER" != "Running" ]; then
    echo "  🔴 ЩИТ TAILSCALE: был Running, сейчас ${TS_AFTER:-нет} — жду до 80 с (ts-watchdog сам лечит)…"
    for _t in 1 2 3 4 5 6 7 8; do sleep 10; TS_AFTER=$(tailscale status --json 2>/dev/null | grep -m1 BackendState | cut -d'"' -f4); [ "$TS_AFTER" = "Running" ] && break; done
    if [ "$TS_AFTER" != "Running" ]; then
        echo "  🔴 Tailscale НЕ вернулся — ОТКАТ файлов этого запуска из $BAK:"; ts_shield_restore
        [ -x /etc/ts-watchdog.sh ] && /etc/ts-watchdog.sh >/dev/null 2>&1
        echo "  🔴 откат выполнен. Проверь: tailscale status"; echo "ЩИТ TAILSCALE: статус не вернулся → откат файлов" >> /tmp/v7.issues; WARNINGS=$((WARNINGS + 1))
    else echo "  ✅ ЩИТ TAILSCALE: вернулся в Running"; fi
fi
TS_PID1=$(pgrep tailscaled | tr '
' ' ')
if [ "$TS_PID0" = "$TS_PID1" ]; then echo "  🛡  ЩИТ TAILSCALE: демон не перезапускался (pid ${TS_PID1:-нет} тот же), статус ${TS_AFTER:-?}"
else echo "  ℹ️  ЩИТ TAILSCALE: pid изменился ($TS_PID0 → $TS_PID1) — это штатный рестарт сторожем, статус ${TS_AFTER:-?}"; fi
snapshot "СОСТОЯНИЕ ПОСЛЕ"
echo ""
echo "  ┌── ИСПРАВЛЕНО В ЭТОМ ЗАПУСКЕ ─────────────────────────────"
if [ -s /tmp/v7.fixed ]; then sed 's/^/  │ ✅ /' /tmp/v7.fixed; else echo "  │ ничего — всё уже по эталону"; fi
echo "  ├── НЕДОЧЁТЫ (нужны руки/решение) ───────────────────────────"
if [ -s /tmp/v7.issues ]; then sed 's/^/  │ ⚠️  /' /tmp/v7.issues; else echo "  │ нет"; fi
echo "  └──────────────────────────────────────────────────────────"
echo "  📁 бэкапы заменённого: $BAK"
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
echo "  vpn-watchdog:$(crontab -l 2>/dev/null | grep -cE "forkop-watchdog|podkop-watchdog") cron"
echo "  fix-lists:   $(crontab -l 2>/dev/null | grep -cE "forkop-fix-lists|podkop-fix-lists") cron"
echo "  gh-mirror:   $(grep -q GITHUB_RAW_URL /etc/init.d/forkop 2>/dev/null && echo OK || echo NONE)"
echo "  hotplug WAN: $(ls /etc/hotplug.d/iface/30-vpn >/dev/null 2>&1 && echo OK || echo MISSING)"
echo "  guard v3:    $(grep -c 'guard.sh v3' /etc/forkop-domain-guard.sh 2>/dev/null || echo 0)   ts-wd: $(grep -o 'ts-watchdog v6\.[0-9]' /etc/ts-watchdog.sh 2>/dev/null | head -1)   zram: $(grep -c zram /proc/swaps 2>/dev/null)"
echo "  crond:       $(pgrep crond >/dev/null 2>&1 && echo running || echo NOT running)"
echo "  state:       $(wc -c < "${TS_STATEDIR}tailscaled.state" 2>/dev/null || echo 0) байт"
echo "  backup:      $(wc -c < /root/tailscaled.state.backup 2>/dev/null || echo 0) байт"
echo "  exclude_ntp: $(uci get ${VPN_CONFIG}.settings.exclude_ntp 2>/dev/null || echo 'N/A')"
echo "  list_update:  $(uci get ${VPN_CONFIG}.settings.update_interval 2>/dev/null || echo 'N/A')"
echo "  rulesets:     $(ls /tmp/sing-box/rulesets/*.srs 2>/dev/null | wc -l | tr -d ' ') srs (fakeip_subnets должен быть НЕ пуст)"
echo "  sing-box:    $(pgrep sing-box >/dev/null 2>&1 && echo running || echo NOT running)"
echo "═══════════════════════════════════════════"
echo ""
if [ "$WARNINGS" -gt 0 ]; then
    echo "  ⚠️  Предупреждений: $WARNINGS — см. выше"
else
    echo "  ✅ Готово. Ребут НЕ нужен. Файлы эталона применены; forkop-правки конфига — RESTART=1 (один рестарт) или /etc/init.d/forkop restart."
fi
echo ""