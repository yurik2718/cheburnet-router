#!/bin/sh
# 06-vpn-mode.sh — установить vpn-mode CLI и поддержку физической кнопки.
#
# Что делает:
#   1. Устанавливает /usr/bin/vpn-mode — команда переключения режимов
#   2. Устанавливает hotplug-обработчик кнопки (Cudy TR3000, Beryl AX)
#   3. Устанавливает init.d-сервис для синхронизации режима при загрузке
#   4. Выставляет режим по умолчанию: home (.ru напрямую, остальное через VPN)
set -e

echo "== 06. vpn-mode CLI + кнопка =="

# === 1. vpn-mode CLI ===
if [ -f /tmp/scripts/vpn-mode ]; then
    cp /tmp/scripts/vpn-mode /usr/bin/vpn-mode
    chmod +x /usr/bin/vpn-mode
    echo "→ установлен /usr/bin/vpn-mode"
else
    echo "✗ /tmp/scripts/vpn-mode не найден"; exit 1
fi

# === 2. Hotplug-обработчик физической кнопки ===
# Cudy TR3000: нажатие VPN-кнопки → vpn-mode toggle
# Beryl AX: нажатие кнопки → vpn-mode toggle (GPIO-слайдер читается отдельно при загрузке)
mkdir -p /etc/hotplug.d/button
if [ -f /tmp/scripts/hotplug/button/10-vpn-mode ]; then
    cp /tmp/scripts/hotplug/button/10-vpn-mode /etc/hotplug.d/button/10-vpn-mode
    chmod +x /etc/hotplug.d/button/10-vpn-mode
    echo "→ установлен hotplug-обработчик кнопки"
else
    echo "⚠ hotplug/button/10-vpn-mode не найден — физическая кнопка работать не будет"
fi

# === 3. Init.d для синхронизации режима при загрузке ===
if [ -f /tmp/scripts/init.d/vpn-mode ]; then
    cp /tmp/scripts/init.d/vpn-mode /etc/init.d/vpn-mode
    chmod +x /etc/init.d/vpn-mode
    /etc/init.d/vpn-mode enable
    echo "→ установлен init.d/vpn-mode (автозапуск)"
else
    echo "⚠ init.d/vpn-mode не найден — режим не будет восстанавливаться при перезагрузке"
fi

# === 4. Режим по умолчанию ===
# Если режим ещё не задан — применяем home (безопасный дефолт)
if [ ! -f /etc/vpn-mode.state ]; then
    /usr/bin/vpn-mode home
    echo "→ режим по умолчанию: home"
else
    echo "→ режим уже задан: $(cat /etc/vpn-mode.state)"
fi

echo
echo "✓ vpn-mode OK"
echo "  Переключение режимов:"
echo "    vpn-mode home    — .ru/.su/.рф напрямую, остальное через VPN"
echo "    vpn-mode travel  — весь трафик через VPN"
echo "    vpn-mode status  — текущий режим"
