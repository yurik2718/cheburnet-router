#!/bin/sh
# bootstrap.sh — развернуть веб-мастер cheburnet-router на свежем OpenWrt.
#
# ЗАПУСКАЕТСЯ НА САМОМ РОУТЕРЕ, не с ноутбука.
#
# Разовая команда для установки (из терминала ноутбука):
#   ssh root@192.168.1.1 'wget -qO- https://raw.githubusercontent.com/yurik2718/cheburnet-router/main/bootstrap.sh | sh'
#
# Или вручную на роутере:
#   wget -qO- https://raw.githubusercontent.com/yurik2718/cheburnet-router/main/bootstrap.sh | sh
#
# После выполнения откройте в браузере:
#   http://<IP_роутера>/cheburnet/
#
# Всё остальное — настройку VPN/zapret, Wi-Fi, adblock — мастер сделает сам.
set -e

REPO_TAR="https://codeload.github.com/yurik2718/cheburnet-router/tar.gz/refs/heads/main"
INSTALL_DIR="/opt/cheburnet"
WEB_DIR="/www/cheburnet"
RPCD_BIN="/usr/libexec/rpcd/cheburnet"
RPCD_ACL="/usr/share/rpcd/acl.d/cheburnet.json"

echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║   cheburnet-router · web-мастер                      ║"
echo "║   установка на этот роутер                           ║"
echo "╚══════════════════════════════════════════════════════╝"
echo

# === 1. Sanity checks ===
if [ ! -f /etc/openwrt_release ]; then
    echo "✗ Это не OpenWrt. Bootstrap запускается только на OpenWrt 25.12+."
    exit 1
fi

if ! command -v apk >/dev/null 2>&1; then
    echo "✗ apk не найден. Нужен OpenWrt 25.12+, где apk — пакетный менеджер."
    echo "  На OpenWrt 23.05/24.10 (с opkg) используйте старый флоу ./setup.sh с ноутбука."
    exit 1
fi

. /etc/openwrt_release
echo "→ Роутер: $DISTRIB_DESCRIPTION"
echo "→ Архитектура: $(uname -m)"
echo

# === 2. Свободное место ===
# Установщик + подкop + awg занимают ~30 MB на /overlay
AVAIL_KB=$(df /overlay | awk 'NR==2{print $4}')
if [ "$AVAIL_KB" -lt 40000 ]; then
    echo "⚠ Мало места на /overlay: ${AVAIL_KB}KB. Рекомендуется ≥40MB."
    echo "  Продолжаем, но установка может не поместиться."
    echo
fi

# === 3. Интернет ===
echo "→ Проверяю интернет"
if ! wget -q --spider --timeout=10 https://raw.githubusercontent.com 2>/dev/null; then
    echo "✗ Нет доступа к GitHub. Проверьте WAN и DNS на роутере."
    echo "  Проверка: ping 8.8.8.8  и  nslookup github.com"
    exit 1
fi
echo "✓ интернет есть"

# === 4. Базовые пакеты ===
echo
echo "→ Обновляю индекс пакетов"
apk update 2>&1 | tail -3

echo "→ Устанавливаю uhttpd-mod-ubus (HTTP-бридж для ubus)"
if ! apk add --no-interactive uhttpd-mod-ubus >/tmp/apk-out 2>&1; then
    tail -5 /tmp/apk-out
    echo "✗ Не удалось установить uhttpd-mod-ubus."
    echo "  Проверьте: apk update && apk search uhttpd-mod-ubus"
    exit 1
fi
tail -3 /tmp/apk-out

# rpcd обычно предустановлен, но проверим
if ! command -v rpcd >/dev/null 2>&1 && [ ! -x /sbin/rpcd ] && [ ! -x /usr/sbin/rpcd ]; then
    if ! apk add --no-interactive rpcd >/tmp/apk-out 2>&1; then
        tail -5 /tmp/apk-out
        echo "✗ Не удалось установить rpcd."; exit 1
    fi
fi

