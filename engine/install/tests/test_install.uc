// test_install.uc — юнит-тесты политики оркестрации установки. Без роутера.
//   ucode -R engine/install/tests/test_install.uc

import { test, eq, ok, deep_eq, summary } from "../../lib/assert.uc";
import { pick_wan_fallback } from "../../lib/route.uc";
import { route_uses_iface, fresh_handshake,
         enabled_steps, snapshot_scope, dirty_steps,
         decide_outcome, protocol_ids, default_protocol, tunnel_info, tunnel_ifs,
         uses_singbox, tunnel_conf,
         disabled_tunnels, handshake_state, tunnel_health,
         HANDSHAKE_FRESH_S } from "../install.uc";

function names(steps) {
	let out = [];
	for (let i = 0; i < length(steps); i++) push(out, steps[i].name);
	return out;
}

test("порядок шагов: vpn → singbox → dns → doh → wifi → firewall (firewall последним)", () => {
	deep_eq(names(enabled_steps({})), [ "vpn", "singbox", "dns", "doh", "wifi", "firewall" ]);
});

test("enabled_steps: disable убирает шаг, порядок сохраняется", () => {
	let s = enabled_steps({ disable: [ "singbox", "doh" ] });
	deep_eq(names(s), [ "vpn", "dns", "wifi", "firewall" ]);
});

test("enabled_steps возвращает копию (мутация не ломает реестр)", () => {
	let a = enabled_steps({});
	a[0].name = "HACKED";
	push(a[0].configs, "x");
	let b = enabled_steps({});
	eq(b[0].name, "vpn");
	deep_eq(b[0].configs, [ "network" ]);
});

test("snapshot_scope: объединение чистых конфигов, дедуп; uci-часть dirty-шага входит", () => {
	let scope = snapshot_scope(enabled_steps({}));
	// dhcp у dns/doh → один раз; singbox вносит sing-box (uci-часть — чистый откат); wifi —
	// wireless; firewall (dirty) — uci 'firewall' (NAT-зона), его nft/ip-часть — teardown, не snapshot
	deep_eq(scope, [ "network", "sing-box", "dhcp", "https-dns-proxy", "wireless", "firewall" ]);
});

test("snapshot_scope: reality-протокол (vpn off, singbox on) → sing-box + network (маршрут в туннель)", () => {
	// reality: disable vpn (через disabled_tunnels), остаётся singbox. Его configs — sing-box И
	// network (netifd-маршрут в singtun): обе uci-части откатываются snapshot'ом (гибридный шаг).
	let scope = snapshot_scope(enabled_steps({ disable: [ "vpn" ] }));
	deep_eq(scope, [ "sing-box", "network", "dhcp", "https-dns-proxy", "wireless", "firewall" ]);
});

test("dirty_steps: singbox + firewall (runtime config.json/nft/ip → safe-fail teardown)", () => {
	deep_eq(dirty_steps(enabled_steps({})), [ "singbox", "firewall" ]);
});

// КРИТИЧНО для чистой смены протокола: перед шагами run.uc делает teardown НЕактивного туннеля
// (awg0 при reality и наоборот) — он мутирует network. Значит network ОБЯЗАН быть в snapshot-
// scope при ЛЮБОМ активном протоколе, иначе откат не вернёт снятый туннель. Проверяем оба.
test("snapshot_scope: network защищён при обоих протоколах (иначе смена протокола не откатна)", () => {
	let awg = snapshot_scope(enabled_steps({ disable: disabled_tunnels("awg") }));
	ok(index(awg, "network") >= 0, "awg: network в снимке (vpn.configs)");
	let reality = snapshot_scope(enabled_steps({ disable: disabled_tunnels("reality") }));
	ok(index(reality, "network") >= 0, "reality: network в снимке (singbox.configs)");
});

// Teardown неактивного туннеля адресуется по имени ШАГА (vpn/singbox) — у обоих есть --teardown.
// Если сюда попадёт не-туннельный шаг, run.uc дёрнул бы у него несуществующий режим.
test("disabled_tunnels возвращает только туннель-шаги (у них есть --teardown)", () => {
	let protos = protocol_ids();
	for (let i = 0; i < length(protos); i++) {
		let dt = disabled_tunnels(protos[i]);
		for (let j = 0; j < length(dt); j++)
			ok(index([ "vpn", "singbox" ], dt[j]) >= 0,
				sprintf("%s: '%s' — туннель-шаг", protos[i], dt[j]));
	}
});

