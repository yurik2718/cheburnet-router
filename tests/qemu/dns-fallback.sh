#!/bin/bash
# tests/qemu/dns-fallback.sh — T3j: DNS ПЕРЕЖИВАЕТ СМЕРТЬ ТУННЕЛЯ.
#
# Зачем. Панель при мёртвом туннеле обещает: «открываются только сайты из списка напрямую».
# Обещание было ЛОЖНЫМ. Цепочка резолва — dnsmasq(noresolv) → https-dns-proxy → DoH — вся уходила
# в туннель: сокеты роутера идут по main-таблице, а метка direct живёт в prerouting и локальный
# трафик не задевает. Туннель умер → DoH недостижим → dnsmasq без upstream → не резолвится НИЧЕГО,
# включая домены из direct-списка. Их адреса не попадают в nft-набор, значит не помечаются, значит
# их режет kill-switch. Для человека это «интернет пропал совсем», хотя WAN живой.
#
# Фикс: ДВА экземпляра DoH одного провайдера. Основной (nobody) ходит как раньше — через туннель.
# Резервный (network) уводится мимо туннеля правилом `ip rule uidrange` — по ВЛАДЕЛЬЦУ СОКЕТА, а не
# меткой: правило по владельцу работает уже при выборе маршрута, поэтому берётся WAN-овский src.
# Пометка в output-хуке тут бесполезна — src выбирается до неё (проверено отдельно, QEMU 2026-08-23).
# dnsmasq спрашивает их строго по порядку (strict-order), поэтому в норме DoH идёт ТОЛЬКО туннелем,
# а провайдер не видит даже факта обращения к резолверу.
#
# Тест герметичен: живой VPN-сервер не нужен, «мёртвый туннель» изображает dummy-интерфейс,
# забирающий дефолт half-route'ами — ровно как настоящий.
#
# Запуск: make qemu-dns-fallback (нужен интернет для apk). ~6-9 мин с KVM.

set -e -u -o pipefail

. "$(dirname "$0")/lib.sh"

TUN=tun0            # «туннель»: dummy-интерфейс, забирающий дефолт
DIRECT_DOMAIN=example.com

vm_lib_init
vm_prepare_image
vm_start
vm_boot_and_setup
vm_check_dns

echo "→ apk update"
apk_try "apk update" || { echo "✗ apk update упал"; exit 1; }

echo "→ Ставлю зависимости"
for pkg in ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus nftables ip-full \
           dnsmasq-full https-dns-proxy kmod-dummy; do
    apk_try "apk add $pkg" || { echo "  ✗ не встал $pkg"; exit 1; }
done

echo "→ Раскладываю движок"
vm_ssh "mkdir -p /usr/share/cheburnet /etc/cheburnet"
tar -C "$REPO_ROOT" --exclude='engine/*/tests' --exclude='engine/*/*/tests' --exclude='*README.md' \
    -cf - engine | vm_ssh "tar -C /usr/share/cheburnet -xf -"
ENGINE=/usr/share/cheburnet/engine

vm_start_firewall

WAN_DEV="$(vm_ssh "ip -4 route show default | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1")"
WAN_GW="$(vm_ssh "ip -4 route show default | sed -n 's/.*via \([0-9.]*\).*/\1/p' | head -1")"
echo "  WAN: dev=$WAN_DEV gw=${WAN_GW:-<нет>}"

# inv_json — чек-лист инвариантов с живой системы (тем же CLI, что зовут диагностика и watchdog).
# `|| true`: check.uc намеренно выходит 1 при отклонениях, а нам нужен сам отчёт.
inv_json() { vm_ssh "ucode -R $ENGINE/invariants/gather.uc | ucode -R $ENGINE/invariants/check.uc --json" || true; }
# inv_ok ID — прошла ли конкретная проверка ("true"/"false"/"missing").
inv_ok() {
    inv_json | python3 -c "import json,sys
r = json.load(sys.stdin)
print(next((str(c['ok']).lower() for c in r['checks'] if c['id'] == '$1'), 'missing'))"
}