# jsonfilter — для парсинга JSON из ubus-вызовов (отдельный apk-пакет)
if ! command -v jsonfilter >/dev/null 2>&1; then
    if ! apk add --no-interactive jsonfilter >/tmp/apk-out 2>&1; then
        tail -5 /tmp/apk-out
        echo "✗ Не удалось установить jsonfilter."; exit 1
    fi
fi

# === 5. Скачать исходники ===
echo
echo "→ Скачиваю cheburnet-router"
rm -rf /tmp/cheburnet-src
mkdir -p /tmp/cheburnet-src
cd /tmp/cheburnet-src
if ! wget -qO source.tar.gz "$REPO_TAR"; then
    echo "✗ Не удалось скачать исходники с $REPO_TAR"
    exit 1
fi
tar xzf source.tar.gz
SRC=$(find . -maxdepth 1 -type d -name 'cheburnet-router*' | head -1)
[ -n "$SRC" ] || { echo "✗ Не удалось распаковать архив"; exit 1; }

# === 6. Установка файлов ===
echo "→ Копирую файлы в $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp -r "$SRC/setup"    "$INSTALL_DIR/"
cp -r "$SRC/scripts"  "$INSTALL_DIR/"
cp -r "$SRC/configs"  "$INSTALL_DIR/"
# run-install.sh + rpcd-handler поставляются в web/
cp "$SRC/web/run-install.sh" "$INSTALL_DIR/run-install.sh"
chmod +x "$INSTALL_DIR/run-install.sh"
# Все setup-скрипты тоже должны быть исполняемые
chmod +x "$INSTALL_DIR/setup/"*.sh 2>/dev/null || true
chmod +x "$INSTALL_DIR/scripts/"* 2>/dev/null || true

echo "→ Устанавливаю RPC-handler в $RPCD_BIN"
mkdir -p "$(dirname "$RPCD_BIN")"
cp "$SRC/web/rpcd-cheburnet" "$RPCD_BIN"
chmod +x "$RPCD_BIN"

echo "→ Устанавливаю ACL в $RPCD_ACL"
mkdir -p "$(dirname "$RPCD_ACL")"
cp "$SRC/web/rpcd-acl.json" "$RPCD_ACL"

echo "→ Устанавливаю веб-UI в $WEB_DIR"
mkdir -p "$WEB_DIR"
cp "$SRC/web/index.html" "$WEB_DIR/index.html"

# === 7. Runtime state directory ===
mkdir -p /tmp/cheburnet
chmod 755 /tmp/cheburnet

# === 8. Гарантируем что uhttpd слушает /ubus ===
# На голом OpenWrt без LuCI option ubus_prefix может быть не установлен.
# Без него браузер не сможет вызывать ubus-методы.
echo "→ Включаю /ubus endpoint в uhttpd"
if ! uci -q get uhttpd.main.ubus_prefix >/dev/null; then
    uci set uhttpd.main.ubus_prefix='/ubus'
    uci commit uhttpd
    echo "  добавлено: uhttpd.main.ubus_prefix=/ubus"
fi

# === 9. Restart rpcd и uhttpd ===
echo
echo "→ Перезапускаю rpcd"
/etc/init.d/rpcd enable
/etc/init.d/rpcd restart

echo "→ Перезапускаю uhttpd"
/etc/init.d/uhttpd enable
/etc/init.d/uhttpd restart

sleep 2

# === 9. Проверка ===
if ubus list cheburnet >/dev/null 2>&1; then
    echo "✓ ubus cheburnet зарегистрирован"
else
    echo "⚠ ubus cheburnet НЕ зарегистрирован. Проверьте:"
    echo "    logread | grep rpcd"
    echo "    sh -x $RPCD_BIN list"
fi

ROUTER_IP=$(uci -q get network.lan.ipaddr || echo "192.168.1.1")

echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║   ✓ Bootstrap завершён                               ║"
echo "╚══════════════════════════════════════════════════════╝"
echo
echo "  Откройте в браузере:"
echo "  →  http://$ROUTER_IP/cheburnet/"
echo
echo "  Веб-мастер настроит VPN/zapret, Wi-Fi и adblock сам."
echo

# Cleanup
rm -rf /tmp/cheburnet-src
