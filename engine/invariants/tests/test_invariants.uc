// test_invariants.uc — юнит-тесты списка инвариантов data-plane. Без роутера.
//   ucode -R engine/invariants/tests/test_invariants.uc
//
// Сырой вывод команд в фикстурах — НАСТОЯЩИЙ (снят в QEMU): разбор текста живёт в чистой части
// именно ради этих тестов, и подделанный формат обесценил бы их.

import { test, eq, ok, deep_eq, summary } from "../../lib/assert.uc";
import { evaluate, repairs, render_report, half_routes_present,
         dns_instance } from "../invariants.uc";

const RULE_OK = "0:\tfrom all lookup local\n" +
	"32764:\tfrom all uidrange 101-101 lookup 100\n" +
	"32765:\tfrom all fwmark 0x1 lookup 100\n" +
	"32766:\tfrom all lookup main\n" +
	"32767:\tfrom all lookup default";
const MAIN_OK = "0.0.0.0/1 dev awg0 scope link\n" +
	"default via 10.0.2.2 dev br-lan proto static src 10.0.2.15\n" +
	"10.0.2.0/24 dev br-lan proto kernel scope link src 10.0.2.15\n" +
	"128.0.0.0/1 dev awg0 scope link";
const DEFAULT_OK = "default via 10.0.2.2 dev br-lan proto static src 10.0.2.15";
const DIRECT_OK = "default via 10.0.2.2 dev br-lan";
const KS_OK = "table inet fw4 {\n\tchain cheburnet_ks {\n\t\ttype filter hook forward priority filter; policy accept;\n" +
	"\t\toifname \"br-lan\" meta mark != 0x00000001 ct state new drop\n\t}\n}";
const MARK_OK = "table inet fw4 {\n\tchain cheburnet_mark {\n\t\ttype filter hook prerouting priority mangle; policy accept;\n" +
	"\t\tip daddr @direct meta mark set 0x00000001\n\t}\n}";
const PS_OK = " 5392 nobody    2624 S    /usr/sbin/https-dns-proxy -r https://dns.adguard-dns.com/dns-query -p 5053 -b 94.140.14.14\n" +
	" 5393 network   2620 S    /usr/sbin/https-dns-proxy -r https://dns.adguard-dns.com/dns-query -p 5054 -b 94.140.14.14";

function facts(over) {
	let f = {
		installed: true, mode: "home", tunnel_if: "awg0", tunnel_ifs: [ "awg0", "singtun0" ],
		wan_if: "br-lan", tunnel_alive: true, ip_rule: RULE_OK, route_default: DEFAULT_OK, route_main: MAIN_OK,
		route_direct: DIRECT_OK,
		nft_ks: KS_OK, nft_mark: MARK_OK, hdp_ps: PS_OK,
		dns_uid: 101, dns_url: "https://dns.adguard-dns.com/dns-query",
		dns_ports: { main: 5053, wan: 5054 },
	};
	if (over) for (let k in over) f[k] = over[k];
	return f;
}
// failed_ids(rep) → id провалившихся проверок (удобнее, чем сверять весь отчёт).
function failed_ids(rep) {
	let out = [];
	for (let i = 0; i < length(rep.checks); i++)
		if (!rep.checks[i].ok) push(out, rep.checks[i].id);
	return out;
}

test("здоровая система: все инварианты выполнены", () => {
	let rep = evaluate(facts(null));
	deep_eq(failed_ids(rep), [], "на исправном роутере отчёт обязан быть пустым от провалов");
	ok(rep.ok);
	eq(rep.critical_failed, 0);
	eq(rep.total, 10, "home: путь наружу, туннель, kill-switch, правило+таблица direct, пометка, резервный DNS, два экземпляра DoH и их владельцы");
});

test("не настроен → проверять нечего (это не поломка)", () => {
	let rep = evaluate({ installed: false });
	ok(rep.ok); eq(rep.total, 0);
	eq(render_report(rep)[0], "Роутер не настроен — проверять нечего.");
});

// Аварийный режим: защита снята по решению человека — это не поломка, но и не молчание.
test("аварийный режим → проверок нет, но отчёт говорит об этом прямо", () => {
	let rep = evaluate(facts({ paused: true, nft_ks: "", ip_rule: "" }));
	ok(rep.ok, "сторожу чинить нечего — иначе он отменил бы решение владельца");
	ok(rep.paused === true);
	eq(rep.total, 0);
	let lines = join("\n", render_report(rep));
	ok(index(lines, "АВАРИЙНЫЙ РЕЖИМ") >= 0, "молчаливо снятая защита — недопустима");
	ok(index(lines, "Вернуть защиту") >= 0, "человеку сразу сказано, как вернуть");
});

