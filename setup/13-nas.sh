#!/bin/sh
# 13-nas.sh — превратить роутер в семейный NAS через ksmbd + USB-storage.
#
# Что делает:
#   - Ставит kmod для USB-storage + файловых систем (ntfs3 / ext4 / vfat / exfat)
#   - Ставит ksmbd-server (SMB3 в ядре — быстрый, lightweight)
#   - Настраивает share /mnt/storage с общим логином 'family'
#   - Устанавливает hotplug-handler для auto-mount USB-дисков
#   - Генерирует strong случайный пароль, пишет credentials в /root/family-smb.txt
#
# Окружение:
#   SMB_USER=family       (default)
#   SMB_PASS=...          (default — auto-generate)
#   SHARE_NAME=storage    (default)
#
# После запуска: воткните USB-диск → /mnt/storage автоматически монтируется
# → share доступен на \\<router>\storage
set -e

echo "== 13. Family NAS (ksmbd + USB storage) =="

SMB_USER="${SMB_USER:-family}"
SHARE_NAME="${SHARE_NAME:-storage}"

# === 1. Пакеты ===
echo "→ установка ksmbd + USB filesystem kmods"
apk add --no-interactive \
    kmod-usb-storage \
    kmod-scsi-core \
    block-mount \
    kmod-fs-ntfs3 \
    kmod-fs-ext4 \
    kmod-fs-vfat \
    kmod-fs-exfat \
    ksmbd-server \
    kmod-fs-ksmbd \
    luci-app-ksmbd \
    e2fsprogs 2>&1 | tail -3 || true

# === 2. Mount point ===
mkdir -p /mnt/storage
chmod 755 /mnt/storage

# === 3. Сгенерировать пароль (если не передан) ===
if [ -z "$SMB_PASS" ]; then
    SMB_PASS=$(tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom 2>/dev/null | head -c 14)
    echo "→ сгенерирован случайный пароль (14 chars, без confusing 0/O/1/l/I)"
fi

# === 4. ksmbd UCI share ===
echo "→ ksmbd UCI config"
uci -q delete ksmbd.$SHARE_NAME 2>/dev/null || true
uci set ksmbd.$SHARE_NAME=share
uci set ksmbd.$SHARE_NAME.name="$SHARE_NAME"
uci set ksmbd.$SHARE_NAME.path='/mnt/storage'
uci set ksmbd.$SHARE_NAME.read_only='no'
uci set ksmbd.$SHARE_NAME.guest_ok='no'
uci set ksmbd.$SHARE_NAME.browseable='yes'
uci set ksmbd.$SHARE_NAME.writeable='yes'
uci set ksmbd.$SHARE_NAME.create_mask='0644'
uci set ksmbd.$SHARE_NAME.dir_mask='0755'
uci -q delete ksmbd.$SHARE_NAME.users 2>/dev/null || true
uci add_list ksmbd.$SHARE_NAME.users="$SMB_USER"
uci commit ksmbd

# === 5. Добавить samba-пользователя ===
echo "→ добавляю пользователя '$SMB_USER'"
mkdir -p /etc/ksmbd
# Обновляем если есть, создаём если нет
ksmbd.adduser -a "$SMB_USER" -p "$SMB_PASS" 2>&1 | tail -2 || \
    ksmbd.adduser -u "$SMB_USER" -p "$SMB_PASS" 2>&1 | tail -2

# === 6. Hotplug handler для auto-mount USB ===
echo "→ hotplug auto-mount handler"
mkdir -p /etc/hotplug.d/block
if [ -f /tmp/scripts/hotplug/block/10-usb-storage-mount ]; then
    cp /tmp/scripts/hotplug/block/10-usb-storage-mount /etc/hotplug.d/block/10-usb-storage-mount
    chmod +x /etc/hotplug.d/block/10-usb-storage-mount
else
    echo "⚠ /tmp/scripts/hotplug/block/10-usb-storage-mount отсутствует — handler не установлен"
fi

# === 7. Enable + start ===
/etc/init.d/ksmbd enable
/etc/init.d/ksmbd restart >/dev/null 2>&1
sleep 2

# === 8. Сохранить credentials для пользователя ===
cat > /root/family-smb.txt <<EOF
=== cheburnet-router Family NAS credentials ===
Server:  \\\\192.168.1.1\\$SHARE_NAME   (Windows)
         smb://192.168.1.1/$SHARE_NAME  (macOS/Linux/mobile)
User:    $SMB_USER
Pass:    $SMB_PASS

Хранение: /mnt/storage (USB-диск автоматически монтируется сюда)
Файловые системы: ntfs/ntfs3, ext4/ext3/ext2, vfat, exfat

Для использования:
1. Воткните USB-диск в роутер
2. Проверьте что смонтировался: ssh root@192.168.1.1 'df -h /mnt/storage'
3. Подключитесь с клиента по credentials выше
EOF
chmod 600 /root/family-smb.txt

echo
echo "✓ NAS готов"
echo
echo "Credentials сохранены в /root/family-smb.txt (покажите только семье)"
echo "  Share: \\\\192.168.1.1\\$SHARE_NAME"
echo "  User:  $SMB_USER"
echo "  Pass:  $SMB_PASS"
echo
echo "Чтобы начать использовать: воткните USB-диск в порт роутера."