# resolve_time — сколько секунд занял успешный резолв ИМЕНИ через наш dnsmasq; "-" если не вышло.
# Имена всегда РАЗНЫЕ у вызывающего: dnsmasq кеширует, и кеш скрыл бы поломку upstream'а.
resolve_time() {
    local name="$1" limit="${2:-60}" t=0
    while [ "$t" -lt "$limit" ]; do
        if vm_ssh "nslookup $name 127.0.0.1 >/dev/null 2>&1"; then echo "$t"; return 0; fi
        t=$((t + 3)); sleep 3
    done
    echo "-"; return 1
}

# Чек-листу инвариантов нужна сохранённая конфигурация — на ненастроенном роутере он молчит
# (и правильно делает). Пишем ровно то, что записала бы установка.
vm_ssh "mkdir -p /etc/cheburnet && printf '%s' '{\"protocol\":\"awg\",\"dns_provider\":\"adguard\",\"domains\":[\"$DIRECT_DOMAIN\"],\"routing_opts\":{\"mode\":\"home\",\"wan_if\":\"$WAN_DEV\",\"tunnel_if\":\"$TUN\",\"ipv6\":false}}' > /etc/cheburnet/install.json"

echo
echo "→ Применяю шаги: dns → doh → firewall"
vm_ssh "echo '{\"domains\":[\"$DIRECT_DOMAIN\"],\"routing_opts\":{\"ipv6\":false}}' | ucode -R $ENGINE/steps/dns/apply.uc" \
    || { echo "  ✗ шаг dns упал"; exit 1; }
vm_ssh "echo '{\"provider\":\"adguard\"}' | ucode -R $ENGINE/steps/doh/apply.uc" \
    || { echo "  ✗ шаг doh упал"; exit 1; }
vm_ssh "echo '{\"domains\":[\"$DIRECT_DOMAIN\"],\"routing_opts\":{\"wan_if\":\"$WAN_DEV\",\"wan_gw\":\"$WAN_GW\",\"ipv6\":false},\"fw_opts\":{\"tunnel_if\":\"$TUN\"}}' | ucode -R $ENGINE/steps/firewall/apply.uc" \
    || { echo "  ✗ шаг firewall упал"; exit 1; }
vm_ssh "/etc/init.d/dnsmasq restart; sleep 3"

# ─── 1. Два экземпляра DoH под РАЗНЫМИ пользователями ────────────────────────
echo
echo "→ ПРОВЕРКА 1: два экземпляра DoH, у резервного отдельный владелец"
# procd поднимает экземпляры не мгновенно и может перезапустить упавший — ЖДЁМ, а не гадаем по
# одному снимку ps (иначе тест краснеет по таймингу, а не по делу).
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(vm_ssh 'pgrep https-dns-proxy | wc -l')" = "2" ] && break
    sleep 2
done
vm_ssh "ps w | grep '[h]ttps-dns-proxy' || true" | sed 's/^/    /'
UIDS="$(vm_ssh "for p in \$(pgrep https-dns-proxy); do awk '/^Uid:/{print \$3}' /proc/\$p/status; done | sort -u | tr '\n' ' '")"
CNT="$(vm_ssh "pgrep https-dns-proxy | wc -l")"
[ "$CNT" = "2" ] || { echo "  ✗ экземпляров $CNT, ожидалось 2"; vm_ssh "uci show https-dns-proxy";
                      vm_ssh "logread | grep -i 'https-dns' | tail -15"; exit 1; }
case "$UIDS" in
    *" "*[0-9]*) : ;; esac
UIDCNT="$(printf '%s' "$UIDS" | wc -w)"
[ "$UIDCNT" = "2" ] \
    || { echo "  ✗ оба экземпляра под одним uid [$UIDS] — правило по владельцу их не различит"; exit 1; }
# Секции пакета анонимные, и их удаление сдвигает индексы — выживший чужой экземпляр занимает
# наш порт и молча подменяет собой резервный резолвер (dns.google вместо выбранной фильтрации).
# Поэтому проверяем не только количество, но и ЧЕЙ резолвер у каждого процесса.
FOREIGN="$(vm_ssh "ps w | grep '[h]ttps-dns-proxy' | grep -vc 'dns.adguard-dns.com' || true")"
[ "$FOREIGN" = "0" ] \
    || { echo "  ✗ среди экземпляров есть ЧУЖОЙ резолвер ($FOREIGN шт.) — фильтрация обойдена";
         vm_ssh "ps w | grep '[h]ttps-dns-proxy'; uci show https-dns-proxy | grep '=https-dns-proxy\$'"; exit 1; }
