# thin-podkop 🎯

**Podkop + sing-box-tiny** — быстрая установка на OpenWrt 24.x и 25.x.

[![OpenWrt](https://img.shields.io/badge/OpenWrt-24.10_|_25.12-00ff00)](https://openwrt.org)
[![License](https://img.shields.io/badge/license-GPL--2.0-blue)](LICENSE)

## Что это

Установщик Podkop (прокси-туннелирование) с **тонким sing-box** вместо полного.  
Создан для роутеров с ограниченной flash-памятью (Cudy WR3000S/H, TR3000, M300 и аналоги).

| | Полный (itdoginfo) | Тонкий (thin-podkop) |
|---|---|---|
| sing-box | полный ~40 MB | **tiny ~10 MB** |
| Flash нужно | ≥ 42 MB свободно | ≥ 18 MB свободно |
| Время установки | ~20 сек | ~18 сек |
| Что ставится | podkop + luci + русский | podkop + luci + русский |
| Работает на Cudy с 44 MB | ❌ не влезает | ✅ влезает |

## Установка

**Скопируй и выполни** в консоли роутера (SSH):

```bash
sh <(wget -O - https://raw.githubusercontent.com/vasneverov/openwrt-fix/main/thin-podkop-installer.sh)
```

или через curl:

```bash
sh <(curl -sL https://raw.githubusercontent.com/vasneverov/openwrt-fix/main/thin-podkop-installer.sh)
```

**Никаких флагов, выборов, подтверждений.**  
Скрипт сам определяет:
- Какой менеджер пакетов: `opkg` (24.x) или `apk` (25.x)
- Какой sing-box нужен — тянет тонкий
- Русский язык — ставится без вопросов

## После установки

```bash
# 1. Вставить ключ
uci set podkop.main.proxy_string='vless://YOUR_UUID@YOUR_SERVER:5090?...'
uci commit podkop

# 2. 21 список (youtube в списке, YT секцию удалить)
uci del podkop.main.community_lists
for l in telegram meta youtube geoblock block porn news anime discord twitter hdrezka tiktok cloudflare google_ai google_play hodca roblox hetzner ovh digitalocean cloudfront; do
    uci add_list podkop.main.community_lists="$l"
done
uci commit podkop

# 3. Спасительный скрипт
sh <(wget -O - https://raw.githubusercontent.com/vasneverov/openwrt-fix/main/fix-tailscale-openwrt.sh)

# 4. Обновить списки и запустить
/usr/bin/podkop list_update
/etc/init.d/podkop restart
```

## Поддерживаемые роутеры

| Модель | Flash | OpenWrt | Архитектура | Результат |
|--------|-------|---------|-------------|-----------|
| Cudy WR3000S v1 | 44.7 MB | 24.10.5 | aarch64_cortex-a53 | ✅ |
| Cudy WR3000H v1 | 44.7 MB | 24.10.x | aarch64_cortex-a53 | ✅ |
| Cudy TR3000 v1 | 44.7 MB | 25.12.0 | aarch64_cortex-a53 | ✅ |
| Cudy M300 | 44.7 MB | 24.10.x | aarch64_cortex-a53 | ✅ |
| Xiaomi AX3000T | 59.8 MB | 24.10.1 | aarch64_cortex-a53 | ✅ (и полный влезает) |

## Как это работает

Скрипт основан на [itdoginfo/podkop/install.sh](https://github.com/itdoginfo/podkop) с одним ключевым отличием.
itdoginfo ставит **полный** sing-box (40 MB), который **не влезает** на Cudy-роутеры с 44 MB флеш-памяти.  

`thin-podkop` **перед** установкой podkop ставит **sing-box-tiny** (10 MB),  
который предоставляет (имеет `Provides: sing-box`) тот же функционал,  
поэтому opkg/apk не тянет полный sing-box как зависимость.

## Как выглядит установка

```
╔══════════════════════════════════════════════════════════╗
║     🎯  thin-podkop v1.0  —  тонкая установка          ║
║     📡  100.99.179.1  │  Cudy TR3000                   ║
║     🔧  opkg  │  aarch64_cortex-a53                    ║
║     📦  Podkop 0.7.17  │  sing-box-tiny 1.12.22        ║
╚══════════════════════════════════════════════════════════╝

 ─── [1/6]  System Check ─────────────────────────────
   ✓ Device: Cudy TR3000 v1
   ✓ OS:     OpenWrt 25.12.0  │  AArch64
   ✓ Flash:  18.9 MB free

 ─── [2/6]  Cleaning Old Podkop ───────────────────────
   ✓ Removed old podkop

 ─── [3/6]  Installing sing-box-tiny ──────────────────
   ✓ sing-box-tiny 1.12.22  │  7.2 MB installed

 ─── [4/6]  Downloading Podkop from GitHub ────────────
   ✓ podkop-v0.7.17-r1-all.ipk
   ✓ luci-app-podkop-v0.7.17-r1-all.ipk
   ✓ luci-i18n-podkop-ru-0.7.17.ipk

 ─── [5/6]  Installing Podkop + LuCI ──────────────────
   ✓ Podkop v0.7.17
   ✓ LuCI: Services → Podkop
   ✓ Russian language
   ✓ Default config (DNS 1.1.1.1, exclude_ntp=1)

 ─── [6/6]  Verify ────────────────────────────────────
   ✓ podkop: v0.7.17  │  sing-box: 1.12.22
   ✓ Free space: 18.9 MB
   ✓ Proxy: loc=DE

╔══════════════════════════════════════════════════════════╗
║     🎉  Установка завершена!                            ║
╚══════════════════════════════════════════════════════════╝
```

## Известные ограничения

- **OpenWrt 25.x:** sing-box-tiny может отсутствовать в репозиториях.  
  В этом случае скрипт загружает бинарник напрямую.
- Для **24.x** стабильно: `opkg install sing-box-tiny` из официального репозитория.
- После установки требуется ручная настройка ключа и списков (см. выше).

## Автор

[@vasneverov](https://github.com/vasneverov)  
Основано на [podkop](https://github.com/itdoginfo/podkop) от itdoginfo.

---

## fix-tailscale-openwrt.sh v3.3 — спасительный скрипт

Автоматическая настройка Tailscale + watchdogs на OpenWrt.

### Что нового в v3.3 (16.05.2026)

| Изменение | Было (v3.2) | Стало (v3.3) | Зачем |
|-----------|-------------|--------------|-------|
| **rc.local** | `tailscale up ... &` (в фоне, без authkey) | `tailscale up --reset --authkey=$TS_AUTH_KEY --hostname=... --netfilter-mode=off` (синхронно) | После ребута `--reset` без ключа сбрасывал авторизацию → Logged out |
| **Authkey** | Не сохранялся, rc.local перезаписывался без ключа | Извлекается из старого rc.local **до** перезаписи | Ключ не теряется после применения скрипта |
| **Очистка сокета** | Отсутствовала | `rm -f /var/run/tailscale/tailscaled.sock` | Старый сокет → NoState loop |
| **nftables** | Отсутствовали | `nft add rule inet fw4 forward ip daddr 100.64.0.0/10 counter accept` | Tailscale через двойной NAT не мог установить long-poll |
| **Watchdog v3.2** | Проверял только наличие `100.x.x.x` в статусе | Проверяет **и** отсутствие `offline` | При offline tailscale всё равно показывает IP → watchdog не чинил |
| **Grace period** | Отсутствовал | 180 секунд после загрузки | Не убивает tailscaled пока он стартует |

### Схема работы watchdog v3.2

```
tailscale status → 100.x.x.x  z56-70  ...  offline
                          ↑ IP есть           ↑ watchdog видит "offline"
                          └── раньше watchdog выходил (думал ONLINE)
                          └── теперь watchdog: "offline! → перезапуск"
```

### Установка

```bash
sh <(wget -O - https://raw.githubusercontent.com/vasneverov/openwrt-fix/main/fix-tailscale-openwrt.sh)
```

**Важно:** После скрипта нужно восстановить rc.local с authkey (если скрипт не нашёл ключ в старом rc.local).  
Подробнее: шаг 7 в `flash_router_universal.md`.

---

## fix-tailscale-openwrt.sh v7.6 — «безопасность доступа» + щит Tailscale (актуальная версия)

Тот же спасительный скрипт, та же команда. Безопасный режим: **без перезапусков и без ребута**, файлы эталона ставятся
только если установленная версия **старее** (бэкап заменённого — `/root/rescue-v7-<дата>/`).

```bash
sh <(wget -O - https://raw.githubusercontent.com/vasneverov/openwrt-fix/main/fix-tailscale-openwrt.sh)
# применить правки конфига forkop одним рестартом:
RESTART=1 sh <(wget -O - https://raw.githubusercontent.com/vasneverov/openwrt-fix/main/fix-tailscale-openwrt.sh)
```

**⛔ Железное правило: Tailscale не ломать никакими правками.** Демон `tailscaled` скрипт не останавливает и не перезапускает. «Щит Tailscale»: статус и pid до и после; если Tailscale был `Running`, а после правок нет — через 80 с скрипт сам откатывает файлы этого запуска из бэкапа и зовёт `ts-watchdog`. Ребут скрипт не делает никогда.

**v7.7 (10.10.2026):** паритет «чат ↔ компьютер» — встроены **ts-watchdog v6.8** (подтверждение «tailscaled not running» 3 проверками + общий кулдаун рестартов), **forkop-watchdog v2.2** (проверка перехвата fakeip tproxy на LAN), **сторож доменов v3.1**; маркеры обновления `ts-watchdog v6.8` / `ПЕРЕХВАТ fakeip` / `SOCIAL=`. Устаревшие версии заменяются, новые не трогаются.

**v7.6 (09.10.2026):**
- **3.8. Безопасность доступа — `dropbear`: `MaxAuthTries=6`, `IdleTimeout=120`.** Причина «SSH и LuCI пропали и вернулись сами»: dropbear рубит соединение на **3-й неудачной авторизации** (`Max auth tries reached`). При плотной работе/медленном пути через DERP-релей заходы обрывались → доступ пропадал на 20-30 с. Теперь бан на 3 опечатках доступ не вырубит. Idempotent.
- **5.95. Чистка следов:** убирает диагностический мусор (`/tmp/w*.sh`, `/tmp/*.log`, cron-строки `w*.sh`). Полезные бэкапы в `/root` НЕ трогает.
- **Проверка недопустимого nft-перехвата DNS** (`redirect :53` / `iifname br-lan`) — он заворачивает DNS клиентов и **рубит LuCI/rpcd** (наш урок ночи 09.10, z56-68).
- **⚠️ СТОП-ФАКТ:** НЕ импровизировать nft-перехват DNS + DoT/DoH-отказ на LAN — это убивает доступ (LuCI/SSH). **QUIC-блок (`udp dport 443 reject` в `raw_prerouting`) — безопасен и полезен**, только его и стоит ставить.
- Проверено: **z56-68** (Андрей Тиханов) — `MaxAuthTries=6` применён, следы убраны, доступ стабилен, Tailscale не тронут.

**v7.5 (08.10.2026):** «часы при загрузке» (P1 NTP по IP, P2 hotplug ntp 30-ts-sync, P3 rc.local ждёт NTP) — Tailscale на загрузке `Running` ~24 с вместо ~107 с (s78-39-karpin).

**v7.4:** в заголовке выводится имя роутера из панели Tailscale.

**v7.3:** перед установкой zram выполняется `opkg update`/`apk update` (без него на opkg-роутерах zram не ставился).

**v7.2:** способ запуска Tailscale вслепую не меняем. Если Tailscale стартует через `init.d` (в `rc.local` нет строки запуска), автозапуск `init.d` остаётся включённым, `rc.local` не трогается; если запуска нет нигде — эталонный блок добавляется в `rc.local`, ваши строки (`tailscale serve`, модем и т.д.) сохраняются. Правка `rc.local` считается сделанной только если файл реально изменился. Версии v7.0/v7.1 снимали автозапуск `init.d`, **не используйте их**.

Что нового с v6.7 (07.09 → 03.10.2026):
- блоки **«СОСТОЯНИЕ ДО / ПОСЛЕ»** с версиями и ✅/❌, список «исправлено» и «недочёты»;
- **ИИ (ChatGPT/Claude/Claude Code):** секция `ai` ставится ПЕРВОЙ, ИИ-домены убираются из `main`; в конце проверка выхода
  по `claude.ai/cdn-cgi/trace` (должно быть `US`, иначе Cloudflare блокирует: «Sorry, you have been blocked»);
- ts-watchdog **v6.6**, forkop-watchdog **v2.1**, hotplug 30-vpn **v2**, сторож доменов **v3**, безопасные fix-lists;
- `rc.local` правится **точечно** (userspace-networking, oom_score_adj −900, autoupdate off, hostname без «_»);
- уборка дублей: `podkop-watchdog.sh`, `podkop-fix-lists.sh`, `30-forkop`, `99-vpn-tailscale`, `init.d/*.bak`, `S80tailscale`, дубли cron;
- zram-swap, пояс Europe/Moscow, `filter_aaaa` по версии sing-box, исправлена проверка urltest (старая смотрела только `@urltest[0]`
  и плодила дубль «Самый лучший»), `dns_server` больше не затирает список серверов.

Секции `ai`/`kino` и подписки скрипт **не создаёт** (нужны подписки владельца) — в конце он подсказывает, как добавить.
