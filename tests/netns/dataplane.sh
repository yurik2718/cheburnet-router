#!/bin/sh
# dataplane.sh — герметичный тест ПОВЕДЕНИЯ split-routing после установки (форвард-путь).
#
# Отвечает на вопрос «а точно ли трафик разделяется правильно и не утекает?» — детерминированно,
# за секунды, БЕЗ роутера/QEMU и БЕЗ рабочего VPN. Ключевая идея: разделение трафика — это
# ЛОКАЛЬНОЕ решение ядра (nftset-членство + fwmark + ip rule + kill-switch drop), не зависящее от
# VPN-крипты. Туннель подменяем dummy-интерфейсом и НАБЛЮДАЕМ egress через nft-счётчики.
#
# ПОЧЕМУ форвард-путь (а не output, как в poc/split-routing-netns.sh): продакшн метит трафик в
# PREROUTING, а kill-switch живёт в FORWARD-хуке. Локальный трафик их не проходит → kill-switch там
# непроверяем в принципе. Поэтому строим client→router→{wan,tun} и гоним настоящий форвард-трафик.
#
# Всё ROOTLESS (unshare -rn + дочерний netns по PID) — как poc-split, без sudo. Гоняет РЕАЛЬНЫЙ
# вывод движка (tests/netns/emit.uc → build_firewall_plan/render_dnsmasq), а не свою копию правил.
#
#   make test-netns          # или:  sh tests/netns/dataplane.sh
#   NETNS_REQUIRE=1 …         # в CI: отсутствие инструментов = ФЕЙЛ, а не тихий скип
#
# Покрывает: split (direct→WAN, остальное→туннель) для awg0 И singtun0 (общий интерфейс обоих
# Full-протоколов — Reality и Hysteria2); kill-switch антиутечку
# (туннель упал → непрямой трафик ДРОПается, не течёт в WAN); travel (весь трафик в туннель);
# идентичность data-plane обоих протоколов; реальный dnsmasq: резолв direct-домена → IP попадает
# в @direct → маршрут уходит в WAN (мост «домен→IP→set», главный шрам v1).

set -eu

