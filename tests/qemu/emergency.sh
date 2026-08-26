#!/bin/bash
# tests/qemu/emergency.sh — T3k: АВАРИЙНЫЙ РЕЖИМ возвращает интернет и обратим одной кнопкой.
#
# Зачем. Туннель может умереть по причине, до которой человеку из панели не дотянуться: сервер
# выключили, ключ просрочен, провайдер режет протокол. До аварийной кнопки у неспециалиста
# оставались ровно два выхода — SSH или factory_reset (снести настройку целиком). Это прямо
# противоречит цели продукта: роутер для тех, кто не хочет разбираться.
#
# Проверяем ровно то, что обещано человеку:
#   • пока защита включена, а туннель мёртв — наружу не ходит ничего (это kill-switch, так и надо);
#   • одна кнопка — и интернет есть, а настройки целы;
#   • пока защита снята, никто её молча не возвращает (ни сторож, ни переприменение);
#   • вторая кнопка — и защита вернулась целиком.
#
# Живой VPN-сервер НЕ нужен: туннель настоящий (awg0 с ключами нужной длины), но его endpoint
# заведомо недостижим — RFC 5737. Это и есть «сервер умер».
#
# Запуск: make qemu-emergency (нужен интернет для apk). ~6-9 мин с KVM.

set -e -u -o pipefail

. "$(dirname "$0")/lib.sh"

TUN=awg0
PROBE_URL=https://downloads.openwrt.org/

vm_lib_init
vm_prepare_image
vm_start
vm_boot_and_setup
vm_check_dns

echo "→ apk update"
apk_try "apk update" || { echo "✗ apk update упал"; exit 1; }

echo "→ Ставлю зависимости"
for pkg in ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus nftables ip-full \
           dnsmasq-full https-dns-proxy; do
    apk_try "apk add $pkg" || { echo "  ✗ не встал $pkg"; exit 1; }
done

echo "→ AmneziaWG (vendored инсталлятор, как на роутере)"
vm_scp "$REPO_ROOT/vendor/amneziawg-install.sh" "/tmp/awg-install.sh"
awg_ok=0
for _ in 1 2 3; do
    vm_ssh "sh /tmp/awg-install.sh -n -e > /tmp/awg-install.log 2>&1 || true"
    if vm_ssh "modprobe amneziawg 2>/dev/null; lsmod | grep -q '^amneziawg'"; then awg_ok=1; break; fi
done
[ "$awg_ok" = "1" ] || { echo "  ✗ kmod-amneziawg не встал"; exit 1; }

echo "→ Раскладываю движок"
vm_ssh "mkdir -p /usr/share/cheburnet /etc/cheburnet"
tar -C "$REPO_ROOT" --exclude='engine/*/tests' --exclude='engine/*/*/tests' --exclude='*README.md' \
    -cf - engine | vm_ssh "tar -C /usr/share/cheburnet -xf -"
ENGINE=/usr/share/cheburnet/engine
# rpcd-обработчик как в пакете: панельные методы гоняем через НАСТОЯЩИЙ rpcd/ubus, а не вызовом
# скрипта напрямую. ШРАМ: stdout шага попадал в JSON-ответ, прямой вызов этого не видел.
vm_ssh "mkdir -p /usr/libexec/rpcd /usr/share/rpcd/acl.d"
vm_scp "$REPO_ROOT/package/cheburnet/files/rpcd-cheburnet.sh" "/usr/libexec/rpcd/cheburnet"
vm_scp "$REPO_ROOT/engine/ubus/rpcd-acl.json" "/usr/share/rpcd/acl.d/cheburnet.json"
vm_ssh "chmod +x /usr/libexec/rpcd/cheburnet && /etc/init.d/rpcd reload && sleep 1 && ubus list cheburnet >/dev/null" \
    || { echo "  ✗ объект cheburnet не появился на шине ubus"; vm_ssh "logread | grep -i rpcd | tail -5"; exit 1; }
# rpc <метод> '<json>' — через ubus; ответ ubus печатает многострочно, поэтому сравниваем без пробелов.
rpc() { vm_ssh "ubus call cheburnet $1 '$2'"; }
flat() { tr -d '\n\t ' ; }

vm_start_firewall

WAN_DEV="$(vm_ssh "ip -4 route show default | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1")"
WAN_GW="$(vm_ssh "ip -4 route show default | sed -n 's/.*via \([0-9.]*\).*/\1/p' | head -1")"
echo "  WAN: dev=$WAN_DEV gw=${WAN_GW:-<нет>}"

# Ключи — base64 РОВНО 32 байт (иначе `awg setconf` не примет конфиг и интерфейс останется
# pending). Endpoint из RFC 5737: «сервер умер» — ровно то, что воспроизводим.
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

