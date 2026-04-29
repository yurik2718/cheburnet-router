#!/bin/sh
# run-install.sh — orchestrator установки, запускается на роутере в фоне из
# RPC-метода install_start. Заменяет ssh/scp-часть full-deploy.sh для случая
# когда мы УЖЕ на роутере.
#
# Пишет прогресс в /tmp/cheburnet/state, итоговый результат в /tmp/cheburnet/done.
# Логи уходят в stdout/stderr → перехватываются вызывающим кодом в /tmp/cheburnet/install.log
set -e

INSTALL_DIR="/opt/cheburnet"
STATE_DIR="/tmp/cheburnet"
STATE="$STATE_DIR/state"
DONE="$STATE_DIR/done"

mkdir -p "$STATE_DIR"

# === Подготовка /tmp/scripts и /tmp/configs ===
# Setup-скрипты исторически ожидают файлы в этих путях (их раньше scp'шил full-deploy).
# На роутере мы просто копируем из /opt/cheburnet/.
echo "[prepare] копирую скрипты в /tmp/scripts и /tmp/configs"
rm -rf /tmp/scripts /tmp/configs
mkdir -p /tmp/scripts/hotplug/button /tmp/scripts/init.d /tmp/configs

cp "$INSTALL_DIR/scripts/vpn-mode"         /tmp/scripts/ 2>/dev/null || true
cp "$INSTALL_DIR/scripts/dns-provider"     /tmp/scripts/ 2>/dev/null || true
cp "$INSTALL_DIR/scripts/dns-healthcheck"  /tmp/scripts/ 2>/dev/null || true
cp "$INSTALL_DIR/scripts/awg-watchdog"     /tmp/scripts/ 2>/dev/null || true
cp "$INSTALL_DIR/scripts/log-snapshot"     /tmp/scripts/ 2>/dev/null || true
cp "$INSTALL_DIR/scripts/sqm-tune"         /tmp/scripts/ 2>/dev/null || true
cp "$INSTALL_DIR/scripts/travel-"*         /tmp/scripts/ 2>/dev/null || true
cp "$INSTALL_DIR/scripts/hotplug/button/10-vpn-mode" /tmp/scripts/hotplug/button/ 2>/dev/null || true
cp "$INSTALL_DIR/scripts/init.d/vpn-mode"  /tmp/scripts/init.d/ 2>/dev/null || true
cp "$INSTALL_DIR/configs/sysupgrade.conf"  /tmp/configs/ 2>/dev/null || true

# Wi-Fi параметры (положены rpcd-хендлером в configs/)
if [ ! -f "$INSTALL_DIR/configs/wireless-actual.txt" ]; then
    echo "✗ configs/wireless-actual.txt не найден"
    echo "fail-no-wifi-config" > "$DONE"
    exit 1
fi
# shellcheck disable=SC1091
. "$INSTALL_DIR/configs/wireless-actual.txt"
export WIFI_SSID WIFI_KEY WIFI_COUNTRY

# === Список шагов ===
# .conf должен быть уже в /etc/amnezia/amneziawg/awg0.conf (положен rpcd-handler'ом)
if [ ! -f /etc/amnezia/amneziawg/awg0.conf ]; then
    echo "✗ /etc/amnezia/amneziawg/awg0.conf не найден"
    echo "fail-no-awg-config" > "$DONE"
    exit 1
fi
STEPS="00-prerequisites.sh 01-amneziawg.sh 02-podkop.sh 03-adblock.sh \
       04-dns.sh 05-wifi.sh 06-vpn-mode.sh 07-killswitch.sh 08-watchdog.sh \
       10-quality.sh 11-travel.sh 12-travel-plus.sh"

# === Выполнение ===
for STEP in $STEPS; do
    SHORT=$(echo "$STEP" | sed 's/\.sh$//')
    echo "[STEP] $SHORT" > "$STATE"
    echo
    echo "════════════════════════════════════════════"
    echo " ШАГ: $STEP"
    echo "════════════════════════════════════════════"

    if [ ! -f "$INSTALL_DIR/setup/$STEP" ]; then
        echo "⚠ $STEP не найден, пропускаю"
        continue
    fi

    # 05-wifi.sh ожидает env-переменные, остальные — нет
    if ! sh "$INSTALL_DIR/setup/$STEP"; then
        echo
        echo "✗ ШАГ $STEP завершился с ошибкой."
        echo "fail-$SHORT" > "$DONE"
        exit 1
    fi
done

# === Постобработка ===
# SSH hardening (09) в веб-флоу пропускаем: пользователь мог не положить SSH-ключ
# до bootstrap. Если авторизация уже сконфигурена ключом — запускаем отдельно ниже.
if [ -s /etc/dropbear/authorized_keys ]; then
    echo "[STEP] 09-ssh-hardening" > "$STATE"
    echo
    echo "════════════════════════════════════════════"
    echo " ШАГ: 09-ssh-hardening.sh (authorized_keys не пусты — ужесточаем SSH)"
    echo "════════════════════════════════════════════"
    sh "$INSTALL_DIR/setup/09-ssh-hardening.sh" || {
        echo "⚠ 09-ssh-hardening.sh не прошёл — оставляем как было"
    }
else
    echo
    echo "ℹ SSH hardening пропущен: /etc/dropbear/authorized_keys пуст."
    echo "  Если хотите использовать удалённый SSH — добавьте свой публичный ключ вручную."
fi

echo
echo "════════════════════════════════════════════"
echo " ✓ Установка завершена успешно"
echo "════════════════════════════════════════════"
echo "ok" > "$DONE"
echo "[done]" > "$STATE"
