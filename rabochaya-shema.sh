#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════════════════
#  РАБОЧАЯ СХЕМА v1.0 (11.11.2026) — привести секции Tachyon к схеме TR-Boss.
#  Usage: sh <(wget -O - https://raw.githubusercontent.com/vasneverov/openwrt-fix/main/rabochaya-shema.sh)
# ═══════════════════════════════════════════════════════════════════════════════════════
#
#  ЧТО ДЕЛАЕТ: смотрит, какие секции уже есть (ai / main / youtube / kino), и кладёт в них рабочие
#  подписки и балансировщики по шаблону:
#      main    = Чехия 1 (cz5v2) + Чехия 4 (cz4) [+ Германия digit, резерв]
#      youtube = Чехия 1 + Чехия 4   (через тоннель)
#      kino    = Чехия 1 + Чехия 4
#      ai      = Америка 3 (us3)
#  Убирает мёртвые источники (Чехия 3, старая Чехия 5) и «живые» следы Forkop, из-за которых
#  откатывался DNS. Показывает всё на экране: шкала шагов, ✅/⚠️/❌, состояние ДО и ПОСЛЕ.
#
#  ⛔ ЧЕГО НЕ ДЕЛАЕТ: секции не создаёт · версию Tachyon и ядро не обновляет · пакеты не ставит и
#     не удаляет · Запрет 2 и другие секции не трогает · без kill · без ребута · Tailscale не трогает.
#
#  ПОДПИСКИ зашиты в этот файл (рабочие на 11.11.2026), отдельно передавать ничего не нужно.
#  ⚠️ Файл содержит ссылки с токенами: репозиторий публичный = ссылки видны всем. Сменились подписки —
#     поменяй четыре строки SUB_* ниже (или передай свои: SUB_CZ4='…' sh <(wget -O - …)).
#  Режимы:  --check (только посмотреть, ничего не менять) · --only main|youtube|kino|ai · --no-digit
#
#  ЗАЩИТЫ: бэкап конфигов · один перезапуск ядра · живой DNS на время старта · состояние ДО и ПОСЛЕ ·
#          если ядро не поднялось / нет tproxy / клиенты не получают fakeip — автоматический откат из бэкапа.
#          Замеры сайтов с самого роутера (wget) показываются справочно и откат не вызывают (они неточны).
# ═══════════════════════════════════════════════════════════════════════════════════════

# ── Защита от обрыва скачивания: всё тело в функции main и вызов в самом конце файла.
# Если файл докачался не до конца, оболочка не дойдёт до "main" и НИЧЕГО не выполнит.
main(){
VER_S="1.0"
trap '' HUP PIPE
CHECK=0; ONLY=""; DIGIT=1
while [ $# -gt 0 ]; do case "$1" in
  --check) CHECK=1;; --only) ONLY="$2"; shift;; --no-digit) DIGIT=0;; esac; shift; done

# ── ПОДПИСКИ (рабочие на 11.11.2026). Можно переопределить из окружения. ──
SUB_CZ5V2="${SUB_CZ5V2:-https://92.61.71.140:2096/red/fk5jc53zhfp82mpm}"      # Чехия 1 (cz5v2)
SUB_CZ4="${SUB_CZ4:-https://cz4.theredhat.su:2097/red/pp9me0wdoqbdbf9m}"        # Чехия 4 (cz4)
SUB_US3="${SUB_US3:-https://us3.theredhat.su:2097/red/iuf5856tsflu0mw7}"        # Америка 3 (us3, для ai)
SUB_DIG="${SUB_DIG:-https://digitde.theredhat.su:2097/red/qmp1ie4mxlj5lbgu}"    # Германия (digit, резерв в main)

