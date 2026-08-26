// test_routing.uc — юнит-тесты генератора маршрутизации. Без роутера, секунды.
//   ucode -R engine/routing/tests/test_routing.uc
//
// Проверяем чистую логику: нормализацию/валидацию доменов, отбрасывание мусора (fail-safe),
// дедуп, и три рендера в каждом режиме (home/travel, ipv6 on/off, hook prerouting/output).

import { test, eq, ok, deep_eq, summary } from "../../lib/assert.uc";
import { normalize_domain, is_valid_domain, build_plan, set_names,
         render_dnsmasq, render_nft, render_iprules,
         render_all } from "../routing.uc";

// --- нормализация ---
test("normalize: lowercase + trim + снятие корневой точки", () => {
	eq(normalize_domain("  EXample.COM.  "), "example.com");
	eq(normalize_domain("Example.Org"), "example.org");
	eq(normalize_domain("trailing.dots..."), "trailing.dots");
});

// --- валидация ---
test("valid: обычный домен и punycode проходят", () => {
	ok(is_valid_domain("example.com"));
	ok(is_valid_domain("a.b.c.example.org"));
	ok(is_valid_domain("xn--80akhbyknj4f.com")); // punycode (дефисы в середине метки ок)
});
test("invalid: юникод/подчёркивание/пустые/крайние дефисы отбрасываются", () => {
	ok(!is_valid_domain("пример.рф"));       // не-ASCII (должен быть punycode)
	ok(!is_valid_domain("under_score.com")); // '_' не LDH
	ok(!is_valid_domain("-bad.com"));        // метка не может начинаться с дефиса
	ok(!is_valid_domain("bad-.com"));        // ...и заканчиваться им
	ok(!is_valid_domain(""));
});

// --- build_plan: дедуп, мусор → rejected (fail-safe), не падаем ---
test("build_plan: дедуп + нормализация + сбор rejected", () => {
	// build_plan получает уже распарсенный список (комментарии снимает CLI-ридер generate.uc).
	let plan = build_plan([
		"Example.com", "example.com.", // дубликат после нормализации
		"  example.org  ",
		"",                            // пустое → молча мимо
		"пример.рф",                   // невалид → rejected, НЕ фатал
	], {});
	deep_eq(plan.domains, ["example.com", "example.org"], "уникальные валидные домены");
	eq(length(plan.rejected), 1, "ровно один отвергнутый");
	eq(plan.rejected[0].raw, "пример.рф");
});

// --- dnsmasq рендер ---
test("render_dnsmasq: v4+v6 строки в правильном формате", () => {
	let plan = build_plan(["example.com"], {});
	deep_eq(render_dnsmasq(plan), [
		"/example.com/4#inet#fw4#direct",
		"/example.com/6#inet#fw4#direct6",
	]);
});
test("render_dnsmasq: ipv6=false → только v4", () => {
	let plan = build_plan(["example.com"], { ipv6: false });
	deep_eq(render_dnsmasq(plan), [ "/example.com/4#inet#fw4#direct" ]);
});
// --- nft рендер ---
test("render_nft: сеты + правила пометки (prerouting по умолчанию)", () => {
	let plan = build_plan(["example.com"], {});
	deep_eq(render_nft(plan), [
		"add set inet fw4 direct { type ipv4_addr; flags interval; }",
		"add set inet fw4 direct6 { type ipv6_addr; flags interval; }",
		"add rule inet fw4 mangle_prerouting ip daddr @direct meta mark set 0x1",
		"add rule inet fw4 mangle_prerouting ip6 daddr @direct6 meta mark set 0x1",
	]);
});
test("render_nft: hook=output → mangle_output (путь netns-теста)", () => {
	let plan = build_plan(["example.com"], { ipv6: false, hook: "output" });
	deep_eq(render_nft(plan), [
		"add set inet fw4 direct { type ipv4_addr; flags interval; }",
		"add rule inet fw4 mangle_output ip daddr @direct meta mark set 0x1",
	]);
});

