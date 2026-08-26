#!/bin/bash
# tests/qemu/lib.sh — shared infrastructure для T3-тестов в qemu.
#
# Source-only. Тестовые скрипты (smoke.sh, smoke-http.sh) делают:
#
#     . "$(dirname "$0")/lib.sh"
#     vm_lib_init                      # пути, deps, trap EXIT, мусор от прошлого прогона
#     vm_prepare_image                 # cache + sha256 + extract
#     vm_start                         # запустить qemu в фоне (-nographic + fifo)
#     vm_boot_and_setup                # дождаться shell, DHCP, прокинуть ssh-key
#     # … специфичные asserts через vm_ssh / vm_scp …
#
# Все имена с префиксом `vm_` — public API. Без префикса — внутреннее.
# Зависимости: bash 4+, qemu-system-x86_64, qemu-img, ncat, ssh, scp,
# ssh-keygen, sha256sum, gunzip, python3, wget.

# ─── конфиг по умолчанию (можно переопределить ДО vm_lib_init) ───────────────
# Гоняем ОБРАЗ РЕЛИЗА, а не rolling snapshot. Три причины, каждая оплачена:
#   - пользователи ставят релиз (README требует OpenWrt 25.12+); snapshot не стоит ни у кого,
#     то есть вся QEMU-пирамида проверяла сборку, которой нет ни на одном роутере;
#   - файл релиза неизменен и не исчезает с зеркала → пин перестаёт протухать сам по себе.
#     Snapshot переписывался upstream'ом ежедневно и ронял master в произвольный момент;
#   - kmod-amneziawg из awg-openwrt собирается ПОД РЕЛИЗ (тег vX.Y.Z) — под snapshot его нет
#     в принципе, поэтому туннельная часть стека в QEMU не проверялась вообще.
# Snapshot не выброшен: отдельный необязательный джоб (test.yml, раз в неделю) гоняет smoke
# на нём и даёт ранний сигнал о поломках upstream, НЕ блокируя релиз.
#
# ПОРЯДОК ОБНОВЛЕНИЯ ВЕРСИИ (иначе пин перестаёт что-либо гарантировать):
#   1. взять хеш из upstream-файла sha256sums рядом с образом (а не «что скачалось»);
#   2. убедиться, что у awg-openwrt есть релиз vX.Y.Z под эту версию — иначе install-тест
#      упадёт на AWG (это и есть смысл проверки, а не повод её ослабить);
#   3. прогнать qemu-smoke, qemu-install и qemu-reality локально;
#   4. только потом менять цифры здесь, одним коммитом с результатом прогона.
: "${OPENWRT_VERSION:=25.12.5}"
: "${IMG_URL:=https://downloads.openwrt.org/releases/$OPENWRT_VERSION/targets/x86/64/openwrt-$OPENWRT_VERSION-x86-64-generic-ext4-combined.img.gz}"
: "${IMG_SHA256:=23e2538e8ab0eb52dfed1c65d608ecdb71ffd432dd54885da138ae67cd9e4461}"
# Если qemu говорит «Could not set up host forwarding rule 'tcp::2222-:22'» — порт держит НЕ другой
# прогон, а хост. На WSL2/Windows Hyper-V резервирует целые диапазоны TCP, и bind падает с
# «Address already in use», при том что `ss -lnt` внутри WSL пуст (он не видит Windows-сторону).
# Лечится сменой порта: SSH_PORT=18022 HTTP_PORT=18080 make qemu-… (проверено: <2256 занят, 18022+ свободен).
: "${SSH_PORT:=2222}"
: "${HTTP_PORT:=8080}"      # для smoke-http (port-forward 8080→80)
: "${VM_RAM_MB:=512}"
: "${VM_CPUS:=2}"
: "${BOOT_TIMEOUT:=90}"
: "${SSH_TIMEOUT:=60}"

# ─── состояние (заполняет vm_lib_init) ───────────────────────────────────────
REPO_ROOT=""
WORK=""
IMG_GZ=""
IMG_RAW=""
CMD_FIFO=""
SERIAL_LOG=""
SSH_KEY=""
QPID=""
FIFO_FD=""
SSH_OPTS=()

