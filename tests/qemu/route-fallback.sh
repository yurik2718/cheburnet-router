#!/bin/bash
# tests/qemu/route-fallback.sh — T3i: у пути наружу ВСЕГДА есть фолбэк, а маршрут туннеля
# переживает переподключение WAN.
#
# Зачем. Маршрут туннеля ставил proto-handler AWG (`route_allowed_ips='1'`) — ОДИН
# `default dev awg0`, который ЗАМЕЩАЛ WAN-дефолт (тот же prefix, та же метрика) и обратно его не
# возвращал. В main оставался ровно один дефолт, и принадлежал он туннелю. Дальше любое
# исчезновение awg0 — ifdown кнопкой «перезапустить туннель» в панели, сбой netifd, смена
# протокола — оставляло роутер ВООБЩЕ без маршрута наружу: ни LAN, ни сам роутер (а значит ни DoH,
# ни apk, ни повторный подъём туннеля по имени хоста) никуда не идут, и само это не чинится —
# нужен ребут или ручной `ifup wan`. Проверено на сыром uci в этой же VM: после ifdown awg0 в main
# не остаётся ни одного дефолта.
#
# Фикс — half-routes (0.0.0.0/1 + 128.0.0.0/1, для v6 ::/1 + 8000::/1), как у Full-тира: они
# специфичнее WAN-дефолта, поэтому побеждают его НЕ УДАЛЯЯ, и WAN остаётся постоянным фолбэком.
# Ключевая здесь — ПРОВЕРКА 4: на старой схеме она падает (дефолтов нет вовсе).
#
# ПРОВЕРКА 3 (подъём WAN не отбирает маршрут у туннеля) — страховка на будущее, а не
# воспроизведение известного бага: на старой схеме в этой VM подъём WAN дефолт НЕ отбирал.
# Оставлена намеренно: «кто владеет дефолтом» — то место, где ошибка стоит всему дому интернета,
# и стоит зафиксировать, что подъём WAN на него не влияет.
#
# Живой VPN-сервер НЕ нужен: проверяется маршрутизация, а не трафик сквозь туннель.
# В VM интернет приходит одним slirp-NIC на br-lan, поэтому роль WAN здесь играет netifd-интерфейс
# `lan` — «переподключение провайдера» = ifup этого интерфейса.
#
# Запуск: make qemu-route-fallback (нужен интернет для apk). ~5-8 мин с KVM.

set -e -u -o pipefail

. "$(dirname "$0")/lib.sh"

WAN_IFACE=lan          # netifd-имя интерфейса, через который в VM приходит интернет
TUN=awg0

vm_lib_init
vm_prepare_image
vm_start
vm_boot_and_setup

vm_check_dns

echo "→ apk update"
apk_try "apk update" || { echo "✗ apk update упал"; vm_ssh "apk update 2>&1 | tail -10"; exit 1; }

echo "→ Ставлю зависимости"
for pkg in ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus nftables ip-full; do
    apk_try "apk add $pkg" || { echo "  ✗ не встал $pkg"; exit 1; }
done

echo "→ AmneziaWG тем же путём, что на роутере (vendored awg-инсталлятор)"
vm_scp "$REPO_ROOT/vendor/amneziawg-install.sh" "/tmp/awg-install.sh"
awg_ok=0
for attempt in 1 2 3; do
    vm_ssh "sh /tmp/awg-install.sh -n -e > /tmp/awg-install.log 2>&1 || true"
    if vm_ssh "modprobe amneziawg 2>/dev/null; lsmod | grep -q '^amneziawg'"; then awg_ok=1; break; fi
    echo "  … попытка $attempt не дала модуль, повтор"
done
[ "$awg_ok" = "1" ] || { echo "  ✗ kmod-amneziawg не встал"; vm_ssh "tail -20 /tmp/awg-install.log"; exit 1; }
echo "  ✓ модуль amneziawg в ядре"

