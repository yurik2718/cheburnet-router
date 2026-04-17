#!/bin/sh
# 12-travel-plus.sh — USB tethering + Wi-Fi scan/profiles + MAC random + diag.
# Расширяет Tier 1 (11-travel.sh) до полного travel-функционала, сопоставимого
# со стоковой прошивкой GL.iNet.
set -e

echo "== 12. Travel plus (USB tether, scan, profiles, MAC, diag) =="

# === 1. USB tethering kmods + userspace ===
echo "→ установка USB-tethering пакетов"
apk add --no-interactive \
    kmod-usb-net \
    kmod-usb-net-rndis \
    kmod-usb-net-ipheth \
    kmod-usb-net-cdc-ether \
    kmod-usb-net-qmi-wwan \
    kmod-usb-net-cdc-mbim \
    kmod-usb-serial-option \
    kmod-usb-serial-wwan \
    uqmi \
    umbim \
    usb-modeswitch \
    usbutils \
    comgt 2>&1 | tail -3 || true

# === 2. Scripts ===
for SRC in travel-tether travel-scan travel-wifi travel-mac travel-check; do
    if [ -f /tmp/scripts/$SRC ]; then
        cp /tmp/scripts/$SRC /usr/bin/$SRC
        chmod +x /usr/bin/$SRC
        echo "→ установлен /usr/bin/$SRC"
    fi
done

# === 3. Directory для Wi-Fi profiles ===
mkdir -p /etc/travel-wifi
chmod 700 /etc/travel-wifi

echo
echo "✓ travel-plus OK"
echo
echo "Быстрый справочник в дороге:"
echo "  travel-scan               # найти доступные Wi-Fi"
echo "  travel-connect \"SSID\" \"pwd\"  # подключиться"
echo "  travel-wifi save foo \"SSID\" \"pwd\"  # запомнить"
echo "  travel-wifi connect foo   # быстрый reconnect"
echo "  travel-tether on          # USB-модем/телефон"
echo "  travel-portal             # captive portal bypass"
echo "  travel-mac random         # сменить MAC"
echo "  travel-check              # полная диагностика"