if [ -t 1 ]; then G='\033[32m'; R='\033[31m'; Y='\033[33m'; B='\033[36m'; W='\033[1m'; N='\033[0m'; TTY=1; else G=; R=; Y=; B=; W=; N=; TTY=0; fi
STEPS=9; CUR=0; LOG=/tmp/rabochaya-shema.log; : > $LOG
T0=$(date +%s); TS_STEP=$T0
FIXED=/tmp/rs.fixed; ISSUES=/tmp/rs.issues; : > $FIXED; : > $ISSUES
say(){ printf "%b\n" "$*" | tee -a $LOG; }
bar(){ # $1 = процент
  F=$(($1/5)); BR=""; i=0; while [ $i -lt 20 ]; do if [ $i -lt $F ]; then BR="$BR█"; else BR="$BR░"; fi; i=$((i+1)); done; printf '%s' "$BR"; }
step(){ NOW=$(date +%s); CUR=$((CUR+1)); P=$((CUR*100/STEPS))
  say "\n${B}━━ шаг $CUR из $STEPS ━━ $(bar $P) ${P}%  ·  ${W}$1${N}${B}  ·  прошло $((NOW-T0)) с${N}"; }
info(){ say "  ℹ️  $*"; }
ok(){ say "  ${G}✅ $*${N}"; }
did(){ echo "$*" >> $FIXED; say "  ${G}✅ $*${N}"; }
warn(){ echo "$*" >> $ISSUES; say "  ${Y}⚠️  $*${N}"; }
bad(){ echo "$*" >> $ISSUES; say "  ${R}❌ $*${N}"; }
die(){ bad "$*"; say "\n${R}━━ ОСТАНОВЛЕНО ━━ ничего не изменено (или изменения откатаны).${N}"; exit 1; }
g(){ uci -q get "$1" 2>/dev/null; }
want(){ [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }
mk(){ [ "$1" = 1 ] && printf '✅' || printf '❌'; }
# Везде встроенный wget (он есть на всех роутерах). curl с роутера даёт ложные замеры — не используется.
# dl URL ФАЙЛ [сек] -> печатает 200 (скачалось) или 000
dl(){ rm -f "$2"; if wget -q -T ${3:-15} --no-check-certificate -O "$2" "$1" >/dev/null 2>&1; then echo 200; else echo 000; fi; }
m(){ dl "$1" /dev/null 12; }
good(){ [ "$1" = 200 ] || [ "$1" = 301 ] || [ "$1" = 302 ]; }

say "${B}╔════════════════════════════════════════════════════════════════╗${N}"
say "${B}║${N}   ${W}РАБОЧАЯ СХЕМА  v$VER_S${N}  ·  Tachyon · схема TR-Boss              ${B}║${N}"
say "${B}║${N}   $(date '+%d.%m.%Y %H:%M:%S')   режим: $([ $CHECK = 1 ] && echo 'ТОЛЬКО ПРОВЕРКА (ничего не меняю)' || echo 'ПРИМЕНЕНИЕ')            ${B}║${N}"
say "${B}╚════════════════════════════════════════════════════════════════╝${N}"

snap(){ # $1 = подпись, $2 = префикс переменных (pre/post)
  p=$2
  eval "${p}_yt=$(m https://www.youtube.com/)"; eval "${p}_tg=$(m https://t.me/)"
  eval "${p}_ig=$(m https://www.instagram.com/)"; eval "${p}_wa=$(m https://web.whatsapp.com/)"
  st=$(tachyon get_status 2>/dev/null | tr -d '\n'); case "$st" in *'"running": 1'*) r=1;; *) r=0;; esac
  case "$st" in *'"dns_configured": 1'*) d=1;; *) d=0;; esac
  tp=$(nft list ruleset 2>/dev/null | grep -c tproxy); eval "${p}_run=$r; ${p}_dns=$d; ${p}_tp=$tp"
  LAN=$(g network.lan.ipaddr | cut -d/ -f1); fip=$(nslookup www.youtube.com "${LAN:-127.0.0.1}" 2>/dev/null | grep -oE '198\.18\.[0-9.]+' | head -1); eval "${p}_fip=\$fip"
  DS=$(g dhcp.$DM.server); NR=$(g dhcp.$DM.noresolv); dnsok=0; [ "$DS" = 127.0.0.42 ] && [ "$NR" = 1 ] && dnsok=1; eval "${p}_dnsok=$dnsok"
  FK=$( (apk list -I 2>/dev/null; opkg list-installed 2>/dev/null) | grep -ciE 'forkop|podkop'); FC=$(grep -E 'forkop|podkop' /etc/crontabs/root 2>/dev/null | grep -vc '^#')
  eval "${p}_fk=$FK; ${p}_fc=$FC"
  eval "yt=\$${p}_yt; tg=\$${p}_tg; ig=\$${p}_ig; wa=\$${p}_wa"
  say "\n  ┌── $1 ──────────────────────────────────────────────"
  say "  │ Tachyon: $([ $r = 1 ] && echo 'работает ✅' || echo 'НЕ работает ❌') · DNS Tachyon: $(mk $d) · tproxy: $tp · dnsmasq: $DS (noresolv=$NR) $(mk $dnsok)"
  say "  │ $(mk $([ -n "$fip" ] && echo 1 || echo 0)) клиенты получают fakeip для YouTube: ${fip:-НЕТ (DNS слетел в failsafe)}"
  for s in main youtube kino ai; do [ "$(g tachyon.$s)" = section ] && say "  │ секция $s ← [$(g tachyon.$s.outbound_source_refs)]"; done
  say "  │ замер wget с роутера (справочно, не вердикт): YouTube $yt · Telegram $tg · Instagram $ig · WhatsApp $wa"
  say "  │ следы Forkop: пакетов $FK · активных cron-строк $FC $(mk $([ "$FK$FC" = "00" ] && echo 1 || echo 0))"
  say "  └──────────────────────────────────────────────────────────────"
}

