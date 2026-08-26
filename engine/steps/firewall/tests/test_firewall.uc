// test_firewall.uc — юнит-тесты data-plane шага. Фокус — содержимое kill-switch (security).
//   ucode -R engine/steps/firewall/tests/test_firewall.uc

import { test, eq, ok, deep_eq, summary } from "../../../lib/assert.uc";
import { build_plan } from "../../../routing/routing.uc";
import { build_firewall_plan, build_nat_ops, render_hotplug, HOTPLUG_PATH } from "../firewall.uc";

// routing-план с заданным WAN (v4-only для краткости, если не сказано иначе).
function rp(extra) {
	let o = { ipv6: false, wan_if: "eth0" };
	if (extra) for (let k in extra) o[k] = extra[k];
	return build_plan([ "example.com" ], o);
}

function has(arr, s) {
	for (let i = 0; i < length(arr); i++) if (arr[i] == s) return true;
	return false;
}

// --- kill-switch: HOME ---
test("HOME kill-switch: непомеченное в WAN → drop, по oifname (не по LAN-CIDR)", () => {
	let p = build_firewall_plan(rp(null), null);
	ok(p.ok);
	deep_eq(p.killswitch, [
		"oifname \"eth0\" meta mark != 0x1 ct state new drop",
	]);
	// LAN-подсеть нигде не упоминается — kill-switch от неё не зависит
	ok(index(p.nft_file, "192.168") < 0, "нет хардкода LAN-подсети");
});

// --- kill-switch: TRAVEL строже (нет direct-исключений) ---
test("TRAVEL kill-switch: всё в WAN → drop, без mark-исключения", () => {
	let p = build_firewall_plan(rp({ mode: "travel" }), null);
	deep_eq(p.killswitch, [
		"oifname \"eth0\" ct state new drop",
	]);
});

// --- wan_if обязателен, не хардкодим ---
test("без wan_if: план.ok=false, kill-switch не строится", () => {
	let plan = build_plan([ "example.com" ], { ipv6: false }); // wan_if не задан
	let p = build_firewall_plan(plan, null);
	ok(!p.ok, "должен отказать");
	eq(length(p.killswitch), 0);
	ok(length(p.errors) >= 1);
});

// --- динамический WAN прокидывается в правило ---
test("kill-switch использует переданный wan_if (динамический)", () => {
	let p = build_firewall_plan(rp({ wan_if: "wwan0" }), null);
	ok(has(p.killswitch, "oifname \"wwan0\" meta mark != 0x1 ct state new drop"));
});

// --- nftables.d-файл: путь + сеты + цепочки + правила (декларативно, для fw4-include) ---
test("nft_file: путь /etc/nftables.d, сеты, цепочка пометки, правило, ks-цепочка", () => {
	let p = build_firewall_plan(rp(null), null);
	eq(p.nft_path, "/etc/nftables.d/10-cheburnet.nft");
	ok(index(p.nft_file, "set direct { type ipv4_addr; flags interval; }") >= 0);
	ok(index(p.nft_file, "chain cheburnet_mark {") >= 0);
	ok(index(p.nft_file, "type filter hook prerouting priority mangle;") >= 0);
	ok(index(p.nft_file, "ip daddr @direct meta mark set 0x1") >= 0);
	ok(index(p.nft_file, "chain cheburnet_ks {") >= 0);
	ok(index(p.nft_file, "type filter hook forward priority filter;") >= 0);
	// декларативный формат fw4-include: без императивных `add` и без обёртки `table` (её ставит fw4)
	ok(index(p.nft_file, "add rule") < 0 && index(p.nft_file, "add chain") < 0, "нет императивных add-команд");
	ok(index(p.nft_file, "table inet fw4 {") < 0, "нет обёртки table (её ставит fw4)");
});

