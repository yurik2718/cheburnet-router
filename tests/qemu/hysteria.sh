#!/bin/bash
# tests/qemu/hysteria.sh — T3e: Hysteria2 (Full-тир) data-plane WIRING на живом OpenWrt.
#
# Зачем (чего НЕ покрывают юниты, reality и install):
#   • ЗАМЕР веса Full-тира на предпочтительной сборке sing-box-tiny и сверка с порогом preflight
#     в ОБЕ стороны (порог занижен = обещаем невозможное; завышен = отсекаем годное железо);
#   • проверка ключевого допущения ADR 0004: `sing-box-tiny` действительно ставит бинарь
#     `sing-box` (PROVIDES) и его сборка УМЕЕТ hysteria2 — то есть `sing-box check` принимает
#     наш конфиг с QUIC-outbound'ом. Это единственное место, где допущение проверяется фактом;
#   • реальный порядок предпочтения пакетов через боевой install-singbox.sh;
#   • singbox-шаг применяется на живом netifd/uci с hysteria2-ссылкой: config.json (+ port
#     hopping через server_ports), интерфейс network.singtun, half-routes, TUN singtun0;
#   • новый гейт: семантически битый конфиг ОТВЕРГАЕТСЯ до подмены живого (`sing-box check`
#     во временный файл) — раньше такой конфиг молча поднимал мёртвый демон;
#   • connectivity-probe на ЖИВОЙ системе корректно валит неработающий туннель (fail-safe);
#   • tunnel_health для protocol=hysteria2 честен в обе стороны (up при живом TUN, down после
#     teardown) — тот же регресс панели, что чинили для Reality;
#   • teardown снимает интерфейс+маршрут+сервис начисто (LAN не остаётся без интернета).
#
# ГЕРМЕТИЧНО: рабочий Hysteria2-СЕРВЕР НЕ нужен. Проверяется ВСЯ наша обвязка; сам QUIC-handshake
# до сервера-заглушки заведомо не проходит, и это ОЖИДАЕМО — проба обязана его отвергнуть.
# Замер пропускной способности под потерями — отдельный стенд (make qemu-netem).
#
# Запуск: make qemu-hysteria (нужен интернет для apk). ~4-6 мин с KVM.

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

# Порог флеша Full-тира — из блока FULL_REQUIREMENTS (единственный источник правды).
FULL_MIN_FLASH="$(awk '
    /^const FULL_REQUIREMENTS/ { inblock = 1 }
    inblock && /min_flash_mb:/ && match($0, /[0-9]+/) { print substr($0, RSTART, RLENGTH); exit }
' "$REPO_ROOT/engine/preflight/preflight.uc")"
case "$FULL_MIN_FLASH" in
    ''|*[!0-9]*) echo "✗ не удалось прочитать FULL_REQUIREMENTS.min_flash_mb (получено '$FULL_MIN_FLASH')"; exit 1 ;;
esac

# Свободное место на writable-ФС — третье ЦЕЛОЕ поле строки данных df (как parse_df движка).
free_kb() {
    vm_ssh "df -k /overlay 2>/dev/null || df -k /" \
        | awk 'NR>1 { n=0; for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+$/) { n++; if (n==3) { print $i; exit } } }'
}

echo "→ Ставлю зависимости движка (без sing-box — его вес мерим отдельно)"
for pkg in kmod-tun ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus ip-full; do
    if apk_try "apk add $pkg"; then echo "  ✓ $pkg"; else echo "  ✗ $pkg не ставится из feed"; exit 1; fi
done

echo "→ Раскладываю движок (как пакет)"
vm_ssh "mkdir -p /usr/share/cheburnet /etc/cheburnet /tmp/cheburnet"
tar -C "$REPO_ROOT" --exclude='engine/*/tests' --exclude='engine/*/*/tests' \
    --exclude='*README.md' -cf - engine \
    | vm_ssh "tar -C /usr/share/cheburnet -xf -"
ENG=/usr/share/cheburnet/engine