echo "→ Настраиваю роутер как после установки: туннель + dns + doh + firewall"
vm_ssh "printf '%s' '{\"protocol\":\"awg\",\"dns_provider\":\"adguard\",\"domains\":[\"example.com\"],\"routing_opts\":{\"mode\":\"home\",\"wan_if\":\"$WAN_DEV\",\"tunnel_if\":\"$TUN\",\"ipv6\":false}}' > /etc/cheburnet/install.json"
vm_ssh "cat /tmp/awg.conf | ucode -R $ENGINE/steps/vpn/apply.uc" || { echo "  ✗ шаг vpn упал"; exit 1; }
vm_ssh "echo '{\"domains\":[\"example.com\"],\"routing_opts\":{\"ipv6\":false}}' | ucode -R $ENGINE/steps/dns/apply.uc" >/dev/null
vm_ssh "echo '{\"provider\":\"adguard\"}' | ucode -R $ENGINE/steps/doh/apply.uc" >/dev/null
vm_ssh "echo '{\"domains\":[\"example.com\"],\"routing_opts\":{\"wan_if\":\"$WAN_DEV\",\"wan_gw\":\"$WAN_GW\",\"ipv6\":false},\"fw_opts\":{\"tunnel_if\":\"$TUN\"}}' | ucode -R $ENGINE/steps/firewall/apply.uc" >/dev/null
sleep 3

inv() { vm_ssh "ucode -R $ENGINE/invariants/gather.uc | ucode -R $ENGINE/invariants/check.uc" || true; }
# ЕДИНСТВЕННОЕ допустимое отклонение — dns_main: туннель здесь мёртв по сценарию, а на молчащих
# bootstrap-серверах основной экземпляр DoH уходит в crash-loop (баг апстрима, конфигурацией не
# лечится). Резервный при этом обязан быть жив — на нём и держится резолв.
inv_rc() {
    local failed; failed="$(vm_inv_failed "$ENGINE" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')"
    case "$failed" in
        ""|"dns_main") return 0 ;;
        *) echo "  отклонения: $failed"; return 1 ;;
    esac
}
# fetch_ok — ходит ли роутер наружу ВООБЩЕ (не DNS: резолв переживает смерть туннеля отдельно).
fetch_ok() { vm_ssh "uclient-fetch -q -T 8 -O /dev/null $PROBE_URL >/dev/null 2>&1"; }

# ─── 1. Исходное: защита включена, туннель мёртв, наружу не ходим ────────────
echo
echo "→ ПРОВЕРКА 1: защита включена — при мёртвом туннеле наружу не ходим (так и надо)"
vm_ssh "ip route show | grep -q '0.0.0.0/1 dev $TUN'" \
    || { echo "  ✗ half-routes туннеля не установлены — сцена не собрана"; vm_ssh "ip route show"; exit 1; }
if fetch_ok; then
    echo "  ✗ трафик уходит наружу при мёртвом туннеле — это утечка, а не рабочая защита"
    vm_ssh "ip route get 1.1.1.1"; exit 1
fi
# Ждём, а не гадаем: шаги только что применены, procd поднимает экземпляры DoH не мгновенно и
# может перезапустить упавший. Обещание — «через минуту после настройки всё на месте», а не
# «через три секунды».
settled=0
for _ in $(seq 1 20); do
    if inv_rc; then settled=1; break; fi
    sleep 3
done
[ "$settled" = "1" ] || {
    echo "  ✗ чек-лист инвариантов красный ещё до аварийного режима"; inv
    vm_ssh "ps w | grep '[h]ttps-dns-proxy' || true"
    vm_ssh "logread | grep -iE 'https-dns|dnsmasq' | tail -20" || true; exit 1; }
echo "  ✓ туннель вооружён, наружу не проходит, инварианты зелёные"

# ─── 2. Кнопка ───────────────────────────────────────────────────────────────
echo "→ ПРОВЕРКА 2: аварийная кнопка возвращает интернет"
vm_ssh "ucode -R $ENGINE/install/pause.uc" || { echo "  ✗ pause.uc упал"; exit 1; }
sleep 3
fetch_ok || { echo "  ✗ интернет НЕ заработал — кнопка бесполезна";
              vm_ssh "ip route show; ip rule show"; exit 1; }
echo "  ✓ интернет заработал"

echo "→ ПРОВЕРКА 3: защита снята ЦЕЛИКОМ, а настройки целы"
vm_ssh "! ip route show | grep -q '0.0.0.0/1 dev $TUN'" \
    || { echo "  ✗ маршрут туннеля остался — трафик так и уходит в мёртвый туннель"; exit 1; }
vm_ssh "! ip rule show | grep -qE 'fwmark|uidrange'" \
    || { echo "  ✗ правила направления остались"; vm_ssh "ip rule show"; exit 1; }