# ═════════ 1. Знакомство с роутером ═════════
step "Знакомлюсь с роутером"
[ -x /usr/bin/tachyon ] || die "Tachyon не установлен (этот скрипт ничего не устанавливает)"
VER=$( (apk list -I 2>/dev/null; opkg list-installed 2>/dev/null) | grep -E '^tachyon[- ]+[0-9]' | head -1 | sed -E 's/^tachyon[- ]+([0-9][0-9.]*).*/\1/')
MAJ=$(echo "$VER" | cut -d. -f1); MIN=$(echo "$VER" | cut -d. -f2)
info "роутер $(g system.@system[0].hostname) · $(cat /tmp/sysinfo/model 2>/dev/null) · OpenWrt $(. /etc/openwrt_release 2>/dev/null; echo $DISTRIB_RELEASE)"
ok "Tachyon ${VER:-?} · ядро $(tachyon-core version 2>/dev/null | head -1 | sed 's/.* //')"
{ [ "${MAJ:-0}" -gt 1 ] || { [ "${MAJ:-0}" = 1 ] && [ "${MIN:-0}" -ge 6 ]; }; } 2>/dev/null || die "версия Tachyon ${VER:-?} < 1.6: нет модели источников (версию скрипт не обновляет)"
FREE=$(free | awk '/Mem/{print $7}'); ok "свободно ОЗУ $((FREE/1024)) МБ"
[ "${FREE:-0}" -ge 25000 ] || die "мало памяти ($((FREE/1024)) МБ < 25): перезапуск ядра опасен"
BUSY=$(ps w | grep -E 'apk add|opkg install|tachyon (start|stop|reload|restart)|lifecycle' | grep -v grep | wc -l)
[ "$BUSY" = 0 ] || die "на роутере уже идёт установка/перезапуск ($BUSY процессов), подожди и повтори"
DM=$(uci show dhcp | grep -m1 '=dnsmasq' | cut -d. -f2 | cut -d= -f1)
TSB=$(pgrep -P 1 tailscaled | head -1); ok "Tailscale pid $TSB (не трогаю)"

