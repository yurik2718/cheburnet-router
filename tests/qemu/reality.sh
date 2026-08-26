#!/bin/bash
# tests/qemu/reality.sh — T3d: Full-тир (VLESS+Reality) data-plane WIRING на живом OpenWrt.
#
# Зачем (чего НЕ покрывают юниты и install):
#   • singbox-шаг РЕАЛЬНО применяется на живом netifd/uci: config.json пишется, создаётся
#     интерфейс network.singtun (proto none) + half-routes, sing-box поднимает TUN singtun0,
#     netifd ставит 0.0.0.0/1 + 128.0.0.0/1 dev singtun0 в main-таблицу.
#   • connectivity-probe (tunnel_connectivity) на ЖИВОЙ системе КОРРЕКТНО валит неработающий
#     туннель (сервер-заглушка недостижим) — подтверждение fail-safe: процесс жив ≠ туннель везёт.
#   • teardown снимает интерфейс+маршрут+сервис начисто (LAN не остаётся без интернета).
#
# ГЕРМЕТИЧНО и БЕЗОПАСНО: рабочий Reality-СЕРВЕР НЕ нужен (и в песочнице недостижим). Тест
# проверяет ВСЮ нашу обвязку (генерация конфига, netifd-маршрут, проба, откат) — то, что мы
# пишем; сам Reality-handshake sing-box (не наш код) тут заведомо не проходит, и это ОЖИДАЕМО:
# проба обязана его отвергнуть. Полный трафик через живой Reality-сервер — только на железе с
# внешним VPS (см. ADR 0004, раздел «что НЕ подтверждено живьём»).
#
# Замер потерь/goodput — отдельный стенд (make qemu-netem); Hysteria2-обвязка — qemu-hysteria.
#
# Запуск: make qemu-reality (нужен интернет для apk). ~4-6 мин с KVM.

set -e -u -o pipefail

. "$(dirname "$0")/lib.sh"

vm_lib_init
vm_prepare_image
vm_start
vm_boot_and_setup
# fw4 ОБЯЗАТЕЛЬНО запущен: на роутере он работает всегда, а с остановленным (как оставляет
# vm_boot_and_setup) этот тест показывал «зелено» при неработающем TCP через туннель —
# см. WHY у vm_start_firewall.
vm_start_firewall

vm_check_dns

echo "→ apk update"
apk_try "apk update" || { echo "✗ apk update упал"; exit 1; }

# Порог флеша Full-тира — из блока FULL_REQUIREMENTS (единственный источник правды). Нужен и
# ассертам статуса ниже, и итоговому замеру, поэтому читаем один раз здесь.
FULL_MIN_FLASH="$(awk '
    /^const FULL_REQUIREMENTS/ { inblock = 1 }
    inblock && /min_flash_mb:/ && match($0, /[0-9]+/) { print substr($0, RSTART, RLENGTH); exit }
' "$REPO_ROOT/engine/preflight/preflight.uc")"
case "$FULL_MIN_FLASH" in
    ''|*[!0-9]*) echo "✗ не удалось прочитать FULL_REQUIREMENTS.min_flash_mb (получено '$FULL_MIN_FLASH')"; exit 1 ;;
esac

# Свободное место на writable-ФС — третье ЦЕЛОЕ поле строки данных df (как parse_df движка).
# Нужен ЗАМЕР: порог Full-тира (min_flash_mb) должен опираться на реальный вес sing-box, а не
# на прикидку — иначе отсекаем железо, которое Full утянуло бы (урок калибровки Light-тира).
free_kb() {
    vm_ssh "df -k /overlay 2>/dev/null || df -k /" \
        | awk 'NR>1 { n=0; for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+$/) { n++; if (n==3) { print $i; exit } } }'
}

# sing-box + TUN-модуль — минимум для Full-тира. ip-full/ucode — движок и маршруты.
echo "→ Ставлю зависимости движка (без sing-box — его вес мерим отдельно)"
for pkg in kmod-tun ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus ip-full; do
    if apk_try "apk add $pkg"; then echo "  ✓ $pkg"; else echo "  ✗ $pkg не ставится из feed"; exit 1; fi
done