echo "→ Раскладываю движок"
vm_ssh "mkdir -p /usr/share/cheburnet /etc/cheburnet"
tar -C "$REPO_ROOT" --exclude='engine/*/tests' --exclude='engine/*/*/tests' --exclude='*README.md' \
    -cf - engine | vm_ssh "tar -C /usr/share/cheburnet -xf -"
ENGINE=/usr/share/cheburnet/engine

vm_start_firewall

# ─── хелперы проверок ────────────────────────────────────────────────────────
# Дефолт МИМО туннеля: именно он обязан пережить и вооружение, и снятие туннеля.
wan_default() { vm_ssh "ip -4 route show default 2>/dev/null | grep -v ' dev $TUN' | head -1"; }
half_routes()  { vm_ssh "ip -4 route show 2>/dev/null | grep -cE '^(0\.0\.0\.0|128\.0\.0\.0)/1 dev $TUN' || true"; }
half_routes6() { vm_ssh "ip -6 route show 2>/dev/null | grep -cE '^(::|8000::)/1 dev $TUN' || true"; }
# Куда ядро реально отправит обычный (не-direct) пакет — единственный честный ответ на вопрос
# «кто владеет дефолтом»: конфиг может выглядеть правильно, а FIB решать иначе.
route_dev()    { vm_ssh "ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1"; }

# Ключи — base64 РОВНО 32 байт: `awg setconf` проверяет длину, и на «красивых» строках из
# юнит-тестов он падает («Key is not the correct length or format»), интерфейс навсегда остаётся
# pending и маршрутов нет вовсе — тест краснел бы не по делу (поймано на втором прогоне).
# Обфускация обязательна: без неё awg-proto ругается на неполный конфиг. Endpoint — RFC 5737,
# гарантированно не отвечает (живой сервер тут не нужен).
AWG_CONF='[Interface]
PrivateKey = Y2hlYnVybmV0LXRlc3QtcHJpdmF0ZS1rZXktMDAwMDE=
Address = 10.13.13.2/32
Jc = 4
Jmin = 40
Jmax = 70
S1 = 78
S2 = 22
H1 = 1234567
H2 = 2345678
H3 = 3456789
H4 = 4567890
[Peer]
PublicKey = Y2hlYnVybmV0LXRlc3QtcHVibGljLWtleS0wMDAwMDI=
Endpoint = 192.0.2.10:51820
PersistentKeepalive = 25'
printf '%s\n' "$AWG_CONF" > "$WORK/awg.conf"
vm_scp "$WORK/awg.conf" /tmp/awg.conf

BEFORE_WAN="$(wan_default)"
echo "  · WAN-дефолт до всего: ${BEFORE_WAN:-<нет>}"
[ -n "$BEFORE_WAN" ] || { echo "✗ в VM нет дефолтного маршрута — проверять нечего"; exit 1; }

# ─── 1. --no-arm: интерфейс поднят, но дом на туннель НЕ переключён ───────────
echo
echo "→ ПРОВЕРКА 1: --no-arm поднимает awg0, но маршрут не вооружает"
vm_ssh "cat /tmp/awg.conf | ucode -R $ENGINE/steps/vpn/apply.uc --no-arm" \
    || { echo "  ✗ шаг vpn --no-arm упал"; exit 1; }
vm_ssh "ip link show $TUN >/dev/null 2>&1" \
    || { echo "  ✗ устройство $TUN не создано"; vm_ssh "logread | tail -20"; exit 1; }
# Устройство существует и при провалившемся `awg setconf` (netifd оставляет link, а интерфейс
# висит в pending) — тогда маршрутов не будет НИКОГДА, и весь тест ниже врал бы про half-routes.
vm_ssh "ifstatus $TUN 2>/dev/null | grep -q '\"up\": true'" \
    || { echo "  ✗ netifd не поднял $TUN (интерфейс pending — конфиг не принят ядром)";
         vm_ssh "ifstatus $TUN | head -12; logread | grep -i -E 'awg|wireguard' | tail -10"; exit 1; }
