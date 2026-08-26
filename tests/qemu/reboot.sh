#!/bin/bash
# tests/qemu/reboot.sh — T3h: data-plane ПЕРЕЖИВАЕТ ПЕРЕЗАГРУЗКУ роутера.
#
# Зачем. Обещание продукта — «настроил один раз и работает годами». Между этим обещанием и
# реальностью стоит ровно одно событие, которое случается у каждого: роутер перезагрузили (свет
# мигнул, обновили прошивку, выдернули шнур). До этого теста НИ ОДНА проверка не перезагружала
# систему: fw4 reload покрыт (install), а полная перезагрузка со всеми init-скриптами, hotplug'ами
# и порядком старта сервисов — нет. А это разные вещи: reload перечитывает конфиг живого fw4, ребут
# же собирает всё с нуля, и правило, добавленное «в память», исчезает молча.
#
# Тест герметичный: рабочий VPN-сервер НЕ нужен. Проверяется то, что от сервера не зависит —
# ПЕРСИСТЕНТНОСТЬ нашей конфигурации и САМОСТОЯТЕЛЬНЫЙ подъём сервисов. Туннель после ребута не
# поднимется (сервера нет) — и это правильное поведение kill-switch'а, его мы тоже фиксируем:
# трафик должен ДРОПАТЬСЯ, а не течь в WAN, причём сразу после загрузки, до всякого вмешательства.
#
# Запуск: make qemu-reboot (нужен интернет для apk). ~6-9 мин с KVM.

set -e -u -o pipefail

. "$(dirname "$0")/lib.sh"

vm_lib_init
vm_prepare_image
vm_start
vm_boot_and_setup

vm_check_dns

echo "→ apk update"
apk_try "apk update" || { echo "✗ apk update упал"; vm_ssh "apk update 2>&1 | tail -10"; exit 1; }

echo "→ Ставлю зависимости (как пакет)"
for pkg in ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus rpcd rpcd-mod-file nftables ip-full \
           https-dns-proxy dnsmasq-full; do
    apk_try "apk add $pkg" || { echo "  ✗ не встал $pkg"; exit 1; }
done

echo "→ Раскладываю движок"
vm_ssh "mkdir -p /usr/share/cheburnet /etc/cheburnet /tmp/cheburnet"
tar -C "$REPO_ROOT" --exclude='engine/*/tests' --exclude='engine/*/*/tests' --exclude='*README.md' \
    -cf - engine | vm_ssh "tar -C /usr/share/cheburnet -xf -"
ENGINE=/usr/share/cheburnet/engine

# Ребут собирает всё с нуля (в отличие от reload) — нужен автостарт firewall при загрузке,
# его даёт vm_start_firewall (постоянное uci-правило, не одноразовая nft-инъекция).
vm_start_firewall

# ─── применяем data-plane (шаги, которым живой сервер не нужен) ───────────────
echo "→ Применяю data-plane: dns → doh → firewall"
vm_ssh "echo '{\"domains\":[\"example.com\"],\"dns_provider\":\"adguard\"}' | ucode -R $ENGINE/steps/dns/apply.uc" \
    || { echo "  ✗ dns-шаг упал"; exit 1; }
vm_ssh "echo '{\"dns_provider\":\"adguard\"}' | ucode -R $ENGINE/steps/doh/apply.uc" \
    || { echo "  ✗ doh-шаг упал"; exit 1; }
# install.json — то, из чего система восстанавливает себя после загрузки (его пишет оркестратор на
# commit). Без него hotplug-хук честно ничего не делает, и «переживает ребут» проверялось бы на
# системе, которая с точки зрения движка не настроена.
vm_ssh "echo '{\"protocol\":\"awg\",\"domains\":[\"example.com\"],\"routing_opts\":{\"wan_if\":\"eth0\",\"tunnel_if\":\"awg0\"}}' > /etc/cheburnet/install.json" \
    || { echo "✗ не записал install.json"; exit 1; }

vm_ssh "echo '{\"domains\":[\"example.com\"],\"routing_opts\":{\"wan_if\":\"eth0\"},\"fw_opts\":{\"tunnel_if\":\"awg0\"}}' | ucode -R $ENGINE/steps/firewall/apply.uc" \
    || { echo "  ✗ firewall-шаг упал"; exit 1; }
vm_ssh "/etc/init.d/dnsmasq restart >/dev/null 2>&1; sleep 3"
echo "  ✓ шаги применены"

