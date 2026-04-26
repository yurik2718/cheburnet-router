#!/bin/sh
# full-deploy-zapret.sh — развернуть zapret на чистом OpenWrt-роутере.
#
# Запускать с вашего ноутбука (не с роутера!). Аргумент — SSH-target роутера.
# Предполагается что configs/wireless-actual.txt уже подготовлен через setup.sh.
#
# Пример:
#   ./setup/full-deploy-zapret.sh root@192.168.1.1
set -e

ROUTER="${1:?Usage: $0 root@<router-ip>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== cheburnet-router (zapret) deploy to $ROUTER ==="
echo

if [ ! -f "$REPO_ROOT/configs/wireless-actual.txt" ]; then
    echo "ERROR: configs/wireless-actual.txt не найден."
    echo "Запустите ./setup.sh — он создаст этот файл автоматически."
    exit 1
fi

if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$ROUTER" 'echo ok' >/dev/null 2>&1; then
    echo "ERROR: не могу подключиться по SSH к $ROUTER."
    exit 1
fi

# === Копируем служебные файлы ===
# В zapret-режиме dns-provider/dns-healthcheck не нужны — они управляют
# podkop'ом, которого здесь нет. DoH обеспечивает https-dns-proxy через
# 04-dns-zapret.sh (с автофейловером между Quad9 и Cloudflare через dnsmasq).
echo "=== Копируем служебные файлы на роутер ==="
ssh "$ROUTER" 'mkdir -p /tmp/configs'
scp -q "$REPO_ROOT/configs/sysupgrade.conf" "$ROUTER":/tmp/configs/
echo "✓ файлы скопированы"

# === Запускаем базовые скрипты ===
# 00 — apk update + базовые тулзы
# 03 — adblock-lean + Hagezi Pro
# 04-dns-zapret — https-dns-proxy (Quad9 DoH + Cloudflare fallback)
# 09 — SSH hardening (key-only, REJECT SSH с WAN)
for SCRIPT in 00-prerequisites.sh 03-adblock.sh 04-dns-zapret.sh; do
    echo
    echo "=== RUN: setup/$SCRIPT ==="
    ssh "$ROUTER" 'sh -s' < "$REPO_ROOT/setup/$SCRIPT"
done

# === Wi-Fi ===
echo
echo "=== RUN: setup/05-wifi.sh ==="
# shellcheck disable=SC1090
. "$REPO_ROOT/configs/wireless-actual.txt"
ssh "$ROUTER" "WIFI_SSID='$WIFI_SSID' WIFI_KEY='$WIFI_KEY' WIFI_COUNTRY='${WIFI_COUNTRY:-RU}' sh -s" \
    < "$REPO_ROOT/setup/05-wifi.sh"

# === zapret ===
echo
echo "=== RUN: setup/13-zapret.sh ==="
ssh "$ROUTER" 'sh -s' < "$REPO_ROOT/setup/13-zapret.sh"

# === Финальный статус ===
echo
echo "=== ФИНАЛЬНЫЙ СТАТУС ==="
ssh "$ROUTER" \
    'echo "--- zapret ---"; /etc/init.d/zapret status 2>&1 | head -5; \
     echo "--- adblock ---"; /etc/init.d/adblock-lean status 2>&1 | head -3; \
     echo "--- DoH (https-dns-proxy) ---"; /etc/init.d/https-dns-proxy status 2>&1 | head -3; \
     echo "  инстансы: $(pgrep https-dns-proxy | wc -l) (ожидается 2: Quad9 + Cloudflare)"; \
     echo "--- uptime ---"; uptime'

echo
echo "=== ГОТОВО ==="
echo "Дальше:"
echo "  1. Подключитесь к Wi-Fi с вашим SSID"
echo "  2. Проверьте speedtest.net — должен открыться (заблокирован в РФ)"
echo "  3. Если не работает — попробуйте другую стратегию zapret: README.md → zapret"
