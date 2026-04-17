#!/bin/sh
# 04-dns.sh — настроить Quad9 DoH + Cloudflare fallback + автофейловер.
set -e

echo "== 04. DNS (Quad9 DoH + failover) =="

# === 1. UCI podkop DNS ===
uci set podkop.settings.dns_type='doh'
uci set podkop.settings.dns_server='dns.quad9.net/dns-query'
uci set podkop.settings.bootstrap_dns_server='1.1.1.1'
uci commit podkop

# === 2. Копируем скрипты (vpn-mode и dns-* должны быть в scripts/) ===
# Эти скрипты предполагаются скопированными через scp или через full-deploy.sh
for SRC in dns-provider dns-healthcheck; do
    if [ -f /tmp/scripts/$SRC ]; then
        cp /tmp/scripts/$SRC /usr/bin/$SRC
        chmod +x /usr/bin/$SRC
        echo "→ установлен /usr/bin/$SRC"
    else
        echo "⚠ /tmp/scripts/$SRC не найден — скопируйте вручную"
    fi
done

# === 3. Cron для health-check ===
echo "→ настраиваем cron для авто-фейловера"
crontab -l 2>/dev/null | grep -v dns-healthcheck > /tmp/cron.tmp
echo "* * * * * /usr/bin/dns-healthcheck" >> /tmp/cron.tmp
echo "* * * * * sleep 30 && /usr/bin/dns-healthcheck" >> /tmp/cron.tmp
crontab /tmp/cron.tmp
rm /tmp/cron.tmp
/etc/init.d/cron restart >/dev/null

# === 4. Reload podkop для применения нового DNS ===
/etc/init.d/podkop reload >/dev/null 2>&1 &
sleep 8

# === 5. Проверка ===
if /usr/bin/dns-provider status 2>/dev/null | grep -q Quad9; then
    echo "✓ Quad9 DoH активен"
else
    echo "⚠ dns-provider status говорит:"
    /usr/bin/dns-provider status
fi

# Живой тест
if nslookup cloudflare.com 192.168.1.1 2>/dev/null | grep -q Address; then
    echo "✓ резолвинг работает"
else
    echo "⚠ DNS не резолвит — проверьте logread | grep sing-box | grep dns"
fi

echo "✓ DNS OK"
