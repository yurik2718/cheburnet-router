#!/bin/bash
# setup.sh — интерактивный мастер настройки cheburnet-router.
# Запускайте с вашего ноутбука/компьютера, не с роутера.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
BOLD='\033[1m'; G='\033[0;32m'; R='\033[0;31m'; Y='\033[0;33m'; B='\033[0;34m'; N='\033[0m'

ok()   { printf "  ${G}✓${N} %s\n" "$1"; }
info() { printf "  → %s\n" "$1"; }
warn() { printf "  ${Y}⚠${N}  %s\n" "$1"; }
die()  { printf "\n  ${R}✗ Ошибка: %s${N}\n\n" "$1" >&2; exit 1; }
hr()   { printf "${BOLD}%s${N}\n" "──────────────────────────────────────────────"; }
ask()  { printf "  %s: " "$1"; }
step() { printf "\n${B}${BOLD}[%s] %s${N}\n\n" "$1" "$2"; }

# ══════════════════════════════════════════════════════════════════════
# ЭКРАН 1 — Приветствие и выбор режима
# ══════════════════════════════════════════════════════════════════════
clear
hr
printf "${BOLD}  cheburnet-router — свободный интернет дома${N}\n"
hr
printf "\n"
printf "  Этот мастер настроит ваш роутер, чтобы:\n"
printf "    • Заблокированные сайты открывались\n"
printf "    • Реклама блокировалась на всех устройствах в сети\n"
printf "    • .ru .su .рф сайты работали с обычной скоростью\n"
printf "\n"

hr
printf "\n"
printf "  ${BOLD}Выберите способ обхода блокировок:${N}\n\n"

printf "  ${B}${BOLD}[1] VPN — AmneziaWG${N}   ${G}★ рекомендуем${N}\n\n"
printf "      Как работает:\n"
printf "      Ваш трафик идёт через зашифрованный туннель до VPN-сервера\n"
printf "      за рубежом. Провайдер видит только зашифрованный поток —\n"
printf "      не видит ни сайты, ни содержимое.\n\n"
printf "      Что открывает:\n"
printf "      ✓ Все заблокированные сайты — YouTube, Instagram, Telegram\n"
printf "      ✓ Любые IP-блокировки\n"
printf "      ✓ .ru .su .рф идут напрямую без VPN — скорость не страдает\n\n"
printf "      Что нужно:\n"
printf "      ✗ Платный VPN-сервер (~300–500 руб/мес)\n"
printf "        Amnezia VPN (amnezia.org) или свой VPS с AmneziaWG\n\n"

hr
printf "\n"

printf "  ${B}${BOLD}[2] zapret${N}   ${Y}бесплатно, без сервера${N}\n\n"
printf "      Как работает:\n"
printf "      Роутер «ломает» заголовки TCP-пакетов так, что DPI-оборудование\n"
printf "      провайдера не распознаёт к какому сайту вы идёте и не блокирует.\n"
printf "      Никакого внешнего сервера — всё работает локально на роутере.\n\n"
printf "      Что открывает:\n"
printf "      ✓ Сайты заблокированные через DPI: YouTube, Twitch, часть других\n"
printf "      ✓ Бесплатно, без вложений\n\n"
printf "      Ограничения:\n"
printf "      ✗ НЕ работает с IP-блокировками: Instagram, Facebook\n"
printf "        могут по-прежнему не открываться\n"
printf "      ✗ Провайдер видит какие сайты вы открываете (трафик не скрыт)\n"
printf "      ✗ Эффективность зависит от провайдера — может не помочь у всех\n\n"

hr
printf "\n"
printf "  ${BOLD}Наш совет:${N}\n\n"
printf "  Если нужен Instagram или важна приватность — берите VPN [1].\n"
printf "  Если нет денег на VPN прямо сейчас — попробуйте zapret [2],\n"
printf "  это лучше чем ничего.\n\n"
hr
printf "\n"

ask "Ваш выбор [1 = VPN / 2 = zapret]"
read -r _mode_input

case "${_mode_input:-}" in
    1) MODE="vpn" ;;
    2) MODE="zapret" ;;
    *) die "Введите 1 или 2" ;;
