#!/bin/bash
# tests/qemu/rollback.sh — T3g: ПОЛНАЯ установка через ubus на живом OpenWrt и ОТКАТ.
#
# Зачем (чего не покрывал ни один тест до него):
#   • До этого теста успешная последовательность оркестратора (preflight → снимок UCI → шаги →
#     health-check → commit/rollback) на живой системе НЕ запускалась НИ РАЗУ: все обращения к
#     `install` в QEMU были путями ОТКАЗА (неверный токен, короткий пароль), а счастливый путь и
#     откат существовали только в хостовых тестах с подделками. То есть главное обещание продукта
#     — «поставилось и не сломало роутер» — было проверено в симуляции.
#   • steps/vpn/apply.uc (шаг туннеля ДЕФОЛТНОГО тира) не исполнялся ни одним тестом: его чистая
#     часть покрыта юнитами, импурная — создание секций network, ifup, вооружение маршрута — нет.
#     Здесь он применяется по-настоящему, с настоящим kmod в ядре.
#
# Сценарий взят самый частый у пользователя: конфиг синтаксически верный, а сервер мёртвый
# (просрочен, выключен, ключ от другого сервера). Ожидаемое поведение — НЕ «установилось и не
# работает», а честный откат: health-check не подтвердил связь → система возвращена как была.
#
# Что проверяем после откатa (каждый пункт — обещание, на которое ссылается UI):
#   1. код исхода = health (не «шаг упал» и не «preflight») — диагноз в панели зависит от него;
#   2. секции туннеля из network сняты, dnsmasq вернулся к обычному резолву;
#   3. фантомный install.json не остался (иначе панель считает роутер настроенным);
#   4. install-токен НЕ израсходован — человек правит данные и повторяет без bootstrap по SSH;
#   5. ИНТЕРНЕТ НА РОУТЕРЕ ЖИВОЙ. Это главный пункт: удаление дефолтного маршрута через туннель
#      без restart сети оставляло роутер без связи (оплачено инцидентом в reset.uc).
#
# Живого VPN-сервера тест НЕ требует — он и проверяет случай, когда сервера нет.
# Запуск: make qemu-rollback (нужен интернет для apk). ~5-8 мин с KVM.

set -e -u -o pipefail

. "$(dirname "$0")/lib.sh"

vm_lib_init
vm_prepare_image
vm_start
vm_boot_and_setup

vm_check_dns

echo "→ apk update"
apk_try "apk update" || { echo "✗ apk update упал"; vm_ssh "apk update 2>&1 | tail -10"; exit 1; }

echo "→ Ставлю зависимости (как пакет: CORE + dnsmasq-full)"
for pkg in ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus rpcd rpcd-mod-file nftables ip-full \
           https-dns-proxy uhttpd uhttpd-mod-ubus dnsmasq-full; do
    apk_try "apk add $pkg" || { echo "  ✗ не встал $pkg"; exit 1; }
done

echo "→ AmneziaWG тем же путём, что на роутере (vendored awg-инсталлятор)"
# rc инсталлятора игнорируем осознанно (как bootstrap.sh: upstream делает exit 1 из-за
# ненужного нам luci-proto) — проверяем ФАКТ наличия модуля и утилиты.
vm_scp "$REPO_ROOT/vendor/amneziawg-install.sh" "/tmp/awg-install.sh"
# Ретраим САМ ИНСТАЛЛЯТОР, а не только apk: он тянет ассет с GitHub, и фильтрующая сеть рвёт
# запрос («Failed to send request: Operation not permitted») — прогон падал на этом при полностью
# рабочем коде. rc инсталлятора игнорируем осознанно (как bootstrap.sh: upstream делает exit 1
# из-за ненужного нам luci-proto) — критерий успеха один: модуль грузится в ядро.
awg_ok=0
for attempt in 1 2 3; do
    vm_ssh "sh /tmp/awg-install.sh -n -e > /tmp/awg-install.log 2>&1 || true"
    if vm_ssh "modprobe amneziawg 2>/dev/null; lsmod | grep -q '^amneziawg'"; then awg_ok=1; break; fi
    echo "    попытка $attempt не удалась, повтор через 15с"
    sleep 15
