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

# main section: всё от LAN → через AWG
uci set podkop.main.connection_type='vpn'
uci set podkop.main.interface='awg0'
uci -q delete podkop.main.community_lists
uci -q delete podkop.main.proxy_config_type
uci -q delete podkop.main.proxy_string
uci -q delete podkop.main.fully_routed_ips
uci add_list podkop.main.fully_routed_ips='192.168.1.0/24'

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
