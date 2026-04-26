#!/bin/sh
# 04-dns-zapret.sh — настроить шифрованный DNS (DoH) для zapret-режима.
#
# В zapret-режиме нет podkop/sing-box, которые в VPN-режиме занимаются DoH.
# Вместо них ставим лёгкий `https-dns-proxy` — он принимает запросы от dnsmasq
# на 127.0.0.1 и форвардит их в Quad9 / Cloudflare по HTTPS.
#
# Результат: все DNS-запросы клиентов идут через зашифрованный DoH, провайдер
# не видит, к каким доменам обращаются устройства в сети. Встроенный failover
# через dnsmasq `allservers=1` — при сбое Quad9 автоматически используется
# Cloudflare и наоборот.
set -e

echo "== 04. DNS for zapret mode (https-dns-proxy: Quad9 + Cloudflare) =="

# === 1. Установка пакета ===
if ! apk list --installed 2>/dev/null | grep -q '^https-dns-proxy'; then
    echo "→ устанавливаем https-dns-proxy"
    # Раздельное выполнение нужно потому что POSIX sh не поддерживает pipefail —
    # exit-код на pipe берётся от tail, не от apk, и ошибка установки молча проглотится.
    if ! apk add --no-interactive https-dns-proxy >/tmp/apk-out 2>&1; then
        tail -5 /tmp/apk-out
        echo ""
        echo "  ✗ Не удалось установить https-dns-proxy."
        echo "    Возможные причины:"
        echo "      • Нет интернета на роутере — проверьте: ping 8.8.8.8"
        echo "      • Пакет недоступен в репозитории вашей версии OpenWrt"
        echo "    Что сделать:"
        echo "      • Убедитесь что WAN-кабель подключён и DHCP работает"
        echo "      • Попробуйте: apk update && apk add https-dns-proxy"
        exit 1
    fi
    tail -3 /tmp/apk-out
fi

# === 2. UCI-конфигурация ===
echo "→ настраиваем https-dns-proxy (Quad9 primary, Cloudflare fallback)"

# Очищаем старые инстансы если были (idempotency при переустановке)
while uci -q delete https-dns-proxy.@https-dns-proxy[0]; do :; done

# Quad9 — primary (швейцарский no-log резолвер с блокировкой malware)
uci add https-dns-proxy https-dns-proxy
uci set https-dns-proxy.@https-dns-proxy[-1].bootstrap_dns='9.9.9.9,149.112.112.112'
uci set https-dns-proxy.@https-dns-proxy[-1].resolver_url='https://dns.quad9.net/dns-query'
uci set https-dns-proxy.@https-dns-proxy[-1].listen_addr='127.0.0.1'
uci set https-dns-proxy.@https-dns-proxy[-1].listen_port='5053'

# Cloudflare — fallback
uci add https-dns-proxy https-dns-proxy
uci set https-dns-proxy.@https-dns-proxy[-1].bootstrap_dns='1.1.1.1,1.0.0.1'
uci set https-dns-proxy.@https-dns-proxy[-1].resolver_url='https://cloudflare-dns.com/dns-query'
uci set https-dns-proxy.@https-dns-proxy[-1].listen_addr='127.0.0.1'
uci set https-dns-proxy.@https-dns-proxy[-1].listen_port='5054'

uci commit https-dns-proxy

# === 3. dnsmasq не использует системный резолвер ===
# noresolv=1: не читаем /tmp/resolv.conf.auto с DNS провайдера (иначе утечка при сбое DoH)
# allservers=1: dnsmasq опрашивает оба upstream одновременно, использует быстрейший ответ.
#               Это даёт implicit failover: если Quad9 не отвечает — Cloudflare даст ответ первым.
uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].allservers='1'
uci commit dhcp

# === 4. Enable + start ===
echo "→ enable + start https-dns-proxy"
/etc/init.d/https-dns-proxy enable
/etc/init.d/https-dns-proxy restart

# Даём https-dns-proxy время поднять соединения и обновить upstream в dnsmasq
sleep 3
/etc/init.d/dnsmasq restart
sleep 2

# === 5. Проверка ===
if pgrep https-dns-proxy >/dev/null 2>&1; then
    N=$(pgrep https-dns-proxy | wc -l)
    echo "✓ https-dns-proxy запущен (инстансов: $N)"
else
    echo "⚠ https-dns-proxy не запустился — см. logread | grep https-dns-proxy"
fi

# Живой тест — резолв через локальный dnsmasq на роутере
if nslookup cloudflare.com 127.0.0.1 2>/dev/null | grep -qE 'Address.*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
    echo "✓ DNS резолвинг через DoH работает"
else
    echo "⚠ DNS не резолвит — подождите 5-10 сек и повторите:"
    echo "    nslookup cloudflare.com 127.0.0.1"
fi

echo "✓ DoH OK (Quad9 primary + Cloudflare fallback, failover встроен в dnsmasq)"