# ═════════ 2. Что нашёл ═════════
step "Смотрю, какие секции есть"
SECS=""
for s in main youtube kino ai; do
  if [ "$(g tachyon.$s)" = section ]; then SECS="$SECS $s"; ok "секция ${W}$s${N}${G} найдена (действие: $(g tachyon.$s.action))"; else warn "секции $s нет: пропускаю (секции скрипт не создаёт)"; fi
done
OTHERS=$(uci show tachyon | grep -E "=section$" | cut -d. -f2 | cut -d= -f1 | grep -vxE 'main|youtube|kino|ai' | tr '\n' ' ')
[ -n "$OTHERS" ] && info "другие секции не трогаю: $OTHERS"
[ "$(g tachyon.youtube.action)" = zapret2 ] && warn "youtube сейчас на Запрете 2: переведу на тоннель (схема TR-Boss)"
[ -n "$SECS" ] || die "не найдено ни одной из секций main/youtube/kino/ai"
[ -z "$ONLY" ] || echo "$SECS" | grep -qw "$ONLY" || die "секции $ONLY на роутере нет"

# ═════════ 3. Подписки ═════════
step "Проверяю подписки (откуда брать узлы)"
ask(){ eval "v=\${$1}"; if [ -z "$v" ] && [ -t 0 ]; then printf "   вставь ссылку %s: " "$2"; read -r v; eval "$1=\$v"; fi; }
ask SUB_CZ5V2 "Чехия 1 (cz5v2)"; ask SUB_CZ4 "Чехия 4 (cz4)"; ask SUB_US3 "Америка 3 (us3, для ai)"
[ "$DIGIT" = 1 ] && ask SUB_DIG "Германия (digit, резерв в main; Enter — без неё)"
[ -z "$SUB_DIG" ] && DIGIT=0
NEED_CZ=0; NEED_AI=0
for s in $SECS; do want $s || continue; case $s in ai) NEED_AI=1;; *) NEED_CZ=1;; esac; done
chk(){ c=000; n=0; t=0
  while [ $t -lt 3 ] && [ "$c" != 200 ]; do t=$((t+1)); c=$(dl "$2" /tmp/.rs-sub.chk 15); if [ -f /tmp/.rs-sub.chk ]; then n=$(wc -c < /tmp/.rs-sub.chk); else n=0; fi; [ "$c" = 200 ] || sleep 2; done
  rm -f /tmp/.rs-sub.chk
  if [ "$c" = 200 ] && [ "${n:-0}" -gt 100 ]; then ok "$1: отдаётся (http 200, ${n} байт)"; return 0; else bad "$1: http $c, ${n:-0} байт после $t попыток (с этого роутера не отдаётся)"; return 1; fi; }
FAILSUB=0
if [ $NEED_CZ = 1 ]; then
  if [ -n "$SUB_CZ5V2" ]; then chk "Чехия 1 (cz5v2)" "$SUB_CZ5V2" || FAILSUB=1; else bad "нужна ссылка cz5v2"; FAILSUB=1; fi
  if [ -n "$SUB_CZ4" ]; then chk "Чехия 4 (cz4)" "$SUB_CZ4" || FAILSUB=1; else bad "нужна ссылка cz4"; FAILSUB=1; fi
fi
if [ $NEED_AI = 1 ]; then
  if [ -n "$SUB_US3" ]; then chk "Америка 3 (us3)" "$SUB_US3" || FAILSUB=1; else bad "нужна ссылка us3"; FAILSUB=1; fi
fi
[ "$DIGIT" = 1 ] && { chk "Германия (digit)" "$SUB_DIG" || { warn "digit не отдаётся — ставлю без Германии"; DIGIT=0; }; }
[ $FAILSUB = 0 ] || die "подписки недоступны или не заданы"

# ═════════ 4. Состояние ДО + бэкап ═════════
step "Фиксирую состояние ДО и делаю бэкап"
snap "СОСТОЯНИЕ ДО" pre
say "\n  ${W}ПЛАН (было → станет):${N}"
for s in $SECS; do want $s || continue
  case $s in main) T="cz5v2 cz4$([ $DIGIT = 1 ] && echo ' digit')";; youtube|kino) T="cz5v2 cz4";; ai) T="us3";; esac
  say "    • $s: [$(g tachyon.$s.outbound_source_refs)]  →  [$T]"; done
