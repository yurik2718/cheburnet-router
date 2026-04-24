#!/bin/bash
# setup.sh — интерактивная настройка cheburnet-router.
# Запускайте с вашего ноутбука/компьютера, не с роутера.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

# ── Цвета ──────────────────────────────────────────────────────────────
BOLD='\033[1m'; G='\033[0;32m'; R='\033[0;31m'; Y='\033[0;33m'; B='\033[0;34m'; N='\033[0m'

say()  { printf "\n${BOLD}%s${N}\n" "$1"; }
ok()   { printf "  ${G}✓${N} %s\n" "$1"; }
info() { printf "  → %s\n" "$1"; }
warn() { printf "  ${Y}!${N} %s\n" "$1"; }
die()  { printf "\n  ${R}✗ Ошибка: %s${N}\n\n" "$1" >&2; exit 1; }
hr()   { printf "${BOLD}%s${N}\n" "──────────────────────────────────────────────"; }
ask()  { printf "  %s: " "$1"; }
step() { printf "\n${B}${BOLD}[%s] %s${N}\n" "$1" "$2"; }

# ── Приветствие ────────────────────────────────────────────────────────
clear
hr
printf "${BOLD}  cheburnet-router — свободный интернет дома${N}\n"
hr
printf "\n"
printf "  Этот мастер настроит ваш роутер за ~12 минут:\n\n"
printf "    .ru .su .рф    — через обычный интернет (без VPN)\n"
printf "    Всё остальное  — через зашифрованный VPN-туннель\n"
printf "    Реклама        — заблокирована на всех устройствах\n\n"
hr

# ── Предварительные требования ─────────────────────────────────────────
printf "\n${BOLD}Перед началом убедитесь:${N}\n\n"
printf "  1. Роутер прошит на OpenWrt 25.12 и подключён к компьютеру\n"
printf "     (если ещё нет — инструкция: README.md → Шаг 1 и Шаг 2)\n\n"
printf "  2. Есть файл .conf от AmneziaWG\n"
printf "     (скачайте в приложении Amnezia: Настройки → Экспорт конфигурации)\n\n"
printf "  3. SSH-доступ к роутеру работает:\n"
printf "     ${BOLD}ssh root@192.168.1.1${N}\n\n"
printf "  Нажмите Enter чтобы начать, или Ctrl+C для выхода: "
read -r _

# ══════════════════════════════════════════════════════════════════════
# Шаг 1: адрес роутера
# ══════════════════════════════════════════════════════════════════════
step "1/4" "Адрес роутера"
printf "\n"
printf "  Обычно роутер доступен по адресу 192.168.1.1 сразу после прошивки.\n\n"
ask "Адрес роутера [192.168.1.1]"
read -r _input
ROUTER_IP="${_input:-192.168.1.1}"
ROUTER="root@${ROUTER_IP}"

info "Проверяем подключение к $ROUTER_IP..."

if ! ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
         "$ROUTER" 'echo ok' >/dev/null 2>&1; then
    printf "\n  ${Y}Не удалось подключиться автоматически (без пароля).${N}\n"
    printf "  Это нормально при первом подключении — сейчас попробуем с паролем.\n"
    printf "  Если роутер просит пароль — введите его (по умолчанию пустой или 'admin').\n\n"
    if ! ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
             "$ROUTER" 'echo ok' >/dev/null 2>&1; then
        printf "\n  ${R}Всё равно не получилось.${N}\n\n"
        printf "  Что проверить:\n"
        printf "    • Роутер включён и подключён кабелем к компьютеру\n"
        printf "    • Попробуйте: ping $ROUTER_IP\n"
        printf "    • Убедитесь что SSH включён в OpenWrt (System → Administration)\n"
        die "Нет SSH-доступа к $ROUTER_IP"
    fi
fi
ok "Роутер $ROUTER_IP доступен"

# Проверяем что на роутере OpenWrt
if ! ssh -o ConnectTimeout=10 "$ROUTER" 'grep -q OpenWrt /etc/openwrt_release 2>/dev/null'; then
    die "На $ROUTER_IP не OpenWrt или нет /etc/openwrt_release"
fi
ok "OpenWrt подтверждён"

# ══════════════════════════════════════════════════════════════════════
# Шаг 2: VPN-конфиг
# ══════════════════════════════════════════════════════════════════════
step "2/4" "VPN-конфигурация (AmneziaWG)"
printf "\n"
printf "  Где взять файл .conf:\n"
printf "    • Amnezia Premium: в приложении → сервер → Поделиться → Экспорт\n"
printf "    • Свой сервер: amnezia.org → инструкция по self-hosted\n\n"
ask "Путь к файлу .conf"
read -r _input
CONF_PATH="${_input/#\~/$HOME}"

[ -n "$CONF_PATH" ] || die "Путь не может быть пустым"
[ -f "$CONF_PATH" ] || die "Файл не найден: $CONF_PATH"

