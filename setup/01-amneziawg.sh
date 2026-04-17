#!/bin/sh
# 01-amneziawg.sh — установить AmneziaWG (kmod + tools + luci-proto), создать awg0.
#
# ПЕРЕД ЗАПУСКОМ: положите ваш .conf в /etc/amnezia/amneziawg/awg0.conf
#   scp configs/awg0.conf root@router:/etc/amnezia/amneziawg/awg0.conf
#
# Скрипт распарсит .conf и создаст UCI-интерфейс awg0 с нужными параметрами.
# Работает на aarch64_cortex-a53_mediatek_filogic (Beryl AX). Для других
# архитектур отредактируйте переменную ARCH ниже.
set -e

echo "== 01. AmneziaWG =="

CONF=/etc/amnezia/amneziawg/awg0.conf
if [ ! -f "$CONF" ]; then
    echo "ERROR: $CONF не найден." >&2
    echo "Скопируйте конфиг от Amnezia: scp your-awg.conf root@router:$CONF" >&2
    exit 1
fi

# === 1. Установка пакетов ===
# Если модуль уже загружен — пропускаем установку
if lsmod | grep -q '^amneziawg '; then
    echo "→ amneziawg уже установлен, пропускаю установку"
else
    echo "→ скачиваем и ставим kmod-amneziawg + tools"
    BASE=https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v25.12.2
    ARCH=aarch64_cortex-a53_mediatek_filogic   # для Beryl AX

    mkdir -p /etc/amnezia/amneziawg
    cd /tmp
    for PKG in kmod-amneziawg_v25.12.2 amneziawg-tools_v25.12.2 luci-proto-amneziawg_v25.12.2; do
        FILE="${PKG}_${ARCH}.apk"
        wget -q -O "$FILE" "$BASE/$FILE" || { echo "download failed: $FILE"; exit 1; }
    done
    apk add --allow-untrusted ./kmod-amneziawg_v25.12.2_${ARCH}.apk \
                              ./amneziawg-tools_v25.12.2_${ARCH}.apk \
                              ./luci-proto-amneziawg_v25.12.2_${ARCH}.apk
    modprobe amneziawg
fi

# === 2. Парсим .conf ===
get_iface() { awk -F' *= *' "/^$1/{print \$2; exit}" "$CONF" | head -n1; }
get_peer()  { awk -F' *= *' "BEGIN{f=0} /^\\[Peer\\]/{f=1; next} f && /^$1/{print \$2; exit}" "$CONF"; }

PRIV=$(get_iface PrivateKey)
ADDR=$(get_iface Address)
JC=$(get_iface Jc)
JMIN=$(get_iface Jmin)
JMAX=$(get_iface Jmax)
S1=$(get_iface S1)
S2=$(get_iface S2)
# v1.5 опциональные параметры (могут отсутствовать в v1.0 конфигах):
S3=$(get_iface S3)
S4=$(get_iface S4)
H1=$(get_iface H1)
H2=$(get_iface H2)
H3=$(get_iface H3)
H4=$(get_iface H4)
# I1-I5 — Custom Protocol Signature (AWG v1.5), опционально:
I1=$(get_iface I1)
I2=$(get_iface I2)
I3=$(get_iface I3)
I4=$(get_iface I4)
I5=$(get_iface I5)

