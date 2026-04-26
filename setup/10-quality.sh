#!/bin/sh
# 10-quality.sh — базовые системные настройки.
set -e

echo "== 10. System settings =="

# === 1. Timezone ===
echo "→ timezone → Europe/Moscow (MSK, UTC+3)"
uci set system.@system[0].timezone='MSK-3'
uci set system.@system[0].zonename='Europe/Moscow'
uci commit system
/etc/init.d/system reload
echo "  date: $(date)"

# === 2. /etc/sysupgrade.conf — сохранить кастомные файлы при обновлении прошивки ===
echo "→ /etc/sysupgrade.conf (сохранение файлов при sysupgrade)"
if [ -f /tmp/configs/sysupgrade.conf ]; then
    cp /tmp/configs/sysupgrade.conf /etc/sysupgrade.conf
    echo "  установлен, protect-list:"
    cat /etc/sysupgrade.conf | grep -v '^#' | grep -v '^$' | head -15
else
    echo "  ⚠ /tmp/configs/sysupgrade.conf отсутствует — protect-list не обновлён"
fi

echo
echo "✓ Quality OK"