SECT="$(vm_ssh "uci show https-dns-proxy | grep -c '=https-dns-proxy\$'")"
[ "$SECT" = "2" ] \
    || { echo "  ✗ секций $SECT (ожидал 2) — остались чужие/дубли"; vm_ssh "uci show https-dns-proxy"; exit 1; }
echo "  ✓ два экземпляра нашего резолвера, uid: [$UIDS]"

echo "→ ПРОВЕРКА 2: dnsmasq спрашивает их строго по порядку (иначе DoH утекает мимо туннеля всегда)"
vm_ssh "uci -q get dhcp.@dnsmasq[0].strictorder | grep -q 1" \
    || { echo "  ✗ strictorder не выставлен"; exit 1; }
SRV="$(vm_ssh "uci -q get dhcp.@dnsmasq[0].server")"
case "$SRV" in
    *"127.0.0.1#5053"*"127.0.0.1#5054"*) echo "  ✓ upstream'ы по порядку: $SRV" ;;
    *) echo "  ✗ порядок upstream'ов неверен: $SRV"; exit 1 ;;
esac

echo "→ ПРОВЕРКА 3: правило policy-routing по владельцу сокета на месте"
FB_UID="$(vm_ssh "awk -F: '\$1==\"network\"{print \$3}' /etc/passwd")"
vm_ssh "ip rule show | grep -q 'uidrange $FB_UID-$FB_UID lookup 100'" \
    || { echo "  ✗ нет правила uidrange для uid $FB_UID"; vm_ssh "ip rule show"; exit 1; }
echo "  ✓ ip rule uidrange $FB_UID-$FB_UID lookup 100"

# ─── 4. Контроль: пока туннеля нет, резолв работает (обычное состояние) ───────
echo "→ ПРОВЕРКА 4: резолв работает в обычном состоянии"
T="$(resolve_time openwrt.org 30)" \
    || { echo "  ✗ резолв не работает ДО всякой аварии — тест ничего не докажет"; \
         vm_ssh "logread | grep -i 'dnsmasq\|https-dns' | tail -10"; exit 1; }
echo "  ✓ резолв за ~${T}с"

# ─── 5. Туннель поднялся и умер ──────────────────────────────────────────────
echo "→ Изображаю ЖИВОЙ туннель, который умер (дефолт уходит в него half-route'ами)"
vm_ssh "ip link add $TUN type dummy 2>/dev/null || true; ip link set $TUN up
        ip addr add 10.77.0.1/24 dev $TUN 2>/dev/null || true
        ip route replace 0.0.0.0/1 dev $TUN; ip route replace 128.0.0.0/1 dev $TUN"
echo "  путь ОСНОВНОГО экземпляра (nobody): $(vm_ssh "ip route get 94.140.14.14 | head -1")"
echo "  путь РЕЗЕРВНОГО экземпляра (uid $FB_UID): $(vm_ssh "ip route get 94.140.14.14 uid $FB_UID | head -1")"
vm_ssh "ip route get 94.140.14.14 uid $FB_UID | grep -q \" dev $WAN_DEV \"" \
    || { echo "  ✗ резервный экземпляр тоже уходит в туннель — фолбэка нет"; exit 1; }

echo "→ ПРОВЕРКА 5: ГЛАВНОЕ — при мёртвом туннеле имя всё равно резолвится"
vm_ssh "/etc/init.d/dnsmasq restart; sleep 2"   # кеш не должен скрыть поломку
T="$(resolve_time downloads.openwrt.org 60)" || {
    echo "  ✗ резолв УМЕР вместе с туннелем — обещание панели «direct-сайты открываются» ложно"
    vm_ssh "logread | grep -i 'dnsmasq\|https-dns' | tail -15"; exit 1; }