# Работает ли DoH-резолв ДО ребута. Нужно, чтобы после ребута отличить НАШ регресс от
# окружения, которое DoH не пропускает вообще: иначе один и тот же провал читался бы двояко.
if vm_ssh "nslookup example.com 127.0.0.1 >/dev/null 2>&1"; then
    DOH_BEFORE=yes
    echo "  ✓ резолв через наш стек работает до ребута (сравним после)"
else
    DOH_BEFORE=no
    echo "  ⚠ резолв через DoH не работает и ДО ребута — сеть окружения его не пропускает."
    echo "    Проверки персистентности останутся строгими, а сам резолв после ребута сверять не с чем."
fi

# Состояние ДО ребута — с ним и сравниваем. Считаем не «есть ли файл», а то, что реально в ЯДРЕ:
# файл на диске может лежать, а правил в ядре не быть — именно так тихо умирал kill-switch.
before_ks="$(vm_ssh "nft list chain inet fw4 cheburnet_ks 2>/dev/null | grep -c drop || true")"
# Наборы спрашиваем ПОИМЕННО (`nft list set inet fw4 direct`). `nft list sets inet fw4` —
# синтаксическая ошибка (family без таблицы), grep по её выводу давал бы 0 и до и после ребута,
# то есть проверка проходила бы ВПУСТУЮ. Молчащая проверка хуже отсутствующей.
sets_present() { # sets_present → "direct direct6" из тех, что реально есть в ядре
    local out=""
    for s in direct direct6; do
        if vm_ssh "nft list set inet fw4 $s >/dev/null 2>&1"; then out="$out $s"; fi
    done
    echo "${out# }"
}
before_sets="$(sets_present)"
echo "    kill-switch drop-правил в ядре: $before_ks"
echo "    наборы в ядре:                  ${before_sets:-нет}"
[ "$before_ks" -gt 0 ] || { echo "  ✗ kill-switch не в ядре ДО ребута — проверять нечего"; exit 1; }
[ -n "$before_sets" ] || { echo "  ✗ наборов нет в ядре ДО ребута — проверять нечего"; exit 1; }

# ─── ПЕРЕЗАГРУЗКА ────────────────────────────────────────────────────────────
echo
echo "→ ПЕРЕЗАГРУЖАЮ роутер (то, чего не делал ни один тест до этого)"
# reboot рвёт ssh-соединение — код возврата не значим, поэтому || true.
vm_ssh "reboot" >/dev/null 2>&1 || true
sleep 10
# Ждём, пока SSH снова начнёт отвечать. Настройки сети и ключ персистентны (uci + ext4), поэтому
# vm_boot_and_setup повторно НЕ нужен: если SSH не вернулся сам — это и есть провал теста.
back=0
for _ in $(seq 1 40); do
    if vm_ssh true 2>/dev/null; then back=1; break; fi
    sleep 5
done
[ "$back" = "1" ] || {
    echo "  ✗ роутер не вернулся в сеть после перезагрузки за 200с — для пользователя это"
    echo "    «после ребута интернета нет», худший из возможных исходов"
    tail -40 "$SERIAL_LOG" 2>/dev/null || true; exit 1; }
echo "  ✓ роутер загрузился и доступен (uptime: $(vm_ssh 'cut -d. -f1 /proc/uptime')с)"

# ─── ПРОВЕРКИ ПОСЛЕ РЕБУТА: всё поднялось САМО ───────────────────────────────
echo
echo "→ ПРОВЕРКА 1: kill-switch снова в ядре (антиутечка не исчезла)"
# Главный пункт. Правила, добавленные «в память», после ребута пропадают молча: kill-switch
# мёртв, а панель зелёная. Поэтому смотрим на ЯДРО, а не на файл в /etc/nftables.d.
after_ks="$(vm_ssh "nft list chain inet fw4 cheburnet_ks 2>/dev/null | grep -c drop || true")"
[ "$after_ks" -gt 0 ] || {
    echo "  ✗ kill-switch НЕ восстановился после ребута — трафик потечёт в WAN при мёртвом туннеле"
    vm_ssh "ls -l /etc/nftables.d/ 2>/dev/null; nft list table inet fw4 | head -30" || true; exit 1; }
[ "$after_ks" = "$before_ks" ] || echo "    ⚠ число drop-правил изменилось: было $before_ks, стало $after_ks"
echo "  ✓ kill-switch в ядре ($after_ks drop-правил)"