// --- nft teardown: fw4 reload не удаляет чужие цепочки/сеты — план снимает их явно ---
test("nft_teardown удаляет обе цепочки и оба сета (независимо от opts)", () => {
	let p = build_firewall_plan(rp(null), null);
	deep_eq(p.nft_teardown, [
		"delete chain inet fw4 cheburnet_mark",
		"delete chain inet fw4 cheburnet_ks",
		"delete set inet fw4 direct",
		"delete set inet fw4 direct6",
	]);
	// и при выключенном kill-switch список тот же: прошлая установка могла создать ks-цепочку
	let off = build_firewall_plan(rp(null), { killswitch: false });
	deep_eq(off.nft_teardown, p.nft_teardown);
});

// --- ip rule/route teardown+setup ---
test("ip setup из routing + teardown снимает правило и чистит таблицу", () => {
	let p = build_firewall_plan(rp(null), null);
	ok(has(p.ip_setup, "ip rule add fwmark 0x1 lookup 100"));
	ok(has(p.ip_setup, "ip route add default dev eth0 table 100"));
	ok(has(p.ip_teardown, "ip rule del fwmark 0x1 lookup 100"));
	ok(has(p.ip_teardown, "ip route flush table 100"));
});

// --- TRAVEL: нет ip-правил направления (всё в туннель main-таблицей) ---
test("TRAVEL: ip_setup и mark-правила пусты", () => {
	let p = build_firewall_plan(rp({ mode: "travel" }), null);
	deep_eq(p.ip_setup, []);
	ok(index(p.nft_file, "meta mark set") < 0, "правил пометки нет");
});

// --- IPv6: v6 сет/правило пометки появляются, ks остаётся одним inet-правилом ---
test("ipv6: добавляются v6 сет и правило пометки; ks по-прежнему одно", () => {
	let p = build_firewall_plan(build_plan([ "example.com" ], { ipv6: true, wan_if: "eth0" }), null);
	ok(index(p.nft_file, "set direct6 { type ipv6_addr; flags interval; }") >= 0);
	ok(index(p.nft_file, "ip6 daddr @direct6 meta mark set 0x1") >= 0);
	eq(length(p.killswitch), 1, "kill-switch — одно inet-правило на оба семейства");
	ok(has(p.ip_setup, "ip -6 rule add fwmark 0x1 lookup 100"));
});

// --- killswitch=false отключает ks (но пометка/маршрутизация остаются) ---
test("killswitch=false: ks-цепочки/правил нет, mark и ip остаются", () => {
	let p = build_firewall_plan(rp(null), { killswitch: false });
	eq(length(p.killswitch), 0);
	ok(index(p.nft_file, "cheburnet_ks") < 0);
	ok(index(p.nft_file, "ip daddr @direct meta mark set 0x1") >= 0);
});

// --- NAT-зона awg0: masq + forwarding lan→vpn (uci firewall, чистый откат) ---
test("build_nat_ops: именованные секции, masq, mtu_fix, forwarding lan→vpn", () => {
	let n = build_nat_ops({});
	// delete-before-set по именованным секциям → идемпотентность
	deep_eq(n.teardown, [ "delete firewall.cheburnet_vpn", "delete firewall.cheburnet_lan_vpn" ]);
	ok(has(n.setup, "set firewall.cheburnet_vpn=zone"));
	ok(has(n.setup, "set firewall.cheburnet_vpn.name='vpn'"));
	ok(has(n.setup, "add_list firewall.cheburnet_vpn.network='awg0'"));
	ok(has(n.setup, "set firewall.cheburnet_vpn.masq='1'"), "SNAT туннеля");
	ok(has(n.setup, "set firewall.cheburnet_vpn.mtu_fix='1'"), "MSS-clamp");
	ok(has(n.setup, "set firewall.cheburnet_lan_vpn=forwarding"));
	ok(has(n.setup, "set firewall.cheburnet_lan_vpn.src='lan'"));
	ok(has(n.setup, "set firewall.cheburnet_lan_vpn.dest='vpn'"));
});

test("build_nat_ops: имена интерфейса/зон переопределяемы (не хардкод)", () => {
	let n = build_nat_ops({ tunnel_if: "wg0", lan_zone: "guest", vpn_zone: "tun" });
	ok(has(n.setup, "add_list firewall.cheburnet_tun.network='wg0'"));
	ok(has(n.setup, "set firewall.cheburnet_guest_tun.src='guest'"));
	ok(has(n.setup, "set firewall.cheburnet_guest_tun.dest='tun'"));
});

