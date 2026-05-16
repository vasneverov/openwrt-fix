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