SELF=$(cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")
REPO=$(cd -- "$(dirname -- "$0")/../.." && pwd)

emit() { printf '%s' "$1" | ucode -R "$REPO/tests/netns/emit.uc"; }

pass=0; fail=0
ok()   { printf '  \033[32m✓ PASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗ FAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
note() { printf '  \033[33m…\033[0m %s\n' "$1"; }

# ---- зависимости / политика скипа ----------------------------------------------------------
# NETNS_REQUIRE=1 (CI): нехватка инструмента = провал (иначе тихий скип = ложно-зелёный CI).
require_or_skip() {
	miss=""
	for t in unshare nsenter ip nft ucode; do
		command -v "$t" >/dev/null 2>&1 || miss="$miss $t"
	done
	if [ -n "$miss" ]; then
		if [ "${NETNS_REQUIRE:-0}" = "1" ]; then
			printf '\033[31mНет инструментов:%s (NETNS_REQUIRE=1)\033[0m\n' "$miss"; exit 1
		fi
		note "Пропуск: нет инструментов:$miss (rootless netns-тест). NETNS_REQUIRE=1 сделает это фейлом."
		exit 0
	fi
	# Проба: доступен ли rootless user+net namespace в этом окружении.
	if ! unshare -rn true 2>/dev/null; then
		if [ "${NETNS_REQUIRE:-0}" = "1" ]; then
			printf '\033[31mrootless unshare -rn недоступен (NETNS_REQUIRE=1)\033[0m\n'; exit 1
		fi
		note "Пропуск: rootless unshare -rn недоступен в этом окружении."
		exit 0
	fi
}

# =================================  ВНУТРИ NETNS (__run)  ====================================
# Каждый сценарий запускается в СВЕЖЕМ unshare -rn (ре-exec ниже) — чистый netns без следов
# предыдущего. Топологию клиента держим в дочернем netns (unshare -n sleep), ссылаемся по PID.

CPID=""
cleanup_child() { [ -n "$CPID" ] && kill "$CPID" 2>/dev/null || true; }

# build_topology TUN MODE — поднять client→router→{wan0,TUN}, загрузить РЕАЛЬНЫЙ вывод движка
# (nft mark+kill-switch, ip rules) для режима MODE, повесить счётчики-наблюдатели egress.
build_topology() {
	tun=$1; mode=$2
	ip link set lo up
	unshare -n sleep 300 & CPID=$!
	# Дождаться, пока ребёнок РЕАЛЬНО войдёт в свой netns: /proc/PID/ns/net существует сразу
	# (указывая на НАШ ns до exec unshare) — ждём, пока inode станет ОТЛИЧНЫМ от нашего, иначе
	# veth уедет в старый ns и «Cannot find device vC» (гонка fork→exec, ловилась не всегда).
	myns=$(readlink "/proc/self/ns/net")
	i=0
	while [ "$(readlink "/proc/$CPID/ns/net" 2>/dev/null)" = "$myns" ] && [ "$i" -lt 100 ]; do
		i=$((i+1)); sleep 0.05
	done

	ip link add vR type veth peer name vC
	ip link set vC netns "$CPID"
	ip addr add 10.0.0.1/24 dev vR; ip link set vR up
	nsenter -t "$CPID" -n ip link set lo up
	nsenter -t "$CPID" -n ip addr add 10.0.0.2/24 dev vC
	nsenter -t "$CPID" -n ip link set vC up
	nsenter -t "$CPID" -n ip route add default via 10.0.0.1

	sysctl -wq net.ipv4.ip_forward=1
	sysctl -wq net.ipv4.conf.all.rp_filter=0

	# Туннель и WAN — dummy: пакет дропается на xmit, но форвард-хук уже оценил oifname (нам хватит).
	ip link add "$tun" type dummy; ip link set "$tun" up; ip addr add 10.88.0.1/24 dev "$tun"
	ip link add wan0 type dummy;   ip link set wan0 up;   ip addr add 10.99.0.1/24 dev wan0

	# main-таблица КАК НА РОУТЕРЕ: туннель держат half-routes 0.0.0.0/1 + 128.0.0.0/1 — они
	# специфичнее WAN-дефолта, поэтому побеждают его НЕ УДАЛЯЯ (см. HALF_ROUTES в steps/vpn/vpn.uc
	# и build_net_plan в steps/singbox). Их ставит netifd, не наш шаг — поэтому стенд, а не движок.
	ip route add 0.0.0.0/1   dev "$tun"
	ip route add 128.0.0.0/1 dev "$tun"
	ip route add default     dev wan0

	# --- РЕАЛЬНЫЙ вывод движка: nft (mark + kill-switch) + policy-routing ---
	nft_body=$(emit "{\"what\":\"nft\",\"domains\":[\"x.example\"],\"routing_opts\":{\"ipv6\":false,\"wan_if\":\"wan0\",\"mode\":\"$mode\"},\"fw_opts\":{\"tunnel_if\":\"$tun\"}}")
	printf 'table inet fw4 {\n%s\n}\n' "$nft_body" | nft -f -
	emit "{\"what\":\"ip\",\"domains\":[\"x.example\"],\"routing_opts\":{\"ipv6\":false,\"wan_if\":\"wan0\",\"mode\":\"$mode\"}}" \
		| while IFS= read -r c; do [ -n "$c" ] && eval "$c"; done

	# Счётчики-наблюдатели egress: priority 200 > kill-switch(filter=0) → drop сюда НЕ долетает,
	# значит инкремент c_wan = трафик РЕАЛЬНО ушёл в WAN (утёк). Свои — тест их владелец, не движок.
	nft add counter inet fw4 c_wan
	nft add counter inet fw4 c_tun
	nft -f - <<-NFTEOF
	table inet fw4 {
	  chain test_obs {
	    type filter hook forward priority 200; policy accept;
	    oifname "wan0" counter name c_wan
	    oifname "$tun" counter name c_tun
	  }
	}
	NFTEOF
}

TUN=""          # имя туннель-интерфейса текущего сценария (для ctun)
D=10; O=10      # курсоры адресов: каждый probe — свежий IP (203.0.113.D / 198.51.100.O) →
                # ct state new гарантирован без conntrack-flush (иначе established обошёл бы kill-switch).
cwan() { nft list counter inet fw4 c_wan | grep -oE 'packets [0-9]+' | grep -oE '[0-9]+'; }
ctun() { nft list counter inet fw4 c_tun | grep -oE 'packets [0-9]+' | grep -oE '[0-9]+'; }
zero() { nft reset counter inet fw4 c_wan >/dev/null; nft reset counter inet fw4 c_tun >/dev/null; }
send_direct() { D=$((D+1)); nsenter -t "$CPID" -n ping -c1 -W1 "203.0.113.$D" >/dev/null 2>&1 || true; }
send_other()  { O=$((O+1)); nsenter -t "$CPID" -n ping -c1 -W1 "198.51.100.$O" >/dev/null 2>&1 || true; }

# scenario_home TUN — split + kill-switch (главный сценарий, гоняется для awg0 и singtun0).
scenario_home() {
	TUN=$1
	trap cleanup_child EXIT
	build_topology "$TUN" home
	# @direct = весь 203.0.113.0/24 → любой probe-адрес прямой, но каждый свежий (ct new).
	nft add element inet fw4 direct '{ 203.0.113.0/24 }'

	hdr "HOME / $TUN — туннель UP"
	zero; send_direct
	[ "$(cwan)" -ge 1 ] && ok "[$TUN] direct-адрес → WAN напрямую (c_wan=$(cwan))" \
		|| bad "[$TUN] direct не ушёл в WAN (c_wan=$(cwan))"
	zero; send_other
	{ [ "$(ctun)" -ge 1 ] && [ "$(cwan)" -eq 0 ]; } \
		&& ok "[$TUN] непрямой → туннель, WAN чист (c_tun=$(ctun) c_wan=$(cwan))" \
		|| bad "[$TUN] непрямой распределён неверно (c_tun=$(ctun) c_wan=$(cwan))"

	hdr "HOME / $TUN — KILL-SWITCH (туннель УПАЛ: netifd снял half-routes)"
	ip route del 0.0.0.0/1 dev "$TUN"; ip route del 128.0.0.0/1 dev "$TUN"
	zero; send_other
	[ "$(cwan)" -eq 0 ] \
		&& ok "[$TUN] АНТИУТЕЧКА: непрямой ДРОПнут, НЕ утёк в WAN (c_wan=$(cwan))" \
		|| bad "[$TUN] УТЕЧКА! непрямой ушёл в открытый WAN (c_wan=$(cwan))"
	zero; send_direct
	[ "$(cwan)" -ge 1 ] \
		&& ok "[$TUN] direct продолжает работать при мёртвом туннеле (c_wan=$(cwan))" \
		|| bad "[$TUN] direct сломался при мёртвом туннеле (c_wan=$(cwan))"
}

# scenario_travel — режим «в поездке»: весь трафик в туннель, kill-switch рубит любой выход в WAN.
scenario_travel() {
	TUN=$1
	trap cleanup_child EXIT
	build_topology "$TUN" travel

	hdr "TRAVEL / $TUN — весь трафик в туннель"
	zero; send_other
	{ [ "$(ctun)" -ge 1 ] && [ "$(cwan)" -eq 0 ]; } \
		&& ok "[travel] трафик → туннель, WAN чист (c_tun=$(ctun) c_wan=$(cwan))" \
		|| bad "[travel] трафик не в туннеле (c_tun=$(ctun) c_wan=$(cwan))"

	hdr "TRAVEL / $TUN — KILL-SWITCH (туннель УПАЛ)"
	ip route del 0.0.0.0/1 dev "$TUN"; ip route del 128.0.0.0/1 dev "$TUN"
	zero; send_other
	[ "$(cwan)" -eq 0 ] \
		&& ok "[travel] АНТИУТЕЧКА: при мёртвом туннеле ничего не утекло в WAN (c_wan=$(cwan))" \
		|| bad "[travel] УТЕЧКА в travel! (c_wan=$(cwan))"
}

# scenario_membership — РЕАЛЬНЫЙ dnsmasq: резолв direct-домена наполняет @direct, и маршрут уходит
# в WAN; непрямой домен в set НЕ попадает и идёт в туннель. Мост «домен→IP→set» (главный шрам v1).
# Требует dnsmasq + резолвер (nslookup/dig); нет — скип (в CI NETNS_REQUIRE=1 сделает фейлом).
scenario_membership() {
	TUN=awg0
	trap 'cleanup_child; [ -n "${UP_PID:-}" ] && kill "$UP_PID" 2>/dev/null; [ -n "${CB_PID:-}" ] && kill "$CB_PID" 2>/dev/null' EXIT

	resolver=""
	command -v nslookup >/dev/null 2>&1 && resolver="nslookup"
	[ -z "$resolver" ] && command -v dig >/dev/null 2>&1 && resolver="dig"
	if ! command -v dnsmasq >/dev/null 2>&1 || [ -z "$resolver" ]; then
		if [ "${NETNS_REQUIRE:-0}" = "1" ]; then
			bad "[membership] нет dnsmasq/resolver, а NETNS_REQUIRE=1"; return
		fi
		note "[membership] пропуск: нет dnsmasq и/или nslookup/dig (проверяется в CI)"; return
	fi
	# dnsmasq без nftset-поддержки (сборочный флаг) — не наш баг, а лимит окружения: честный
	# пропуск даже под NETNS_REQUIRE (иначе спутаем сборку дистрибутива с ошибкой data-plane).
	if dnsmasq --version 2>/dev/null | grep -qw 'no-nftset'; then
		note "[membership] пропуск: dnsmasq собран без nftset-поддержки (no-nftset)"; return
	fi
	# Rootless-namespace запрещает setgroups → dnsmasq не может сбросить привилегии и умирает
	# на старте (см. ветку NS_UNSHARE ниже). Это ограничение окружения, а не data-plane:
	# честный скип с ПРИЧИНОЙ, чтобы никто снова не искал баг в nftset. В CI джоб идёт под sudo.
	# ВАЖНО: внутри userns `id -u` == 0 ВСЕГДА (мы root в нём), поэтому «настоящий ли root»
	# определяет внешний диспетчер и передаёт сюда через NETNS_ROOTLESS — сам сценарий это
	# отличить не может.
	if [ "${NETNS_ROOTLESS:-0}" = "1" ]; then
		note "[membership] пропуск: нужен настоящий root (rootless netns запрещает setgroups,"
		note "             dnsmasq не стартует). Покрытие: CI под sudo + qemu-install."
		return
	fi

	build_topology "$TUN" home  # @direct пустой — его наполнит dnsmasq на резолве

	# Апстрим-резолвер (авторитетно отвечает на тестовые домены). Отдельный процесс — чтобы путь
	# был «форвард к апстриму», как в проде (dnsmasq наполняет nftset на форварднутом ответе).
	# Вывод dnsmasq НЕ глушим в /dev/null: если он не смог добавить IP в nftset (нет прав на
	# netlink, AppArmor, сборка без поддержки), он скажет об этом именно в stderr — а мы прежде
	# выбрасывали единственное объяснение и получали загадочный пустой сет (CLAUDE.md: «2>/dev/null
	# глушит причину»). Логи печатаем ТОЛЬКО при провале — в норме вывод не засоряется.
	UP_LOG="${TMPDIR:-/tmp}/netns-dnsmasq-upstream.log"
	CB_LOG="${TMPDIR:-/tmp}/netns-dnsmasq-cheburnet.log"
	# --pid-file В ПИСЧЕЕ МЕСТО — обязательно: сценарий живёт в rootless user-namespace (мы root
	# только внутри него), а /var/run принадлежит настоящему root. Дефолтный
	# /var/run/dnsmasq.pid → EACCES → dnsmasq УМИРАЕТ на старте, и @direct остаётся пустым.
	# Ровно на это тест и падал в CI с 17.07, выглядя как «dnsmasq не умеет nftset».
	# --log-facility=- : ВСЁ в stderr. Без него ошибки старта уходят в syslog, и наш лог пуст —
	# именно так «dnsmasq не стартовал» пришёл в CI без единой строки объяснения.
	dnsmasq -k -u root -p 5354 --no-resolv --no-hosts --bind-interfaces --listen-address=127.0.0.1 \
		--pid-file="${TMPDIR:-/tmp}/netns-dnsmasq-upstream.pid" --log-facility=- \
		--address=/directtest.example/203.0.113.77 \
		--address=/othertest.example/198.51.100.55 > "$UP_LOG" 2>&1 &
	UP_PID=$!
	# Наш dnsmasq: nftset-строку берём из РЕАЛЬНОГО вывода движка (render_dnsmasq).
	nftset_line=$(emit '{"what":"dnsmasq","domains":["directtest.example"],"routing_opts":{"ipv6":false}}')
	dnsmasq -k -u root -p 53 --no-resolv --no-hosts --bind-interfaces \
		--listen-address=10.0.0.1 --listen-address=127.0.0.1 \
		--pid-file="${TMPDIR:-/tmp}/netns-dnsmasq-cheburnet.pid" --log-facility=- \
		--server=127.0.0.1#5354 --nftset="$nftset_line" > "$CB_LOG" 2>&1 &
	CB_PID=$!
	sleep 0.5

	# Живость демонов проверяем ДО ассертов: мёртвый dnsmasq и рабочий-но-без-nftset дают
	# одинаково пустой сет, а диагнозы разные. Без этой проверки тест месяц врал про nftset.
	for d in "up:$UP_PID:$UP_LOG" "cheburnet:$CB_PID:$CB_LOG"; do
		name=${d%%:*}; rest=${d#*:}; pid=${rest%%:*}; log=${rest#*:}
		if ! kill -0 "$pid" 2>/dev/null; then
			# `wait` отдаёт код упавшего процесса, а под `set -e` это убило бы скрипт ДО печати
			# диагностики (ровно так предыдущая версия молчала). Поэтому `|| drc=$?`.
			drc=0; wait "$pid" 2>/dev/null || drc=$?
			hdr "MEMBERSHIP — реальный dnsmasq наполняет @direct на резолве"
			bad "[membership] dnsmasq ($name) не стартовал (код $drc) — сет заведомо пуст"
			printf '     лог:\n'; sed 's/^/       /' "$log" 2>/dev/null | tail -10
			return
		fi
	done

	resolve() { # resolve NAME → запрос к нашему dnsmasq (10.0.0.1) из клиента
		if [ "$resolver" = "nslookup" ]; then
			nsenter -t "$CPID" -n nslookup "$1" 10.0.0.1 >/dev/null 2>&1 || true
		else
			nsenter -t "$CPID" -n dig "@10.0.0.1" "$1" +short >/dev/null 2>&1 || true
		fi
	}

	hdr "MEMBERSHIP — реальный dnsmasq наполняет @direct на резолве"
	resolve directtest.example
	resolve othertest.example
	sleep 0.2
	setdump=$(nft list set inet fw4 direct)
	if echo "$setdump" | grep -q '203.0.113.77'; then
		ok "[membership] direct-домен зарезолвлен → IP в @direct (dnsmasq→nftset)"
	else
		bad "[membership] IP direct-домена НЕ попал в @direct: $setdump"
		# Диагностика ровно там, где она нужна: пустой сет сам по себе не отличает «dnsmasq не
		# умеет nftset» от «не смог применить» и от «наш nftset-аргумент не тот».
		printf '     nftset-аргумент движка: %s\n' "$nftset_line"
		printf '     dnsmasq compile options: %s\n' \
			"$(dnsmasq --version 2>/dev/null | sed -n 's/^Compile time options: //p')"
		printf '     лог нашего dnsmasq:\n'; sed 's/^/       /' "$CB_LOG" 2>/dev/null | tail -15
		printf '     лог апстрим-dnsmasq:\n'; sed 's/^/       /' "$UP_LOG" 2>/dev/null | tail -5
	fi
	echo "$setdump" | grep -q '198.51.100.55' \
		&& bad "[membership] непрямой домен ошибочно попал в @direct (лишнее исключение)" \
		|| ok "[membership] непрямой домен НЕ в @direct (исключён только direct-список)"

	# Мост замыкается на маршруте: пакет к зарезолвленному direct-IP уходит в WAN, к непрямому — в туннель.
	zero
	nsenter -t "$CPID" -n ping -c1 -W1 203.0.113.77 >/dev/null 2>&1 || true
	[ "$(cwan)" -ge 1 ] \
		&& ok "[membership] трафик к зарезолвленному direct-IP → WAN (домен→IP→set→маршрут)" \
		|| bad "[membership] direct-IP не ушёл в WAN (c_wan=$(cwan))"
	zero
	nsenter -t "$CPID" -n ping -c1 -W1 198.51.100.55 >/dev/null 2>&1 || true
	[ "$(ctun)" -ge 1 ] \
		&& ok "[membership] трафик к непрямому IP → туннель (c_tun=$(ctun))" \
		|| bad "[membership] непрямой IP распределён неверно (c_tun=$(ctun))"
}

# Диспетчер ре-exec: каждый сценарий — в своём свежем netns.
if [ "${1:-}" = "__run" ]; then
	case "$2" in
		home)       scenario_home "$3" ;;
		travel)     scenario_travel "$3" ;;
		membership) scenario_membership ;;
		*) echo "unknown scenario: $2" >&2; exit 2 ;;
	esac
	[ "$fail" -eq 0 ] || exit 1
	exit 0