vm_ssh "! nft list chain inet fw4 cheburnet_ks >/dev/null 2>&1" \
    || { echo "  ✗ kill-switch остался — он и дропал бы весь трафик"; exit 1; }
vm_ssh "uci -q get network.${TUN}.private_key >/dev/null" \
    || { echo "  ✗ КОНФИГ ТУННЕЛЯ ПОТЕРЯН — вернуть защиту одной кнопкой уже нельзя"; exit 1; }
# ucode печатает JSON с пробелом после двоеточия («"paused": true») — ищем терпимо к формату.
vm_ssh "grep -qE '\"paused\":[[:space:]]*true' /etc/cheburnet/install.json" \
    || { echo "  ✗ флаг paused не записан — панель и сторож не узнают о решении человека";
         vm_ssh "cat /etc/cheburnet/install.json"; exit 1; }
echo "  ✓ правила сняты, ключи и endpoint на месте, флаг записан"

# ─── 4. Никто не возвращает защиту молча ─────────────────────────────────────
echo "→ ПРОВЕРКА 4: аварийный режим переживает сторожа и переприменение"
OUT="$(inv)"
printf '%s\n' "$OUT" | grep -q "АВАРИЙНЫЙ РЕЖИМ" \
    || { echo "  ✗ чек-лист молчит о снятой защите: $OUT"; exit 1; }
inv_rc || { echo "  ✗ чек-лист считает аварийный режим поломкой — сторож начнёт «чинить»"; exit 1; }
WD_BEFORE="$(vm_ssh "logread | grep -c 'cheburnet-watchdog' || true")"
vm_ssh "ucode -R $ENGINE/watchdog/tick.uc"
vm_ssh "ucode -R $ENGINE/install/reapply.uc"   # то же делает hotplug при подъёме WAN
sleep 2
vm_ssh "! ip rule show | grep -qE 'fwmark|uidrange'" \
    || { echo "  ✗ защиту вернули за спиной человека — он снова остался без интернета";
         vm_ssh "ip rule show; logread | grep watchdog | tail -5"; exit 1; }
[ "$(vm_ssh "logread | grep -c 'cheburnet-watchdog' || true")" = "$WD_BEFORE" ] \
    || { echo "  ✗ сторож шумит про осознанно снятую защиту"; vm_ssh "logread | grep watchdog | tail -5"; exit 1; }
fetch_ok || { echo "  ✗ интернет пропал после тика сторожа/переприменения"; exit 1; }
echo "  ✓ ни сторож, ни reapply защиту не вернули и не шумят"

# ─── 5. Возврат ──────────────────────────────────────────────────────────────
echo "→ ПРОВЕРКА 5: вторая кнопка возвращает защиту целиком"
vm_ssh "ucode -R $ENGINE/install/pause.uc --resume" || { echo "  ✗ resume упал"; exit 1; }
sleep 4
inv_rc || { echo "  ✗ после возврата чек-лист красный — защита вернулась не полностью"; inv; exit 1; }
vm_ssh "ip route show | grep -q '0.0.0.0/1 dev $TUN'" \
    || { echo "  ✗ маршрут туннеля не вернулся"; vm_ssh "ip route show"; exit 1; }
vm_ssh "nft list chain inet fw4 cheburnet_ks 2>/dev/null | grep -q drop" \
    || { echo "  ✗ kill-switch не вернулся — роутер остался бы без защиты при живом туннеле"; exit 1; }
vm_ssh "! grep -qE '\"paused\":[[:space:]]*true' /etc/cheburnet/install.json" \
    || { echo "  ✗ флаг paused остался — панель продолжит пугать снятой защитой"; exit 1; }
if fetch_ok; then
    echo "  ✗ трафик всё ещё уходит наружу — защита формально вернулась, но не работает"; exit 1
fi
echo "  ✓ маршрут, kill-switch и флаг вернулись; трафик снова заперт мёртвым туннелем"

# ─── 6. Смена режима из панели идёт через ту же реализацию переприменения ──────
# ШРАМ: у set_mode была своя копия «переприменить firewall» (без tunnel_if — на Full-тире она
# пересобирала NAT-зону под awg0), а hotplug-хук в travel гейтился по правилу fwmark, которого в
# travel нет по замыслу, — и переприменял firewall на каждый ifup. Здесь: set_mode через rpcd,
# как его зовёт панель, и оба артефакта после него.
echo "→ ПРОВЕРКА 6: set_mode через rpcd — travel и обратно, хук гейтится по режиму"
OUT="$(rpc set_mode '{"mode":"travel"}' | flat)"
printf '%s\n' "$OUT" | grep -q '"status":"ok"' \
    || { echo "  ✗ set_mode travel через ubus не ответил ok: $OUT"; vm_ssh "logread | tail -20"; exit 1; }
