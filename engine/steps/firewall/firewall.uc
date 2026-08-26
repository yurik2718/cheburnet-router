// firewall.uc — data-plane шаг: пометка direct-трафика, policy routing и kill-switch.
// build_firewall_plan(routing_plan, opts) → чистый план (nft-файл, ip- и uci-команды);
// apply.uc применяет на роутере. Подробно: [[policy-routing]], [[kill-switch]]. Тесты: tests/.

import { render_iprules } from "../../routing/routing.uc";

const NFT_PATH = "/etc/nftables.d/10-cheburnet.nft";
// ИНВАРИАНТ: наши цепочки/сеты живут в /etc/nftables.d/, не инъекцией `nft add` — fw4 включает
// файл в table inet fw4 при каждом reload, поэтому reload их не стирает. Подробно: [[kill-switch]].
const HOTPLUG_PATH = "/etc/hotplug.d/iface/99-cheburnet";

const FW_DEFAULTS = {
	mark_chain: "cheburnet_mark",
	ks_chain: "cheburnet_ks",
	killswitch: true,
	nat: true, // зона masq на awg0 + forwarding lan→vpn, см. build_nat_ops
	tunnel_if: "awg0", // интерфейс туннеля (совпадает с vpn-шагом)
	lan_zone: "lan",   // имя LAN-зоны fw4; forwarding по ИМЕНИ зоны, не по CIDR
	vpn_zone: "vpn",
};

function resolve_opts(opts) {
	let o = {};
	for (let k in FW_DEFAULTS) o[k] = FW_DEFAULTS[k];
	if (opts) for (let k in opts) if (exists(FW_DEFAULTS, k)) o[k] = opts[k];
	return o;
}

// chain_names(opts?) → имена наших nft-цепочек [пометка, kill-switch]. Единственный источник для
// тех, кто их ПРОВЕРЯЕТ (invariants/gather), а не строит — не дрейфует при переименовании.
function chain_names(opts) {
	let o = resolve_opts(opts);
	return [ o.mark_chain, o.ks_chain ];
}

// build_nat_ops(opts) → { teardown, setup }: uci-зона туннеля (masq+mtu_fix) + forwarding lan→vpn.
// Именованные секции, идемпотентно (delete-before-set). Чистый uci-конфиг (∈ CLEAN_CONFIGS,
// откатывается snapshot'ом), в отличие от nft/ip ниже — применять ДО nft-инъекции (apply.uc).
//   masq=1 — SNAT LAN→awg0 (без него обратный путь не находится); mtu_fix=1 — MSS-clamp под MTU
//   туннеля; input REJECT — снаружи по туннелю в роутер не лезут.
function build_nat_ops(opts) {
	let o = opts ?? {};
	let tif  = o.tunnel_if ?? "awg0";
	let lan  = o.lan_zone ?? "lan";
	let zone = o.vpn_zone ?? "vpn";
	let zsect = "cheburnet_" + zone;
	let fsect = "cheburnet_" + lan + "_" + zone;

	let teardown = [
		sprintf("delete firewall.%s", zsect),
		sprintf("delete firewall.%s", fsect),
	];
	let setup = [
		sprintf("set firewall.%s=zone", zsect),
		sprintf("set firewall.%s.name='%s'", zsect, zone),
		sprintf("add_list firewall.%s.network='%s'", zsect, tif),
		sprintf("set firewall.%s.masq='1'", zsect),
		sprintf("set firewall.%s.mtu_fix='1'", zsect),
		sprintf("set firewall.%s.input='REJECT'", zsect),
		sprintf("set firewall.%s.output='ACCEPT'", zsect),
		sprintf("set firewall.%s.forward='REJECT'", zsect),
		sprintf("set firewall.%s=forwarding", fsect),
		sprintf("set firewall.%s.src='%s'", fsect, lan),
		sprintf("set firewall.%s.dest='%s'", fsect, zone),
	];
	return { teardown: teardown, setup: setup };
}