esac

# ══════════════════════════════════════════════════════════════════════
# ЭКРАН 2 — Предварительные требования
# ══════════════════════════════════════════════════════════════════════
clear
hr
if [ "$MODE" = "vpn" ]; then
    printf "${BOLD}  Режим: VPN (AmneziaWG)${N}\n"
else
    printf "${BOLD}  Режим: zapret (обход DPI)${N}\n"
fi
hr
printf "\n"
printf "  ${BOLD}Перед началом убедитесь что у вас есть:${N}\n\n"
printf "  ✓ Роутер, прошитый на OpenWrt 25.12\n"
printf "    (инструкция: README.md → Шаг 1 и Шаг 2)\n\n"
if [ "$MODE" = "vpn" ]; then
    printf "  ✓ Файл .conf от AmneziaWG\n"
    printf "    Amnezia VPN: в приложении → Настройки → Экспорт конфигурации\n"
    printf "    Свой сервер: amnezia.org → установите через приложение на VPS\n\n"
fi
printf "  ✓ Компьютер подключён к роутеру кабелем\n\n"
printf "  ✓ SSH работает: ssh root@192.168.1.1\n\n"
hr
printf "\n  Нажмите Enter чтобы начать, или Ctrl+C для выхода: "
read -r _

# ══════════════════════════════════════════════════════════════════════
# ШАГ 1 — Адрес роутера
# ══════════════════════════════════════════════════════════════════════
step "1/4" "Адрес роутера"
printf "  Сразу после прошивки OpenWrt роутер доступен по адресу 192.168.1.1.\n"
printf "  Если вы его не меняли — просто нажмите Enter.\n\n"
ask "Адрес роутера [192.168.1.1]"
read -r _input
ROUTER_IP="${_input:-192.168.1.1}"
ROUTER="root@${ROUTER_IP}"

info "Проверяем подключение к $ROUTER_IP..."
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
         "$ROUTER" 'echo ok' >/dev/null 2>&1; then
    printf "\n"
    warn "Не удалось подключиться автоматически (без пароля)."
    printf "  Это нормально при первом запуске — введите пароль роутера.\n"
    printf "  По умолчанию пароль пустой — просто нажмите Enter.\n\n"
    if ! ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
             "$ROUTER" 'echo ok' >/dev/null 2>&1; then
        printf "\n"
        printf "  ${R}Не удалось подключиться.${N}\n\n"
        printf "  Что проверить:\n"
        printf "    • Роутер включён и подключён кабелем к вашему компьютеру\n"
        printf "    • Компьютер получил IP в подсети роутера (обычно 192.168.1.x)\n"
        printf "    • Попробуйте: ping %s\n" "$ROUTER_IP"
        printf "    • В OpenWrt SSH включён по умолчанию — если вы его выключали,\n"
        printf "      зайдите в веб-интерфейс http://%s → System → Administration\n" "$ROUTER_IP"
        die "Нет SSH-доступа к $ROUTER_IP"
    fi
fi
ok "Роутер $ROUTER_IP доступен"

if ! ssh -o ConnectTimeout=10 "$ROUTER" 'grep -q OpenWrt /etc/openwrt_release 2>/dev/null'; then
    printf "\n"
    printf "  На %s что-то есть, но это не OpenWrt.\n\n" "$ROUTER_IP"
    printf "  Возможные причины:\n"
    printf "    • Вы подключились не к тому роутеру — проверьте IP\n"
    printf "    • Роутер ещё не перепрошит с GL.iNet/Cudy-стока на OpenWrt\n"
    printf "  Что сделать:\n"
    printf "    • Прошейте OpenWrt 25.12+ по инструкции: README.md → Шаг 2\n"
    die "На $ROUTER_IP не OpenWrt"
fi
ok "OpenWrt подтверждён"

