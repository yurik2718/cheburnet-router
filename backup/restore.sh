#!/bin/sh
# restore.sh — восстановить снимок на чистый OpenWrt-роутер.
#
# Предполагается что пакеты уже установлены (через setup/*).
# Этот скрипт только накатывает UCI-конфиги, скрипты и секреты.
#
# Пример:
#   ./backup/restore.sh backup/snapshots/20260417-120000 root@192.168.1.1
set -e

SNAP="${1:?Usage: $0 <snapshot-dir> root@<router-ip>}"
ROUTER="${2:?Usage: $0 <snapshot-dir> root@<router-ip>}"

[ -d "$SNAP" ] || { echo "ERROR: $SNAP не директория"; exit 1; }

echo "=== restore из $SNAP → $ROUTER ==="

# === 1. UCI ===
if [ -f "$SNAP/uci-export.txt" ]; then
    echo "→ UCI import"
    scp -q "$SNAP/uci-export.txt" "$ROUTER":/tmp/uci-restore.txt
    ssh "$ROUTER" 'uci import < /tmp/uci-restore.txt && uci commit && rm /tmp/uci-restore.txt'
fi

# === 2. Custom scripts ===
echo "→ custom scripts"
for F in vpn-mode dns-provider dns-healthcheck awg-watchdog log-snapshot sqm-tune \
         travel-connect travel-portal travel-vpn-on \
         travel-tether travel-scan travel-wifi travel-mac travel-check; do
    if [ -f "$SNAP/usr-bin/$F" ]; then
        scp -q "$SNAP/usr-bin/$F" "$ROUTER":/usr/bin/$F
        ssh "$ROUTER" "chmod +x /usr/bin/$F"
    fi
done

# === 3. Hotplug / init.d ===
if [ -f "$SNAP/hotplug/button/10-vpn-mode" ]; then
    ssh "$ROUTER" 'mkdir -p /etc/hotplug.d/button'
    scp -q "$SNAP/hotplug/button/10-vpn-mode" "$ROUTER":/etc/hotplug.d/button/
    ssh "$ROUTER" 'chmod +x /etc/hotplug.d/button/10-vpn-mode'
fi

if [ -f "$SNAP/init.d/vpn-mode" ]; then
    scp -q "$SNAP/init.d/vpn-mode" "$ROUTER":/etc/init.d/vpn-mode
    ssh "$ROUTER" 'chmod +x /etc/init.d/vpn-mode; /etc/init.d/vpn-mode enable'
fi

# === 4. Секреты ===
if [ -f "$SNAP/secrets/awg0.conf" ]; then
    echo "→ awg0.conf"
    ssh "$ROUTER" 'mkdir -p /etc/amnezia/amneziawg'
    scp -q "$SNAP/secrets/awg0.conf" "$ROUTER":/etc/amnezia/amneziawg/awg0.conf
    ssh "$ROUTER" 'chmod 600 /etc/amnezia/amneziawg/awg0.conf'
fi

if [ -f "$SNAP/secrets/vpn-mode.state" ]; then
    scp -q "$SNAP/secrets/vpn-mode.state" "$ROUTER":/etc/vpn-mode.state
fi

# === 5. Adblock-lean ===
if [ -f "$SNAP/adblock-lean/config" ]; then
    echo "→ adblock-lean config"
    ssh "$ROUTER" 'mkdir -p /etc/adblock-lean'
    scp -q "$SNAP/adblock-lean/config" "$ROUTER":/etc/adblock-lean/config
fi

# === 6. Crontab ===
if [ -s "$SNAP/crontab.txt" ]; then
    echo "→ crontab"
    scp -q "$SNAP/crontab.txt" "$ROUTER":/tmp/crontab.txt
    ssh "$ROUTER" 'crontab /tmp/crontab.txt; rm /tmp/crontab.txt'
fi

# === 7. Перезагрузка сервисов ===
echo "→ restart сервисов"
ssh "$ROUTER" '/etc/init.d/network reload; \
    /etc/init.d/firewall reload; \
    /etc/init.d/podkop restart >/dev/null 2>&1 & \
    /etc/init.d/dnsmasq restart; \
    /etc/init.d/adblock-lean restart; \
    wifi reload; \
    sleep 5'

echo
echo "✓ Restore готов."
echo "Проверьте статус: ssh $ROUTER 'awg show awg0; vpn-mode status'"