done
[ "$awg_ok" = "1" ] || {
    echo "  ✗ модуль amneziawg не загрузился — без него шаг vpn нечего проверять"
    vm_ssh "tail -15 /tmp/awg-install.log" || true; exit 1; }
echo "  ✓ модуль в ядре, утилита awg на месте"

echo "→ Раскладываю движок и регистрирую rpcd-обработчик (как пакет)"
vm_ssh "mkdir -p /usr/share/cheburnet /etc/cheburnet /tmp/cheburnet /usr/libexec/rpcd /usr/share/rpcd/acl.d"
tar -C "$REPO_ROOT" --exclude='engine/*/tests' --exclude='engine/*/*/tests' --exclude='*README.md' \
    -cf - engine | vm_ssh "tar -C /usr/share/cheburnet -xf -"
# Обработчик ставится ТЕМ ЖЕ shim'ом, что кладёт пакет (симлинк на ucode-скрипт rpcd не
# подхватывает) — иначе тест проверял бы не то, что стоит у пользователя.
vm_scp "$REPO_ROOT/package/cheburnet/files/rpcd-cheburnet.sh" "/usr/libexec/rpcd/cheburnet"
vm_scp "$REPO_ROOT/engine/ubus/rpcd-acl.json"                 "/usr/share/rpcd/acl.d/cheburnet.json"
vm_ssh "chmod +x /usr/libexec/rpcd/cheburnet && /etc/init.d/rpcd restart >/dev/null 2>&1; sleep 3"
vm_ssh "ubus list | grep -q '^cheburnet$'" \
    || { echo "  ✗ cheburnet не зарегистрирован на шине"; exit 1; }

# fw4 обязан РАБОТАТЬ до установки: firewall-шаг добавляет цепочки в СУЩЕСТВУЮЩУЮ таблицу inet
# fw4, а vm_boot_and_setup сервис стопил (первый прогон этого теста получил outcome
# `step:firewall` вместо `health`).
vm_start_firewall

# Снимок «как было» ДО установки — с ним сравниваем состояние после откатa. Смотрим на то, что
# трогают наши шаги: секции network/dhcp и дефолтный маршрут.
echo "→ Снимаю состояние «как было» до установки"
BEFORE_NET="$(vm_ssh "uci show network | grep -c . || true")"
BEFORE_ROUTE="$(vm_ssh "ip -4 route show default | head -1")"
# noresolv сравниваем С ИСХОДНЫМ значением, а не с «должно отсутствовать»: что именно лежит в
# стоковом /etc/config/dhcp — не наше дело, и первый прогон этого теста упал именно на таком
# предположении. Правильный инвариант откатa — «как было», каким бы оно ни было.
BEFORE_NORESOLV="$(vm_ssh "uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null || true")"
echo "    секций/строк в network: $BEFORE_NET"
echo "    дефолтный маршрут:      $BEFORE_ROUTE"
echo "    dhcp noresolv:          ${BEFORE_NORESOLV:-<нет>}"

echo "→ Запускаю ПОЛНУЮ установку через ubus (конфиг верный, сервер мёртвый)"
vm_ssh "echo rollback-test-token > /etc/cheburnet/install-token"
# Ключи — валидный base64 нужной длины (WireGuard проверяет форму, не владельца). Endpoint —
# адрес из документационного диапазона RFC 5737: он гарантированно не отвечает, что и требуется.
# Jc/Jmin/Jmax/S1/S2/H1..H4 — обфускация AmneziaWG; без них awg-proto ругается на неполный конфиг.
AWG_CONF='[Interface]
PrivateKey = QFxsc0Gk3nJ2VZUwvVYqNlH9y7bTf1cKmXpRsAeDgHo=
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
PublicKey = Bp7uKqLmNoPqRsTuVwXyZaBcDeFgHiJkLmNoPqRsTuV=
AllowedIPs = 0.0.0.0/0
Endpoint = 192.0.2.10:51820
PersistentKeepalive = 25'

# Payload через файл: в ссылке JSON с переводами строк, а через vm_ssh экранирование его убивает.
printf '%s' "{\"awg_conf\":$(printf '%s' "$AWG_CONF" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))'),\"root_password\":\"install-test-pass\",\"domains\":[\"example.com\"],\"accept_risk\":true,\"token\":\"rollback-test-token\"}" \
    > "$WORK/install-args.json"