// render_nft_file(routing_plan, o) → содержимое /etc/nftables.d/10-cheburnet.nft.
// Формат — тело, которое fw4 включает ВНУТРЬ table inet fw4 (без обёртки table и без `add`):
// декларативные `set …` и `chain …` с правилами. Возвращает { content, killswitch }.
// killswitch отдаём отдельно (список ks-правил) — для юнит-проверки security-семантики.
function render_nft_file(routing_plan, o) {
	let ro = routing_plan.opts;
	let wan = ro.wan_if, mark = ro.mark;
	let L = [
		"# cheburnet: пометка direct-трафика + kill-switch (см. firewall.uc).",
		"# fw4 включает этот файл в table inet fw4 при каждом reload — правила переживают reload.",
		sprintf("set %s { type ipv4_addr; flags interval; }", ro.set4),
	];
	if (ro.ipv6)
		push(L, sprintf("set %s { type ipv6_addr; flags interval; }", ro.set6));

	// Цепочка пометки (prerouting/mangle): daddr ∈ direct → mark. В travel правил нет.
	push(L, sprintf("chain %s {", o.mark_chain));
	push(L, "\ttype filter hook prerouting priority mangle; policy accept;");
	if (ro.mode != "travel") {
		push(L, sprintf("\tip daddr @%s meta mark set %s", ro.set4, mark));
		if (ro.ipv6)
			push(L, sprintf("\tip6 daddr @%s meta mark set %s", ro.set6, mark));
	}
	push(L, "}");

	// kill-switch (forward/filter): ct state new рубит только новые соединения мимо туннеля,
	// established проходит. AWG-handshake — output роутера, не forward, поэтому не задет.
	let ks = [];
	if (o.killswitch && wan) {
		if (ro.mode == "travel")
			push(ks, sprintf("oifname \"%s\" ct state new drop", wan));
		else
			push(ks, sprintf("oifname \"%s\" meta mark != %s ct state new drop", wan, mark));
		push(L, sprintf("chain %s {", o.ks_chain));
		push(L, "\ttype filter hook forward priority filter; policy accept;");
		for (let i = 0; i < length(ks); i++)
			push(L, "\t" + ks[i]);
		push(L, "}");
	}

	return { content: join("\n", L) + "\n", killswitch: ks };
}

// render_hotplug(table, tunnel_if, mode?, ks_chain?) → текст hotplug-хука (POSIX sh, busybox-ash).
// ШРАМ: ip-часть data-plane живёт только в ядре и не переживает ребут — split молча уходит в
// туннель при зелёной панели. Хук зовёт reapply.uc на ifup ЛЮБОГО интерфейса (имя WAN-логики в
// netifd не гарантировано). Гейт «всё на месте» сверяет маршрут таблицы с ТЕКУЩИМ WAN (прежний
// пропускал протухший маршрут) и ждёт ОБА артефакта. В travel правил направления нет по замыслу —
// там целостность = kill-switch в ядре; гейт по fwmark заставлял бы переприменять на каждый ifup.
function render_hotplug(table, tunnel_if, mode, ks_chain) {
	let tun = tunnel_if ?? "awg0";
	let gate = (mode == "travel")
		? [ "# В поездке правил направления нет по замыслу: целостность — kill-switch в ядре.",
		    sprintf("if nft list chain inet fw4 %s 2>/dev/null | grep -q drop; then", ks_chain ?? "cheburnet_ks"),
		    "\texit 0",
		    "fi" ]
		: [ "# Текущий WAN — первый дефолт МИМО туннеля; и с ним сверяем маршрут direct-таблицы.",
		    sprintf("cur=$(ip -4 route show default 2>/dev/null | grep -v ' dev %s' | \\", tun),
		    "      sed -n 's/.* dev \\([^ ]*\\).*/\\1/p' | head -1)",
		    sprintf("tab=$(ip route show table %d 2>/dev/null | grep '^default' | \\", table),
		    "      sed -n 's/.* dev \\([^ ]*\\).*/\\1/p' | head -1)",
		    "# Всё сходится — выходим сразу (дешёвый путь на каждый ifup).",
		    "if ip rule show 2>/dev/null | grep -q fwmark && \\",
		    '   [ -n "$cur" ] && [ "$cur" = "$tab" ]; then',
		    "\texit 0",
		    "fi" ];
	let head = [
		"#!/bin/sh",
		"# cheburnet: вернуть ip-часть data-plane (policy-routing) — она живёт только в ядре.",
		"# Файл создаёт шаг firewall; правки перезапишутся при следующем применении.",
		'[ "$ACTION" = "ifup" ] || exit 0',
		"# Идёт установка/замена сервера — она сама двигает сеть (pid-файл + done-маркер ubus-слоя).",
		'p=$(cat /tmp/cheburnet/pid 2>/dev/null)',
		'if [ ! -f /tmp/cheburnet/done ] && [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then',
		"\texit 0",
		"fi",
	];
	let tail = [
		"ucode -R /usr/share/cheburnet/engine/install/reapply.uc >/dev/null 2>&1",
		"exit 0",
	];
	return join("\n", head) + "\n" + join("\n", gate) + "\n" + join("\n", tail) + "\n";
}