// --- модель протокола (три оси покрытия, ADR 0004) ---
test("protocol_ids / default_protocol: awg (дефолт), reality, hysteria2", () => {
	deep_eq(protocol_ids(), [ "awg", "reality", "hysteria2" ]);
	eq(default_protocol(), "awg", "дефолт — лёгкий туннель в ядре, а не userspace");
});

test("tunnel_info: шаг, интерфейс и conf_key каждого протокола; неизвестный → дефолт", () => {
	deep_eq(tunnel_info("awg"), { step: "vpn", tunnel_if: "awg0", conf_key: "awg_conf" });
	deep_eq(tunnel_info("reality"),
		{ step: "singbox", tunnel_if: "singtun0", conf_key: "reality_conf" });
	deep_eq(tunnel_info("hysteria2"),
		{ step: "singbox", tunnel_if: "singtun0", conf_key: "hysteria2_conf" });
	deep_eq(tunnel_info("bogus"), { step: "vpn", tunnel_if: "awg0", conf_key: "awg_conf" },
		"fail-safe на дефолт");
});

// КЛЮЧЕВОЙ инвариант ADR 0004: оба Full-протокола делят ОДИН туннельный интерфейс. Разъедься
// они — firewall/policy-routing/NAT-зона перестали бы быть протокол-независимыми.
test("оба sing-box-протокола презентуют ОДИН интерфейс (data-plane их не различает)", () => {
	eq(tunnel_info("reality").tunnel_if, tunnel_info("hysteria2").tunnel_if);
	eq(tunnel_info("reality").step, tunnel_info("hysteria2").step);
});

test("uses_singbox: Full-протоколы определяются по ШАГУ, не по списку имён", () => {
	ok(!uses_singbox("awg"), "awg считается в ядре");
	ok(uses_singbox("reality"));
	ok(uses_singbox("hysteria2"));
	ok(!uses_singbox("bogus"), "неизвестный → дефолтный awg → не Full (fail-safe)");
});

test("tunnel_ifs: интерфейсы всех туннелей без дублей (оба Full-протокола — один singtun0)", () => {
	deep_eq(tunnel_ifs(), [ "awg0", "singtun0" ], "по нему lib/wan.uc ищет WAN «мимо туннелей»");
});

test("tunnel_conf: конфиг берётся по conf_key активного протокола", () => {
	let cfg = { awg_conf: "AWG", reality_conf: "vless://x", hysteria2_conf: "hy2://y" };
	eq(tunnel_conf("awg", cfg), "AWG");
	eq(tunnel_conf("reality", cfg), "vless://x");
	eq(tunnel_conf("hysteria2", cfg), "hy2://y");
	eq(tunnel_conf("hysteria2", {}), "", "нет ключа → пусто (шаг честно упадёт, а не возьмёт чужой)");
	eq(tunnel_conf("reality", { reality_conf: 42 }), "", "не строка → пусто");
	eq(tunnel_conf("bogus", cfg), "AWG", "неизвестный протокол → ключ дефолтного");
});

test("disabled_tunnels: отключает неактивный туннель-шаг (взаимоисключение)", () => {
	deep_eq(disabled_tunnels("awg"), [ "singbox" ], "awg → singbox off");
	deep_eq(disabled_tunnels("reality"), [ "vpn" ], "reality → vpn off");
	deep_eq(disabled_tunnels("hysteria2"), [ "vpn" ], "hysteria2 → vpn off (шаг тот же, что у reality)");
});

test("enabled_steps: awg-протокол (disable singbox) → туннель = vpn", () => {
	let s = enabled_steps({ disable: disabled_tunnels("awg") });
	deep_eq(names(s), [ "vpn", "dns", "doh", "wifi", "firewall" ]);
});

test("enabled_steps: reality/hysteria2 (disable vpn) → туннель = singbox", () => {
	deep_eq(names(enabled_steps({ disable: disabled_tunnels("reality") })),
		[ "singbox", "dns", "doh", "wifi", "firewall" ]);
	deep_eq(names(enabled_steps({ disable: disabled_tunnels("hysteria2") })),
		[ "singbox", "dns", "doh", "wifi", "firewall" ], "новый протокол не добавляет шагов");
});

// --- decide_outcome ---
test("decide: нет/проваленный preflight → abort (ничего не трогали)", () => {
	eq(decide_outcome({ preflight: { ok: false } }).action, "abort");
	eq(decide_outcome({ preflight: { ok: false } }).code, "preflight");
	eq(decide_outcome({}).action, "abort");
	eq(decide_outcome(null).action, "abort");
});

