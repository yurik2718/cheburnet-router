#!/bin/sh
# 06-slider-led.sh — установить vpn-mode CLI, vpn-led скрипт, hotplug-хендлер,
# init.d сервис и cron для мониторинга AWG-здоровья.
set -e

echo "== 06. Slider + LED =="

# === 1. Копируем скрипты (предполагается /tmp/scripts от full-deploy.sh) ===
for SRC in vpn-mode vpn-led; do
    if [ -f /tmp/scripts/$SRC ]; then
        cp /tmp/scripts/$SRC /usr/bin/$SRC
        chmod +x /usr/bin/$SRC
        echo "→ установлен /usr/bin/$SRC"
    else
        echo "⚠ /tmp/scripts/$SRC отсутствует"
        exit 1
    fi
done

# === 2. Hotplug-хендлер слайдера ===
mkdir -p /etc/hotplug.d/button
if [ -f /tmp/scripts/hotplug/button/10-vpn-mode ]; then
    cp /tmp/scripts/hotplug/button/10-vpn-mode /etc/hotplug.d/button/10-vpn-mode
    chmod +x /etc/hotplug.d/button/10-vpn-mode
    echo "→ установлен hotplug-handler"
fi

# === 3. Init.d для синхронизации режима при загрузке ===
if [ -f /tmp/scripts/init.d/vpn-mode ]; then
    cp /tmp/scripts/init.d/vpn-mode /etc/init.d/vpn-mode
    chmod +x /etc/init.d/vpn-mode
    /etc/init.d/vpn-mode enable
    echo "→ установлен init.d/vpn-mode"
fi

# === 4. Cron для LED-мониторинга ===
crontab -l 2>/dev/null | grep -v vpn-led > /tmp/cron.tmp
echo "* * * * * /usr/bin/vpn-led" >> /tmp/cron.tmp
echo "* * * * * sleep 30 && /usr/bin/vpn-led" >> /tmp/cron.tmp
crontab /tmp/cron.tmp
rm /tmp/cron.tmp
/etc/init.d/cron restart >/dev/null

# === 5. Применяем текущее положение слайдера ===
/usr/bin/vpn-mode detect
/usr/bin/vpn-led

echo "→ текущее состояние:"
/usr/bin/vpn-mode status

echo "✓ slider + LED OK"
