#!/usr/bin/env bash
# tests/qemu/live-vps.sh — T4a: трафик НАСКВОЗЬ через НАСТОЯЩИЙ сервер Full-тира.
#
# Единственный тест, который доказывает не «обвязка применилась», а «байты дошли до интернета
# через туннель». Всё остальное в пирамиде герметично и этого дать не может: у Reality-инбаунда
# поле handshake обязательное, и сервер реально ходит на заимствованный сайт — в изолированной VM
# такая цель недостижима (это и есть объяснение `REALITY: processed invalid connection` из ADR 0004).
#
# ЧЕМ ДОКАЗЫВАЕТ. Проба (tunnel_connectivity) говорит лишь «байты куда-то дошли». Здесь сильнее:
# тянем «какой у меня IP» ЧЕРЕЗ туннель и сверяем ответ с адресом VPS. Совпало — значит трафик
# реально вышел в интернет на той стороне, а не утёк мимо. Плюс контрольный замер БЕЗ туннеля:
# если бы сверка проходила и так, она ничего не значила бы.
#
# Нужен поднятый стенд: tests/vps/provision-lab.sh на чистом VPS (ключи он генерирует сам, ничего
# ни у кого просить не надо). Ссылки берутся из tests/vps/links.env — его наполняет
# tests/vps/fetch-links.sh, и он НЕ коммитится (содержит credentials).
#
#     bash tests/vps/fetch-links.sh root@<vps>     # один раз
#     make qemu-live-vps
#
# НЕ в CI: зависит от арендованного сервера. Постоянная автоматизация остаётся герметичной —
# см. tests/vps/README.md, раздел «Почему это НЕ в CI».

set -e -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINKS_FILE="${LINKS_FILE:-$HERE/../vps/links.env}"

# shellcheck disable=SC1090  # путь вычисляется, файл не коммитится
[ -f "$LINKS_FILE" ] && . "$LINKS_FILE"

: "${VLESS_REALITY:=}"
: "${HYSTERIA2:=}"
: "${HYSTERIA2_PORT_HOPPING:=}"

if [ -z "$VLESS_REALITY" ] && [ -z "$HYSTERIA2" ]; then
    echo "✗ нет ссылок. Ожидается $LINKS_FILE (или env VLESS_REALITY / HYSTERIA2)."
    echo "  Поднять стенд:  bash tests/vps/provision-lab.sh   (на VPS)"
    echo "  Забрать ссылки: bash tests/vps/fetch-links.sh root@<vps>"
    exit 1
fi

# Адрес VPS достаём из самой ссылки (часть после '@' до ':') — отдельной переменной, которую можно
# забыть обновить, быть не должно.
link_host() { printf '%s' "$1" | sed -n 's|^[a-z2]*://[^@]*@\([^:/?#,]*\).*|\1|p'; }
VPS_IP="${VPS_IP:-$(link_host "${VLESS_REALITY:-$HYSTERIA2}")}"
[ -n "$VPS_IP" ] || { echo "✗ не удалось выделить адрес сервера из ссылки"; exit 1; }

. "$HERE/lib.sh"

vm_lib_init
vm_prepare_image
vm_start
vm_boot_and_setup
# fw4 ОБЯЗАТЕЛЬНО запущен: на роутере он работает всегда, а с остановленным (как оставляет
# vm_boot_and_setup) этот тест показывал «зелено» при неработающем TCP через туннель —
# см. WHY у vm_start_firewall.
vm_start_firewall

PASS=0; FAIL=0
REALITY_PATH_BROKEN=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

vm_check_dns
apk_try "apk update" || { echo "✗ apk update упал"; exit 1; }

# libustream-mbedtls + ca-bundle — чтобы uclient-fetch умел https С ПРОВЕРКОЙ сертификата:
# сверку «какой у меня IP» нельзя делать по http, иначе ответ можно подменить по пути.
echo "→ Ставлю зависимости"
for pkg in kmod-tun ip-full sing-box-tiny libustream-mbedtls ca-bundle \
           ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus; do
    apk_try "apk add $pkg" || { echo "✗ $pkg не ставится"; exit 1; }
done
vm_ssh "command -v sing-box >/dev/null" || { echo "✗ бинарь sing-box не появился"; exit 1; }
vm_ssh "/etc/init.d/sing-box stop >/dev/null 2>&1; /etc/init.d/sing-box disable >/dev/null 2>&1 || true"

echo "→ Раскладываю движок (как пакет)"
vm_ssh "mkdir -p /usr/share/cheburnet /etc/cheburnet /tmp/cheburnet"
tar -C "$REPO_ROOT" --exclude='engine/*/tests' --exclude='engine/*/*/tests' \
    --exclude='*README.md' -cf - engine \
    | vm_ssh "tar -C /usr/share/cheburnet -xf -"
ENG=/usr/share/cheburnet/engine

