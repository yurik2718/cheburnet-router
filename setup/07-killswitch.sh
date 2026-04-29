#!/bin/sh
# 07-killswitch.sh — добавить fw4-правила KillSwitch для защиты от утечек.
set -e

echo "== 07. Kill switch =="

# Реальная LAN-подсеть из uci (не хардкод 192.168.1.0/24, иначе на нестандартных
# подсетях правило просто не сматчится и kill-switch будет тихо дырявым).
LAN_CIDR=""
if [ -f /lib/functions/network.sh ]; then
    # shellcheck disable=SC1091
    . /lib/functions/network.sh
    network_flush_cache
    network_get_subnet LAN_CIDR lan 2>/dev/null || true
fi
if [ -z "$LAN_CIDR" ]; then
    LAN_IP=$(uci -q get network.lan.ipaddr || echo "")
    LAN_MASK=$(uci -q get network.lan.netmask || echo "255.255.255.0")
    if [ -n "$LAN_IP" ] && command -v ipcalc.sh >/dev/null 2>&1; then
        LAN_CIDR=$(ipcalc.sh "$LAN_IP" "$LAN_MASK" 2>/dev/null \
            | awk -F= '/^NETWORK/{n=$2} /^PREFIX/{p=$2} END{if(n && p) print n"/"p}')
    fi
fi
if [ -z "$LAN_CIDR" ]; then
    echo "✗ Не удалось определить LAN-подсеть из uci." >&2
    exit 1
fi
echo "→ LAN-подсеть для kill-switch: $LAN_CIDR"

# Проверяем, нет ли уже правил
if uci show firewall | grep -q 'KillSwitch-IPv4-LAN-direct-egress'; then
    echo "→ правила KillSwitch уже установлены"
else
    echo "→ добавляем правила"

    # IPv4: dropим любой пакет LAN → WAN с src $LAN_CIDR
    uci add firewall rule
    uci set firewall.@rule[-1].name='KillSwitch-IPv4-LAN-direct-egress'
    uci set firewall.@rule[-1].src='lan'
    uci set firewall.@rule[-1].dest='wan'
    uci set firewall.@rule[-1].family='ipv4'
    uci set firewall.@rule[-1].src_ip="$LAN_CIDR"
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