# Время печатаем как НАБЛЮДЕНИЕ, а не как обещание: в стенде мёртвый туннель — dummy-интерфейс,
# и connect() к нему проваливается сразу. На живом мёртвом сервере пакеты уходят в никуда, и
# основной upstream замолкает по таймауту — там же аварийный резолв будет заметно медленнее.
echo "  ✓ резолв работает при мёртвом туннеле (в стенде занял ~${T}с)"

echo "→ ПРОВЕРКА 6: домен из direct-списка попадает в nft-набор (значит реально откроется)"
vm_ssh "nslookup $DIRECT_DOMAIN 127.0.0.1 >/dev/null 2>&1 || true; sleep 1"
vm_ssh "nft list set inet fw4 direct 2>/dev/null | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'" \
    || { echo "  ✗ адрес direct-домена не попал в набор — kill-switch его порежет";
         vm_ssh "nft list set inet fw4 direct"; exit 1; }
echo "  ✓ адрес в наборе — трафик к нему пойдёт напрямую и не будет дропнут"

# ─── 7. Чек-лист инвариантов на живой системе ────────────────────────────────
# Тот же список, что печатает диагностика и по которому будет чинить watchdog. Здесь он должен
# быть ЗЕЛЁНЫМ ЦЕЛИКОМ: применены все шаги, туннель на месте, резервный путь включён.
# ЕДИНСТВЕННОЕ допустимое отклонение — dns_main: при мёртвом туннеле основной экземпляр DoH
# гарантированно уходит в crash-loop (его bootstrap молчит; баг апстрима, размером пула bootstrap
# не лечится — проверено). Всё остальное обязано быть на месте, включая резервный путь.
inv_ok_but_main() {
    local failed; failed="$(vm_inv_failed "$ENGINE" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')"
    case "$failed" in
        ""|"dns_main") return 0 ;;
        *) echo "  отклонения: $failed"; return 1 ;;
    esac
}

echo "→ ПРОВЕРКА 7: чек-лист инвариантов зелёный (кроме dns_main — его убивает мёртвый туннель)"
if ! inv_ok_but_main; then
    vm_ssh "ucode -R $ENGINE/invariants/gather.uc | ucode -R $ENGINE/invariants/check.uc" || true
    echo "  ✗ есть отклонения сверх ожидаемого — либо шаг не доработал, либо инвариант врёт"
    exit 1
fi
echo "  ✓ инварианты на месте"

# ─── 8. Отрицательный контроль ───────────────────────────────────────────────
# Без него тест мог бы «зеленеть» просто потому, что что-то ходит мимо туннеля само. Заодно это
# проверка самого чек-листа: он ОБЯЗАН покраснеть ровно на том инварианте, который мы сломали.
echo "→ ПРОВЕРКА 8: снимаю правило по владельцу — резолв ОБЯЗАН умереть"
vm_ssh "ip rule del uidrange $FB_UID-$FB_UID lookup 100"
vm_ssh "/etc/init.d/https-dns-proxy restart; sleep 4; /etc/init.d/dnsmasq restart; sleep 2"
if resolve_time archive.openwrt.org 20 >/dev/null; then
    echo "  ✗ резолв работает БЕЗ правила — значит его несёт не резервный путь, а что-то ещё"
    vm_ssh "ip rule show; ip route show"; exit 1
fi
echo "  ✓ без правила резолв умирает — доказано, что его несёт именно резервный путь"

BROKEN="$(inv_ok dns_rule)"
[ "$BROKEN" = "false" ] \
    || { echo "  ✗ чек-лист инвариантов НЕ заметил снятое правило (dns_rule=$BROKEN) — он бесполезен";
         inv_json; exit 1; }
REPAIR="$(inv_json | python3 -c "import json,sys; print(' '.join(sorted({c['repair'] for c in json.load(sys.stdin)['checks'] if not c['ok'] and c['repair']})))")"
case "$REPAIR" in
    *reapply*) echo "  ✓ чек-лист покраснел на dns_rule и предлагает почин: $REPAIR" ;;
    *) echo "  ✗ подсказки починки нет ($REPAIR) — watchdog'у будет не за что зацепиться"; exit 1 ;;
esac