# Эндпоинт «какой у меня IP» и крупный файл для проверки фрагментации. Оба резолвим ОДИН раз и
# дальше пиним по адресу: маршрут в туннель ставится на IP, а не на имя.
ECHO_HOST="api.ipify.org"
BIG_URL="https://downloads.openwrt.org/releases/$OPENWRT_VERSION/packages/x86_64/packages/sing-box-tiny-1.12.17-r1.apk"
BIG_HOST="downloads.openwrt.org"
resolve() { vm_ssh "nslookup $1 2>/dev/null | awk '/^Address( 1)?: / && \$NF ~ /^[0-9.]+\$/ {print \$NF; exit}'"; }
ECHO_IP="$(resolve "$ECHO_HOST")"
BIG_IP="$(resolve "$BIG_HOST")"
[ -n "$ECHO_IP" ] && [ -n "$BIG_IP" ] || { echo "✗ не удалось разрешить тестовые адреса"; exit 1; }
echo "  ✓ $ECHO_HOST → $ECHO_IP, $BIG_HOST → $BIG_IP"

# ─── контрольный замер: БЕЗ туннеля мы выходим НЕ с адреса VPS ─────────────────
# Без этого сверка exit-IP ничего не доказывала бы: вдруг наш собственный адрес и так совпадает.
echo ""
echo "→ Контроль: без туннеля внешний адрес НЕ равен адресу VPS"
DIRECT_IP="$(vm_ssh "uclient-fetch -q -T 15 -O - https://$ECHO_HOST/ 2>/dev/null" | tr -d '\r\n ')"
if [ -z "$DIRECT_IP" ]; then
    bad "не удалось узнать внешний адрес без туннеля (https не работает?)"
    exit 1
fi
if [ "$DIRECT_IP" = "$VPS_IP" ]; then
    bad "внешний адрес и так равен адресу VPS ($DIRECT_IP) — сверка ничего не докажет"
    exit 1
fi
ok "без туннеля выходим с $DIRECT_IP, VPS — $VPS_IP (сверка осмысленна)"