test("decide: упавший шаг → rollback + список failed + code первого упавшего", () => {
	let d = decide_outcome({
		preflight: { ok: true },
		steps: [ { name: "vpn", ok: true }, { name: "dns", ok: false }, { name: "doh", ok: false } ],
	});
	eq(d.action, "rollback");
	deep_eq(d.failed, [ "dns", "doh" ]);
	eq(d.code, "step:dns"); // адресная диагностика UI — по ПЕРВОМУ упавшему (fail-fast)
});

test("decide: все шаги ок, health провалился (старый/минимальный health) → rollback, code=health", () => {
	let d = decide_outcome({
		preflight: { ok: true },
		steps: [ { name: "vpn", ok: true } ],
		health: { ok: false }, // нет dns_ok/tun_ok — не с чем адресовать точнее
	});
	eq(d.action, "rollback");
	eq(d.code, "health"); // UI по этому коду говорит «VPN-сервер не ответил», не «упал шаг»
	ok(index(d.reason, "health") >= 0);
});

// --- decide_outcome: адресный health-код (DNS и туннель — разные поломки, разный совет в UI) ---
test("decide: упал только DNS (туннель ok) → code=health:dns", () => {
	let d = decide_outcome({
		preflight: { ok: true },
		steps: [ { name: "singbox", ok: true } ],
		health: { ok: false, dns_ok: false, tun_ok: true, tun_reason: null },
	});
	eq(d.code, "health:dns");
});

test("decide: упал туннель с reason → code=health:tunnel:<reason>, даже если DNS тоже упал", () => {
	for (let reason in [ "process", "route", "fetch" ]) {
		let d = decide_outcome({
			preflight: { ok: true },
			steps: [ { name: "singbox", ok: true } ],
			health: { ok: false, dns_ok: false, tun_ok: false, tun_reason: reason },
		});
		eq(d.code, "health:tunnel:" + reason, "туннель-причина приоритетнее DNS — она обычно и есть корень");
	}
});

test("decide: туннель упал без reason (awg: просто нет рукопожатия) → code=health:tunnel:fetch (дефолт)", () => {
	let d = decide_outcome({
		preflight: { ok: true },
		steps: [ { name: "vpn", ok: true } ],
		health: { ok: false, dns_ok: true, tun_ok: false, tun_reason: null },
	});
	eq(d.code, "health:tunnel:fetch");
});

test("decide: всё ок → commit", () => {
	let d = decide_outcome({
		preflight: { ok: true },
		steps: [ { name: "vpn", ok: true }, { name: "firewall", ok: true } ],
		health: { ok: true },
	});
	eq(d.action, "commit");
	deep_eq(d.failed, []);
});

test("decide: шаги ок, health не дошёл (null) → commit", () => {
	let d = decide_outcome({
		preflight: { ok: true },
		steps: [ { name: "vpn", ok: true } ],
		health: null,
	});
	eq(d.action, "commit");
});

// --- handshake_state (fix #2: health-check поллит рукопожатие, а не валит мгновенно) ---
test("handshake_state: пустой вывод → none (vpn не настраивался — health не валим)", () => {
	eq(handshake_state(""), "none");
	eq(handshake_state("  \n "), "none");
	eq(handshake_state(null), "none");
});

test("handshake_state: peer есть, рукопожатия ещё нет ('\\t0') → waiting (поллить дальше)", () => {
	// именно этот кейс ловил баг: мгновенная проверка видела waiting и откатывала установку
	eq(handshake_state("dCtNRb28Iu+YT2OWBnfFQTXJ79C4NhWeQTU5+hV3zG8=\t0"), "waiting");
});

test("handshake_state: peer с ненулевым timestamp → up", () => {
	eq(handshake_state("dCtNRb28Iu+YT2OWBnfFQTXJ79C4NhWeQTU5+hV3zG8=\t1782814714"), "up");
	// timestamp, оканчивающийся на 0 (не '\t0'), — рукопожатие было, не ложный waiting
	eq(handshake_state("AAA=\t1782814710"), "up");
});

test("handshake_state: несколько peer — любой с ненулевым timestamp → up", () => {
	eq(handshake_state("AAA=\t0\nBBB=\t0"), "waiting", "ни один peer не сделал рукопожатие");
	eq(handshake_state("AAA=\t1782814700\nBBB=\t0"), "up", "первый peer с рукопожатием");
	eq(handshake_state("AAA=\t0\nBBB=\t1782814700"), "up", "второй peer с рукопожатием");
});