# ─── 9. Сторож чинит сам ─────────────────────────────────────────────────────
# Правило НЕ возвращаем руками: его обязан вернуть watchdog по тому же чек-листу инвариантов.
# Это и есть обещание «настроил один раз — работает годами»: никто не сидит у консоли.
echo "→ ПРОВЕРКА 9: watchdog чинит сломанный инвариант сам"
# Считаем ПРИРОСТ строк, а не абсолют: `logread -c` буфер не чистит (проверено — в счёт попадала
# строка из прошлой проверки, и тест краснел на исправном сторожe).
wd_lines() { vm_ssh "logread | grep -c 'cheburnet-watchdog' || true"; }
WD_BEFORE="$(wd_lines)"
# Сторож НАМЕРЕННО молчит первые 3 минуты после загрузки (SETTLE_S: не драться с netifd и procd).
# Тест обязан уважать это окно, а не подгонять продукт под себя, — поэтому ждём его конца.
# Первый прогон промахнулся на 4 секунды (uptime 176 при окне 180) и красил тест на исправном коде.
for _ in $(seq 1 40); do
    UP="$(vm_ssh 'cut -d. -f1 /proc/uptime')"
    [ "$UP" -ge 185 ] && break
    sleep 5
done
echo "  (uptime VM: ${UP}с — окно тишины сторожа 180с позади)"
vm_ssh "ucode -R $ENGINE/watchdog/tick.uc" || { echo "  ✗ тик сторожа завершился ошибкой"; exit 1; }
sleep 2
vm_ssh "ip rule show | grep -q 'uidrange $FB_UID-$FB_UID lookup 100'" \
    || { echo "  ✗ сторож не вернул правило"; vm_ssh "ip rule show; logread | grep watchdog"; exit 1; }
inv_ok_but_main \
    || { echo "  ✗ чек-лист всё ещё красный после починки";
         vm_ssh "ucode -R $ENGINE/invariants/gather.uc | ucode -R $ENGINE/invariants/check.uc" || true; exit 1; }
vm_ssh "logread | grep -q 'cheburnet-watchdog.*чиню'" \
    || { echo "  ✗ сторож починил молча — в поддержке это неотличимо от «ничего не было»";
         vm_ssh "logread | tail -20"; exit 1; }
[ "$(wd_lines)" -gt "$WD_BEFORE" ] \
    || { echo "  ✗ в журнале не прибавилось строк — сторож не отчитался о работе"; exit 1; }
echo "  ✓ правило вернулось, чек-лист зелёный, в журнале есть строка о починке"

# ─── 10. …и молчит, когда всё в порядке ──────────────────────────────────────
# Cron-задача, пишущая каждые 5 минут, забивает log-snapshot и делает диагностику бесполезной.
echo "→ ПРОВЕРКА 10: на здоровой системе сторож молчит"
WD_MID="$(wd_lines)"
vm_ssh "ucode -R $ENGINE/watchdog/tick.uc"
vm_ssh "ucode -R $ENGINE/watchdog/tick.uc"
NOISE=$(( $(wd_lines) - WD_MID ))
# Ровно одна новая строка допустима: «инварианты восстановлены» — она говорится ОДИН раз.
[ "$NOISE" -le 1 ] \
    || { echo "  ✗ сторож шумит (+$NOISE строк за два тика) — журнал перестанет быть полезным";
         vm_ssh "logread | grep watchdog"; exit 1; }
echo "  ✓ два тика подряд — не больше одной новой строки в журнале (+$NOISE)"

echo "→ ПРОВЕРКА 11: teardown снимает правило вместе с остальным data-plane"
vm_ssh "echo '{\"domains\":[],\"routing_opts\":{\"wan_if\":\"$WAN_DEV\",\"ipv6\":false}}' | ucode -R $ENGINE/steps/firewall/apply.uc --teardown" \
    || { echo "  ✗ teardown упал"; exit 1; }
vm_ssh "! ip rule show | grep -q uidrange" \
    || { echo "  ✗ правило uidrange осталось после teardown"; vm_ssh "ip rule show"; exit 1; }
echo "  ✓ правило снято"

vm_ssh "ip link del $TUN 2>/dev/null" || true

echo
printf '\033[32m✓ dns-fallback: DNS переживает смерть туннеля, резервный путь доказан отрицательным контролем\033[0m\n'