// build_firewall_plan(routing_plan, opts) → структурный план (nft/ip/uci).
// ИНВАРИАНТ: kill-switch ключуется по oifname WAN, не по LAN-CIDR (хардкод CIDR — тихо-дырявый
// kill-switch на нестандартной подсети, урок v1). wan_if — из routing_plan.opts, не хардкод.
function build_firewall_plan(routing_plan, opts) {
	let o = resolve_opts(opts);
	let ro = routing_plan.opts;
	let wan = ro.wan_if;
	let errors = [];

	if (o.killswitch && !wan)
		push(errors, "нет wan_if: kill-switch не построить без WAN-интерфейса (не хардкодим)");

	let nft = render_nft_file(routing_plan, o);

	// policy routing: правило fwmark + default в table через WAN (из routing). Teardown — снять
	// правила и очистить таблицу; НЕ зависит от режима: он снимает то, что оставил ПРЕЖНИЙ режим.
	// ШРАМ (qemu-emergency, 2026-08-26): в travel teardown был пуст → после home→travel правила
	// fwmark/uidrange оставались в ядре, и резервный DNS ходил мимо туннеля «в поездке».
	let ip_setup = render_iprules(routing_plan);
	let ip_teardown = [
		sprintf("ip rule del fwmark %s lookup %d", ro.mark, ro.table),
	];
	if (ro.ipv6)
		push(ip_teardown, sprintf("ip -6 rule del fwmark %s lookup %d", ro.mark, ro.table));
	// Правило резервного DNS снимаем ВСЕГДА, когда знаем uid: `ip rule add` не идемпотентен.
	if (ro.dns_uid != null) {
		push(ip_teardown, sprintf("ip rule del uidrange %d-%d lookup %d", ro.dns_uid, ro.dns_uid, ro.table));
		if (ro.ipv6)
			push(ip_teardown, sprintf("ip -6 rule del uidrange %d-%d lookup %d", ro.dns_uid, ro.dns_uid, ro.table));
	}
	push(ip_teardown, sprintf("ip route flush table %d", ro.table));
	if (ro.ipv6)
		push(ip_teardown, sprintf("ip -6 route flush table %d", ro.table));

	// NAT-зона туннеля (uci firewall, чистый откат). Выключаемо через fw_opts.nat=false.
	let nat = o.nat ? build_nat_ops(o) : { teardown: [], setup: [] };

	// ШРАМ (smoke): fw4 reload не удаляет чужие цепочки/сеты из inet fw4 — после unlink файла
	// остаются пустые hooked-цепочки. Снимаем явно, все 4 имени (могла создать прошлая установка).
	let nft_teardown = [
		sprintf("delete chain inet fw4 %s", o.mark_chain),
		sprintf("delete chain inet fw4 %s", o.ks_chain),
		sprintf("delete set inet fw4 %s", ro.set4),
		sprintf("delete set inet fw4 %s", ro.set6),
	];

	return {
		ok: length(errors) == 0,
		errors: errors,
		uci_teardown: nat.teardown,
		uci_setup: nat.setup,
		nft_path: NFT_PATH,
		nft_file: nft.content,
		hotplug_path: HOTPLUG_PATH,
		hotplug_file: render_hotplug(ro.table, o.tunnel_if, ro.mode, o.ks_chain),
		nft_teardown: nft_teardown,
		ip_teardown: ip_teardown,
		ip_setup: ip_setup,
		killswitch: nft.killswitch,
	};
}

export { NFT_PATH, HOTPLUG_PATH, chain_names, build_nat_ops, render_nft_file, render_hotplug, build_firewall_plan };