# ─── зависимости ─────────────────────────────────────────────────────────────
vm_require() { command -v "$1" >/dev/null 2>&1 || { echo "✗ нужен $1"; exit 1; }; }

# ─── cleanup (trap EXIT регистрируется в vm_lib_init) ────────────────────────
vm_cleanup() {
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo
        echo "✗ smoke FAILED (exit $rc). Последние 60 строк serial-лога:"
        echo "─────────────────────────────────────────────────────────────"
        tail -n 60 "$SERIAL_LOG" 2>/dev/null || echo "  (serial.log пуст)"
        echo "─────────────────────────────────────────────────────────────"
    fi
    [ -n "$FIFO_FD" ] && eval "exec ${FIFO_FD}>&-" 2>/dev/null || true
    [ -n "$QPID" ] && kill "$QPID" 2>/dev/null || true
    sleep 0.3
    [ -n "$QPID" ] && kill -9 "$QPID" 2>/dev/null || true
    pkill -9 -f "qemu-system-x86_64.*$IMG_RAW" 2>/dev/null || true
    rm -f "$CMD_FIFO"
    return "$rc"
}

# ─── инициализация ───────────────────────────────────────────────────────────
vm_lib_init() {
    # REPO_ROOT — корень репо (lib.sh лежит в tests/qemu/).
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    WORK="$REPO_ROOT/tests/qemu/.work"
    # Имя с версией: при смене пина старый образ остаётся в кеше, а не молча подменяется.
    IMG_GZ="$WORK/openwrt-$OPENWRT_VERSION.img.gz"
    IMG_RAW="$WORK/disk.img"
    CMD_FIFO="$WORK/cmd.fifo"
    SERIAL_LOG="$WORK/serial.log"
    SSH_KEY="$WORK/id_ed25519"

    for t in qemu-system-x86_64 qemu-img ncat ssh scp ssh-keygen sha256sum \
             gunzip python3 wget; do
        vm_require "$t"
    done

    mkdir -p "$WORK"
    rm -f "$CMD_FIFO" "$SERIAL_LOG"

    # Освобождаем :SSH_PORT и :HTTP_PORT от орфанов прошлого упавшего прогона.
    fuser -k "$SSH_PORT/tcp"  2>/dev/null || true
    fuser -k "$HTTP_PORT/tcp" 2>/dev/null || true

    SSH_OPTS=(-i "$SSH_KEY"
              -o "Port=$SSH_PORT"
              -o StrictHostKeyChecking=no
              -o UserKnownHostsFile=/dev/null
              -o IdentitiesOnly=yes
              -o LogLevel=ERROR
              -o ConnectTimeout=10)

    trap vm_cleanup EXIT
}

# ─── образ ───────────────────────────────────────────────────────────────────
vm_prepare_image() {
    if [ ! -f "$IMG_GZ" ] \
       || [ "$(sha256sum "$IMG_GZ" | awk '{print $1}')" != "$IMG_SHA256" ]; then
        echo "→ Качаю образ OpenWrt $OPENWRT_VERSION ($(basename "$IMG_URL"))"
        wget -qO "$IMG_GZ.tmp" "$IMG_URL"
        local actual; actual="$(sha256sum "$IMG_GZ.tmp" | awk '{print $1}')"
        if [ "$actual" != "$IMG_SHA256" ]; then
            echo "✗ SHA256 mismatch."
            echo "  expected: $IMG_SHA256"
            echo "  actual:   $actual"
            echo "  Файл релиза неизменен — расхождение значит подмену на зеркале либо"
            echo "  правку OPENWRT_VERSION без обновления IMG_SHA256 (см. порядок в шапке)."
            rm -f "$IMG_GZ.tmp"; exit 1
        fi
        mv "$IMG_GZ.tmp" "$IMG_GZ"
    fi

    # Свежий disk.img каждый запуск — ноль state'а от прошлых прогонов.
    # `gunzip -c` отдаёт rc=2 на trailing-garbage (норма для image+padding).
    rm -f "$IMG_RAW"
    gunzip -c "$IMG_GZ" > "$IMG_RAW" || [ $? -eq 2 ]
    qemu-img resize -f raw "$IMG_RAW" 512M >/dev/null

    [ -f "$SSH_KEY" ] || ssh-keygen -t ed25519 -N '' -f "$SSH_KEY" -q
}