if [ $CHECK = 1 ]; then
  say "\n${G}╔════════════ ПРОВЕРКА ВЫПОЛНЕНА ════════════╗${N}"
  say "${G}║${N} Ничего не менялось. Чтобы применить, запусти ту же команду без --check. ${G}║${N}"
  say "${G}╚══════════════════════════════════════════╝${N}"; exit 0; fi
TS=$(date +%s)
cp /etc/config/tachyon /root/tachyon.before_shema.$TS; cp /etc/config/dhcp /root/dhcp.before_shema.$TS
cp /etc/tachyon-core/config.json /root/config.json.before_shema.$TS 2>/dev/null; cp /etc/crontabs/root /root/crontab.before_shema.$TS 2>/dev/null
ok "бэкап: /root/*.before_shema.$TS (для отката)"

# ═════════ 5. Источники и балансировщики ═════════
step "Кладу подписки и балансировщики по шаблону"
set_src(){ uci set tachyon.src_$1='outbound_source'; uci set tachyon.src_$1.enabled='1'; uci set tachyon.src_$1.name="$1"; uci set tachyon.src_$1.url="$2"; uci set tachyon.src_$1.source_type='subscription'; uci set tachyon.src_$1.subscription_update_enabled='1'; }
set_refs(){ sec=$1; opt=$2; shift 2; cur=$(uci show tachyon.$sec.$opt 2>/dev/null)
  case "$cur" in *"' '"*|*list*) uci -q delete tachyon.$sec.$opt; for v in "$@"; do uci add_list tachyon.$sec.$opt="$v"; done;; *) uci set tachyon.$sec.$opt="$*";; esac; }
[ -n "$SUB_CZ5V2" ] && set_src cz5v2 "$SUB_CZ5V2"; [ -n "$SUB_CZ4" ] && set_src cz4 "$SUB_CZ4"
[ -n "$SUB_US3" ] && set_src us3 "$SUB_US3"; [ "$DIGIT" = 1 ] && set_src digit "$SUB_DIG"
for s in $SECS; do want $s || continue
  case $s in main) R="src_cz5v2 src_cz4$([ $DIGIT = 1 ] && echo ' src_digit')";; youtube|kino) R="src_cz5v2 src_cz4";; ai) R="src_us3";; esac
  BAL=$(g tachyon.$s.balancer_refs | awk '{print $1}')
  if [ -z "$BAL" ] || [ "$(g tachyon.$BAL)" != balancer ]; then
    BAL=bal_${s}_${s}; uci set tachyon.$BAL='balancer'; uci set tachyon.$BAL.name="$s"; uci set tachyon.$BAL.enabled='1'
    uci set tachyon.$BAL.balancer_type='urltest'; uci set tachyon.$BAL.testing_url='https://captive.apple.com'
    uci set tachyon.$BAL.check_interval='1m'; uci set tachyon.$BAL.tolerance='100'; uci set tachyon.$BAL.idle_timeout='30m'
    uci set tachyon.$BAL.interrupt_exist_connections='1'; uci set tachyon.$BAL.pin_dashboard='1'; warn "$s: балансировщика не было, создан $BAL"
  fi
  set_refs $BAL source_refs $R
  uci set tachyon.$s.enabled='1'; uci set tachyon.$s.action='connection'; uci set tachyon.$s.sort_by_latency='1'
  set_refs $s outbound_source_refs $R; uci set tachyon.$s.balancer_refs="$BAL"
  did "секция $s ← $R  (балансировщик $BAL)"