echo "→ ПРОВЕРКА 2: наши nft-наборы на месте"
after_sets="$(sets_present)"
[ "$after_sets" = "$before_sets" ] || {
    echo "  ✗ наборы не восстановились: было «$before_sets», стало «${after_sets:-нет}»"
    echo "    без набора direct дом резолвится, но адрес некуда положить — split мёртв"
    vm_ssh "nft list table inet fw4 | head -40" || true; exit 1; }
echo "  ✓ наборы в ядре: $after_sets"

echo "→ ПРОВЕРКА 3: сервисы поднялись сами (procd-автостарт)"
# Ждём с ограничением, а не проверяем мгновенно: https-dns-proxy стартует НЕ на boot напрямую —
# его init ставит procd-триггер и поднимает сервис, когда поднялся интерфейс («Setting trigger
# (on_boot)» в логе). Первая версия проверки спрашивала статус на 7-й секунде uptime и честно
# рапортовала провал при нормальном поведении. Важно не «стартовал мгновенно», а «стартовал САМ».
wait_service() { # wait_service <имя> <секунд> → 0, если поднялся сам
    local svc="$1" limit="$2" i=0
    while [ "$i" -lt "$limit" ]; do
        if vm_ssh "/etc/init.d/$svc status 2>/dev/null | grep -qi running"; then return 0; fi
        i=$(( i + 3 )); sleep 3
    done
    return 1
}
wait_service dnsmasq 30 \
    || { echo "  ✗ dnsmasq не поднялся сам после ребута"; vm_ssh 'logread | grep -i dnsmasq | tail -10'; exit 1; }
wait_service https-dns-proxy 90 \
    || { echo "  ✗ https-dns-proxy не поднялся сам за 90с — шифрованный DNS молча выключился"; \
         vm_ssh 'logread | grep -i dns-proxy | tail -15'; exit 1; }
echo "  ✓ dnsmasq и https-dns-proxy работают без вмешательства"

echo "→ ПРОВЕРКА 4: привязка dnsmasq к нашему nftset уцелела в uci"
vm_ssh "uci -q show dhcp | grep -q 'ipset\|nftset'" \
    || { echo "  ✗ ipset/nftset-секция dnsmasq пропала из uci"; vm_ssh 'uci show dhcp | tail -20'; exit 1; }
vm_ssh "uci -q get dhcp.@dnsmasq[0].noresolv >/dev/null 2>&1" \
    || { echo "  ✗ noresolv не сохранился — dnsmasq пошёл в обход шифрованного DNS"; exit 1; }
echo "  ✓ привязка и noresolv на месте"

echo "→ ПРОВЕРКА 5: DNS через наш стек РАБОТАЕТ после ребута"
# Не косметика: после ребута dnsmasq стоит с noresolv=1, то есть /etc/resolv.conf он не читает и
# зависит ТОЛЬКО от нашего DoH-апстрима. Не поднялся https-dns-proxy — у пользователя «интернета
# нет» при живом туннеле. Сравниваем с состоянием ДО ребута: так провал окружения (DoH не
# пропускают) не выдаётся за наш регресс и наоборот.
# ОКНО, а не единственный выстрел. Обещание — «после перезагрузки DNS работает», а не «работает
# на второй секунде»: https-dns-proxy умеет падать на старте фатальной ошибкой c-ares
# (`needed more IO event handler`, баг апстрима — падают ОБА экземпляра разом, наблюдалось дважды),
# procd поднимает его за считанные секунды. Проверять одним выстрелом — значит красить тест в
# зависимости от того, попали мы в это окно или нет. Не поднялся за минуту — это уже регресс.
if [ "$DOH_BEFORE" = "yes" ]; then
    dns_back=0
    for _ in $(seq 1 20); do
        if vm_ssh "nslookup example.com 127.0.0.1 >/dev/null 2>&1"; then dns_back=1; break; fi
        sleep 3
    done
    [ "$dns_back" = "1" ] \
        || { echo "  ✗ резолв РАБОТАЛ до ребута и не вернулся за минуту — регресс персистентности DNS";
             vm_ssh "uci show dhcp.@dnsmasq[0] | grep -E 'noresolv|server'" || true
             vm_ssh "pgrep -a https-dns-proxy" || true
             vm_ssh "logread | grep -iE 'dnsmasq|dns-proxy' | tail -15" || true; exit 1; }
    echo "  ✓ имя резолвится через наш dnsmasq + шифрованный DNS (как и до ребута)"
else
    echo "  ⊘ пропущено: DoH не работал и до ребута (ограничение сети окружения, не роутера)"
fi

