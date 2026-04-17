#!/bin/sh
# 10-quality.sh — меры улучшения качества эксплуатации:
# - Часовой пояс MSK (Europe/Moscow)
# - Persistent logs с дневной ротацией (хранение 14 дней на flash)
# - SQM (cake) установка, но без автоматического включения
#   (скорость ISP нужно измерить вручную и применить через /usr/bin/sqm-tune)
set -e

echo "== 10. Quality improvements =="

# === 1. Timezone ===
echo "→ timezone → Europe/Moscow (MSK, UTC+3)"
uci set system.@system[0].timezone='MSK-3'
uci set system.@system[0].zonename='Europe/Moscow'
uci commit system
/etc/init.d/system reload
echo "  date: $(date)"

# === 2. Persistent logs ===
echo "→ устанавливаем log-snapshot (cron ежедневно в 23:55)"
if [ -f /tmp/scripts/log-snapshot ]; then
    cp /tmp/scripts/log-snapshot /usr/bin/log-snapshot
    chmod +x /usr/bin/log-snapshot
    mkdir -p /root/logs
    # cron
    crontab -l 2>/dev/null | grep -v log-snapshot > /tmp/cron.tmp
    echo "55 23 * * * /usr/bin/log-snapshot" >> /tmp/cron.tmp
    crontab /tmp/cron.tmp
    rm /tmp/cron.tmp
    /etc/init.d/cron restart >/dev/null
    # первый прогон
    /usr/bin/log-snapshot
    echo "  first snapshot: $(ls -la /root/logs/*.log 2>/dev/null | tail -1)"
else
    echo "  ⚠ /tmp/scripts/log-snapshot отсутствует"
fi

# === 3. SQM (установка, не включение) ===
echo "→ SQM (cake) установка для eth0"
apk add --no-interactive sqm-scripts 2>&1 | tail -3 || true

# Помощник для тюнинга
if [ -f /tmp/scripts/sqm-tune ]; then
    cp /tmp/scripts/sqm-tune /usr/bin/sqm-tune
    chmod +x /usr/bin/sqm-tune
fi

# Конфиг для eth0 (WAN), но ВЫКЛЮЧЕН
uci -q delete sqm.eth1 2>/dev/null || true
uci set sqm.eth0=queue
uci set sqm.eth0.interface='eth0'
uci set sqm.eth0.enabled='0'          # ВЫКЛЮЧЕН — включать после sqm-tune
uci set sqm.eth0.download='95000'     # placeholder
uci set sqm.eth0.upload='95000'       # placeholder
uci set sqm.eth0.qdisc='cake'
uci set sqm.eth0.script='piece_of_cake.qos'
uci set sqm.eth0.qdisc_advanced='0'
uci set sqm.eth0.linklayer='ethernet'
uci set sqm.eth0.overhead='18'
uci commit sqm

# === 4. /etc/sysupgrade.conf — preserve наши кастомные файлы при sysupgrade ===
echo "→ /etc/sysupgrade.conf (preserve custom files across firmware upgrades)"
if [ -f /tmp/configs/sysupgrade.conf ]; then
    cp /tmp/configs/sysupgrade.conf /etc/sysupgrade.conf
    echo "  установлен, preserve-list:"
    sysupgrade -l 2>&1 | grep -E "amnezia|vpn-mode|vpn-led|dns-provider|awg-watchdog|log-snapshot|sqm-tune|hotplug.d/button|adblock-lean" | head -10
else
    echo "  ⚠ /tmp/configs/sysupgrade.conf отсутствует — preserve-list не обновлён"
fi

echo
echo "✓ Quality OK"
echo
echo "Для активации SQM (ПОСЛЕ измерения скорости ISP):"
echo "  sqm-tune <download_Mbps> <upload_Mbps>"
echo "Пример: sqm-tune 500 500"