[ "$(half_routes)" = "0" ] \
    || { echo "  ✗ half-routes появились до вооружения — дом переключился на непроверенный туннель";
         vm_ssh "ip -4 route show"; exit 1; }
[ "$(route_dev)" != "$TUN" ] \
    || { echo "  ✗ обычный трафик уже уходит в невооружённый туннель"; exit 1; }
echo "  ✓ awg0 поднят, маршрут не тронут (health-check ещё не подтвердил туннель)"

# ─── 2. --arm: half-routes выигрывают у WAN-дефолта, НЕ удаляя его ────────────
echo "→ ПРОВЕРКА 2: --arm вооружает half-routes, WAN-дефолт остаётся в main"
vm_ssh "ucode -R $ENGINE/steps/vpn/apply.uc --arm" \
    || { echo "  ✗ шаг vpn --arm упал"; exit 1; }
sleep 3
[ "$(half_routes)" = "2" ] \
    || { echo "  ✗ half-routes 0.0.0.0/1 + 128.0.0.0/1 не установлены (netifd не принял route-секции?)";
         vm_ssh "uci show network | grep route; ifstatus $TUN | head -30; ip -4 route show"; exit 1; }
[ "$(route_dev)" = "$TUN" ] \
    || { echo "  ✗ обычный трафик идёт не в туннель (dev $(route_dev)) — вооружение не сработало";
         vm_ssh "ip -4 route show"; exit 1; }
ARMED_WAN="$(wan_default)"
[ -n "$ARMED_WAN" ] \
    || { echo "  ✗ WAN-дефолт ИСЧЕЗ из main — это и есть корень инцидента: туннель некому подстраховать,";
         echo "    а снятие awg0 оставит роутер вообще без маршрута"; vm_ssh "ip -4 route show"; exit 1; }
echo "  ✓ туннель забрал трафик (dev $TUN), WAN-дефолт цел: $ARMED_WAN"
echo "  · v6 half-routes (::/1 + 8000::/1): $(half_routes6) из 2"

# ─── 3. ГЛАВНОЕ: переподключение WAN не отбирает маршрут у туннеля ────────────
echo "→ ПРОВЕРКА 3: провайдер переподключился (ifup $WAN_IFACE) — маршрут остаётся у туннеля"
# Отцепляем: ifup рвёт тот самый интерфейс, по которому идёт ssh.
vm_ssh "nohup sh -c 'sleep 1; ifup $WAN_IFACE' >/dev/null 2>&1 &" || true
sleep 8
vm_wait_ssh 90 || { echo "  ✗ ssh не вернулся после ifup $WAN_IFACE"; exit 1; }
sleep 3
AFTER_DEV="$(route_dev)"
[ "$AFTER_DEV" = "$TUN" ] || {
    echo "  ✗ ПОСЛЕ ПОДЪЁМА WAN ДЕФОЛТ УШЁЛ НА '$AFTER_DEV':"
    echo "    туннель жив и панель зелёная, а весь не-direct трафик LAN режет kill-switch —"
    echo "    худший из возможных симптомов, потому что снаружи всё выглядит исправным."
    vm_ssh "ip -4 route show; awg show $TUN 2>/dev/null | head -5"; exit 1; }
[ "$(half_routes)" = "2" ] \
    || { echo "  ✗ half-routes не пережили подъём WAN"; vm_ssh "ip -4 route show"; exit 1; }
[ -n "$(wan_default)" ] \
    || { echo "  ✗ WAN-дефолт пропал после собственного ifup"; vm_ssh "ip -4 route show"; exit 1; }
echo "  ✓ маршрут остался у туннеля, WAN-дефолт на месте (замещения нет ни в одну сторону)"