done
for o in $(uci show tachyon | grep -oE '^tachyon\.src_[A-Za-z0-9_]+=outbound_source' | cut -d. -f2 | cut -d= -f1); do
  case "$o" in src_cz5v2|src_cz4|src_us3|src_digit) continue;; esac
  u=$(g tachyon.$o.url)
  case "$u" in *cz3.*|*cz5.theredhat.su*|*87.236.146.156*)
    used=$(uci show tachyon | grep -E '(source_refs|outbound_source_refs)' | grep -cw "$o")
    [ "$used" = 0 ] && { uci delete tachyon.$o; did "удалён мёртвый источник $o"; } ;; esac
done
uci commit tachyon
sed -i -E '/forkop|podkop/{/^#/!s/^/#FKOFF /}' /etc/crontabs/root 2>/dev/null
rm -f /etc/forkop-watchdog.sh /etc/forkop-domain-guard.sh /etc/forkop-fix-lists.sh 2>/dev/null
Q=0; for f in /etc/nftables.d/20-drop-quic.nft /etc/nftables.d/*forkop* /etc/nftables.d/*podkop*; do [ -e "$f" ] && { rm -f "$f"; Q=1; }; done
rm -f /etc/hotplug.d/iface/*forkop* /etc/rc.d/*forkop* 2>/dev/null; [ -x /etc/init.d/forkop ] && /etc/init.d/forkop disable >/dev/null 2>&1
[ $Q = 1 ] && fw4 reload >/dev/null 2>&1
[ "${pre_fc:-0}" != 0 ] || [ "${pre_fk:-0}" != 0 ] && did "следы Forkop отключены (cron/сторожа, откатывавшие DNS)"

# ═════════ 6. DNS и подписки ═════════
step "Включаю живой DNS и загружаю узлы"
boot_dns(){ uci -q delete dhcp.$DM.server; uci add_list dhcp.$DM.server='1.1.1.1'; uci add_list dhcp.$DM.server='8.8.8.8'; uci set dhcp.$DM.noresolv='0'; uci commit dhcp; /etc/init.d/dnsmasq restart >/dev/null 2>&1; sleep 3; }
assert_dns(){ uci -q delete dhcp.$DM.server; uci add_list dhcp.$DM.server='127.0.0.42'; uci set dhcp.$DM.noresolv='1'; uci set dhcp.$DM.filter_aaaa='1'; uci set dhcp.$DM.cachesize='0'; uci -q delete dhcp.$DM.tachyon_server; uci commit dhcp; /etc/init.d/dnsmasq restart >/dev/null 2>&1; }
boot_dns; ok "на время старта dnsmasq смотрит на 1.1.1.1 + 8.8.8.8 (чтобы подписки скачались)"
T=""; command -v timeout >/dev/null 2>&1 && T="timeout 90"
$T tachyon subscription_update >/dev/null 2>&1; $T tachyon list_update >/dev/null 2>&1; ok "подписки и списки обновлены"

# ═════════ 7. Перезапуск ядра ═════════
step "Перезапускаю ядро Tachyon (один раз, 1–3 минуты)"
wait_run(){ i=0; while [ $i -lt 24 ]; do sleep 4; i=$((i+1)); if [ $TTY = 1 ]; then printf "\r  ⏳ жду запуск ядра… %s с   " $((i*4)); fi; tachyon get_status 2>/dev/null | grep -q '"running": 1' && { [ $TTY = 1 ] && printf "\n"; return 0; }; done; [ $TTY = 1 ] && printf "\n"; return 1; }
tachyon stop >/dev/null 2>&1; sleep 4
TACHYON_SING_BOX_START_VERIFY_TIMEOUT=180 tachyon start >/dev/null 2>&1 &
if wait_run; then did "ядро запущено"; else bad "ядро не поднялось за ~100 с"; fi
assert_dns; sleep 8; did "dnsmasq возвращён на 127.0.0.42 (noresolv=1)"

# ═════════ 8. Состояние ПОСЛЕ ═════════
step "Проверяю результат (состояние ПОСЛЕ)"
st=$(tachyon get_status 2>/dev/null | tr -d '\n'); case "$st" in *'"running": 1'*) RUN=1;; *) RUN=0;; esac
TP=$(nft list ruleset 2>/dev/null | grep -c tproxy)
if [ "$RUN" = 1 ] && [ "${TP:-0}" = 0 ]; then warn "tproxy=0 при живом ядре: штатный doctor --fix"; tachyon doctor --fix >/dev/null 2>&1; sleep 15; wait_run; assert_dns; sleep 6; fi
snap "СОСТОЯНИЕ ПОСЛЕ" post
TSA=$(pgrep -P 1 tailscaled | head -1)
[ "$TSA" = "$TSB" ] && ok "Tailscale pid не менялся ($TSA)" || warn "Tailscale pid $TSB → $TSA (родной ts-watchdog мог перезапустить демон на время простоя DNS; связь жива)"
GOOD=0
if [ "$post_run" = 1 ] && [ "${post_tp:-0}" -gt 0 ] && [ -n "$post_fip" ]; then GOOD=1; fi
[ "$post_dns" = 1 ] || warn "dns_configured=0 у Tachyon (проверь в LuCI)"

# ═════════ 9. Итог ═════════
step "Итог"
if [ $GOOD = 1 ]; then
  say "\n  ${W}ДО → ПОСЛЕ:${N}"
  say "    Ядро Tachyon     $(mk $pre_run) → $(mk $post_run)      tproxy  $pre_tp → $post_tp"
  say "    fakeip клиентам  ${pre_fip:-нет} → ${post_fip:-нет}   $(mk $([ -n "$post_fip" ] && echo 1 || echo 0))"
  say "    DNS Tachyon      $(mk $pre_dns) → $(mk $post_dns)      следы Forkop (пакеты/cron)  $pre_fk/$pre_fc → $post_fk/$post_fc"
  say "    замер wget (справочно): YouTube $pre_yt→$post_yt · Telegram $pre_tg→$post_tg · Instagram $pre_ig→$post_ig · WhatsApp $pre_wa→$post_wa"
  say "\n  ${G}ИСПРАВЛЕНО:${N}"; sed 's/^/    ✅ /' $FIXED | tee -a $LOG
  if [ -s $ISSUES ]; then say "\n  ${Y}ОБРАТИ ВНИМАНИЕ:${N}"; sed 's/^/    ⚠️  /' $ISSUES | tee -a $LOG; fi
  say "    ℹ️  Точная проверка — в браузере клиента (YouTube, Instagram): замеры с самого роутера неточны."
  say "\n  бэкап для отката: /root/tachyon.before_shema.$TS · лог: $LOG · всего $(( $(date +%s) - T0 )) с"
  say "\n${G}╔══════════════════════ СКРИПТ ВЫПОЛНЕН ══════════════════════╗${N}"
  say "${G}║${N}  Выходи из терминала и открывай LuCI → Сервисы → Tachyon:      ${G}║${N}"
  say "${G}║${N}  секции уже на рабочей схеме.                                   ${G}║${N}"
  say "${G}╚════════════════════════════════════════════════════════════════╝${N}"
  exit 0
fi
bad "схема не заработала (ядро=$post_run tproxy=$post_tp fakeip=${post_fip:-нет}) — ОТКАТ из бэкапа"
cp /root/tachyon.before_shema.$TS /etc/config/tachyon; boot_dns
tachyon stop >/dev/null 2>&1; sleep 4; TACHYON_SING_BOX_START_VERIFY_TIMEOUT=180 tachyon start >/dev/null 2>&1 &
wait_run; assert_dns; sleep 8
say "   после отката: ядро running=$(tachyon get_status 2>/dev/null | grep -o '"running": *[01]' | grep -o '[01]')"
say "\n${R}╔══════════════ СХЕМА НЕ ПРИМЕНЕНА ══════════════╗${N}"
say "${R}║${N}  Конфиг возвращён как был. Лог: $LOG   ${R}║${N}"
say "${R}╚════════════════════════════════════════════════╝${N}"
exit 2
}
main "$@"