FREE_BEFORE_SB="$(free_kb)"
# sing-box-tiny — предпочтительная сборка Full-тира (ADR 0004): те же нужные теги (with_utls для
# Reality, with_quic для Hysteria2), но легче. Она объявляет PROVIDES:=sing-box и ставит ТОТ ЖЕ
# /usr/bin/sing-box — на это допущение опирается весь детект Full-тира, поэтому проверяем фактом.
echo "→ Ставлю sing-box-tiny (замер веса Full-тира)"
apk_try "apk add sing-box-tiny" || { echo "  ✗ sing-box-tiny не ставится из feed"; exit 1; }
vm_ssh "command -v sing-box >/dev/null" \
    || { echo "  ✗ бинарь sing-box не появился — PROVIDES сломан, детект Full-тира не работает"; exit 1; }
FREE_AFTER_SB="$(free_kb)"
SB_KB=$(( FREE_BEFORE_SB - FREE_AFTER_SB ))
echo "  ✓ sing-box-tiny занял $SB_KB КБ (≈ $(( SB_KB / 1024 )) МБ) на флеше, бинарь sing-box на месте"
vm_ssh "sing-box version" 2>/dev/null | sed 's/^/    /' || true

echo "→ Раскладываю движок (как пакет)"
vm_ssh "mkdir -p /usr/share/cheburnet /etc/cheburnet /tmp/cheburnet"
tar -C "$REPO_ROOT" --exclude='engine/*/tests' --exclude='engine/*/*/tests' \
    --exclude='*README.md' -cf - engine \
    | vm_ssh "tar -C /usr/share/cheburnet -xf -"
ENG=/usr/share/cheburnet/engine

# ─── 1. applying singbox шаг: конфиг + netifd-маршрут + TUN ───────────────────
# Сервер-заглушка 10.0.2.99:8443 заведомо недостижим (герметично). Нам важна ОБВЯЗКА,
# не рукопожатие: config.json, uci network.singtun, half-routes, устройство singtun0.
echo "→ Применяю singbox-шаг (dummy-сервер: проверяем обвязку, не туннель)"
LINK="vless://11111111-1111-1111-1111-111111111111@10.0.2.99:8443?security=reality&pbk=lMnOLPmu5a9v-taChNAwhvtZ_uj0QfEuBGtOf1k_phM&sni=www.cloudflare.com&sid=a8128a2d384507a3&flow=xtls-rprx-vision&type=tcp#lab"
vm_ssh "printf '%s' '$LINK' | ucode -R $ENG/steps/singbox/apply.uc" \
    || { echo "  ✗ singbox/apply.uc exit != 0"; exit 1; }
sleep 3

echo "  • config.json написан и валиден для sing-box"
vm_ssh "sing-box check -c /etc/sing-box/config.json" \
    || { echo "  ✗ сгенерированный config.json не проходит sing-box check"; vm_ssh 'cat /etc/sing-box/config.json'; exit 1; }
vm_ssh "grep -q '\"auto_route\": false' /etc/sing-box/config.json" \
    || { echo "  ✗ инвариант auto_route=false потерян"; exit 1; }

echo "  • netifd: секции network.singtun + route в uci"
vm_ssh "uci -q get network.singtun >/dev/null && uci -q get network.cheburnet_str0 >/dev/null && uci -q get network.cheburnet_str1 >/dev/null" \
    || { echo "  ✗ uci-секции singtun/routes не созданы"; vm_ssh 'uci -q show network | grep -E "singtun|cheburnet_str" || true'; exit 1; }

echo "  • sing-box поднял TUN-устройство singtun0"
vm_ssh "ip link show singtun0 >/dev/null 2>&1" \
    || { echo "  ✗ устройство singtun0 не появилось"; vm_ssh 'logread | grep -i sing-box | tail -8'; exit 1; }

echo "  • netifd поставил half-routes 0.0.0.0/1 + 128.0.0.0/1 dev singtun0"
vm_ssh "ip route show | grep -q '0.0.0.0/1 dev singtun0' && ip route show | grep -q '128.0.0.0/1 dev singtun0'" \
    || { echo "  ✗ half-routes в туннель не установлены"; vm_ssh 'ip route show | grep -E "singtun|0.0.0.0/1" || true'; exit 1; }
echo "  ✓ обвязка Full-тира применена на живом netifd/uci (конфиг + маршрут + TUN)"