# Базовая проверка формата
grep -q '\[Interface\]' "$CONF_PATH" || die "Файл не похож на WireGuard/AmneziaWG конфиг (нет [Interface])"
grep -q 'PrivateKey'    "$CONF_PATH" || die "В конфиге нет PrivateKey — это не AWG конфиг"
grep -q '\[Peer\]'      "$CONF_PATH" || die "В конфиге нет секции [Peer]"

ok "Конфиг найден и выглядит правильно"

# ══════════════════════════════════════════════════════════════════════
# Шаг 3: Wi-Fi
# ══════════════════════════════════════════════════════════════════════
step "3/4" "Настройка Wi-Fi"
printf "\n"
printf "  Придумайте имя и пароль для вашей домашней Wi-Fi сети.\n\n"

ask "Название сети (SSID)"
read -r WIFI_SSID
[ -n "$WIFI_SSID" ] || die "Название сети не может быть пустым"
[ ${#WIFI_SSID} -le 32 ] || die "Название сети не может быть длиннее 32 символов"

printf "  Пароль Wi-Fi (минимум 8 символов): "
stty -echo 2>/dev/null || true
read -r WIFI_KEY
stty echo 2>/dev/null || true
printf "\n"
[ ${#WIFI_KEY} -ge 8 ] || die "Пароль должен быть не короче 8 символов"

ask "Страна [RU]"
read -r _input
WIFI_COUNTRY="${_input:-RU}"

ok "Wi-Fi: SSID='$WIFI_SSID', страна=$WIFI_COUNTRY"

# ══════════════════════════════════════════════════════════════════════
# Шаг 4: Подтверждение и установка
# ══════════════════════════════════════════════════════════════════════
step "4/4" "Установка"
printf "\n"
hr
printf "${BOLD}  Итог — что будет установлено на роутер $ROUTER_IP:${N}\n"
hr
printf "\n"
printf "  Роутер:  %s\n" "$ROUTER_IP"
printf "  VPN:     файл %s\n" "$(basename "$CONF_PATH")"
printf "  Wi-Fi:   $WIFI_SSID (WPA3)\n\n"
printf "  Компоненты:\n"
printf "    ✓ AmneziaWG — VPN с защитой от блокировок\n"
printf "    ✓ Podkop — умная маршрутизация (.ru напрямую, остальное через VPN)\n"
printf "    ✓ Hagezi Pro — блокировка 200к+ рекламных доменов\n"
printf "    ✓ Quad9 DoH — зашифрованный DNS\n"
printf "    ✓ Kill switch — защита от утечек при сбое VPN\n"
printf "    ✓ Watchdog — автоперезапуск при сбоях\n\n"
hr

printf "\n  Продолжить? [Enter = да, Ctrl+C = отмена]: "
read -r _

# ── Сохраняем конфиги ─────────────────────────────────────────────────
printf "\n"
cp "$CONF_PATH" "$REPO_ROOT/configs/awg0.conf"
chmod 600 "$REPO_ROOT/configs/awg0.conf"
ok "VPN конфиг сохранён в configs/awg0.conf"

cat > "$REPO_ROOT/configs/wireless-actual.txt" << EOF
WIFI_SSID="$WIFI_SSID"
WIFI_KEY="$WIFI_KEY"
WIFI_COUNTRY="$WIFI_COUNTRY"
EOF
ok "Wi-Fi конфиг сохранён в configs/wireless-actual.txt"

# ── Запускаем деплой ──────────────────────────────────────────────────
printf "\n"
printf "  ${BOLD}Начинаем установку — это займёт около 10-12 минут...${N}\n\n"

"$REPO_ROOT/setup/full-deploy.sh" "$ROUTER"

# ══════════════════════════════════════════════════════════════════════
# Финал
# ══════════════════════════════════════════════════════════════════════
printf "\n"
hr
printf "${G}${BOLD}  ✓ Роутер настроен!${N}\n"
hr
printf "\n"
printf "${BOLD}Что делать дальше:${N}\n\n"
printf "  1. Подключитесь к Wi-Fi сети: ${BOLD}$WIFI_SSID${N}\n"
printf "  2. Откройте ${BOLD}speedtest.yandex.ru${N} — должен работать напрямую (RU IP)\n"
printf "  3. Откройте ${BOLD}speedtest.net${N} — в России заблокирован, значит\n"
printf "     откроется только через VPN. Если открылся — всё работает правильно.\n\n"
printf "${BOLD}Полезные команды (выполнять через SSH):${N}\n\n"
printf "  Подключиться:           ${BOLD}ssh root@$ROUTER_IP${N}\n"
printf "  Статус VPN:             ${BOLD}vpn-mode status${N}\n"
printf "  Переключить режим:\n"
printf "    .ru напрямую + VPN:   ${BOLD}vpn-mode home${N}\n"
printf "    Всё через VPN:        ${BOLD}vpn-mode travel${N}\n"
printf "  Диагностика:            ${BOLD}travel-check${N}\n\n"
printf "  Полная документация:    README.md → раздел Документация\n\n"
hr
printf "\n"