# ─── проверка одного протокола ────────────────────────────────────────────────
check_link() { # NAME LINK
    local name="$1" link="$2"
    echo ""
    echo "→ $name"

    if ! vm_ssh "printf '%s' '$link' | ucode -R $ENG/steps/singbox/apply.uc" >/dev/null 2>&1; then
        bad "$name: singbox-шаг отказал (конфиг не принят)"
        vm_ssh "printf '%s' '$link' | ucode -R $ENG/steps/singbox/apply.uc" 2>&1 | tail -5 | sed 's/^/      /'
        return
    fi

    # netifd поднимает half-routes не мгновенно — ждём устройство, как это делает health-check.
    local up=""
    local i=0
    while [ "$i" -lt 20 ]; do
        i=$(( i + 1 ))
        if vm_ssh "ip link show singtun0 >/dev/null 2>&1 && ip route show | grep -q '0.0.0.0/1 dev singtun0'"; then
            up=1; break
        fi
        sleep 1
    done
    if [ -z "$up" ]; then
        bad "$name: singtun0/half-routes не появились"
        vm_ssh 'logread | grep -i sing-box | tail -8' | sed 's/^/      /' || true
        vm_ssh "ucode -R $ENG/steps/singbox/apply.uc --teardown" >/dev/null 2>&1 || true
        return
    fi
    ok "$name: туннель поднят (singtun0 + half-routes)"

    # 1. НАША проба — та самая, что гейтит commit установки. Здесь она работает против живого
    #    сервера, а не против заглушки: это первый раз, когда она обязана сказать UP.
    local probe
    probe="$(vm_ssh 'ucode -R /tmp/probe-check.uc 2>/dev/null')"
    if [ "$probe" = "UP" ]; then
        ok "$name: connectivity-probe подтвердила туннель (UP)"
    else
        bad "$name: проба вернула '$probe' — установка на роутере откатилась бы"
        local cli_log
        cli_log="$(vm_ssh 'logread | grep -i sing-box | tail -10' 2>/dev/null || true)"
        printf '%s\n' "$cli_log" | sed 's/^/      /'
        # Отдельно разбираем самый коварный случай: `reality verification failed` при TCP, который
        # УСТАНОВИЛСЯ. Это значит, что до сервера доехал НЕ наш ClientHello — подпись
        # TLS-инспектирующего middlebox на пути. Без этой подсказки провал читается как наш баг, и
        # человек идёт править конфиг, который на самом деле корректен (проверено 2026-07-31).
        if printf '%s' "$cli_log" | grep -q 'reality verification failed'; then
            REALITY_PATH_BROKEN=1
            echo "      ┌─ ДИАГНОЗ: TCP до сервера установился, но сервер не признал наш ClientHello."
            echo "      │  Это НЕ ошибка конфига (его корректность проверяется отдельно, см. ADR 0004),"
            echo "      │  а признак того, что путь ПЕРЕПИСЫВАЕТ рукопожатие: прозрачный прокси или"
            echo "      │  корпоративный TLS-инспектор. Reality против такого не работает В ПРИНЦИПЕ —"
            echo "      │  его доказательство держится на том, что ClientHello доходит байт-в-байт."
            echo "      └─ Проверять Reality надо из сети БЕЗ инспекции (живой роутер пользователя)."
        fi
    fi

    # 2. ГЛАВНОЕ: выходим ли мы в интернет с адреса VPS. Пин host-route на туннель — тот же приём,
    #    что в пробе: без него запрос ушёл бы на WAN и соврал.
    local exit_ip
    exit_ip="$(vm_ssh "ip route replace $ECHO_IP dev singtun0 2>/dev/null
        uclient-fetch -q -T 20 -O - https://$ECHO_HOST/ 2>/dev/null | tr -d '\r\n '
        ip route del $ECHO_IP dev singtun0 2>/dev/null" | tr -d '\r\n ')"
    if [ "$exit_ip" = "$VPS_IP" ]; then
        ok "$name: трафик ВЫШЕЛ В ИНТЕРНЕТ через сервер ($exit_ip = адрес VPS)"
    elif [ -z "$exit_ip" ]; then
        bad "$name: запрос через туннель не дошёл вообще"
    else
        bad "$name: вышли с $exit_ip вместо $VPS_IP — трафик утёк мимо туннеля"
    fi

    # 3. Крупная загрузка через туннель: ловит фрагментацию/PMTU-блэкхол. Классический симптом
    #    такой поломки — «мелкое открывается, крупное висит», и он не виден на коротких запросах.
    local dl
    dl="$(vm_ssh "ip route replace $BIG_IP dev singtun0 2>/dev/null
        rm -f /tmp/big.bin
        s=\$(awk '{printf \"%d\", \$1 * 100}' /proc/uptime)
        uclient-fetch -q -T 90 -O /tmp/big.bin '$BIG_URL' >/dev/null 2>&1 || true
        e=\$(awk '{printf \"%d\", \$1 * 100}' /proc/uptime)
        ip route del $BIG_IP dev singtun0 2>/dev/null
        sz=\$(wc -c < /tmp/big.bin 2>/dev/null || echo 0)
        cs=\$(( e - s )); [ \"\$cs\" -lt 1 ] && cs=1
        echo \"\$sz \$(( sz * 100 / 1024 / cs ))\"")"
    set -- $dl
    local size="${1:-0}" kbs="${2:-0}"
    if [ "$size" -gt 10000000 ]; then
        ok "$name: крупная загрузка прошла целиком ($(( size / 1048576 )) МБ, ${kbs} КБ/с) — PMTU в порядке"
    elif [ "$size" -gt 0 ]; then
        bad "$name: загрузка ОБОРВАЛАСЬ на $(( size / 1024 )) КБ — похоже на фрагментацию/PMTU"
    else
        bad "$name: крупная загрузка не пошла вовсе"
    fi

    vm_ssh "ucode -R $ENG/steps/singbox/apply.uc --teardown" >/dev/null 2>&1 || true
    sleep 2
}

# Обёртка пробы — тот же код, что гейтит установку.
cat > "$WORK/probe-check.uc" <<'UC'
import { tunnel_connectivity } from "/usr/share/cheburnet/engine/install/probe.uc";
printf("%s\n", tunnel_connectivity("singtun0").ok ? "UP" : "DOWN");
UC
vm_scp "$WORK/probe-check.uc" "/tmp/probe-check.uc"

[ -n "$VLESS_REALITY" ]          && check_link "VLESS+Reality" "$VLESS_REALITY"
[ -n "$HYSTERIA2" ]              && check_link "Hysteria2" "$HYSTERIA2"
[ -n "$HYSTERIA2_PORT_HOPPING" ] && check_link "Hysteria2 + port hopping" "$HYSTERIA2_PORT_HOPPING"

echo ""
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32m✓ T4a LIVE-VPS ЗЕЛЁНЫЙ: PASS=%d — трафик реально идёт через сервер по всем проверенным осям\033[0m\n' "$PASS"
    echo "  Осталось только то, что VPS дать не может: поведение в СЕТИ ПОЛЬЗОВАТЕЛЯ (пропускает ли"
    echo "  его провайдер эти протоколы) и PMTU на PPPoE — это живой роутер, не QEMU."
    exit 0
fi
printf '\033[31m✗ T4a LIVE-VPS: PASS=%d FAIL=%d\033[0m\n' "$PASS" "$FAIL"
if [ "$REALITY_PATH_BROKEN" = "1" ]; then
    echo ""
    echo "Похоже, единственная причина провала — переписанное рукопожатие на пути (см. ДИАГНОЗ выше),"
    echo "а не код. Прогоните этот же тест из другой сети или проверьте Reality с живого роутера."
fi
exit 1
