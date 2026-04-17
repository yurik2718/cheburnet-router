#!/bin/sh
# backup.sh — выгрузить текущее состояние роутера в локальный архив.
#
# Запускать с ноутбука. Архив попадает в backup/snapshots/<timestamp>/
# и содержит: UCI, кастомные скрипты, сертификаты, ключи AWG.
#
# ВНИМАНИЕ: архив содержит СЕКРЕТЫ (private keys). Храните локально!
# Не коммитьте в git, не публикуйте.
#
# Пример:
#   ./backup/backup.sh root@192.168.1.1
set -e

ROUTER="${1:?Usage: $0 root@<router-ip>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
SNAP="$REPO_ROOT/backup/snapshots/$STAMP"
mkdir -p "$SNAP"

echo "=== backup из $ROUTER → $SNAP ==="

# === 1. UCI-конфиги ===
echo "→ UCI"
ssh "$ROUTER" 'uci export' > "$SNAP/uci-export.txt"
# Отдельно ключевые подсистемы (проще вычитывать)
for CONFIG in network firewall wireless dhcp podkop; do
    ssh "$ROUTER" "uci show $CONFIG" > "$SNAP/uci-$CONFIG.txt" 2>/dev/null
done

# === 2. Кастомные скрипты ===
echo "→ /usr/bin custom scripts"
mkdir -p "$SNAP/usr-bin"
for F in vpn-mode vpn-led dns-provider dns-healthcheck awg-watchdog log-snapshot sqm-tune \
         travel-connect travel-portal travel-vpn-on \
         travel-tether travel-scan travel-wifi travel-mac travel-check; do
    ssh "$ROUTER" "cat /usr/bin/$F 2>/dev/null" > "$SNAP/usr-bin/$F" || true
done

# === 3. Hotplug/init.d ===
mkdir -p "$SNAP/hotplug/button" "$SNAP/init.d"
ssh "$ROUTER" 'cat /etc/hotplug.d/button/10-vpn-mode 2>/dev/null' > "$SNAP/hotplug/button/10-vpn-mode" || true
ssh "$ROUTER" 'cat /etc/init.d/vpn-mode 2>/dev/null' > "$SNAP/init.d/vpn-mode" || true

# === 4. Чувствительные конфиги ===
echo "→ secrets (AWG, wifi) — храните архив приватно!"
mkdir -p "$SNAP/secrets"
ssh "$ROUTER" 'cat /etc/amnezia/amneziawg/awg0.conf 2>/dev/null' > "$SNAP/secrets/awg0.conf" || true
ssh "$ROUTER" 'cat /etc/vpn-mode.state 2>/dev/null' > "$SNAP/secrets/vpn-mode.state" || true

# === 5. Adblock-lean config ===
echo "→ adblock-lean"
mkdir -p "$SNAP/adblock-lean"
ssh "$ROUTER" 'cat /etc/adblock-lean/config 2>/dev/null' > "$SNAP/adblock-lean/config" || true

# === 5a. Сохранённые Wi-Fi профили (secrets!) ===
echo "→ travel-wifi profiles"
mkdir -p "$SNAP/travel-wifi"
for CONF in $(ssh "$ROUTER" 'ls /etc/travel-wifi/*.conf 2>/dev/null' || true); do
    NAME=$(basename "$CONF")
    ssh "$ROUTER" "cat $CONF 2>/dev/null" > "$SNAP/travel-wifi/$NAME" || true
done

# === 5b. ksmbd (SMB share) — пароли, hotplug handler ===
echo "→ ksmbd (SMB share)"
mkdir -p "$SNAP/ksmbd"
ssh "$ROUTER" 'tar -cf - -C /etc ksmbd 2>/dev/null' 2>/dev/null | tar -xf - -C "$SNAP/" 2>/dev/null || true
mkdir -p "$SNAP/hotplug.d/block"
ssh "$ROUTER" 'cat /etc/hotplug.d/block/10-usb-storage-mount 2>/dev/null' > "$SNAP/hotplug.d/block/10-usb-storage-mount" || true
ssh "$ROUTER" 'cat /root/family-smb.txt 2>/dev/null' > "$SNAP/family-smb.txt" 2>/dev/null || true

# === 6. Crontab ===
echo "→ crontab"
ssh "$ROUTER" 'crontab -l 2>/dev/null' > "$SNAP/crontab.txt" || true

# === 7. Метаданные ===
echo "→ metadata"
cat > "$SNAP/METADATA.txt" <<EOF
Backup timestamp: $STAMP ($(date))
Router: $ROUTER
OpenWrt version: $(ssh "$ROUTER" 'cat /etc/openwrt_release | head -4')
Hardware: $(ssh "$ROUTER" 'ubus call system board 2>/dev/null | head -6')
Installed packages (adblock/podkop/amneziawg): $(ssh "$ROUTER" 'apk list --installed 2>/dev/null | grep -E "adblock|podkop|amneziawg|sing-box" | sort')
EOF

# === 8. Права ===
chmod -R go-rwx "$SNAP"

# === 9. Упаковка (опционально) ===
tar -C "$REPO_ROOT/backup/snapshots" -czf "$SNAP.tar.gz" "$STAMP"
chmod 600 "$SNAP.tar.gz"

echo
echo "✓ Backup готов:"
echo "  $SNAP/            — директория с файлами"
echo "  $SNAP.tar.gz       — упакованный архив (приватно!)"
echo
echo "⚠ ВНИМАНИЕ: в архиве ПРИВАТНЫЕ КЛЮЧИ. Не коммитьте в git и не публикуйте."
