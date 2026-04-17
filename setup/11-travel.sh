#!/bin/sh
# 11-travel.sh — установить скрипты для TRAVEL-режима (WISP + captive portal).
set -e

echo "== 11. Travel mode helpers =="

for SRC in travel-connect travel-portal travel-vpn-on; do
    if [ -f /tmp/scripts/$SRC ]; then
        cp /tmp/scripts/$SRC /usr/bin/$SRC
        chmod +x /usr/bin/$SRC
        echo "→ установлен /usr/bin/$SRC"
    else
        echo "⚠ /tmp/scripts/$SRC отсутствует"
        exit 1
    fi
done

# Обновлённый vpn-led с поддержкой heartbeat-паттерна для portal-режима
if [ -f /tmp/scripts/vpn-led ]; then
    cp /tmp/scripts/vpn-led /usr/bin/vpn-led
    chmod +x /usr/bin/vpn-led
fi

echo "✓ travel-mode scripts OK"
echo
echo "В поездке:"
echo "  travel-connect \"HotelWiFi\" \"password\"   # подключиться к upstream"
echo "  travel-portal                            # принять отельный portal"
echo "  vpn-mode travel                          # full tunnel"
echo "  travel-connect --off                     # отключиться"
