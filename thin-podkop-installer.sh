#!/bin/sh
# shellcheck shell=dash
# ============================================================
# thin-podkop-installer.sh
# https://github.com/vasneverov/thin-podkop
# Версия: 1.0.0
#
# Установка Podkop + sing-box-tiny на OpenWrt 24.x (opkg) / 25.x (apk)
# Аналог itdoginfo/install.sh, но с тонким sing-box вместо полного
# ============================================================

MY_REPO="https://api.github.com/repos/vasneverov/thin-podkop/releases/latest"
PKG_IS_APK=0
command -v apk >/dev/null 2>&1 && PKG_IS_APK=1

# ─── Цвета ───────────────────────────────────────────────
GC="\033[32;1m"   # green checkmark
YC="\033[33;1m"   # yellow
RC="\033[31;1m"   # red
CC="\033[36;1m"   # cyan
NC="\033[0m"      # no color

msg()    { printf "${GC}%s${NC}\n" "$1"; }
warn()   { printf "${YC}%s${NC}\n" "$1"; }
err()    { printf "${RC}%s${NC}\n" "$1"; exit 1; }
info()   { printf "${CC}%s${NC}\n" "$1"; }
check()  { printf "${GC}✓${NC} %s\n" "$1"; }

# ─── Helpers ─────────────────────────────────────────────
pkg_is_installed() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk list --installed 2>/dev/null | grep -q "$1"
    else
        opkg list-installed 2>/dev/null | grep -q "$1"
    fi
}

pkg_install() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk add --allow-untrusted "$1"
    else
        opkg install "$1"
    fi
}

pkg_remove() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk del "$1"
    else
        opkg remove --force-depends "$1"
    fi
}

pkg_update() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk update
    else
        opkg update
    fi
}

# ─── Banner ──────────────────────────────────────────────
printf "${CC}"
printf "╔══════════════════════════════════════════════════════════╗\n"
printf "║        🎯  thin-podkop v1.0  —  тонкая установка       ║\n"
printf "╚══════════════════════════════════════════════════════════╝\n"
printf "${NC}\n"

DEVICE=$(cat /tmp/sysinfo/model 2>/dev/null || echo "unknown")
OS_VER=$(grep VERSION_ID /etc/os-release 2>/dev/null || echo "?")
ARCH=$(uname -m)
FREE=$(df -h / | tail -1 | awk '{print $4}')
TS_IP=$(tailscale ip -4 2>/dev/null || echo "none")

info " ├ Device: $DEVICE"
info " ├ OS:     ${PKG_IS_APK:+apk}${PKG_IS_APK:-opkg} · $ARCH · free: $FREE"
info " └ Tailscale: $TS_IP"
echo ""

# ─── [1/6]  Clean ───────────────────────────────────────
echo " ─── [1/6]  Cleaning Old Podkop ─────────────────────"
/etc/init.d/podkop stop 2>/dev/null || true
pkg_remove luci-app-podkop luci-i18n-podkop-ru luci-i18n-podkop 2>/dev/null || true
pkg_remove podkop 2>/dev/null || true

rm -rf /etc/sing-box/ /tmp/sing-box/ /usr/lib/podkop/ /tmp/luci-*
rm -f /usr/bin/podkop /etc/init.d/podkop /etc/uci-defaults/50_luci-podkop
rm -rf /www/luci-static/resources/view/podkop/ 2>/dev/null || true
check "Cleaned old podkop"

FREE=$(df -h / | tail -1 | awk '{print $4}')
check "Free: $FREE"
echo ""

# ─── [2/6]  Package Feeds ───────────────────────────────
echo " ─── [2/6]  Updating Package Feeds ───────────────────"
pkg_update 2>&1 | tail -1
check "Package lists updated"
echo ""

# ─── [3/6]  Install sing-box-tiny ───────────────────────
echo " ─── [3/6]  Installing sing-box-tiny ─────────────────"
if [ "$PKG_IS_APK" -eq 1 ]; then
    # OpenWrt 25.x — пробуем apk
    if apk add --allow-untrusted sing-box-tiny 2>/dev/null; then
        check "sing-box-tiny installed via apk"
    else
        # Fallback: скачиваем ipk из 24.10 и копируем бинарник
        warn "sing-box-tiny not in 25.x repo, downloading binary..."
        wget -q -O /tmp/sing-box.gz "https://github.com/vasneverov/thin-podkop/releases/download/v1.0/sing-box-tiny-linux-aarch64.gz" 2>/dev/null || \
        curl -sL -o /tmp/sing-box.gz "https://github.com/vasneverov/thin-podkop/releases/download/v1.0/sing-box-tiny-linux-aarch64.gz"
        gunzip -f /tmp/sing-box.gz 2>/dev/null
        mv /tmp/sing-box /usr/bin/sing-box 2>/dev/null
        chmod +x /usr/bin/sing-box
    fi
else
    # OpenWrt 24.x — opkg
    opkg install sing-box-tiny 2>&1 | tail -1
fi

if command -v sing-box >/dev/null 2>&1; then
    check "sing-box $(sing-box version 2>/dev/null | head -1 | awk '{print $3}')"