# === Бутстрап SSH-ключа ===
# Дальнейшая установка идёт через full-deploy.sh, который делает десятки SSH-команд.
# Каждый раз вводить пароль мучительно, поэтому сейчас один раз кладём публичный
# ключ на роутер — после этого всё пойдёт без запроса пароля.
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$ROUTER" 'true' >/dev/null 2>&1; then
    printf "\n"
    info "Для автоматической установки нужен SSH-ключ."
    printf "  Это разовая операция: сейчас скопируем ключ на роутер, дальше мастер\n"
    printf "  будет выполнять команды без ввода пароля.\n\n"

    # Ищем существующий SSH-ключ пользователя
    USER_KEY=""
    for K in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ecdsa"; do
        if [ -f "${K}.pub" ]; then
            USER_KEY="$K"
            break
        fi
    done

    if [ -z "$USER_KEY" ]; then
        info "SSH-ключа на вашем компьютере ещё нет — создаю новый (ed25519, без пароля)."
        mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
        if ! ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" -C "cheburnet-router" >/dev/null; then
            printf "\n"
            printf "  Что сделать:\n"
            printf "    • Установите OpenSSH: на Linux — пакет 'openssh-client',\n"
            printf "      на macOS — обычно уже есть\n"
            printf "    • Проверьте что ssh-keygen доступен: which ssh-keygen\n"
            die "Не удалось создать SSH-ключ"
        fi
        USER_KEY="$HOME/.ssh/id_ed25519"
        ok "Создан SSH-ключ: $USER_KEY"
    else
        ok "Используем существующий SSH-ключ: $USER_KEY"
    fi

    printf "\n"
    info "Копирую публичный ключ на роутер. Введите пароль роутера один раз."
    info "(по умолчанию пароль пустой — просто нажмите Enter)"
    printf "\n"

    if command -v ssh-copy-id >/dev/null 2>&1; then
        if ! ssh-copy-id -o StrictHostKeyChecking=accept-new -i "${USER_KEY}.pub" "$ROUTER"; then
            printf "\n"
            printf "  Что проверить:\n"
            printf "    • Введённый пароль — попробуйте ещё раз\n"
            printf "    • Роутер не перегружается (подождите 30 сек и повторите)\n"
            die "ssh-copy-id не смог скопировать ключ"
        fi
    else
        # ssh-copy-id отсутствует (редко на голой macOS/Alpine) — делаем вручную
        warn "ssh-copy-id не найден, копирую ключ вручную"
        PUB_CONTENT=$(cat "${USER_KEY}.pub")
        if ! ssh -o StrictHostKeyChecking=accept-new "$ROUTER" \
            "mkdir -p /etc/dropbear && \
             grep -qF '$PUB_CONTENT' /etc/dropbear/authorized_keys 2>/dev/null || \
             echo '$PUB_CONTENT' >> /etc/dropbear/authorized_keys && \
             chmod 600 /etc/dropbear/authorized_keys"; then
            die "Не удалось скопировать ключ вручную. Попробуйте:  cat ${USER_KEY}.pub | ssh $ROUTER 'cat >> /etc/dropbear/authorized_keys'"
        fi
    fi

    # Финальная проверка
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$ROUTER" 'true' >/dev/null 2>&1; then
        printf "\n"
        printf "  Ключ скопирован, но автоматический вход всё ещё не работает.\n"
        printf "  Что проверить:\n"
        printf "    • На роутере: ssh %s 'cat /etc/dropbear/authorized_keys'\n" "$ROUTER"
        printf "    • Права файла должны быть 600 (см. ls -la /etc/dropbear/)\n"
        die "SSH-ключ не сработал — откройте issue на GitHub с выводом проверок"
    fi
    ok "SSH-ключ установлен — дальше всё пойдёт автоматически"
fi