# ─── запуск qemu ─────────────────────────────────────────────────────────────
# Паттерн: -nographic роутит serial→stdio. stdin читаем из fifo. fd 9 держит
# fifo открытым на запись в r/w-режиме (чисто `>`-открытие fifo блокируется
# до появления reader'а — qemu — и зависает ДО запуска qemu).
#
# Параметр (опционально): дополнительные `-netdev`/`-device` форварды и т.п.
# По умолчанию — один user-mode netdev с hostfwd ssh+http.
vm_start() {
    local kvm_flags=()
    if [ -w /dev/kvm ]; then
        kvm_flags+=(-enable-kvm -cpu host)
    else
        echo "⚠ KVM недоступен — fallback на TCG (медленно)."
        kvm_flags+=(-cpu qemu64)
    fi

    mkfifo "$CMD_FIFO"
    echo "→ Запускаю qemu (KVM=$([ -w /dev/kvm ] && echo on || echo off))"
    exec 9<>"$CMD_FIFO"
    FIFO_FD=9

    qemu-system-x86_64 \
        -M pc \
        -m "$VM_RAM_MB" \
        -smp "$VM_CPUS" \
        "${kvm_flags[@]}" \
        -drive file="$IMG_RAW",format=raw,if=virtio \
        -netdev "user,id=net0,hostfwd=tcp::$SSH_PORT-:22,hostfwd=tcp::$HTTP_PORT-:80" \
        -device virtio-net,netdev=net0 \
        -nographic \
        < "$CMD_FIFO" > "$SERIAL_LOG" 2>&1 &
    QPID=$!
}

# ─── serial / network helpers ────────────────────────────────────────────────
vm_serial_send() {
    # `\r\n` — getty/ash на serial-консоли требует CR, иначе строка не
    # отдаётся на выполнение (накапливается в input-буфере).
    printf '%s\r\n' "$1" >&9
}

vm_wait_serial() {
    local marker="$1" timeout="${2:-90}"
    local end=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$end" ]; do
        if grep -qF -- "$marker" "$SERIAL_LOG" 2>/dev/null; then return 0; fi
        kill -0 "$QPID" 2>/dev/null || { echo "✗ qemu умер во время ожидания '$marker'"; return 1; }
        sleep 1
    done
    echo "✗ wait '$marker' timeout (${timeout}s)"
    return 1
}

vm_wait_tcp() {
    local port="$1" timeout="${2:-60}"
    local end=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$end" ]; do
        if ncat -z 127.0.0.1 "$port" 2>/dev/null; then return 0; fi
        sleep 1
    done
    echo "✗ TCP :$port timeout (${timeout}s)"
    return 1
}

# vm_ssh CMD — ssh с подменёнными опциями.
vm_ssh()  { ssh "${SSH_OPTS[@]}" root@127.0.0.1 "$@"; }

# vm_scp LOCAL REMOTE — стримит файл через ssh+cat (а не sftp), потому что
# dropbear в OpenWrt не поставляет sftp-server, на котором работает
# современный scp. Способ proto-независимый и бинарно-безопасный.
vm_scp()  { vm_ssh "cat > '$2'" < "$1"; }