test("build_firewall_plan: NAT включён по умолчанию, выключаем fw_opts.nat=false", () => {
	let on = build_firewall_plan(rp(null), null);
	ok(has(on.uci_setup, "set firewall.cheburnet_vpn.masq='1'"), "NAT в плане по умолчанию");
	deep_eq(on.uci_teardown, [ "delete firewall.cheburnet_vpn", "delete firewall.cheburnet_lan_vpn" ]);
	let off = build_firewall_plan(rp(null), { nat: false });
	deep_eq(off.uci_setup, [], "nat=false → нет uci-операций");
	deep_eq(off.uci_teardown, []);
});

// --- hotplug-хук: восстановление ip-части после перезагрузки ---
// РЕГРЕССИЯ живого прогона (2026-08-01): nft-часть переживала ребут файлом в /etc/nftables.d/, а
// `ip rule fwmark → table` и таблица direct — нет. Итог: панель зелёная, туннель поднят, наборы
// наполняются, а direct-домены идут В ТУННЕЛЬ, потому что направлять их стало нечем.
test("render_hotplug: реагирует на ifup и гейтит по ФАКТУ отсутствия правил", () => {
	let h = render_hotplug(100);
	ok(index(h, '[ "$ACTION" = "ifup" ] || exit 0') >= 0, "прочие события игнорируются");
	// Фильтра по имени интерфейса быть НЕ должно: имя WAN-логики бывает не «wan» (wwan, wan_4),
	// и там хук молча не срабатывал бы. Вместо имени — дешёвая проверка наличия правила.
	ok(index(h, '"$INTERFACE"') < 0, "не завязываемся на имя интерфейса");
	ok(index(h, "grep -q fwmark") >= 0, "повторные срабатывания почти бесплатны");
	// ОБА артефакта: при первом ifup WAN может быть не готов, и остаётся половина (правило без
	// маршрута). Гейт только по правилу закрывал бы путь к починке навсегда.
	ok(index(h, "route show table 100") >= 0, "маршрут таблицы direct тоже проверяется");
});

test("render_hotplug: логику НЕ дублирует, зовёт reapply.uc", () => {
	let h = render_hotplug(100);
	ok(index(h, "install/reapply.uc") >= 0, "одна реализация на ребут и на откат");
	// Единственное упоминание ip rule — дешёвый гейт «правило уже на месте»; СОБИРАТЬ правила
	// хук не должен: их состав знает движок (метка, номер таблицы, шлюз WAN).
	ok(index(h, "ip rule add") < 0, "хук не конструирует правила сам");
	ok(index(h, "ip route add") < 0, "маршрут хук тоже не конструирует");
	ok(index(h, "#!/bin/sh") == 0, "исполняемый POSIX-скрипт");
});

test("build_firewall_plan: хук лежит в плане, номер таблицы — из плана routing", () => {
	let p = build_firewall_plan(rp(null), null);
	ok(index(p.hotplug_file, "table 100") >= 0, "номер таблицы подставлен движком, не зашит в хук");
	eq(p.hotplug_path, HOTPLUG_PATH);
	eq(p.hotplug_path, "/etc/hotplug.d/iface/99-cheburnet", "каталог netifd-событий");
	ok(length(p.hotplug_file) > 0);
});

// `ip rule add` не идемпотентен: без снятия повторное применение плодит дубли правил, и
// диагностика «кто владеет маршрутом» превращается в гадание.
test("ip_teardown снимает и правило резервного DNS (иначе дубли при переприменении)", () => {
	let plan = build_firewall_plan(build_plan([], { wan_if: "eth0", dns_uid: 101 }), null);
	let td = join("\n", plan.ip_teardown);
	ok(index(td, "ip rule del uidrange 101-101 lookup 100") >= 0);
	ok(index(td, "ip -6 rule del uidrange 101-101 lookup 100") >= 0);
});

test("без dns_uid teardown правила uidrange не содержит", () => {
	let plan = build_firewall_plan(build_plan([], { wan_if: "eth0" }), null);
	ok(index(join("\n", plan.ip_teardown), "uidrange") < 0);
});