# ══════════════════════════════════════════════════════════════════════
# ШАГ 2 — VPN-конфиг (только для режима VPN)
# ══════════════════════════════════════════════════════════════════════
if [ "$MODE" = "vpn" ]; then
    step "2/4" "Файл VPN-конфигурации (.conf)"
    printf "  AmneziaWG-конфиг — это небольшой файл с параметрами подключения\n"
    printf "  к вашему VPN-серверу. Без него VPN работать не будет.\n\n"
    printf "  Где взять:\n"
    printf "    Amnezia VPN → в приложении → выберите сервер → Поделиться →\n"
    printf "    Экспорт конфигурации → скачайте файл .conf\n\n"
    printf "    Свой VPS → установите AmneziaWG через приложение Amnezia,\n"
    printf "    потом так же экспортируйте .conf\n\n"
    ask "Путь к файлу .conf (например: ~/Downloads/amnezia.conf)"
    read -r _input
    CONF_PATH="${_input/#\~/$HOME}"
    if [ -z "$CONF_PATH" ]; then
        die "Путь к файлу не может быть пустым — повторите запуск мастера"
    fi
    if [ ! -f "$CONF_PATH" ]; then
        printf "\n"
        printf "  Что проверить:\n"
        printf "    • Скопируйте точный путь из файлового менеджера\n"
        printf "    • Используйте ~/ для домашней папки или полный путь\n"
        printf "    • На macOS — перетащите файл в окно терминала, путь подставится\n"
        die "Файл не найден: $CONF_PATH"
    fi
    if ! grep -q '\[Interface\]' "$CONF_PATH"; then
        printf "\n"
        printf "  Это не похоже на AmneziaWG-конфиг — нет секции [Interface].\n\n"
        printf "  Откуда берётся правильный конфиг:\n"
        printf "    • Приложение Amnezia VPN → Настройки → Экспорт конфигурации\n"
        printf "    • Получится файл вида: [Interface]...PrivateKey=...[Peer]...\n"
        die "Неправильный формат файла"
    fi
    if ! grep -q 'PrivateKey' "$CONF_PATH" || ! grep -q '\[Peer\]' "$CONF_PATH"; then
        printf "\n"
        printf "  В файле отсутствуют критичные секции (PrivateKey и/или [Peer]).\n"
        printf "  Скорее всего вы экспортировали публичную часть вместо полной.\n"
        printf "  Попробуйте ещё раз экспортировать конфиг в приложении Amnezia.\n"
        die "Неполный AmneziaWG-конфиг"
    fi
    ok "Конфиг найден и выглядит правильно"
fi

# ══════════════════════════════════════════════════════════════════════
# ШАГ 3 — Wi-Fi
# ══════════════════════════════════════════════════════════════════════
if [ "$MODE" = "vpn" ]; then
    WIFI_STEP_NUM="3/4"
else
    WIFI_STEP_NUM="2/3"
