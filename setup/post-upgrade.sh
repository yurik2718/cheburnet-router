#!/bin/sh
# post-upgrade.sh — восстановить пакеты после sysupgrade'а OpenWrt.
#
# Эта часть нашего стека НЕ сохраняется стандартным sysupgrade'ом:
#   - Out-of-tree apk-пакеты (AmneziaWG, podkop, sing-box, adblock-lean, sqm-scripts)
#   - wpad-mbedtls (заменяет wpad-basic-mbedtls после апгрейда)
#
# А ЭТО уже preserve'ится (благодаря нашему /etc/sysupgrade.conf):
#   - /usr/bin/vpn-* dns-* awg-watchdog log-snapshot sqm-tune
#   - /etc/hotplug.d/button/10-vpn-mode
#   - /etc/init.d/vpn-mode
#   - /etc/amnezia/amneziawg/awg0.conf (критично, содержит ключи)
#   - /etc/config/* (все UCI: podkop, wireless, firewall, sqm...)
#   - /etc/crontabs/root (все наши cron-записи)
#
# Idempotent: можно запускать многократно.
set -e

echo "=== post-upgrade: восстанавливаем пакеты после sysupgrade ==="

# === 1. apk update ===
echo "→ apk update"
apk update 2>&1 | tail -3

# === 2. wpad-mbedtls (заменяем базовый для поддержки WPA3) ===
if ! apk list --installed 2>/dev/null | grep -q wpad-mbedtls; then
    echo "→ wpad-basic-mbedtls → wpad-mbedtls"
    apk del wpad-basic-mbedtls 2>/dev/null || true
    apk add wpad-mbedtls
fi

# === 3. AmneziaWG (kmod + tools + luci-proto) ===
if ! lsmod | grep -q '^amneziawg '; then
    echo "→ AmneziaWG пакеты"

    # Автодетект архитектуры/версии (см. 01-amneziawg.sh — логика синхронизирована)
    # shellcheck disable=SC1091
    . /etc/openwrt_release
    if [ -z "${DISTRIB_ARCH:-}" ] || [ -z "${DISTRIB_TARGET:-}" ] || [ -z "${DISTRIB_RELEASE:-}" ]; then
        echo "✗ Не удалось определить архитектуру/версию роутера." >&2
        exit 1
    fi
    ARCH="${DISTRIB_ARCH}_$(echo "$DISTRIB_TARGET" | tr '/' '_')"

    AWG_VER=""
    for TRY in "$DISTRIB_RELEASE" "25.12.2"; do
        [ -z "$TRY" ] && continue
        URL="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v${TRY}/kmod-amneziawg_v${TRY}_${ARCH}.apk"
        if wget -q --spider --timeout=15 "$URL" 2>/dev/null; then
            AWG_VER="$TRY"; break
        fi
    done
    if [ -z "$AWG_VER" ]; then
        echo "✗ Нет совместимого релиза awg-openwrt для OpenWrt ${DISTRIB_RELEASE} / ${ARCH}." >&2
        exit 1
    fi
    echo "  arch=${ARCH}, awg-openwrt=v${AWG_VER}"

    BASE="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v${AWG_VER}"
    cd /tmp
    for PKG in "kmod-amneziawg_v${AWG_VER}" "amneziawg-tools_v${AWG_VER}" "luci-proto-amneziawg_v${AWG_VER}"; do
        FILE="${PKG}_${ARCH}.apk"
        wget -q -O "$FILE" "$BASE/$FILE" || { echo "download failed: $FILE"; exit 1; }
    done
    apk add --allow-untrusted "./kmod-amneziawg_v${AWG_VER}_${ARCH}.apk" \
                              "./amneziawg-tools_v${AWG_VER}_${ARCH}.apk" \
                              "./luci-proto-amneziawg_v${AWG_VER}_${ARCH}.apk"
    modprobe amneziawg
fi

# === 4. Podkop + sing-box ===
if [ ! -x /etc/init.d/podkop ]; then
    echo "→ podkop + sing-box"
    wget -qO /tmp/podkop-install.sh \
        https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh
    printf 'n\nn\nn\n' | sh /tmp/podkop-install.sh 2>&1 | tail -5
fi

# === 5. adblock-lean ===
if [ ! -x /etc/init.d/adblock-lean ]; then
    echo "→ adblock-lean"
    uclient-fetch -q \
        https://raw.githubusercontent.com/lynxthecat/adblock-lean/master/abl-install.sh \
        -O /tmp/abl-install.sh
    sh /tmp/abl-install.sh -v release
fi

# === 6. sqm-scripts ===
apk add --no-interactive sqm-scripts 2>&1 | tail -2 || true

# === 7. Enable нашего init.d сервиса ===
/etc/init.d/vpn-mode enable 2>/dev/null || true

# === 8. Перезапуск сервисов (берут сохранённые конфиги) ===
echo "→ перезапуск сервисов"
/etc/init.d/network reload
/etc/init.d/firewall reload >/dev/null 2>&1
/etc/init.d/podkop restart >/dev/null 2>&1 &
sleep 5
/etc/init.d/dnsmasq restart
/etc/init.d/adblock-lean start >/dev/null 2>&1
wifi reload

# === 9. Применяем режим слайдера ===
sleep 3
/usr/bin/vpn-mode detect 2>/dev/null || true

# === 10. Финальная проверка ===
echo
echo "=== СТАТУС ==="
echo "AWG: $(awg show awg0 2>/dev/null | awk '/latest handshake/{print; exit}' || echo 'interface not up — check logread')"
echo "Podkop: $(/etc/init.d/sing-box status 2>&1 | head -1)"
echo "Adblock: $(/etc/init.d/adblock-lean status 2>&1 | head -1)"
echo "VPN mode: $(/usr/bin/vpn-mode status 2>&1 | head -1)"
echo
echo "✓ post-upgrade выполнен"
echo
echo "Если что-то не работает:"
echo "  - logread -t podkop | tail"
echo "  - awg show awg0"
echo "  - /etc/init.d/podkop restart"