vm_scp "$WORK/install-args.json" /tmp/install-args.json
out="$(vm_ssh "ubus call cheburnet install \"\$(cat /tmp/install-args.json)\"")"
echo "$out" | grep -q 'started' \
    || { echo "  ✗ install не запустился: $out"; exit 1; }
echo "  ✓ установка запущена, ждём завершения (health-check самый долгий этап)"

# Ждём done-маркер. Установка делает network restart → ssh может мигнуть, поэтому с ретраями.
done_ok=0
for _ in $(seq 1 60); do
    if vm_ssh '[ -f /tmp/cheburnet/done ]' 2>/dev/null; then done_ok=1; break; fi
    sleep 5
done
[ "$done_ok" = "1" ] || { echo "  ✗ установка не завершилась за 5 минут"; \
    vm_ssh 'cat /tmp/cheburnet/state 2>/dev/null; tail -30 /tmp/cheburnet/install.log' || true; exit 1; }

RC="$(vm_ssh 'cat /tmp/cheburnet/done')"
REASON="$(vm_ssh 'cat /tmp/cheburnet/reason 2>/dev/null || true')"
LOG="$(vm_ssh 'cat /tmp/cheburnet/install.log 2>/dev/null')"

echo
echo "→ ПРОВЕРКА 1: исход — откат по health-check, а не что-то другое"
[ "$RC" != "0" ] || {
    echo "  ✗ установка ОТРАПОРТОВАЛА УСПЕХ с мёртвым сервером — это худший исход:"
    echo "    пользователь получил бы роутер без интернета и «всё работает» в панели."
    echo "$LOG" | tail -20; exit 1; }
[ "$REASON" = "health:tunnel:fetch" ] || {
    echo "  ✗ код исхода '$REASON', ожидался 'health:tunnel:fetch' — панель покажет неверный диагноз"
    echo "$LOG" | tail -20; exit 1; }
echo "  ✓ откат по health-check (reason=health:tunnel:fetch — адресный код, см. install.uc.decide_outcome)"

echo "→ ПРОВЕРКА 2: шаг vpn РЕАЛЬНО применялся (иначе тест ничего не доказывает)"
# Без этой проверки тест мог бы «зеленеть» на конфиге, который шаг вообще не принял: тогда откат
# нечего было бы откатывать, а steps/vpn/apply.uc так и остался бы неисполненным.
printf '%s' "$LOG" | grep -q 'vpn' \
    || { echo "  ✗ в журнале нет следов шага vpn"; echo "$LOG" | tail -20; exit 1; }
printf '%s' "$LOG" | grep -qE 'откат|rollback' \
    || { echo "  ✗ в журнале нет следов откатa"; echo "$LOG" | tail -20; exit 1; }
echo "  ✓ шаг применялся, откат выполнялся"

echo "→ ПРОВЕРКА 3: секции туннеля сняты, dnsmasq вернулся к обычному резолву"
vm_ssh "! uci -q get network.awg0 >/dev/null 2>&1" \
    || { echo "  ✗ секция network.awg0 осталась после откатa"; vm_ssh "uci show network | grep awg"; exit 1; }
AFTER_NORESOLV="$(vm_ssh "uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null || true")"
[ "$AFTER_NORESOLV" = "$BEFORE_NORESOLV" ] \
    || { echo "  ✗ noresolv изменился: было «${BEFORE_NORESOLV:-<нет>}», стало «${AFTER_NORESOLV:-<нет>}»";
         echo "    это опаснее, чем кажется: noresolv=1 без нашего DoH-апстрима = dnsmasq без upstream'а"; exit 1; }
# Наши ipset-секции — то, что dns-шаг добавляет ИМЕННО ОТ СЕБЯ (в стоке их нет по определению):
# на них проверка откатa не зависит от содержимого стокового конфига.
for sect in cheburnet_dns4 cheburnet_dns6; do
    vm_ssh "! uci -q get dhcp.$sect >/dev/null 2>&1" \
        || { echo "  ✗ секция dhcp.$sect осталась после откатa"; vm_ssh "uci show dhcp | grep cheburnet"; exit 1; }