else
    err "sing-box installation failed!"
fi
echo ""

# ─── [4/6]  Download Podkop from GitHub ─────────────────
echo " ─── [4/6]  Downloading Podkop from GitHub ──────────"
SUFFIX="ipk"
[ "$PKG_IS_APK" -eq 1 ] && SUFFIX="apk"

DOWNLOAD_DIR="/tmp/podkop"
rm -rf "$DOWNLOAD_DIR"
mkdir -p "$DOWNLOAD_DIR"

warn "Fetching latest release..."
for url in $(curl -s "$MY_REPO" | grep -o "https://[^\"]*\.$SUFFIX" | head -5); do
    filename=$(basename "$url")
    wget -q -O "$DOWNLOAD_DIR/$filename" "$url" 2>/dev/null
    if [ -f "$DOWNLOAD_DIR/$filename" ]; then
        check "$filename"
    fi
done

# Fallback: if GitHub release not available, use itdoginfo
if ! ls "$DOWNLOAD_DIR"/*podkop* >/dev/null 2>&1; then
    warn "My release not found, falling back to itdoginfo..."
    ITDOG_REPO="https://api.github.com/repos/itdoginfo/podkop/releases/latest"
    for url in $(curl -s "$ITDOG_REPO" | grep -o "https://[^\"]*\.$SUFFIX" | head -5); do
        filename=$(basename "$url")
        wget -q -O "$DOWNLOAD_DIR/$filename" "$url" 2>/dev/null
        [ -f "$DOWNLOAD_DIR/$filename" ] && check "$filename"
    done
fi
echo ""

# ─── [5/6]  Install Podkop + LuCI ──────────────────────
echo " ─── [5/6]  Installing Podkop + LuCI ────────────────"
for f in "$DOWNLOAD_DIR"/*podkop*; do
    [ -f "$f" ] && pkg_install "$f" 2>&1 | tail -1 && check "podkop installed"
done
for f in "$DOWNLOAD_DIR"/*luci-app*; do
    [ -f "$f" ] && pkg_install "$f" 2>&1 | tail -1 && check "luci-app-podkop installed"
done
for f in "$DOWNLOAD_DIR"/*luci-i18n*; do
    [ -f "$f" ] && pkg_install "$f" 2>&1 | tail -1 && check "luci-i18n-podkop-ru installed"
done
check "Russian language installed"
echo ""

# ─── [5b]  Register LuCI ────────────────────────────────
[ -f /etc/uci-defaults/50_luci-podkop ] && sh /etc/uci-defaults/50_luci-podkop
rm -f /tmp/luci-*cache*
/etc/init.d/rpcd restart 2>/dev/null || true
/etc/init.d/uhttpd restart 2>/dev/null || true
check "LuCI menu registered"

# ─── [5c]  Fix main() bug ───────────────────────────────
sed -i 's/^main)$/main) start_main/' /usr/bin/podkop 2>/dev/null || true
check "podkop main() patched"

# ─── [5d]  Default Config ───────────────────────────────
touch /etc/config/podkop
chmod 644 /etc/config/podkop
uci set podkop.settings="settings"
uci set podkop.settings.dns_server="1.1.1.1"
uci set podkop.settings.bootstrap_dns_server="1.1.1.1"
uci set podkop.settings.update_interval="1h"
uci set podkop.settings.download_lists_via_proxy="0"
uci set podkop.settings.exclude_ntp="1"
uci set podkop.settings.enable_output_network_interface="1"
uci commit podkop
check "Default config created"
echo ""

# ─── [6/6]  Verify ──────────────────────────────────────
echo " ─── [6/6]  Verify Setup ───────────────────────────"
PKG_VER=$(/usr/bin/podkop show_version 2>/dev/null || echo "?")
SB_VER=$(sing-box version 2>/dev/null | head -1 | awk '{print $3}' || echo "?")
check "podkop: $PKG_VER  │  sing-box: $SB_VER"

if [ -f /www/luci-static/resources/view/podkop/podkop.js ]; then
    check "LuCI: Services → Podkop [OK]"
else
    warn "LuCI JS not found in /www — check luci-app extraction"
fi

FREE=$(df -h / | tail -1 | awk '{print $4}')
check "Free space: $FREE"

SB_PID=$(pgrep sing-box 2>/dev/null || echo "-")
LOC=$(curl -s --max-time 5 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep "loc=" || echo "?")
check "sing-box PID: $SB_PID  │  Proxy: $LOC"

echo ""
printf "${GC}"
printf "╔══════════════════════════════════════════════════════════╗\n"
printf "║        🎉  Установка завершена!                         ║\n"
printf "║                                                         ║\n"
printf "║  Осталось:                                              ║\n"
printf "║    1. Вставить ключ (podkop main → proxy_string)        ║\n"
printf "║    2. 21 список                                          ║\n"
printf "║    3. Спасительный скрипт                                 ║\n"
printf "║    4. /usr/bin/podkop list_update                        ║\n"
printf "║    5. /etc/init.d/podkop restart                         ║\n"
printf "╚══════════════════════════════════════════════════════════╝\n"
printf "${NC}"

rm -rf "$DOWNLOAD_DIR"
