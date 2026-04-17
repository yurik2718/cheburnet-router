#!/bin/sh
# 08-watchdog.sh — установить awg-watchdog (мониторинг свежести handshake + авто-рестарт).
set -e

echo "== 08. AWG Watchdog =="

# === 1. Копируем скрипт ===
if [ -f /tmp/scripts/awg-watchdog ]; then
    cp /tmp/scripts/awg-watchdog /usr/bin/awg-watchdog
    chmod +x /usr/bin/awg-watchdog
    echo "→ установлен /usr/bin/awg-watchdog"
else
    echo "⚠ /tmp/scripts/awg-watchdog не найден"
    exit 1
fi

# === 2. Cron ===
echo "→ настраиваем cron"
crontab -l 2>/dev/null | grep -v awg-watchdog > /tmp/cron.tmp
echo "* * * * * /usr/bin/awg-watchdog" >> /tmp/cron.tmp
crontab /tmp/cron.tmp
rm /tmp/cron.tmp
/etc/init.d/cron restart >/dev/null

# === 3. Первый прогон ===
echo "→ тестовый прогон:"
/usr/bin/awg-watchdog
echo "exit=$?"

echo "✓ watchdog OK"
echo
echo "Мониторить работу можно через:"
echo "  logread -t awg-watchdog -e awg-watchdog"
echo "  cat /tmp/awg-watchdog/fails   # счётчик подряд-рестартов"
