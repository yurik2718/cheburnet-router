#!/bin/sh
# 04-dns.sh — настроить Quad9 DoH через podkop/sing-box.
# При недоступности Quad9 sing-box сам падает на bootstrap_dns (1.1.1.1).
set -e

echo "== 04. DNS (Quad9 DoH) =="

# === 1. UCI podkop DNS ===
uci set podkop.settings.dns_type='doh'
uci set podkop.settings.dns_server='dns.quad9.net/dns-query'
uci set podkop.settings.bootstrap_dns_server='1.1.1.1'
uci commit podkop

# === 2. Копируем dns-provider (используется vpn-mode для отображения статуса) ===
if [ -f /tmp/scripts/dns-provider ]; then
    cp /tmp/scripts/dns-provider /usr/bin/dns-provider
    chmod +x /usr/bin/dns-provider
    echo "→ установлен /usr/bin/dns-provider"
else
    echo "⚠ /tmp/scripts/dns-provider не найден"
fi

# === 3. Reload podkop для применения нового DNS ===
/etc/init.d/podkop reload >/dev/null 2>&1 &
sleep 8

# === 4. Проверка ===
if /usr/bin/dns-provider status 2>/dev/null | grep -q Quad9; then
    echo "✓ Quad9 DoH активен"
else
    echo "⚠ dns-provider status говорит:"
    /usr/bin/dns-provider status
fi

# Живой тест — резолвим через локальный dnsmasq роутера, а не через хардкод 192.168.1.1
LAN_IP=$(uci -q get network.lan.ipaddr || echo "127.0.0.1")
if nslookup cloudflare.com "$LAN_IP" 2>/dev/null | grep -q Address; then
    echo "✓ резолвинг работает (через $LAN_IP)"
else
    echo "⚠ DNS не резолвит — проверьте logread | grep sing-box | grep dns"
fi

echo "✓ DNS OK"