// --- tunnel_health: ОДИН признак здоровья для обоих протоколов (панель) ---
// Регресс, который это чинит: панель судила о туннеле по AWG-рукопожатию, поэтому на РАБОЧЕМ
// Reality (где awg0 не существует) показывала «VPN не работает» и вела заменять AWG-конфиг.
test("tunnel_health awg: свежее рукопожатие → up, нет/старое → down", () => {
	eq(tunnel_health("awg", { hs_age: 12 }), "up");
	eq(tunnel_health("awg", { hs_age: 0 }), "up", "только что — тоже up");
	eq(tunnel_health("awg", { hs_age: HANDSHAKE_FRESH_S - 1 }), "up", "граница окна изнутри");
	eq(tunnel_health("awg", { hs_age: HANDSHAKE_FRESH_S }), "down", "ровно окно — уже несвежо");
	eq(tunnel_health("awg", { hs_age: null }), "down", "сервер не отвечал ни разу");
	eq(tunnel_health("awg", {}), "down", "фактов нет → не выдаём за рабочий (fail-safe)");
});

test("tunnel_health awg: живой sing-box НЕ делает AWG здоровым (признаки не путаются)", () => {
	eq(tunnel_health("awg", { hs_age: null, sb_running: true, tun_up: true }), "down");
});

test("tunnel_health reality: процесс + TUN → up; что-то одно упало → down", () => {
	eq(tunnel_health("reality", { sb_running: true, tun_up: true }), "up");
	eq(tunnel_health("reality", { sb_running: true, tun_up: false }), "down", "процесс жив, TUN нет");
	eq(tunnel_health("reality", { sb_running: false, tun_up: true }), "down", "TUN остался, процесс мёртв");
	eq(tunnel_health("reality", {}), "down");
});

test("tunnel_health reality: отсутствие AWG-рукопожатия его НЕ роняет (суть бага)", () => {
	eq(tunnel_health("reality", { hs_age: null, sb_running: true, tun_up: true }), "up",
		"у VLESS рукопожатия нет — это не признак поломки");
});

// Инвариант ADR 0004: Hysteria2 НЕ приносит своей семантики здоровья. Признак ветвится по шагу,
// поэтому новый sing-box-протокол получает её автоматически — забыть его здесь невозможно.
test("tunnel_health hysteria2: та же семантика, что у reality (единый контракт транспорта)", () => {
	let facts = [ { sb_running: true, tun_up: true }, { sb_running: true, tun_up: false },
	              { sb_running: false, tun_up: true }, {} ];
	for (let i = 0; i < length(facts); i++)
		eq(tunnel_health("hysteria2", facts[i]), tunnel_health("reality", facts[i]),
			sprintf("факты #%d: здоровье обоих Full-протоколов считается одинаково", i));
	eq(tunnel_health("hysteria2", { hs_age: null, sb_running: true, tun_up: true }), "up",
		"рукопожатия у Hysteria2 тоже нет — это не поломка");
});

test("tunnel_health: неизвестный протокол → правила дефолтного (awg), не исключение", () => {
	eq(tunnel_health("banana", { hs_age: 5 }), "up");
	eq(tunnel_health(null, { hs_age: null }), "down");
});

// --- route_uses_iface (чистая часть connectivity-probe reality) ---
test("route_uses_iface: маршрут через туннель → true (dev-токен, не подстрока)", () => {
	ok(route_uses_iface("1.1.1.1 dev singtun0 src 172.19.0.1 uid 0 \n    cache", "singtun0"));
	ok(route_uses_iface("1.1.1.1 via 10.0.0.1 dev singtun0 src 172.19.0.1", "singtun0"));
});

test("route_uses_iface: маршрут утёк на WAN → false (мёртвый туннель не выдаём за рабочий)", () => {
	ok(!route_uses_iface("1.1.1.1 via 192.168.1.1 dev eth0 src 192.168.1.2", "singtun0"));
});

test("route_uses_iface: точное совпадение имени (dev singtun00 ≠ singtun0)", () => {
	ok(!route_uses_iface("1.1.1.1 dev singtun00 src x", "singtun0"));
});