// --- инцидент 1: единственный дефолт у туннеля, фолбэка нет ---
test("нет дефолта мимо туннеля → критичный провал wan_default", () => {
	let rep = evaluate(facts({ route_default: "default dev awg0 scope link" }));
	ok(index(failed_ids(rep), "wan_default") >= 0);
	ok(rep.critical_failed >= 1, "роутер без пути наружу — это критично, а не «деградация»");
	ok(index(repairs(rep), "ifup_wan") >= 0);
});

test("дефолт есть, но он у ТУННЕЛЯ → всё равно провал (это не фолбэк)", () => {
	let rep = evaluate(facts({ route_default: "default dev awg0 scope link" }));
	ok(index(failed_ids(rep), "wan_default") >= 0);
});

// Регресс живого прогона: судили по ПОЛНОЙ таблице, и первая же строка `0.0.0.0/1 dev tun0`
// сходила за «путь наружу» — инвариант, который стережёт «роутер без связи», давал зелёную
// галочку при отсутствии дефолта вовсе.
test("дефолтов нет совсем, но таблица не пуста → провал (а не ложная галочка)", () => {
	let rep = evaluate(facts({ route_default: "",
		route_main: "0.0.0.0/1 dev awg0 scope link\n10.0.2.0/24 dev br-lan proto kernel" }));
	ok(index(failed_ids(rep), "wan_default") >= 0);
	ok(rep.critical_failed >= 1);
});

// --- инцидент 2: половина маршрута ---
test("только одна половина half-route → провал (полдома мимо туннеля)", () => {
	ok(!half_routes_present("0.0.0.0/1 dev awg0\ndefault via 1.1.1.1 dev eth0", "awg0"));
	ok(half_routes_present(MAIN_OK, "awg0"));
	ok(!half_routes_present(MAIN_OK, "singtun0"), "маршруты чужого туннеля не считаются");
});

// --- шрам: цепочка есть, но пустая после fw4 reload ---
test("kill-switch: пустая цепочка — это провал, а не «цепочка на месте»", () => {
	let empty = "table inet fw4 {\n\tchain cheburnet_ks {\n\t\ttype filter hook forward priority filter; policy accept;\n\t}\n}";
	let rep = evaluate(facts({ nft_ks: empty }));
	ok(index(failed_ids(rep), "killswitch") >= 0, "«зелёная» система без защиты — худший исход");
	let c = rep.checks[2];
	eq(c.id, "killswitch");
	ok(index(c.detail, "ПУСТАЯ") >= 0, "в отчёте видно, что цепочка есть, но пустая");
});

// --- P2 из аудита: протухший WAN в таблице направления ---
test("таблица направления ведёт в ПРОШЛЫЙ WAN → провал direct_table", () => {
	let rep = evaluate(facts({ route_direct: "default via 192.0.2.1 dev eth9" }));
	ok(index(failed_ids(rep), "direct_table") >= 0,
		"правило целое, маршрут есть — но direct-сайты мертвы; это и есть тихая поломка");
	let c = rep.checks[4];
	ok(index(c.detail, "протух") >= 0);
});

test("резервный путь DNS снят → провал dns_rule (важный, не критичный)", () => {
	let rule = "0:\tfrom all lookup local\n32765:\tfrom all fwmark 0x1 lookup 100\n32766:\tfrom all lookup main";
	let rep = evaluate(facts({ ip_rule: rule }));
	ok(index(failed_ids(rep), "dns_rule") >= 0);
	eq(rep.critical_failed, 0, "дом работает, но смерть туннеля унесёт резолв — это important");
});

test("dns_uid неизвестен (нет такого пользователя) → проверку не выдумываем", () => {
	let rep = evaluate(facts({ dns_uid: null }));
	ok(index(failed_ids(rep), "dns_rule") < 0);
	eq(rep.total, 9);
});

// --- шрам: чужой экземпляр занял порт резервного ---
test("экземпляры DoH: чужой резолвер на порту резервного → провал именно dns_fallback", () => {
	let ps = " 1 nobody 1 S /usr/sbin/https-dns-proxy -r https://dns.adguard-dns.com/dns-query -p 5053\n" +
		" 2 nobody 1 S /usr/sbin/https-dns-proxy -r https://dns.google/dns-query -p 5054";
	let rep = evaluate(facts({ hdp_ps: ps }));
	ok(index(failed_ids(rep), "dns_fallback") >= 0, "фильтрация пользователя молча обойдена");
	ok(index(failed_ids(rep), "dns_main") < 0, "основной при этом в порядке — не валим и его");
	eq(dns_instance(ps, "https://dns.adguard-dns.com/dns-query", 5054).state, "foreign");
});