# ─── 4. Снятие туннеля не оставляет роутер без маршрута ──────────────────────
# Путь кнопки «Перезапустить туннель» в панели (ifdown/ifup awg0) — и главный шаг этого теста:
# на старой схеме ifdown уносил ЕДИНСТВЕННЫЙ дефолт (проверено на сыром uci), после чего роутер
# оставался без связи до перезагрузки — в том числе не мог перерезолвить endpoint по имени хоста,
# чтобы поднять туннель обратно.
echo "→ ПРОВЕРКА 4: ifdown $TUN — у роутера остаётся путь наружу"
vm_ssh "ifdown $TUN >/dev/null 2>&1; sleep 3" || true
DOWN_WAN="$(wan_default)"
[ -n "$DOWN_WAN" ] \
    || { echo "  ✗ после ifdown $TUN в main нет ни одного дефолта — роутер отрезан"; vm_ssh "ip -4 route show"; exit 1; }
vm_ssh "nslookup downloads.openwrt.org 2>&1 | grep -q 'Address.*\\.'" \
    || { echo "  ✗ маршрут есть, а связи нет"; exit 1; }
echo "  ✓ дефолт остался ($DOWN_WAN), резолв работает — кнопка «перезапустить туннель» безопасна"

echo "→ ПРОВЕРКА 4b: ifup $TUN возвращает вооружение само"
vm_ssh "ifup $TUN >/dev/null 2>&1; sleep 5" || true
[ "$(half_routes)" = "2" ] \
    || { echo "  ✗ half-routes не вернулись после ifup $TUN (они в uci, netifd обязан их поставить)";
         vm_ssh "uci show network | grep route; ip -4 route show"; exit 1; }
[ "$(route_dev)" = "$TUN" ] || { echo "  ✗ трафик не вернулся в туннель"; exit 1; }
echo "  ✓ вооружение восстановилось без нашего вмешательства"

# ─── 5. teardown чистит и маршруты, и секции ─────────────────────────────────
echo "→ ПРОВЕРКА 5: teardown снимает half-routes вместе с интерфейсом"
vm_ssh "ucode -R $ENGINE/steps/vpn/apply.uc --teardown" \
    || { echo "  ✗ teardown упал"; exit 1; }
sleep 2
[ "$(half_routes)" = "0" ] \
    || { echo "  ✗ half-routes остались после teardown — маршрут в несуществующий туннель";
         vm_ssh "ip -4 route show"; exit 1; }
vm_ssh "! uci -q get network.${TUN}_route4lo >/dev/null 2>&1" \
    || { echo "  ✗ route-секции остались в uci (owned_sections их не покрывает)";
         vm_ssh "uci show network | grep route"; exit 1; }
[ -n "$(wan_default)" ] \
    || { echo "  ✗ после teardown роутер без дефолта"; vm_ssh "ip -4 route show"; exit 1; }
vm_ssh "nslookup downloads.openwrt.org 2>&1 | grep -q 'Address.*\\.'" \
    || { echo "  ✗ после teardown нет связи"; exit 1; }
echo "  ✓ секции и маршруты сняты, интернет на роутере цел"

# ─── 6. обычное применение (замена сервера) вооружает за один проход ─────────
# Путь replace_awg_conf/switch_to_awg: секции интерфейса и маршрута уезжают одним uci batch.
echo "→ ПРОВЕРКА 6: обычное применение (без --arm) сразу ставит half-routes"
vm_ssh "cat /tmp/awg.conf | ucode -R $ENGINE/steps/vpn/apply.uc" \
    || { echo "  ✗ шаг vpn упал"; exit 1; }
sleep 3
[ "$(half_routes)" = "2" ] \
    || { echo "  ✗ обычное применение не вооружило маршрут (замена сервера оставила бы дом без туннеля)";
         vm_ssh "uci show network | grep route; ip -4 route show"; exit 1; }
[ "$(route_dev)" = "$TUN" ] || { echo "  ✗ трафик не в туннеле"; exit 1; }
[ -n "$(wan_default)" ] || { echo "  ✗ WAN-дефолт исчез"; vm_ssh "ip -4 route show"; exit 1; }
echo "  ✓ вооружено за один проход, WAN-дефолт цел"

echo
printf '\033[32m✓ route-fallback: WAN-дефолт остаётся фолбэком, маршрут туннеля переживает подъём WAN\033[0m\n'