# ─── 1b. status видит поднятый Reality-туннель (регресс панели) ────────────────
# Панель судила о туннеле ТОЛЬКО по AWG-рукопожатию, поэтому на рабочем Reality показывала
# «VPN не работает» и вела заменять AWG-конфиг. Теперь движок отдаёт tunnel_health для активного
# протокола. Здесь это проверяется на ЖИВОЙ системе: pgrep sing-box + флаг UP в выводе `ip link`
# (у TUN state=UNKNOWN, поэтому смотрим именно флаг) — юниты видят только чистую функцию.
echo "→ status на живой системе: поднятый Reality-туннель = tunnel_health up"
vm_ssh "mkdir -p /tmp/cheburnet-st && printf '%s' '{\"protocol\":\"reality\",\"routing_opts\":{}}' > /tmp/cheburnet-st/install.json"
st_json() {
    vm_ssh "printf '{}' | ETC_CHEBURNET=/tmp/cheburnet-st STATE_DIR=/tmp/cheburnet-st \
        ucode -R $ENG/ubus/rpcd-cheburnet call status 2>/dev/null"
}
st_health() {
    st_json | sed -n 's/.*"tunnel_health":[ ]*"\([a-z]*\)".*/\1/p'
}
h="$(st_health)"
[ "$h" = "up" ] || {
    echo "  ✗ tunnel_health='$h', ожидался up (панель показала бы «VPN не работает» на рабочем Reality)"
    # tunnel_health для reality = sb_running И tun_up. Без разбивки по фактам провал не отличить
    # от «упало что угодно» — печатаем ровно то, что читает status-батч.
    echo "    pgrep -x sing-box: $(vm_ssh 'pgrep -x sing-box || echo НЕТ')"
    echo "    ip link singtun0:  $(vm_ssh 'ip link show dev singtun0 2>&1 | head -1 || true')"
    vm_ssh 'logread | grep -i sing-box | tail -10' || true
    exit 1
}
echo "  ✓ tunnel_health=up (панель покажет «VLESS+Reality активен»)"

# Гейт кнопки Full-тира читает свободный флеш из БАТЧА m_status (df|awk на busybox). Юниты видят
# только чистую функцию — здесь проверяем РАЗБОР на живом busybox и то, что вердикт гейта совпадает
# с реально измеренным местом (в обе стороны). Абсолютную величину НЕ предполагаем: на 512-МБ
# образе после установки 42-МБ sing-box свободного места закономерно мало.
echo "→ status: свободный флеш разобран на busybox и согласован с гейтом"
mfree="$(vm_ssh "(df -k /overlay 2>/dev/null || df -k /) | awk 'NR>1{for(i=1;i<=NF;i++) if (\$i ~ /^[0-9]+\$/) {n++; if (n==3) {print int(\$i/1024); exit}}}'")"
case "$mfree" in
    ''|*[!0-9]*) echo "  ✗ разбор df на busybox дал '$mfree' вместо числа МБ"; vm_ssh "df -k /overlay 2>/dev/null || df -k /"; exit 1 ;;
esac
echo "    свободно на writable-ФС: $mfree МБ (порог Full-тира: $FULL_MIN_FLASH МБ)"
miss="$(st_json | sed -n 's/.*"full_missing":[ ]*\[\([^]]*\)\].*/\1/p')"
if [ "$mfree" -lt "$FULL_MIN_FLASH" ]; then
    echo "$miss" | grep -q '"flash"' \
        || { echo "  ✗ места меньше порога, а гейт флеш не назвал (кнопка обещала бы невозможное): [$miss]"; exit 1; }
    echo "  ✓ места меньше порога → гейт честно называет причину «flash»"
else
    echo "$miss" | grep -q '"flash"' \
        && { echo "  ✗ места хватает, а гейт винит флеш (кнопка спрятана по ложной причине): [$miss]"; exit 1; }
    echo "  ✓ места хватает → флеш причиной не назван"
fi