done
AFTER_NET="$(vm_ssh "uci show network | grep -c . || true")"
[ "$AFTER_NET" = "$BEFORE_NET" ] \
    || { echo "  ✗ network изменился: было $BEFORE_NET строк, стало $AFTER_NET";
         vm_ssh "uci show network"; exit 1; }
echo "  ✓ конфигурация сети побайтово того же размера, что до установки"

echo "→ ПРОВЕРКА 4: фантомный install.json не остался"
# Останься он — панель считала бы роутер настроенным и показывала статус несуществующей установки.
vm_ssh "[ ! -f /etc/cheburnet/install.json ]" \
    || { echo "  ✗ install.json остался после откатa"; vm_ssh "cat /etc/cheburnet/install.json"; exit 1; }
echo "  ✓ install.json отсутствует"

echo "→ ПРОВЕРКА 5: install-токен НЕ израсходован (повтор без bootstrap по SSH)"
vm_ssh "[ -s /etc/cheburnet/install-token ]" \
    || { echo "  ✗ токен снят на откате — человеку пришлось бы идти в SSH за новым"; exit 1; }
echo "  ✓ токен на месте, можно исправить данные и повторить"

echo "→ ПРОВЕРКА 6: интернет на роутере живой (главный пункт)"
# Оплачено инцидентом: удаление дефолтного маршрута через туннель БЕЗ restart сети оставляло
# роутер без связи. Проверяем и маршрут, и живой резолв — маршрут может быть, а связи нет.
AFTER_ROUTE="$(vm_ssh "ip -4 route show default | head -1")"
[ -n "$AFTER_ROUTE" ] \
    || { echo "  ✗ дефолтного маршрута нет — роутер остался без интернета"; vm_ssh "ip -4 route show"; exit 1; }
vm_ssh "nslookup downloads.openwrt.org 2>&1 | grep -q 'Address.*\\.'" \
    || { echo "  ✗ DNS не работает после откатa — связь не восстановлена"; exit 1; }
echo "  ✓ дефолтный маршрут: $AFTER_ROUTE"
echo "  ✓ резолв работает — роутер в интернете"

echo "→ ПРОВЕРКА 7: панель честно говорит «не настроен»"
vm_ssh "ubus call cheburnet status | grep -q '\"installed\": *false'" \
    || { echo "  ✗ status после откатa не сообщает installed=false"; vm_ssh "ubus call cheburnet status"; exit 1; }
echo "  ✓ status: installed=false"

echo "→ ПРОВЕРКА 8: повторная установка возможна (идемпотентность на живой системе)"
# Откат не должен оставить мусор, из-за которого второй запуск падает иначе. Ожидаем ТОТ ЖЕ исход,
# а не «шаг упал»: разный диагноз на одинаковом входе означал бы остаточное состояние.
vm_ssh "rm -f /tmp/cheburnet/done"
vm_ssh "ubus call cheburnet install \"\$(cat /tmp/install-args.json)\"" >/dev/null
done_ok=0
for _ in $(seq 1 60); do
    if vm_ssh '[ -f /tmp/cheburnet/done ]' 2>/dev/null; then done_ok=1; break; fi
    sleep 5
done
[ "$done_ok" = "1" ] || { echo "  ✗ повторная установка не завершилась"; exit 1; }
REASON2="$(vm_ssh 'cat /tmp/cheburnet/reason 2>/dev/null || true')"
[ "$REASON2" = "health:tunnel:fetch" ] \
    || { echo "  ✗ повтор дал другой исход ('$REASON2' вместо 'health:tunnel:fetch') — откат оставил мусор";
         vm_ssh 'tail -20 /tmp/cheburnet/install.log'; exit 1; }
vm_ssh "nslookup downloads.openwrt.org 2>&1 | grep -q 'Address.*\\.'" \
    || { echo "  ✗ после второго откатa связь не восстановлена"; exit 1; }
echo "  ✓ повтор даёт тот же честный диагноз, связь снова цела"

echo
echo "✓ T3g pass — полная установка и откат на живом OpenWrt:"
echo "  оркестратор доходит до health-check, мёртвый сервер НЕ выдаётся за успех,"
echo "  steps/vpn/apply.uc применяется по-настоящему (модуль в ядре), откат возвращает"
echo "  network/dnsmasq/install.json как было, токен остаётся, интернет на роутере цел."
echo "  Успешный commit (живой сервер) — qemu-live-vps."
