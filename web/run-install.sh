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
# SSH hardening: даже без ssh-key всегда блокируем SSH с WAN-зоны
# (минимальная защита от внешнего доступа). Выключение password-auth — только
# если есть authorized_keys (иначе пользователь потеряет recovery-доступ через пароль).
echo "[STEP] 09-ssh-hardening" > "$STATE"
echo
echo "════════════════════════════════════════════"
echo " ШАГ: 09-ssh-hardening (Block-SSH-from-WAN всегда; password-auth — если есть ключ)"
echo "════════════════════════════════════════════"

# Block-SSH-from-WAN — добавляем безусловно
if uci show firewall 2>/dev/null | grep -q "name='Block-SSH-from-WAN'"; then
    echo "→ Block-SSH-from-WAN правило уже есть"
else
    echo "→ добавляем Block-SSH-from-WAN (REJECT tcp/22 from wan zone)"
    uci add firewall rule
    uci set firewall.@rule[-1].name='Block-SSH-from-WAN'
    uci set firewall.@rule[-1].src='wan'
    uci set firewall.@rule[-1].proto='tcp'
    uci set firewall.@rule[-1].dest_port='22'
    uci set firewall.@rule[-1].target='REJECT'
    uci commit firewall
    /etc/init.d/firewall reload >/dev/null 2>&1
fi

# Выключение password-auth — только при наличии ключа, иначе остаёмся с паролем
if [ -s /etc/dropbear/authorized_keys ]; then
    echo "→ authorized_keys не пуст — выключаем password-auth в dropbear"
    uci set dropbear.main.PasswordAuth='off'
    uci set dropbear.main.RootPasswordAuth='off'
    uci commit dropbear
    /etc/init.d/dropbear restart >/dev/null 2>&1
    echo "✓ SSH hardening полный (key-only + WAN closed)"
else
    echo "ℹ password-auth оставлен включённым: authorized_keys пуст,"
    echo "  иначе вы потеряли бы recovery-доступ через пароль root."
    echo "  Добавьте свой ssh-key в /etc/dropbear/authorized_keys и запустите"
    echo "  setup/09-ssh-hardening.sh для полного hardening."
    echo "✓ SSH hardening минимальный (WAN closed, password ещё работает с LAN)"
fi

# === Применяем root-пароль (положен rpcd-handler'ом в $STATE_DIR/root_pass) ===
if [ -s "$STATE_DIR/root_pass" ]; then
    echo "[STEP] root-password" > "$STATE"
    echo
    echo "════════════════════════════════════════════"
    echo " ШАГ: установка пароля root"
    echo "════════════════════════════════════════════"
    pass=$(cat "$STATE_DIR/root_pass")
    if printf '%s\n%s\n' "$pass" "$pass" | passwd root >/dev/null 2>&1; then
        echo "✓ пароль root установлен"
    else
        echo "⚠ passwd root не сработал — установите пароль вручную через SSH"
    fi
    unset pass
    # Затираем файл (best-effort): сначала перезапись, потом unlink
    dd if=/dev/urandom of="$STATE_DIR/root_pass" bs=1 count=64 conv=notrunc 2>/dev/null || true
    rm -f "$STATE_DIR/root_pass"
fi

# === Запираем ACL: после установки unauth остаётся только read-only ===
echo "[STEP] lock-acl" > "$STATE"
echo
echo "════════════════════════════════════════════"
echo " ШАГ: запираем веб-ACL (read-only без логина)"
echo "════════════════════════════════════════════"
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
echo "✓ ACL заблокирован: чтение без логина, мутации требуют пароль root"

echo
echo "════════════════════════════════════════════"
echo " ✓ Установка завершена успешно"
echo "════════════════════════════════════════════"
echo "ok" > "$DONE"
echo "[done]" > "$STATE"