test("экземпляры DoH: оба под одним владельцем → провал dns_owners", () => {
	let ps = " 1 nobody 1 S /usr/sbin/https-dns-proxy -r https://dns.adguard-dns.com/dns-query -p 5053\n" +
		" 2 nobody 1 S /usr/sbin/https-dns-proxy -r https://dns.adguard-dns.com/dns-query -p 5054";
	ok(index(failed_ids(evaluate(facts({ hdp_ps: ps }))), "dns_owners") >= 0,
		"совпали владельцы — правило uidrange их не различит, резервный путь фиктивен");
});

// Мёртвый туннель гарантированно убивает ОСНОВНОЙ экземпляр (его bootstrap молчит, демон уходит
// в crash-loop — баг апстрима, размером пула не лечится). Требовать «оба живы» значило бы держать
// чек-лист красным по причине, которую мы устранить не можем, и гонять сторожа вхолостую.
test("основной DoH умер при ЖИВОМ туннеле → провал dns_main, некритичный, чинится перезапуском DoH", () => {
	let ps = " 2 network 1 S /usr/sbin/https-dns-proxy -r https://dns.adguard-dns.com/dns-query -p 5054";
	let rep = evaluate(facts({ hdp_ps: ps }));
	ok(index(failed_ids(rep), "dns_main") >= 0);
	ok(index(failed_ids(rep), "dns_fallback") < 0, "резолв жив — резервный несёт его целиком");
	eq(rep.critical_failed, 0);
	// Туннель вернулся, а procd уже исчерпал respawn: без починки основной не встал бы никогда,
	// и весь резолв молча шёл бы мимо туннеля при зелёной панели.
	deep_eq(repairs(rep), [ "doh" ], "перезапуск DoH — единственная починка");
});

test("основной DoH умер при МЁРТВОМ туннеле → dns_main без починки (перезапуск бил бы в стену)", () => {
	let ps = " 2 network 1 S /usr/sbin/https-dns-proxy -r https://dns.adguard-dns.com/dns-query -p 5054";
	// Маршруты ЦЕЛЫ, а рукопожатия нет (сервер мёртв) — ровно так сторож зацикливался на GL-MT3000.
	let rep = evaluate(facts({ hdp_ps: ps, tunnel_alive: false }));
	ok(index(failed_ids(rep), "dns_main") >= 0);
	deep_eq(repairs(rep), [], "чинить нечем: сторож скажет один раз и замолчит");
	let rep2 = evaluate(facts({ hdp_ps: ps, route_main: DEFAULT_OK, tunnel_alive: false }));
	deep_eq(repairs(rep2), [ "arm" ], "снят маршрут — чиним маршрут, не DoH");
	deep_eq(repairs(evaluate(facts({ hdp_ps: ps, tunnel_alive: null }))), [], "факт живости не собран → не гадаем, не чиним");
});

test("резервный DoH умер → провал dns_fallback с починкой (это чинится)", () => {
	let ps = " 1 nobody 1 S /usr/sbin/https-dns-proxy -r https://dns.adguard-dns.com/dns-query -p 5053";
	let rep = evaluate(facts({ hdp_ps: ps }));
	ok(index(failed_ids(rep), "dns_fallback") >= 0);
	ok(index(repairs(rep), "doh") >= 0, "смерть туннеля унесла бы весь резолв — чиним");
});

// --- travel: обещание «мимо туннеля не уходит ничего» ---
test("travel: правила направления ОТСУТСТВУЮТ — иначе «поездка» врёт", () => {
	let rep = evaluate(facts({ mode: "travel", ip_rule: "0:\tfrom all lookup local\n32766:\tfrom all lookup main" }));
	deep_eq(failed_ids(rep), []);
	eq(rep.total, 4, "в travel проверяем путь наружу, туннель, kill-switch и закрытость");
});

test("travel: остались правила направления → критичный провал travel_closed", () => {
	let rep = evaluate(facts({ mode: "travel" }));
	ok(index(failed_ids(rep), "travel_closed") >= 0);
	ok(rep.critical_failed >= 1);
});

// --- контракт для watchdog'а ---
test("repairs: подсказки без дублей и в порядке проверок", () => {
	let rep = evaluate(facts({ ip_rule: "0:\tfrom all lookup local", route_direct: "" }));
	deep_eq(repairs(rep), [ "reapply" ], "три провала чинятся одним переприменением — зовём один раз");
});

test("render_report: у провала печатается «как чинить», у успеха — нет", () => {
	let lines = join("\n", render_report(evaluate(facts({ nft_ks: "" }))));
	ok(index(lines, "✗ kill-switch") >= 0);
	ok(index(lines, "как чинить:") >= 0);
	ok(index(lines, "ИТОГ (есть отклонения)") >= 0);
	let good = join("\n", render_report(evaluate(facts(null))));
	ok(index(good, "как чинить:") < 0);
	ok(index(good, "ИТОГ: 10 из 10") >= 0);
});

exit(summary());
