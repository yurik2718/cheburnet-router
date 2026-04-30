#!/bin/sh
# full-deploy.sh — развернуть всю конфигурацию на чистом OpenWrt-роутере.
#
# Запускать с вашего ноутбука (не с роутера!). Аргумент — SSH-target роутера.
# Предполагается что настройки Wi-Fi и AWG подготовлены в configs/:
#   configs/awg0.conf                      — AWG-конфиг от Amnezia
#   configs/wireless-actual.txt            — ВАШ файл с WIFI_SSID и WIFI_KEY
#
# Пример:
#   ./setup/full-deploy.sh root@192.168.1.1
set -e

ROUTER="${1:?Usage: $0 root@<router-ip>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== cheburnet-router deploy to $ROUTER ==="
echo

# === Предварительные проверки ===
if [ ! -f "$REPO_ROOT/configs/awg0.conf" ]; then
    echo "ERROR: configs/awg0.conf не найден."
    echo "Скопируйте ваш .conf от Amnezia в configs/awg0.conf и повторите."
    exit 1
fi

if [ ! -f "$REPO_ROOT/configs/wireless-actual.txt" ]; then
    echo "ERROR: configs/wireless-actual.txt не найден."
    echo "Создайте файл с переменными:"
    echo "  WIFI_SSID=\"MyNet\""
    echo "  WIFI_KEY=\"correct-horse-battery-staple\""
    echo "  WIFI_COUNTRY=\"RU\""
    exit 1
fi

# Проверим SSH-доступ
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$ROUTER" 'echo ok' >/dev/null 2>&1; then
    echo "ERROR: не могу подключиться по SSH к $ROUTER."
    echo "Проверьте адрес, SSH-ключ, или используйте: ssh-copy-id $ROUTER"
    exit 1
fi

# === 1. Копируем скрипты и конфиг на роутер ===
echo "=== Копируем скрипты на роутер ==="
ssh "$ROUTER" 'mkdir -p /tmp/scripts/hotplug/button /tmp/scripts/init.d /tmp/configs /etc/amnezia/amneziawg'
scp -q "$REPO_ROOT/scripts/vpn-mode"       "$ROUTER":/tmp/scripts/
scp -q "$REPO_ROOT/scripts/dns-provider"   "$ROUTER":/tmp/scripts/
scp -q "$REPO_ROOT/scripts/awg-watchdog"   "$ROUTER":/tmp/scripts/
scp -q "$REPO_ROOT/scripts/travel-connect" "$ROUTER":/tmp/scripts/
scp -q "$REPO_ROOT/scripts/travel-portal"  "$ROUTER":/tmp/scripts/
scp -q "$REPO_ROOT/scripts/travel-vpn-on"  "$ROUTER":/tmp/scripts/
scp -q "$REPO_ROOT/scripts/travel-check"   "$ROUTER":/tmp/scripts/
scp -q "$REPO_ROOT/scripts/hotplug/button/10-vpn-mode" "$ROUTER":/tmp/scripts/hotplug/button/
scp -q "$REPO_ROOT/scripts/init.d/vpn-mode"            "$ROUTER":/tmp/scripts/init.d/
scp -q "$REPO_ROOT/configs/awg0.conf" "$ROUTER":/etc/amnezia/amneziawg/awg0.conf
ssh "$ROUTER" 'chmod 600 /etc/amnezia/amneziawg/awg0.conf'
scp -q "$REPO_ROOT/configs/sysupgrade.conf" "$ROUTER":/tmp/configs/sysupgrade.conf
echo "✓ файлы скопированы"

# === 2. Поочерёдно запускаем setup-скрипты ===
for SCRIPT in 00-prerequisites.sh 01-amneziawg.sh 02-podkop.sh 03-adblock.sh \
              04-dns.sh 06-vpn-mode.sh 07-killswitch.sh 08-watchdog.sh \
              10-quality.sh 11-travel.sh; do
    echo
    echo "=== RUN: setup/$SCRIPT ==="
    ssh "$ROUTER" 'sh -s' < "$REPO_ROOT/setup/$SCRIPT"
done

# === 3. Wi-Fi — отдельно, с env-переменными ===
echo
echo "=== RUN: setup/05-wifi.sh ==="
# shellcheck disable=SC1090
. "$REPO_ROOT/configs/wireless-actual.txt"
ssh "$ROUTER" "WIFI_SSID='$WIFI_SSID' WIFI_KEY='$WIFI_KEY' WIFI_COUNTRY='${WIFI_COUNTRY:-RU}' sh -s" \
    < "$REPO_ROOT/setup/05-wifi.sh"

# === 4. Установка root-пароля (если передан) ===
# ROOT_PASS приходит из setup.sh через env. Пропускаем через ssh stdin,
# чтобы не светить пароль в командной строке/process-листинге.
if [ -n "${ROOT_PASS:-}" ]; then
    echo
    echo "=== RUN: установка пароля root ==="
    printf '%s\n' "$ROOT_PASS" | ssh "$ROUTER" 'sh -c "
        IFS= read -r p
        printf \"%s\n%s\n\" \"\$p\" \"\$p\" | passwd root >/dev/null 2>&1 && echo \"✓ root password set\" || echo \"⚠ passwd root failed\"
    "'
    unset ROOT_PASS
fi

# === 5. Lock ACL и Финальный статус ===
# После успешной установки запираем web-ACL: unauth-доступ остаётся только
# к get_status и install_progress, мутирующие методы требуют login.
ssh "$ROUTER" 'sh -s' <<'LOCK_ACL'
cat > /usr/share/rpcd/acl.d/cheburnet.json <<'ACL'
{
    "unauthenticated": {
        "description": "cheburnet read-only status (post-install LAN-локально)",
        "read": { "ubus": { "cheburnet": ["get_status", "install_progress"] } }
    },
    "cheburnet-admin": {
        "description": "cheburnet admin (login as root required)",
        "read":  { "ubus": { "cheburnet": ["get_status", "install_progress"] } },
        "write": { "ubus": { "cheburnet": ["install_start", "install_cancel", "mode_switch", "service_restart", "set_blocklist_tier", "factory_reset"] } }
    }
}
ACL
/etc/init.d/rpcd reload >/dev/null 2>&1
echo "✓ ACL locked: read-only without login"
LOCK_ACL

# === 6. Финальный статус ===
echo
echo "=== ФИНАЛЬНЫЙ СТАТУС ==="
ssh "$ROUTER" 'echo "--- AWG ---"; awg show awg0 | grep -E "handshake|transfer"; \
  echo "--- podkop ---"; podkop check_nft_rules 2>&1 | head -10; \
  echo "--- adblock ---"; /etc/init.d/adblock-lean status 2>&1 | head -5; \
  echo "--- DNS ---"; /usr/bin/dns-provider status; \
  echo "--- VPN mode ---"; /usr/bin/vpn-mode status; \
  echo "--- uptime ---"; uptime'

echo
echo "=== ГОТОВО ==="
echo "Дальше:"
echo "  1. Подключитесь к Wi-Fi с указанным SSID"
echo "  2. Проверьте IP: curl https://ifconfig.co/json"
echo "  3. Проверьте что yandex.ru открывается напрямую (RU IP)"
echo "  4. Проверьте что youtube.com открывается через VPN (Swiss IP)"