# ─── 1. догрузка бинаря БОЕВЫМ путём + замер веса ─────────────────────────────
# Гоняем именно install-singbox.sh, а не голый `apk add`: так проверяется порядок предпочтения
# (tiny → полная) и критерий успеха «появился бинарь», то есть реальный путь пользователя.
FREE_BEFORE_SB="$(free_kb)"
echo "→ Догружаю бинарь Full-тира боевым install-singbox.sh (замер веса)"
vm_ssh "sh $ENG/install/install-singbox.sh" 2>&1 | sed 's/^/    /' \
    || { echo "  ✗ install-singbox.sh отказал"; exit 1; }
FREE_AFTER_SB="$(free_kb)"
SB_KB=$(( FREE_BEFORE_SB - FREE_AFTER_SB ))
SB_MB=$(( SB_KB / 1024 ))
echo "  ✓ бинарь занял $SB_KB КБ (≈ $SB_MB МБ) на флеше"

# Ключевое допущение ADR 0004: sing-box-tiny объявляет PROVIDES:=sing-box и ставит ТОТ ЖЕ бинарь.
# Если бы это было не так, весь детект Full-тира (`command -v sing-box`) молча сломался бы.
vm_ssh "command -v sing-box >/dev/null" \
    || { echo "  ✗ бинарь sing-box не появился в PATH — детект Full-тира сломан"; exit 1; }
INSTALLED_PKG="$(vm_ssh "apk list --installed 2>/dev/null | grep -oE 'sing-box(-tiny)?-[0-9][^ ]*' | head -1")"
echo "  ✓ бинарь /usr/bin/sing-box на месте, установленный пакет: ${INSTALLED_PKG:-?}"
case "$INSTALLED_PKG" in
    sing-box-tiny-*) echo "  ✓ поехала предпочтительная (лёгкая) сборка" ;;
    sing-box-*)      echo "  ⚠ поехала ПОЛНАЯ сборка — tiny недоступна в этом фиде (фолбэк сработал)" ;;
    *)              echo "  ⚠ не удалось определить пакет (детект по бинарю всё равно прошёл)" ;;
esac
vm_ssh "/etc/init.d/sing-box enabled >/dev/null 2>&1 || true"
vm_ssh "sing-box version" 2>/dev/null | sed 's/^/    /' || true

# ─── 2. singbox-шаг с hysteria2-ссылкой ───────────────────────────────────────
# Сервер-заглушка 10.0.2.99 заведомо недостижим (герметично). Ссылка нарочно «богатая»: порт
# hopping (диапазон), salamander-обфускация, insecure — чтобы проверить сборку конфига целиком.
echo "→ Применяю singbox-шаг с hysteria2-ссылкой (dummy-сервер: проверяем обвязку, не туннель)"
LINK="hysteria2://labpassword@10.0.2.99:8443,9000-9100?sni=www.example.com&obfs=salamander&obfs-password=labobfs&insecure=1#lab"
vm_ssh "printf '%s' '$LINK' | ucode -R $ENG/steps/singbox/apply.uc" \
    || { echo "  ✗ singbox/apply.uc exit != 0"; vm_ssh 'cat /etc/sing-box/config.json 2>/dev/null'; exit 1; }
sleep 3

echo "  • config.json валиден для ЭТОЙ сборки sing-box (значит hysteria2 в ней есть)"
vm_ssh "sing-box check -c /etc/sing-box/config.json" \
    || { echo "  ✗ сборка sing-box не приняла hysteria2-конфиг — допущение про with_quic неверно";
         vm_ssh 'cat /etc/sing-box/config.json'; exit 1; }

echo "  • outbound именно hysteria2, port hopping через server_ports, без server_port"
vm_ssh "grep -q '\"type\": \"hysteria2\"' /etc/sing-box/config.json" \
    || { echo "  ✗ в конфиге нет hysteria2-outbound"; exit 1; }
vm_ssh "grep -q '\"server_ports\"' /etc/sing-box/config.json" \
    || { echo "  ✗ диапазон портов не доехал до server_ports"; vm_ssh 'cat /etc/sing-box/config.json'; exit 1; }