// Гейт хука — то место, где «правило есть» пропускало ПРОТУХШИЙ маршрут: шлюз/интерфейс WAN
// сменился, правило целое, дефолт в таблице есть — а direct-сайты мертвы, и чинить некому.
test("hotplug-гейт сверяет маршрут таблицы с ТЕКУЩИМ WAN, а не с «хоть каким-то»", () => {
	let plan = build_firewall_plan(build_plan([], { wan_if: "eth0" }), { tunnel_if: "awg0" });
	let h = plan.hotplug_file;
	ok(index(h, "ip -4 route show default") >= 0, "текущий WAN берётся из ядра, а не из install.json");
	ok(index(h, "grep -v ' dev awg0'") >= 0, "туннель за WAN не считаем");
	ok(index(h, "\"$cur\" = \"$tab\"") >= 0, "сравнение, а не проверка наличия");
	ok(index(h, "grep -q fwmark") >= 0, "правило направления тоже обязано быть");
	ok(index(h, "reapply.uc") >= 0, "не сошлось — зовём переприменение");
});

// В travel правил направления нет ПО ЗАМЫСЛУ (render_iprules пуст) — гейт по fwmark никогда не
// сходился, и хук переприменял firewall (uci commit + fw4 reload + ip flush) на КАЖДЫЙ ifup любого
// интерфейса. Целостность «поездки» — kill-switch в ядре, по нему и гейтим.
test("hotplug-гейт в travel: по kill-switch в ядре, а не по правилу fwmark (его там нет)", () => {
	let plan = build_firewall_plan(build_plan([], { wan_if: "eth0", mode: "travel" }), null);
	let h = plan.hotplug_file;
	ok(index(h, "grep -q fwmark") < 0, "правила направления в travel не бывает — по нему не гейтим");
	ok(index(h, "nft list chain inet fw4 cheburnet_ks") >= 0, "имя цепочки — из плана, не хардкод хука");
	ok(index(h, "grep -q drop") >= 0, "пустая цепочка после fw4 reload — не «на месте»");
	ok(index(h, "reapply.uc") >= 0, "не сошлось — зовём переприменение");
	let home = build_firewall_plan(build_plan([], { wan_if: "eth0", mode: "home" }), null).hotplug_file;
	ok(index(home, "grep -q fwmark") >= 0, "home-гейт не тронут");
});

// Установка/замена сервера сама двигает сеть (network reload → ifup): хук, запустивший reapply.uc
// параллельно с шагами run.uc, применял бы firewall дважды и вразнобой.
test("hotplug-хук молчит, пока идёт длинная операция движка (pid-файл + done-маркер ubus-слоя)", () => {
	let h = render_hotplug(100);
	ok(index(h, "/tmp/cheburnet/pid") >= 0 && index(h, "/tmp/cheburnet/done") >= 0,
		"та же конвенция занятости, что у rpcd и сторожа");
	ok(index(h, 'kill -0 "$p"') >= 0 && index(h, '[ -n "$p" ]') >= 0,
		"пустой pid отсекаем ДО kill: busybox kill -0 '' = сигнал своей группе = ложное «занято»");
});

// ШРАМ (qemu-emergency, 2026-08-26): в travel teardown был пуст — после home→travel правила
// fwmark/uidrange оставались в ядре, и «в поездке мимо туннеля не уходит ничего» было ложью.
test("travel: teardown снимает правила направления прежнего режима, setup ничего не ставит", () => {
	let plan = build_firewall_plan(build_plan([], { wan_if: "eth0", mode: "travel", dns_uid: 101 }), null);
	let td = join("\n", plan.ip_teardown);
	ok(index(td, "ip rule del fwmark 0x1 lookup 100") >= 0, "правило направления home снимается");
	ok(index(td, "ip rule del uidrange 101-101 lookup 100") >= 0, "резервный DNS в поездке мимо туннеля не ходит");
	ok(index(td, "ip route flush table 100") >= 0);
	deep_eq(plan.ip_setup, [], "в travel правил направления нет по замыслу");
});

exit(summary());