// --- ip rule рендер ---
test("render_iprules: правило fwmark + default через WAN", () => {
	let plan = build_plan([], { ipv6: false, wan_if: "eth0", wan_gw: "192.0.2.1" });
	deep_eq(render_iprules(plan), [
		"ip rule add fwmark 0x1 lookup 100",
		"ip route add default via 192.0.2.1 dev eth0 table 100",
	]);
});
test("render_iprules: без gw → маршрут только через dev", () => {
	let plan = build_plan([], { ipv6: false, wan_if: "direct0" });
	deep_eq(render_iprules(plan), [
		"ip rule add fwmark 0x1 lookup 100",
		"ip route add default dev direct0 table 100",
	]);
});
test("render_iprules: без wan_if → только правило fwmark", () => {
	let plan = build_plan([], { ipv6: false });
	deep_eq(render_iprules(plan), [ "ip rule add fwmark 0x1 lookup 100" ]);
});

// --- режим TRAVEL: всё в туннель ---
test("travel: dnsmasq и iprules пусты, nft = только объявления сетов", () => {
	let plan = build_plan(["example.com"], { mode: "travel" });
	deep_eq(render_dnsmasq(plan), [], "нет direct-доменов");
	deep_eq(render_iprules(plan), [], "нет правил направления → main-таблица (туннель)");
	deep_eq(render_nft(plan), [
		"add set inet fw4 direct { type ipv4_addr; flags interval; }",
		"add set inet fw4 direct6 { type ipv6_addr; flags interval; }",
	], "сеты объявлены (пустые), правил пометки нет");
});

// --- кастомные имена/метки прокидываются ---
test("opts: кастомные mark/table/set прокидываются в рендеры", () => {
	let plan = build_plan(["example.com"], {
		ipv6: false, mark: "0x10", table: 200, set4: "vpn_direct",
	});
	deep_eq(render_dnsmasq(plan), [ "/example.com/4#inet#fw4#vpn_direct" ]);
	deep_eq(render_nft(plan), [
		"add set inet fw4 vpn_direct { type ipv4_addr; flags interval; }",
		"add rule inet fw4 mangle_prerouting ip daddr @vpn_direct meta mark set 0x10",
	]);
	deep_eq(render_iprules(plan), [ "ip rule add fwmark 0x10 lookup 200" ]);
});

test("set_names: имена сетов [v4, v6] — источник для dns/status/reset", () => {
	deep_eq(set_names(), [ "direct", "direct6" ]);
});

test("render_all: композиция всех артефактов + passthrough rejected", () => {
	let plan = build_plan([ "example.com", "битый домен!" ], { ipv6: false });
	let all = render_all(plan);
	deep_eq(all.dnsmasq, render_dnsmasq(plan));
	deep_eq(all.nft, render_nft(plan));
	deep_eq(all.iprules, render_iprules(plan));
	eq(length(all.rejected), 1, "невалидный домен отражён в rejected (видимость для UI)");
});

// --- резервный DNS: правило по владельцу сокета (см. ИНВАРИАНТ в render_iprules) ---
test("render_iprules: dns_uid → правило uidrange в ту же таблицу 100", () => {
	let plan = build_plan([], { wan_if: "eth0", wan_gw: "192.0.2.1", dns_uid: 101 });
	let out = join("\n", render_iprules(plan));
	ok(index(out, "ip rule add uidrange 101-101 lookup 100") >= 0,
		"резервный DoH-экземпляр уходит мимо туннеля тем же путём, что direct-трафик");
	ok(index(out, "ip -6 rule add uidrange 101-101 lookup 100") >= 0, "и для v6");
});

test("render_iprules: без dns_uid правила нет (чужая сборка без такого пользователя)", () => {
	let out = join("\n", render_iprules(build_plan([], { wan_if: "eth0" })));
	ok(index(out, "uidrange") < 0, "нет пользователя — нет правила, поведение как раньше");
});

// В поездке мимо туннеля не уходит НИЧЕГО, включая резервный DNS: в чужом Wi-Fi лучше остаться
// без резолва, чем засветить домены (fail-closed).
test("render_iprules: travel → резервного DNS тоже нет", () => {
	let out = join("\n", render_iprules(build_plan([], { mode: "travel", wan_if: "eth0", dns_uid: 101 })));
	eq(out, "", "в travel policy-routing пуст целиком");
});

exit(summary());