fi

# =====================================  ПАР­ЕНТ  ============================================
require_or_skip

printf '\033[1mnetns data-plane тест — поведение split-routing после установки\033[0m\n'

# Чистая проверка (без netns): data-plane в ядре и на sing-box ИДЕНТИЧЕН — kill-switch/пометка не
# зависят ни от имени туннеля, ни от протокола (ключуются по WAN-oifname и метке пакета, БЕЗ портов).
# Это доказывает «туннель взаимозаменяем» и заодно то, что port hopping Hysteria2 не требует правок
# firewall-слоя: портов в правилах нет. Оба Full-протокола едут на singtun0, поэтому проверка
# awg0 vs singtun0 покрывает и Reality, и Hysteria2.
hdr "Идентичность data-plane (awg0 vs singtun0)"
nft_awg=$(emit '{"what":"nft","domains":["x.example"],"routing_opts":{"ipv6":false,"wan_if":"wan0","mode":"home"},"fw_opts":{"tunnel_if":"awg0"}}')
nft_rea=$(emit '{"what":"nft","domains":["x.example"],"routing_opts":{"ipv6":false,"wan_if":"wan0","mode":"home"},"fw_opts":{"tunnel_if":"singtun0"}}')
if [ "$nft_awg" = "$nft_rea" ]; then
	ok "nft-правила (пометка + kill-switch) идентичны для обоих протоколов"