fi
step "$WIFI_STEP_NUM" "Настройка Wi-Fi"
printf "  Придумайте имя и пароль для домашней Wi-Fi сети.\n"
printf "  Все устройства подключённые к этой сети получат обход блокировок\n"
printf "  автоматически — ничего не нужно настраивать на каждом телефоне/ноутбуке.\n\n"
ask "Название сети (SSID)"
read -r WIFI_SSID
[ -n "$WIFI_SSID" ]      || die "Название сети не может быть пустым"
[ ${#WIFI_SSID} -le 32 ] || die "Название не может быть длиннее 32 символов"

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
# ШАГ 4 — Подтверждение и установка
# ══════════════════════════════════════════════════════════════════════
if [ "$MODE" = "vpn" ]; then
    CONFIRM_STEP_NUM="4/4"
else
    CONFIRM_STEP_NUM="3/3"
fi
step "$CONFIRM_STEP_NUM" "Подтверждение"

hr
if [ "$MODE" = "vpn" ]; then
    printf "${BOLD}  Итог — что будет установлено (режим VPN):${N}\n"
    hr
    printf "\n"
    printf "  Роутер:    %s\n" "$ROUTER_IP"
    printf "  VPN-файл:  %s\n" "$(basename "$CONF_PATH")"
    printf "  Wi-Fi:     %s (WPA3)\n\n" "$WIFI_SSID"
    printf "  Компоненты:\n"
    printf "    ✓ AmneziaWG — VPN-туннель с защитой от DPI-блокировок\n"
    printf "    ✓ Podkop — .ru/.su/.рф напрямую, остальное через VPN\n"
    printf "    ✓ Hagezi Pro — блокировка 200к+ рекламных доменов\n"
    printf "    ✓ Quad9 DoH — зашифрованный DNS (провайдер не видит DNS-запросы)\n"
    printf "    ✓ Kill switch — при падении VPN трафик блокируется, не утекает\n"
    printf "    ✓ Watchdog — автоперезапуск VPN при зависании\n"
else
    printf "${BOLD}  Итог — что будет установлено (режим zapret):${N}\n"
    hr
    printf "\n"
    printf "  Роутер:  %s\n" "$ROUTER_IP"
    printf "  Wi-Fi:   %s (WPA3)\n\n" "$WIFI_SSID"
    printf "  Компоненты:\n"
    printf "    ✓ zapret — обход DPI-блокировок без внешнего сервера\n"
    printf "    ✓ Hagezi Pro — блокировка 200к+ рекламных доменов\n"
    printf "    ✓ Quad9 DoH — зашифрованный DNS\n\n"
    warn "Instagram, Facebook и сайты с IP-блокировкой могут не работать."
    printf "  Для них нужен VPN.\n"
fi
printf "\n"
hr
printf "\n  Продолжить? [Enter = да, Ctrl+C = отмена]: "
read -r _

# ── Сохраняем конфиги ──────────────────────────────────────────────────
printf "\n"
cat > "$REPO_ROOT/configs/wireless-actual.txt" << EOF
WIFI_SSID="$WIFI_SSID"
WIFI_KEY="$WIFI_KEY"
WIFI_COUNTRY="$WIFI_COUNTRY"
EOF
ok "Wi-Fi конфиг сохранён"

if [ "$MODE" = "vpn" ]; then
    cp "$CONF_PATH" "$REPO_ROOT/configs/awg0.conf"
    chmod 600 "$REPO_ROOT/configs/awg0.conf"
    ok "VPN конфиг сохранён"
    printf "\n  ${BOLD}Запускаем установку VPN (~12 минут)...${N}\n\n"
    "$REPO_ROOT/setup/full-deploy.sh" "$ROUTER"
else
    printf "\n  ${BOLD}Запускаем установку zapret (~8 минут)...${N}\n\n"
    "$REPO_ROOT/setup/full-deploy-zapret.sh" "$ROUTER"
fi

# ══════════════════════════════════════════════════════════════════════
# Финал
# ══════════════════════════════════════════════════════════════════════
printf "\n"
hr
printf "${G}${BOLD}  ✓ Роутер настроен!${N}\n"
hr
printf "\n"
printf "${BOLD}Что делать дальше:${N}\n\n"
printf "  1. Подключитесь к Wi-Fi: ${BOLD}%s${N}\n" "$WIFI_SSID"
printf "  2. Откройте ${BOLD}speedtest.yandex.ru${N}\n"
printf "     Российский сервис — должен работать напрямую\n\n"
printf "  3. Откройте ${BOLD}speedtest.net${N}\n"
printf "     В России заблокирован — откроется только если обход работает\n\n"
hr
printf "\n"
if [ "$MODE" = "vpn" ]; then
    printf "${BOLD}Управление VPN (через SSH):${N}\n\n"
    printf "  Подключиться к роутеру:  ${BOLD}ssh root@%s${N}\n\n" "$ROUTER_IP"
    printf "  vpn-mode status    — текущий режим\n"
    printf "  vpn-mode home      — .ru напрямую + остальное через VPN\n"
    printf "  vpn-mode travel    — весь трафик через VPN\n"
    printf "  travel-check       — полная диагностика\n"
else
    printf "${BOLD}Управление zapret (через SSH):${N}\n\n"
    printf "  Подключиться к роутеру:  ${BOLD}ssh root@%s${N}\n\n" "$ROUTER_IP"
    printf "  /etc/init.d/zapret status             — статус DPI-обхода\n"
    printf "  /etc/init.d/zapret restart            — перезапустить zapret\n"
    printf "  /etc/init.d/https-dns-proxy status    — статус шифрованного DNS\n\n"
    warn "Если нужные сайты всё ещё не открываются:"
    printf "  Попробуйте другую стратегию. Подробнее: README.md → раздел zapret\n"
fi
printf "\n"
hr
printf "\n"