PUB=$(get_peer PublicKey)
PSK=$(get_peer PresharedKey)
EP=$(get_peer Endpoint)
KA=$(get_peer PersistentKeepalive)
# Split endpoint host:port
EP_HOST=${EP%:*}
EP_PORT=${EP##*:}

[ -n "$PRIV" ] && [ -n "$PUB" ] && [ -n "$EP_HOST" ] || { echo "ERROR: .conf parse failed"; exit 1; }

echo "→ parsed: Address=$ADDR, Endpoint=$EP_HOST:$EP_PORT, PSK=$([ -n "$PSK" ] && echo yes || echo no)"

# === 3. UCI network interface ===
echo "→ создаём UCI network.awg0"
uci -q delete network.awg0
uci set network.awg0=interface
uci set network.awg0.proto='amneziawg'
uci set network.awg0.private_key="$PRIV"
uci add_list network.awg0.addresses="$ADDR"
uci set network.awg0.mtu='1420'
uci set network.awg0.awg_jc="$JC"
uci set network.awg0.awg_jmin="$JMIN"
uci set network.awg0.awg_jmax="$JMAX"
uci set network.awg0.awg_s1="$S1"
uci set network.awg0.awg_s2="$S2"
uci set network.awg0.awg_h1="$H1"
uci set network.awg0.awg_h2="$H2"
uci set network.awg0.awg_h3="$H3"
uci set network.awg0.awg_h4="$H4"
# v1.5 опциональные параметры — устанавливаем только если есть в конфиге
[ -n "$S3" ] && uci set network.awg0.awg_s3="$S3"
[ -n "$S4" ] && uci set network.awg0.awg_s4="$S4"
[ -n "$I1" ] && uci set network.awg0.awg_i1="$I1"
[ -n "$I2" ] && uci set network.awg0.awg_i2="$I2"
[ -n "$I3" ] && uci set network.awg0.awg_i3="$I3"
[ -n "$I4" ] && uci set network.awg0.awg_i4="$I4"
[ -n "$I5" ] && uci set network.awg0.awg_i5="$I5"

# Peer section
while uci -q delete network.@amneziawg_awg0[0]; do :; done
PEER=$(uci add network amneziawg_awg0)
uci set network.${PEER}.description='peer0'
uci set network.${PEER}.public_key="$PUB"
[ -n "$PSK" ] && uci set network.${PEER}.preshared_key="$PSK"
uci add_list network.${PEER}.allowed_ips='0.0.0.0/0'
uci add_list network.${PEER}.allowed_ips='::/0'
uci set network.${PEER}.endpoint_host="$EP_HOST"
uci set network.${PEER}.endpoint_port="$EP_PORT"
uci set network.${PEER}.persistent_keepalive="${KA:-25}"
# КРИТИЧНО: маршрутизацией будет заниматься podkop, не netifd
uci set network.${PEER}.route_allowed_ips='0'

uci commit network

# === 4. Firewall zone 'vpn' ===
echo "→ создаём firewall zone 'vpn'"
# Удаляем старую если есть
idx=$(uci show firewall | awk -F'[][]' '/@zone.*name=.vpn./{print $2; exit}')
[ -n "$idx" ] && uci -q delete firewall.@zone[$idx] || true

uci add firewall zone
uci set firewall.@zone[-1].name='vpn'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='ACCEPT'
uci set firewall.@zone[-1].masq='1'
uci set firewall.@zone[-1].mtu_fix='1'
uci add_list firewall.@zone[-1].network='awg0'

# Forwarding lan → vpn
if ! uci show firewall | grep -q "src='lan'.*dest='vpn'" 2>/dev/null; then
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='lan'
    uci set firewall.@forwarding[-1].dest='vpn'
fi

uci commit firewall

# === 5. Restart network (поднять awg0) ===
echo "→ перезапуск сети"
/etc/init.d/network restart
/etc/init.d/firewall reload >/dev/null 2>&1
sleep 5

# === 6. Проверка ===
if ip -4 addr show awg0 2>/dev/null | grep -q inet; then
    echo "✓ awg0 interface UP: $(ip -4 addr show awg0 | awk '/inet/{print $2}')"
else
    echo "⚠ awg0 не поднялся — проверьте логи: logread | grep -i amnezia"
    exit 1
fi

# Дадим 10 секунд на первый handshake
echo "→ ждём handshake (до 10 сек)..."
for i in 1 2 3 4 5; do
    sleep 2
    if awg show awg0 | grep -q 'latest handshake'; then
        hs=$(awg show awg0 | awk '/latest handshake:/{print $3,$4,$5,$6,$7,$8}')
        echo "✓ handshake: $hs"
        exit 0
    fi
done

echo "⚠ handshake не получен за 10 сек — может быть проблема с сервером или параметрами"
echo "  Проверьте: awg show awg0, awg-quick, traceroute до endpoint'а"
exit 0