# ─── 1c. set_mode из панели на Full-тире НЕ пересобирает NAT-зону под awg0 ──────
# ШРАМ (аудит 2026-08-26): у set_mode была своя копия переприменения firewall без tunnel_if, и
# dry-run показывал `add_list firewall.cheburnet_vpn.network='awg0'` при активном singtun0 —
# LAN→singtun0 выпадал из зоны. Теперь set_mode идёт через install/reapply.uc; проверяем фактом.
echo "→ set_mode через rpcd на Full-тире: NAT-зона остаётся на singtun0"
WAN_DEV="$(vm_ssh "ip -4 route show default | grep -v ' dev singtun0' | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1")"
WAN_GW="$(vm_ssh "ip -4 route show default | grep -v ' dev singtun0' | sed -n 's/.*via \([0-9.]*\).*/\1/p' | head -1")"
vm_ssh "mkdir -p /tmp/cheburnet /etc/cheburnet && printf '%s' '{\"protocol\":\"reality\",\"domains\":[\"example.com\"],\"routing_opts\":{\"mode\":\"home\",\"wan_if\":\"$WAN_DEV\",\"tunnel_if\":\"singtun0\",\"ipv6\":false}}' > /etc/cheburnet/install.json"
vm_ssh "echo '{\"domains\":[\"example.com\"],\"routing_opts\":{\"wan_if\":\"$WAN_DEV\",\"wan_gw\":\"$WAN_GW\",\"ipv6\":false},\"fw_opts\":{\"tunnel_if\":\"singtun0\"}}' | ucode -R $ENG/steps/firewall/apply.uc" >/dev/null \
    || { echo "  ✗ firewall-шаг не применился"; exit 1; }
for mode in travel home; do
    OUT="$(vm_ssh "printf '%s' '{\"mode\":\"$mode\"}' | ucode -R $ENG/ubus/rpcd-cheburnet call set_mode")"
    printf '%s\n' "$OUT" | grep -q '"status":[ ]*"ok"' \
        || { echo "  ✗ set_mode $mode не ответил ok: $OUT"; vm_ssh "logread | tail -20"; exit 1; }
    vm_ssh "uci -q get firewall.cheburnet_vpn.network | grep -qw singtun0" \
        || { echo "  ✗ после set_mode $mode NAT-зона смотрит не на singtun0: $(vm_ssh 'uci -q get firewall.cheburnet_vpn.network')"; exit 1; }
    # В home хук сверяет WAN мимо ИМЕННО нашего туннеля; в travel интерфейс ему не нужен —
    # гейт по kill-switch в ядре (см. render_hotplug).
    if [ "$mode" = home ]; then
        vm_ssh "grep -q \"grep -v ' dev singtun0'\" /etc/hotplug.d/iface/99-cheburnet" \
            || { echo "  ✗ hotplug-хук в home собран не под singtun0"; vm_ssh "cat /etc/hotplug.d/iface/99-cheburnet"; exit 1; }
    else
        vm_ssh "grep -q 'nft list chain inet fw4 cheburnet_ks' /etc/hotplug.d/iface/99-cheburnet" \
            || { echo "  ✗ hotplug-хук в travel не гейтится по kill-switch"; exit 1; }
        vm_ssh "! ip rule show | grep -qE 'fwmark|uidrange'" \
            || { echo "  ✗ в travel остались правила направления home"; vm_ssh "ip rule show"; exit 1; }
    fi
done
vm_ssh "ip rule show | grep -q 'fwmark 0x1 lookup 100'" \
    || { echo "  ✗ правило направления не вернулось в home"; vm_ssh "ip rule show"; exit 1; }
echo "  ✓ set_mode travel/home: зона vpn и хук остались на singtun0, правила home на месте"
# Возвращаем VM как было: firewall-шаг снят, dnsmasq без noresolv (DNS-шаг set_mode его ставил).
vm_ssh "echo '{\"domains\":[],\"routing_opts\":{\"wan_if\":\"$WAN_DEV\"}}' | ucode -R $ENG/steps/firewall/apply.uc --teardown" >/dev/null
vm_ssh "uci -q delete dhcp.@dnsmasq[0].noresolv; uci -q delete dhcp.cheburnet_dns4; uci -q delete dhcp.cheburnet_dns6; uci commit dhcp; /etc/init.d/dnsmasq reload >/dev/null 2>&1; rm -f /etc/cheburnet/install.json"

