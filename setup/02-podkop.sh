#!/bin/sh
# 02-podkop.sh — установить podkop + sing-box и настроить UCI для режима
# «всё через VPN кроме RU-сервисов» (HOME по умолчанию).
set -e

echo "== 02. Podkop + sing-box =="

# === 1. Установка через официальный скрипт ===
if [ -x /etc/init.d/podkop ]; then
    echo "→ podkop уже установлен"
else
    echo "→ скачиваем и ставим podkop"
    wget -qO /tmp/podkop-install.sh \
        https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh
    # Отвечаем "n" на все y/n вопросы (русский язык интерфейса не нужен)
    printf 'n\nn\nn\n' | sh /tmp/podkop-install.sh 2>&1 | tail -20
fi

# === 2. UCI-конфигурация ===
echo "→ настраиваем podkop UCI"

# Определяем реальную LAN-подсеть (а не хардкод 192.168.1.0/24).
# Сначала пробуем стандартный helper OpenWrt; на старых сборках fallback через ipcalc.sh.
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
    echo "  Проверьте: uci show network.lan" >&2
    exit 1
fi
echo "  LAN-подсеть: $LAN_CIDR"

# main section: всё от LAN → через AWG
uci set podkop.main.connection_type='vpn'
uci set podkop.main.interface='awg0'
uci -q delete podkop.main.community_lists
uci -q delete podkop.main.proxy_config_type
uci -q delete podkop.main.proxy_string
uci -q delete podkop.main.fully_routed_ips
uci add_list podkop.main.fully_routed_ips="$LAN_CIDR"

# exclude_ru section: исключения для RU-сервисов
uci set podkop.exclude_ru=section
uci set podkop.exclude_ru.connection_type='exclusion'
uci set podkop.exclude_ru.user_domain_list_type='dynamic'
uci -q delete podkop.exclude_ru.community_lists
uci add_list podkop.exclude_ru.community_lists='russia_outside'
uci -q delete podkop.exclude_ru.user_domains
uci add_list podkop.exclude_ru.user_domains='.ru'
uci add_list podkop.exclude_ru.user_domains='.su'
uci add_list podkop.exclude_ru.user_domains='.xn--p1ai'
uci add_list podkop.exclude_ru.user_domains='vk.com'

# Лог-уровень — warn (чтобы не забивать logd дебагом)
uci set podkop.settings.log_level='warn'

uci commit podkop

# === 3. Enable + start ===
echo "→ enable + start podkop"
/etc/init.d/podkop enable
/etc/init.d/podkop restart >/dev/null 2>&1 &
sleep 10

# === 4. Проверка ===
echo "→ проверяем"
if /etc/init.d/sing-box status | grep -q running 2>/dev/null; then
    echo "✓ sing-box running"
else
    echo "⚠ sing-box не работает — см. logread | grep sing-box"
fi

# Проверка nft правил
if nft list table inet PodkopTable >/dev/null 2>&1; then
    echo "✓ nft PodkopTable установлен"
else
    echo "⚠ nft-правила подkop'а отсутствуют"
fi

echo "✓ podkop OK"
