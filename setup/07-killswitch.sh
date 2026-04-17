#!/bin/sh
# 07-killswitch.sh — добавить fw4-правила KillSwitch для защиты от утечек.
set -e

echo "== 07. Kill switch =="

# Проверяем, нет ли уже правил
if uci show firewall | grep -q 'KillSwitch-IPv4-LAN-direct-egress'; then
    echo "→ правила KillSwitch уже установлены"
else
    echo "→ добавляем правила"

    # IPv4: dropим любой пакет LAN → WAN с src 192.168.1.0/24
    uci add firewall rule
    uci set firewall.@rule[-1].name='KillSwitch-IPv4-LAN-direct-egress'
    uci set firewall.@rule[-1].src='lan'
    uci set firewall.@rule[-1].dest='wan'
    uci set firewall.@rule[-1].family='ipv4'
    uci set firewall.@rule[-1].src_ip='192.168.1.0/24'
    uci set firewall.@rule[-1].proto='all'
    uci set firewall.@rule[-1].target='DROP'

    # IPv6: весь LAN→WAN
    uci add firewall rule
    uci set firewall.@rule[-1].name='KillSwitch-IPv6-LAN-direct-egress'
    uci set firewall.@rule[-1].src='lan'
    uci set firewall.@rule[-1].dest='wan'
    uci set firewall.@rule[-1].family='ipv6'
    uci set firewall.@rule[-1].proto='all'
    uci set firewall.@rule[-1].target='DROP'

    uci commit firewall
fi

# Reload firewall
/etc/init.d/firewall reload >/dev/null 2>&1
sleep 2

# Проверка
if nft list chain inet fw4 forward_lan 2>/dev/null | grep -q KillSwitch; then
    echo "✓ KillSwitch правила активны в nft"
    nft list chain inet fw4 forward_lan 2>/dev/null | grep -i killswitch
else
    echo "⚠ правила не видны в nft — проверьте /etc/init.d/firewall restart"
fi

echo "✓ Kill switch OK"