# ─── 2. connectivity-probe отвергает неработающий туннель (fail-safe) ─────────
# Сервер недостижим → байты через туннель не идут → tunnel_connectivity ОБЯЗАН вернуть ok=false.
# ШРАМ: проба возвращает { ok, reason } (с 2026-08-19), а тест сравнивал сам объект — он всегда
# истинен, и «мёртвый туннель принят за рабочий» проходил бы молча. Смотрим ровно на .ok.
# Это суть надёжности: «процесс жив» тут true (pgrep sing-box), но проба смотрит на ТРАФИК.
echo "→ connectivity-probe на живой системе — должен ОТВЕРГНУТЬ мёртвый туннель"
cat > "$WORK/probe-check.uc" <<'UC'
import { tunnel_connectivity } from "/usr/share/cheburnet/engine/install/probe.uc";
printf("%s\n", tunnel_connectivity("singtun0").ok ? "UP" : "DOWN");
UC
vm_scp "$WORK/probe-check.uc" "/tmp/probe-check.uc"
probe="$(vm_ssh 'ucode -R /tmp/probe-check.uc 2>/dev/null')"
[ "$probe" = "DOWN" ] \
    || { echo "  ✗ проба вернула '$probe' — ожидался DOWN (мёртвый туннель принят за рабочий!)"; exit 1; }
echo "  ✓ проба корректно отвергла неработающий туннель (fail-safe: трафик ≠ pgrep)"

# ─── 3. teardown снимает всё начисто (LAN не остаётся без интернета) ──────────
echo "→ Teardown singbox-шага"
vm_ssh "ucode -R $ENG/steps/singbox/apply.uc --teardown" \
    || { echo "  ✗ teardown exit != 0"; exit 1; }
sleep 2
vm_ssh "! uci -q get network.singtun >/dev/null && ! uci -q get network.cheburnet_str0 >/dev/null" \
    || { echo "  ✗ uci-секции singtun не удалены teardown'ом"; exit 1; }
vm_ssh "! ip route show | grep -q '0.0.0.0/1 dev singtun0'" \
    || { echo "  ✗ half-route в туннель остался после teardown (LAN был бы без интернета!)"; exit 1; }
vm_ssh "! pgrep -x sing-box >/dev/null" \
    || { echo "  ✗ sing-box не остановлен teardown'ом"; exit 1; }
echo "  ✓ teardown снял интерфейс, маршрут и сервис начисто"

# Зеркальный ассерт к 1b: после teardown статус ОБЯЗАН честно сказать «не поднят» — иначе панель
# показывала бы зелёное на мёртвом туннеле (обратная сторона того же бага).
echo "→ status после teardown: tunnel_health down (зелёного на мёртвом туннеле быть не должно)"
h="$(st_health)"
[ "$h" = "down" ] \
    || { echo "  ✗ tunnel_health='$h', ожидался down"; exit 1; }
echo "  ✓ tunnel_health=down"

# ─── ЗАМЕР: сколько флеша стоит Full-тир и адекватен ли порог ──────────────────
# Порог прочитан заранее (FULL_MIN_FLASH) — из блока FULL_REQUIREMENTS preflight.uc.
SB_MB=$(( SB_KB / 1024 ))
echo ""
echo "→ ЗАМЕР Full-тира: sing-box-tiny = $SB_KB КБ (≈ $SB_MB МБ), порог min_flash_mb = $FULL_MIN_FLASH МБ"
if [ "$SB_MB" -ge "$FULL_MIN_FLASH" ]; then
    echo "  ✗ ПОРОГ ЗАНИЖЕН: sing-box не влезает в заявленный минимум Full-тира"
    exit 1
fi
# Порог должен быть выше веса (место под конфиги/логи/обновление), но не в разы — иначе отсекаем
# железо, которое Full утянуло бы. Ориентир «с запасом, но осмысленно» — до ~3× веса.
if [ "$FULL_MIN_FLASH" -gt $(( SB_MB * 3 )) ]; then
    echo "  ⚠ порог выглядит завышенным: втрое+ больше реального веса — рассмотреть снижение"
    echo "    (тот же класс ошибки, что чинили в Light-тире: паспортные цифры вместо замера)"
else
    echo "  ✓ порог соразмерен весу (запас есть, лишнего железа не отсекаем)"
fi

echo ""
echo "✓ T3d REALITY WIRING ЗЕЛЁНЫЙ: конфиг+netifd-маршрут+TUN применяются, проба отвергает"
echo "  мёртвый туннель (fail-safe), teardown чистит. Полный трафик — на железе с внешним VPS."