else
	bad "nft-правила разошлись между awg0 и singtun0 — data-plane НЕ взаимозаменяем"
fi

# Поведенческие сценарии — каждый в свежем netns.
#
# ПОЧЕМУ ветка по root: rootless-namespace (`unshare -rn`) для маршрутов достаточен, но он
# ЗАПРЕЩАЕТ setgroups (ядро пишет deny в /proc/self/setgroups, иначе gid_map нельзя было бы
# заполнить без CAP_SETGID). dnsmasq при сбросе привилегий вызывает setgroups+setgid ОДНИМ
# условием — значит в rootless он не стартует НИКОГДА и печатает «failed to change group-id»,
# что месяц читалось как «dnsmasq не умеет nftset». Под настоящим root userns не нужен:
# `unshare -n` даёт netns без ограничения setgroups, и membership реально проверяется.
rc=0
if [ "$(id -u)" = "0" ]; then
	NS_UNSHARE="unshare -n"      # настоящий root: netns без userns → dnsmasq может сбросить права
	NETNS_ROOTLESS=0
else
	NS_UNSHARE="unshare -rn"     # обычный пользователь: rootless (маршрутные сценарии)
	NETNS_ROOTLESS=1             # membership пропустится с причиной: setgroups запрещён
fi
export NETNS_ROOTLESS
for spec in "home awg0" "home singtun0" "travel awg0" "membership -"; do
	# shellcheck disable=SC2086
	set -- $spec
	# shellcheck disable=SC2086
	$NS_UNSHARE sh "$SELF" __run "$1" "$2" || rc=1
done

hdr "ИТОГ"
if [ "$rc" -eq 0 ] && [ "$fail" -eq 0 ]; then
	printf '  \033[32mРазделение трафика и kill-switch подтверждены на реальном ядре\n'
	printf '  (форвард-путь, реальный вывод движка) — для AmneziaWG и Full-тира (singtun0).\033[0m\n'
	exit 0
fi
printf '  \033[31mЕсть провалы — смотри выше.\033[0m\n'
exit 1