vm_ssh "! grep -q '\"server_port\"' /etc/sing-box/config.json" \
    || { echo "  ✗ server_port написан вместе с server_ports — схема объявляет их конфликтующими"; exit 1; }
vm_ssh "grep -q '\"auto_route\": false' /etc/sing-box/config.json" \
    || { echo "  ✗ инвариант auto_route=false потерян"; exit 1; }
vm_ssh "grep -q 'salamander' /etc/sing-box/config.json" \
    || { echo "  ✗ обфускация из ссылки не доехала до конфига"; exit 1; }

echo "  • netifd: секции network.singtun + route в uci (те же, что у Reality)"
vm_ssh "uci -q get network.singtun >/dev/null && uci -q get network.cheburnet_str0 >/dev/null && uci -q get network.cheburnet_str1 >/dev/null" \
    || { echo "  ✗ uci-секции singtun/routes не созданы"; vm_ssh 'uci -q show network | grep -E "singtun|cheburnet_str" || true'; exit 1; }

echo "  • sing-box поднял TUN-устройство singtun0"
vm_ssh "ip link show singtun0 >/dev/null 2>&1" \
    || { echo "  ✗ устройство singtun0 не появилось"; vm_ssh 'logread | grep -i sing-box | tail -8'; exit 1; }

echo "  • netifd поставил half-routes 0.0.0.0/1 + 128.0.0.0/1 dev singtun0"
vm_ssh "ip route show | grep -q '0.0.0.0/1 dev singtun0' && ip route show | grep -q '128.0.0.0/1 dev singtun0'" \
    || { echo "  ✗ half-routes в туннель не установлены"; vm_ssh 'ip route show | grep -E "singtun|0.0.0.0/1" || true'; exit 1; }
echo "  ✓ обвязка Hysteria2 применена на живом netifd/uci (конфиг + маршрут + TUN)"

# ─── 2b. гейт «sing-box check ДО подмены живого конфига» ───────────────────────
# Раньше семантически битый конфиг молча поднимал МЁРТВЫЙ демон, и человек узнавал об этом из
# 30-секундной пробы и отката без причины. Теперь шаг обязан упасть сразу И не тронуть рабочий
# конфиг: проверка идёт во временном файле.
echo "→ Битый конфиг обязан быть отвергнут ДО подмены рабочего"
BAD='{"outbounds":[{"type":"hysteria2","tag":"broken-out"}]}'   # нет обязательного server
if vm_ssh "printf '%s' '$BAD' | ucode -R $ENG/steps/singbox/apply.uc" >/dev/null 2>&1; then
    echo "  ✗ шаг принял конфиг без обязательных полей (sing-box его отвергает)"; exit 1
fi
vm_ssh "grep -q 'labpassword' /etc/sing-box/config.json" \
    || { echo "  ✗ РАБОЧИЙ config.json пострадал от отвергнутой попытки"; exit 1; }
vm_ssh "! ls /etc/sing-box/config.json.check >/dev/null 2>&1" \
    || { echo "  ✗ временный файл проверки остался на диске"; exit 1; }
echo "  ✓ отказ быстрый и чистый: рабочий конфиг не тронут, мусора не осталось"