echo "→ ПРОВЕРКА 6: мост «домен → IP → набор» работает после ребута"
# Самая содержательная проверка: не «конфиг на диске», а РАБОТА. Наборы после ребута пусты
# (это состояние ядра), поэтому найденный адрес мог попасть туда только этим резолвом.
if [ "$DOH_BEFORE" = "yes" ]; then
    vm_ssh "nft list set inet fw4 direct 2>/dev/null | grep -qE '[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+'" \
        || { echo "  ✗ адрес не попал в набор — split-routing после ребута мёртв (домены поедут в туннель)";
             vm_ssh "nft list set inet fw4 direct; uci show dhcp | grep -i cheburnet" || true; exit 1; }
    echo "  ✓ адрес direct-домена попал в набор — разделение трафика живо"
else
    echo "  ⊘ пропущено: без резолва наполнить набор нечем (см. проверку 5)"
fi

echo "→ ПРОВЕРКА 7: policy-routing вернулся в ЯДРО (направление direct-трафика)"
# СЛЕПАЯ ЗОНА, стоившая живого прогона (2026-08-01): nft-часть переживала ребут файлом в
# /etc/nftables.d/, а ip-часть (`ip rule fwmark → table` + default этой таблицы через WAN) — нет.
# Проверка 6 при этом ЗЕЛЕНЕЛА: адрес в наборе есть, метка ставится — а направлять помеченный
# трафик нечем, и он уходил в туннель. То есть split-tunnel, главная функция продукта, тихо
# выключался после каждой перезагрузки. Возвращает правила hotplug-хук (install/reapply.uc).
vm_ssh "ip rule show | grep -q fwmark" \
    || { echo "  ✗ правила policy-routing нет — direct-домены пойдут В ТУННЕЛЬ (split мёртв)";
         vm_ssh "ip rule show; ls -l /etc/hotplug.d/iface/ 2>/dev/null" || true; exit 1; }
echo "  ✓ ip rule fwmark на месте"
vm_ssh "ip route show table 100 2>/dev/null | grep -q default" \
    || { echo "  ✗ в таблице direct нет маршрута по умолчанию — помеченный трафик никуда не поедет";
         vm_ssh "ip route show table 100; cat /etc/hotplug.d/iface/99-cheburnet 2>/dev/null" || true; exit 1; }
echo "  ✓ default-маршрут таблицы direct через WAN на месте"
vm_ssh '[ -x /etc/hotplug.d/iface/99-cheburnet ]' \
    || { echo "  ✗ hotplug-хук отсутствует — после следующего ребута правил снова не будет"; exit 1; }
echo "  ✓ hotplug-хук восстановления на месте (исполняемый)"

# Сторож ставится не установкой, а reapply на холодном подъёме WAN — так он появляется и на
# роутерах, поставленных до него. Значит после ребута cron-запись обязана быть на месте.
echo "→ ПРОВЕРКА 7b: сторож (cron) на месте после загрузки"
vm_ssh "grep -q 'watchdog/tick.uc' /etc/crontabs/root" \
    || { echo "  ✗ cron-записи сторожа нет — за роутером после загрузки никто не смотрит";
         vm_ssh "cat /etc/crontabs/root 2>/dev/null; logread | grep -i cheburnet | tail -5"; exit 1; }
echo "  ✓ cron-запись сторожа восстановлена автоматически"

echo "→ ПРОВЕРКА 8: файл правил на диске, а не только в памяти"
# Обратная сторона проверки 1: правила в ядре могли оказаться там случайно (например, кто-то
# применил шаг заново). Файл включения — то, из чего fw4 их берёт при КАЖДОМ старте.
vm_ssh '[ -f /etc/nftables.d/10-cheburnet.nft ]' \
    || { echo "  ✗ /etc/nftables.d/10-cheburnet.nft отсутствует — после следующего ребута правил не будет"; exit 1; }
echo "  ✓ /etc/nftables.d/10-cheburnet.nft на месте"

echo
echo "✓ T3h pass — конфигурация переживает перезагрузку роутера:"
echo "  kill-switch и наборы возвращаются в ядро сами (правила в /etc/nftables.d, не в памяти),"
echo "  dnsmasq и https-dns-proxy стартуют по procd, мост «домен→IP→набор» работает после загрузки,"
echo "  а policy-routing (ip rule + таблица direct) восстанавливает hotplug-хук — без него split"
echo "  молча выключался после каждой перезагрузки при полностью зелёной панели."
echo "  Подъём самого туннеля после ребута требует живого сервера — qemu-live-vps."