vm_ssh "! ip rule show | grep -qE 'fwmark|uidrange'" \
    || { echo "  ✗ в travel остались правила направления — «поездка» врёт"; vm_ssh "ip rule show"; exit 1; }
vm_ssh "nft list chain inet fw4 cheburnet_ks 2>/dev/null | grep -q 'ct state new drop'" \
    || { echo "  ✗ kill-switch travel (без mark) не на месте"; exit 1; }
vm_ssh "grep -q 'nft list chain inet fw4 cheburnet_ks' /etc/hotplug.d/iface/99-cheburnet && ! grep -q 'grep -q fwmark' /etc/hotplug.d/iface/99-cheburnet" \
    || { echo "  ✗ хук в travel гейтится по fwmark — переприменял бы firewall на каждый ifup"; vm_ssh "cat /etc/hotplug.d/iface/99-cheburnet"; exit 1; }
vm_ssh "grep -q '\"mode\":[[:space:]]*\"travel\"' /etc/cheburnet/install.json" \
    || { echo "  ✗ режим не сохранён в install.json"; exit 1; }
# Хук в travel при целом kill-switch обязан выйти сразу — reapply.uc не зовётся (иначе шторм на ifup).
vm_ssh "ACTION=ifup INTERFACE=lan sh /etc/hotplug.d/iface/99-cheburnet"
inv_rc || { echo "  ✗ чек-лист красный в travel после хука"; inv; exit 1; }
OUT="$(rpc set_mode '{"mode":"home"}' | flat)"
printf '%s\n' "$OUT" | grep -q '"status":"ok"' \
    || { echo "  ✗ set_mode home через ubus не ответил ok: $OUT"; exit 1; }
vm_ssh "ip rule show | grep -q 'fwmark 0x1 lookup 100'" \
    || { echo "  ✗ правило направления не вернулось после set_mode home"; vm_ssh "ip rule show"; exit 1; }
vm_ssh "ip route show table 100 | grep -q \"default.* dev $WAN_DEV\"" \
    || { echo "  ✗ таблица direct не ведёт в текущий WAN"; vm_ssh "ip route show table 100"; exit 1; }
vm_ssh "grep -q 'grep -q fwmark' /etc/hotplug.d/iface/99-cheburnet" \
    || { echo "  ✗ хук в home не гейтится по правилу направления"; exit 1; }
inv_rc || { echo "  ✗ чек-лист красный после возврата в home"; inv; exit 1; }
echo "  ✓ set_mode travel/home через rpcd: правила, kill-switch, хук и install.json сходятся"

# ─── 7. Свой список сайтов правится из панели без переустановки ──────────────
echo "→ ПРОВЕРКА 7: set_domains через rpcd — DNS-шаг переприменён, мусор назван, туннель не тронут"
OUT="$(rpc set_domains '{"domains":["example.org","bad..name","ru"]}' | flat)"
printf '%s\n' "$OUT" | grep -q '"status":"ok"' \
    || { echo "  ✗ set_domains через ubus не ответил ok: $OUT"; vm_ssh "logread | tail -20"; exit 1; }
printf '%s\n' "$OUT" | grep -q '"rejected":\["bad..name"\]' \
    || { echo "  ✗ мусорная запись не названа в rejected: $OUT"; exit 1; }
vm_ssh "uci -q get dhcp.cheburnet_dns4.domain | grep -qw example.org" \
    || { echo "  ✗ новый домен не доехал до dnsmasq: $(vm_ssh 'uci -q get dhcp.cheburnet_dns4.domain')"; exit 1; }
vm_ssh "uci -q get dhcp.cheburnet_dns4.domain | grep -qw example.com && exit 1; exit 0" \
    || { echo "  ✗ старый домен остался — список не заменён, а дописан"; exit 1; }
vm_ssh "grep -q 'example.org' /etc/cheburnet/install.json" \
    || { echo "  ✗ список не сохранён в install.json"; exit 1; }
vm_ssh "ip route show | grep -q '0.0.0.0/1 dev $TUN'" \
    || { echo "  ✗ смена списка тронула маршрут туннеля"; exit 1; }
OUT="$(rpc get_domains '{}' | flat)"
printf '%s\n' "$OUT" | grep -q 'example.org' \
    || { echo "  ✗ get_domains не вернул сохранённый список: $OUT"; exit 1; }
inv_rc || { echo "  ✗ чек-лист красный после смены списка"; inv; exit 1; }
echo "  ✓ список заменён на месте: dnsmasq, install.json и get_domains сходятся, мусор назван"

echo
printf '\033[32m✓ emergency: аварийный режим возвращает интернет, обратим и не отменяется за спиной человека\033[0m\n'