# ─── 3. status: панель видит поднятый Hysteria2-туннель ───────────────────────
# tunnel_health ветвится по ШАГУ протокола, а не по имени, поэтому Hysteria2 обязан получить
# правильную семантику без правок движка. Проверяем это на ЖИВОЙ системе (юниты видят только
# чистую функцию): pgrep sing-box + флаг UP в выводе `ip link` (у TUN state=UNKNOWN).
echo "→ status на живой системе: поднятый Hysteria2 = tunnel_health up"
vm_ssh "mkdir -p /tmp/cheburnet-st && printf '%s' '{\"protocol\":\"hysteria2\",\"routing_opts\":{}}' > /tmp/cheburnet-st/install.json"
st_json() {
    vm_ssh "printf '{}' | ETC_CHEBURNET=/tmp/cheburnet-st STATE_DIR=/tmp/cheburnet-st \
        ucode -R $ENG/ubus/rpcd-cheburnet call status 2>/dev/null"
}
st_health() {
    st_json | sed -n 's/.*"tunnel_health":[ ]*"\([a-z]*\)".*/\1/p'
}
h="$(st_health)"
[ "$h" = "up" ] || {
    echo "  ✗ tunnel_health='$h', ожидался up (панель показала бы «туннель не работает» на рабочем Hysteria2)"
    echo "    pgrep sing-box:   $(vm_ssh 'pgrep sing-box || echo НЕТ')"
    echo "    ip link singtun0: $(vm_ssh 'ip link show dev singtun0 2>&1 | head -1 || true')"
    vm_ssh 'logread | grep -i sing-box | tail -10' || true
    exit 1
}
echo "  ✓ tunnel_health=up (панель покажет «Hysteria2 активен»)"

# Гейт кнопки Full-тира читает свободный флеш из БАТЧА m_status (df|awk на busybox).
echo "→ status: свободный флеш разобран на busybox и согласован с гейтом"
mfree="$(vm_ssh "(df -k /overlay 2>/dev/null || df -k /) | awk 'NR>1{for(i=1;i<=NF;i++) if (\$i ~ /^[0-9]+\$/) {n++; if (n==3) {print int(\$i/1024); exit}}}'")"
case "$mfree" in
    ''|*[!0-9]*) echo "  ✗ разбор df на busybox дал '$mfree' вместо числа МБ"; exit 1 ;;
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

# ─── 4. connectivity-probe отвергает неработающий туннель (fail-safe) ─────────
# Сервер недостижим → байты через туннель не идут → tunnel_connectivity ОБЯЗАН вернуть false.
# Суть надёжности: «процесс жив» тут true (pgrep sing-box), но проба смотрит на ТРАФИК.
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

# ─── 5. teardown снимает всё начисто (LAN не остаётся без интернета) ──────────
echo "→ Teardown singbox-шага"
vm_ssh "ucode -R $ENG/steps/singbox/apply.uc --teardown" \
    || { echo "  ✗ teardown exit != 0"; exit 1; }
sleep 2
vm_ssh "! uci -q get network.singtun >/dev/null && ! uci -q get network.cheburnet_str0 >/dev/null" \
    || { echo "  ✗ uci-секции singtun не удалены teardown'ом"; exit 1; }
vm_ssh "! ip route show | grep -q '0.0.0.0/1 dev singtun0'" \
    || { echo "  ✗ half-route в туннель остался после teardown (LAN был бы без интернета!)"; exit 1; }
vm_ssh "! pgrep sing-box >/dev/null" \
    || { echo "  ✗ sing-box не остановлен teardown'ом"; exit 1; }
echo "  ✓ teardown снял интерфейс, маршрут и сервис начисто"

echo "→ status после teardown: tunnel_health down (зелёного на мёртвом туннеле быть не должно)"
h="$(st_health)"
[ "$h" = "down" ] \
    || { echo "  ✗ tunnel_health='$h', ожидался down"; exit 1; }
echo "  ✓ tunnel_health=down"

# ─── ЗАМЕР: сколько флеша стоит Full-тир и адекватен ли порог ──────────────────
echo ""
echo "→ ЗАМЕР Full-тира: бинарь = $SB_KB КБ (≈ $SB_MB МБ), порог min_flash_mb = $FULL_MIN_FLASH МБ"
if [ "$SB_MB" -ge "$FULL_MIN_FLASH" ]; then
    echo "  ✗ ПОРОГ ЗАНИЖЕН: бинарь не влезает в заявленный минимум Full-тира"
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
echo "✓ T3e HYSTERIA2 WIRING ЗЕЛЁНЫЙ: сборка умеет hysteria2, конфиг+port hopping+маршрут+TUN"
echo "  применяются, битый конфиг отвергается до подмены рабочего, проба отвергает мёртвый туннель,"
echo "  teardown чистит. Пропускная способность под потерями — make qemu-netem."