# ─── boot + DHCP + ssh-key ───────────────────────────────────────────────────
# Подразумевает уже запущенную VM. После завершения функции — vm_ssh работает.
vm_boot_and_setup() {
    echo "→ Жду boot OpenWrt (до ${BOOT_TIMEOUT}с)"
    vm_wait_serial "Please press Enter to activate this console" "$BOOT_TIMEOUT"
    vm_serial_send ""
    sleep 1
    vm_serial_send "echo SHELL_READY_$$"
    vm_wait_serial "SHELL_READY_$$" 15

    echo "→ Конфигурирую DHCP на br-lan"
    # Ждём пока netifd зарегистрирует lan в ubus — на свежих сборках
    # /etc/init.d/network restart, запущенный СРАЗУ после shell-ready, валится
    # с `Command failed: Not found` (lan-секции ещё нет в активной конфиге
    # netifd, хотя в /etc/config/network она уже есть).
    vm_serial_send "for i in \$(seq 1 20); do ifstatus lan >/dev/null 2>&1 && break; sleep 1; done"
    sleep 2
    vm_serial_send "uci set network.lan.proto='dhcp'"
    vm_serial_send "uci -q delete network.lan.ipaddr"
    vm_serial_send "uci -q delete network.lan.netmask"
    vm_serial_send "uci commit network"
    # network reload вместо restart: reload подгружает изменённые секции без
    # сброса device'ов; restart на свежем netifd ловит тот же race.
    vm_serial_send "/etc/init.d/network reload"
    sleep 3
    # ifup lan форсит DHCP-renew даже если netifd считает что lan уже up
    # со static IP (его proto только что сменили на dhcp, но netifd мог
    # не подхватить через reload — это бывает).
    vm_serial_send "ifup lan"
    # Ждём пока lan получит IP. Маркер `ipv4-address` появляется в ifstatus
    # после udhcpc handshake; до этого SSH-форвардинг qemu user-mode не
    # доедет до VM (slirp форвардит на assigned IP, обычно 10.0.2.15).
    # 40с — qemu DHCP отвечает за ~2с, но первый udhcpc после ifup может
    # ретраить пакеты.
    vm_serial_send "for i in \$(seq 1 40); do ifstatus lan 2>/dev/null | grep -q ipv4-address && break; sleep 1; done"
    sleep 2
    # Fallback на случай если netifd так и не запустил udhcpc — bare-metal
    # udhcpc на br-lan напрямую. -q (один shot), -n (no-fork), -t 5 (5 retry).
    vm_serial_send "ifstatus lan 2>/dev/null | grep -q ipv4-address || udhcpc -i br-lan -q -n -t 5 2>/dev/null || true"
    sleep 3
    # Диагностика — печатаем что в итоге получили (видно в serial-логе при
    # фейле SSH).
    vm_serial_send "echo IFCONFIG_DUMP_BEGIN; ifstatus lan 2>/dev/null | head -20; ip -4 addr show br-lan 2>/dev/null; echo IFCONFIG_DUMP_END"
    sleep 2

    echo "→ Раздаю SSH-ключ + отключаю firewall в VM"
    local pubkey; pubkey="$(cat "$SSH_KEY.pub")"
    vm_serial_send "mkdir -p /root/.ssh && chmod 700 /root/.ssh"
    vm_serial_send "printf '%s\\n' '$pubkey' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"
    # На свежем OpenWrt SNAPSHOT firewall запускается и блокирует input
    # на :22 со стороны 10.0.2.x (qemu slirp). Для T3a (тестовое окружение)
    # firewall не нужен — отключаем перед dropbear restart.
    vm_serial_send "/etc/init.d/firewall stop 2>/dev/null || true"
    # На дефолтном dropbear-конфиге может быть Interface=lan — после смены
    # proto на dhcp lan-интерфейс «новый», нужен restart чтобы dropbear
    # перебиндил сокет на актуальный l3_device.
    vm_serial_send "/etc/init.d/dropbear restart"
    sleep 2
    # Диагностика на случай если SSH всё равно не отвечает: проверяем что
    # dropbear слушает на :22, и что nft не режет input.
    vm_serial_send "echo SSH_DIAG_BEGIN; netstat -lnt 2>/dev/null | grep ':22 ' || ss -lnt 2>/dev/null | grep ':22 '; nft list ruleset 2>/dev/null | head -5; echo SSH_DIAG_END"
    sleep 2

    echo "→ Жду SSH на :$SSH_PORT"
    vm_wait_tcp "$SSH_PORT" "$SSH_TIMEOUT"
    sleep 2
    local i
    for i in 1 2 3 4 5; do
        if vm_ssh true 2>/dev/null; then break; fi
        [ "$i" = 5 ] && { echo "✗ SSH не отвечает после 5 попыток"; exit 1; }
        sleep 2
    done
    echo "  ✓ SSH OK ($(vm_ssh 'uname -smr'))"
}

