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

# === 3. conntrack тайм-ауты — предотвращение переполнения таблицы ===
# Симптом переполнения: VPN замедляется в 100x через 1-2 недели, лечится ребутом.
echo "→ conntrack-tune (уменьшаем тайм-ауты, предотвращаем переполнение)"
if [ -f /tmp/scripts/conntrack-tune ]; then
    cp /tmp/scripts/conntrack-tune /usr/bin/conntrack-tune
    chmod +x /usr/bin/conntrack-tune
    echo "  установлен /usr/bin/conntrack-tune"
else
    echo "  ⚠ /tmp/scripts/conntrack-tune не найден — пропускаю"
fi

# Применяем немедленно
/usr/bin/conntrack-tune 2>/dev/null && echo "  применено" || true

# Прописываем в sysctl.conf чтобы пережить ребут
# (sysctl.d/11-nf-conntrack.conf нельзя редактировать — теряется при sysupgrade)
cat >> /etc/sysctl.conf <<'SYSCTL'

# conntrack-tune: оптимальные тайм-ауты для VPN-шлюза (cheburnet-router)
net.netfilter.nf_conntrack_tcp_timeout_established=3600
net.netfilter.nf_conntrack_tcp_timeout_close_wait=60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait=60
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
net.netfilter.nf_conntrack_udp_timeout_stream=60
SYSCTL
echo "  записано в /etc/sysctl.conf"

# @reboot cron — применяем сразу после загрузки (перекрываем sysctl.d)
crontab -l 2>/dev/null | grep -v conntrack-tune > /tmp/cron.tmp
echo "@reboot sleep 10 && /usr/bin/conntrack-tune" >> /tmp/cron.tmp
crontab /tmp/cron.tmp
rm /tmp/cron.tmp
/etc/init.d/cron restart >/dev/null
echo "  cron @reboot OK"

echo
echo "✓ Quality OK"