test("route_uses_iface: пустой вход / пустой iface → false (fail-safe)", () => {
	ok(!route_uses_iface("", "singtun0"));
	ok(!route_uses_iface(null, "singtun0"));
	ok(!route_uses_iface("1.1.1.1 dev singtun0", ""));
});

test("route_uses_iface: 'dev' последним токеном (обрезанный вывод) → false", () => {
	ok(!route_uses_iface("1.1.1.1 dev", "singtun0"));
});

// --- fresh_handshake (30с-гейт replace_vpn: multi-peer-корректность) ---
test("fresh_handshake: multi-peer — свежий handshake у ВТОРОГО peer'а находится", () => {
	// Единый regex по многострочному выводу тут всегда фейлил → рабочий конфиг ложно откатывался.
	let hs = "pubkeyA=\t0\npubkeyB=\t1750000100";
	ok(fresh_handshake(hs, 1750000000));
	ok(!fresh_handshake(hs, 1750000200), "оба handshake старше started → false");
});

test("fresh_handshake: одиночный peer, пустой вывод, мусор", () => {
	ok(fresh_handshake("pubkey=\t1750000100", 1750000000));
	ok(!fresh_handshake("pubkey=\t0", 1750000000), "0 = рукопожатия не было");
	ok(!fresh_handshake("", 1750000000));
	ok(!fresh_handshake(null, 1750000000));
	ok(!fresh_handshake("(none)", 1750000000));
});

test("fresh_handshake: принимает и урезанный вывод (одни числа, как awk $2)", () => {
	ok(fresh_handshake("0\n1750000100", 1750000000));
});

// --- pick_wan_fallback (WAN-детект, когда netifd не знает wan) ---
test("pick_wan_fallback: default via gw dev eth0 → wan_if+wan_gw", () => {
	deep_eq(pick_wan_fallback("default via 192.168.100.1 dev eth0 proto dhcp", [ "awg0", "singtun0" ]),
		{ wan_if: "eth0", wan_gw: "192.168.100.1" });
});

test("pick_wan_fallback: p2p-дефолт без via (PPPoE) → wan_gw null", () => {
	deep_eq(pick_wan_fallback("default dev pppoe-wan proto static", [ "awg0", "singtun0" ]),
		{ wan_if: "pppoe-wan", wan_gw: null });
});

test("pick_wan_fallback: туннельные интерфейсы пропускаются (иначе kill-switch на сам туннель)", () => {
	let routes = "default dev awg0 scope link\ndefault via 10.0.0.1 dev eth1 metric 10";
	deep_eq(pick_wan_fallback(routes, [ "awg0", "singtun0" ]), { wan_if: "eth1", wan_gw: "10.0.0.1" });
	eq(pick_wan_fallback("default dev singtun0", [ "awg0", "singtun0" ]), null,
		"только туннельные дефолты → null, не туннель-как-WAN");
});

test("pick_wan_fallback: пустой вывод / нет default → null", () => {
	eq(pick_wan_fallback("", [ "awg0" ]), null);
	eq(pick_wan_fallback(null, [ "awg0" ]), null);
});

// --- дополнение к handshake_state / decide_outcome / copy-семантика ---
test("handshake_state: строка без таба (мусор awg) → waiting, не up (fail-safe поллинг)", () => {
	eq(handshake_state("(none)"), "waiting");
});

test("decide_outcome: preflight ok + пустые шаги + health null → commit", () => {
	eq(decide_outcome({ preflight: { ok: true }, steps: [], health: null }).action, "commit");
});

test("enabled_steps: копия несёт needs/rollback (на них висят step_stdin и dirty-классификация)", () => {
	let steps = enabled_steps({});
	for (let i = 0; i < length(steps); i++) {
		ok(length(steps[i].needs ?? "") > 0 || steps[i].needs == null, "поле needs существует");
		ok(steps[i].rollback == "clean" || steps[i].rollback == "dirty");
	}
	// Оба туннель-шага ждут tunnel_conf — КАКОЙ именно текст, решает conf_key протокола
	// (контракт step_stdin в run.uc). Иначе каждый новый протокол требовал бы ветки в раздаче stdin.
	let by = {};
	for (let i = 0; i < length(steps); i++) by[steps[i].name] = steps[i];
	eq(by.vpn.needs, "tunnel_conf");
	eq(by.singbox.needs, "tunnel_conf");
	// мутация копии не трогает реестр
	by.vpn.needs = "mutated";
	eq(enabled_steps({})[0].needs, "tunnel_conf");
});

exit(summary());