# vm_start_firewall() — поднять fw4 в VM с ПОСТОЯННЫМ ssh-правилом.
#
# ЗАЧЕМ ОБЯЗАТЕЛЬНО. vm_boot_and_setup глушит firewall, чтобы не потерять ssh через slirp. Но на
# роутере firewall запущен ВСЕГДА, и это не мелочь: с остановленным fw4 тесты Full-тира годами
# показывали «зелено», пока TCP через туннель у пользователя не работал вовсе (input у fw4 —
# policy drop, TUN не в зоне; поймано 2026-07-31, фикс — stack=gvisor в steps/singbox).
# Любой тест, который трогает туннель или data-plane, обязан звать это ПЕРЕД проверками —
# иначе он проверяет условия, которых не бывает.
#
# ssh страхуем uci-правилом, а не разовой nft-инъекцией: реальные шаги делают `fw4 reload`,
# который инъекцию стирает, а uci-правило переживает и reload, и перезагрузку.
vm_start_firewall() {
    echo "→ Поднимаю fw4 (условия реального роутера) + постоянное ssh-правило"
    vm_ssh 'uci -q delete firewall.qemu_ssh 2>/dev/null || true
            uci set firewall.qemu_ssh=rule
            uci set firewall.qemu_ssh.name="qemu-ssh"
            uci set firewall.qemu_ssh.src="*"
            uci set firewall.qemu_ssh.proto="tcp"
            uci set firewall.qemu_ssh.dest_port="22"
            uci set firewall.qemu_ssh.target="ACCEPT"
            uci commit firewall
            /etc/init.d/firewall enable >/dev/null 2>&1
            /etc/init.d/firewall start >/dev/null 2>&1; sleep 3
            nft list table inet fw4 >/dev/null' \
        || { echo "  ✗ fw4 не поднялся"; vm_ssh 'logread | tail -15' || true; exit 1; }
    vm_ssh true || { echo "  ✗ ssh потерян после старта fw4"; exit 1; }
    echo "  ✓ fw4 работает, ssh жив"
}

# vm_wait_ssh [СЕКУНД] — дождаться, пока ssh снова отвечает. Нужен тестам, которые дёргают тот
# самый интерфейс, по которому идёт ssh (ifup wan / network restart): команда возвращается раньше,
# чем netifd действительно рвёт и поднимает линк.
vm_wait_ssh() {
    local deadline=$(( SECONDS + ${1:-60} ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if vm_ssh true 2>/dev/null; then return 0; fi
        sleep 2
    done
    return 1
}

# vm_inv_failed ENGINE — id провалившихся инвариантов (engine/invariants), по одному в строке.
# Пусто = всё на месте. Нужен тестам, которые проверяют состояние data-plane целиком, вместо
# самодельных grep по ip/nft в каждом тесте: список инвариантов один, и тесты сверяются с ним.
vm_inv_failed() {
    vm_ssh "ucode -R $1/invariants/gather.uc | ucode -R $1/invariants/check.uc --json" 2>/dev/null \
        | python3 -c 'import json,sys
r = json.load(sys.stdin)
print("\n".join(c["id"] for c in r["checks"] if not c["ok"]))' || true
}

# vm_check_dns() — nslookup в VM или exit 1. Без интернета apk update/add бессмысленны.
vm_check_dns() {
    echo "→ Проверяю интернет в VM"
    vm_ssh "nslookup downloads.openwrt.org 2>&1 | grep -q 'Address.*\\.'" \
        || { echo "✗ DNS не работает в VM — apk update не пройдёт"; exit 1; }
    echo "  ✓ DNS работает"
}

# apk_try CMD — до 10 попыток по 10с, тихо; код возврата честный.
# 10×10с (было 5×3с): фильтрующая сеть рвёт отдельные файлы посреди передачи с высокой частотой,
# и пакет с несколькими новыми deps перемножает вероятность — 5 коротких попыток дважды красили
# тест на живом зеркале.
apk_try() {
    local cmd="$1"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if vm_ssh "$cmd" >/dev/null 2>&1; then return 0; fi
        sleep 10
    done
    return 1
}
