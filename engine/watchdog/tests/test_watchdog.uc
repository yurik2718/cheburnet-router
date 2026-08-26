// test_watchdog.uc — юнит-тесты решения сторожа. Без роутера.
//   ucode -R engine/watchdog/tests/test_watchdog.uc

import { test, eq, ok, deep_eq, summary } from "../../lib/assert.uc";
import { decide, repair_cmd, restart_tunnel_cmd, MAX_ATTEMPTS, SETTLE_S } from "../watchdog.uc";

// rep(failed) — отчёт инвариантов с перечисленными провалами (repair берём осмысленный).
function rep(failed) {
	let checks = [];
	for (let i = 0; i < length(failed); i++)
		push(checks, { id: failed[i][0], ok: false, severity: "critical", repair: failed[i][1] });
	return { ok: length(checks) == 0, checks: checks };
}
const OK = { ok: true, checks: [] };

test("норма → ни починки, ни строчки в логе (молчащий сторож — это норма)", () => {
	let d = decide(OK, {}, false);
	eq(d.action, null);
	deep_eq(d.log, [], "лог каждые 5 минут забил бы log-snapshot и убил диагностику");
});

test("норма после поломки → ровно одна строка «восстановлены»", () => {
	let d = decide(OK, { failed: "dns_rule", repair: "reapply", attempts: 1 }, false);
	deep_eq(d.log, [ "инварианты восстановлены" ]);
	deep_eq(d.state, {}, "состояние сбрасывается — следующая поломка считается с нуля");
	deep_eq(decide(OK, d.state, false).log, [], "и больше об этом не напоминаем");
});

test("идёт установка → сторож не делает НИЧЕГО и не шумит", () => {
	let d = decide(rep([["wan_default","ifup_wan"]]), { failed: "x", attempts: 2 }, true);
	eq(d.action, null);
	deep_eq(d.log, [], "установка сама двигает сеть — мешать ей нельзя");
	deep_eq(d.state, { failed: "x", attempts: 2 }, "состояние не трогаем: тик просто пропущен");
});

// Сразу после ребута половина инвариантов честно «не на месте» — просто потому, что загрузка
// не кончилась. Починка в этот момент дерётся с netifd и procd на ровном месте.
test("первые минуты после загрузки → тик пропускается молча", () => {
	let r = rep([["wan_default","ifup_wan"]]);
	let d = decide(r, {}, false, SETTLE_S - 1);
	eq(d.action, null);
	deep_eq(d.log, []);
	eq(decide(r, {}, false, SETTLE_S).action, "ifup_wan", "после окна — чиним как обычно");
	eq(decide(r, {}, false, null).action, "ifup_wan", "uptime неизвестен → гейт не выдумываем");
});

test("аварийный режим → сторож не вмешивается и молчит", () => {
	let r = rep([["wan_default","ifup_wan"]]);
	r.paused = true;
	let d = decide(r, {}, false, 10000);
	eq(d.action, null, "«починить» защиту здесь = отменить решение человека и снять ему интернет");
	deep_eq(d.log, []);
});

test("поломка → ОДНА починка за тик, первая по порядку проверок", () => {
	let d = decide(rep([["wan_default","ifup_wan"], ["dns_rule","reapply"]]), {}, false);
	eq(d.action, "ifup_wan", "сначала критичное — путь наружу");
	eq(length(d.log), 1);
	ok(index(d.log[0], "чиню (ifup_wan), попытка 1") >= 0);
	eq(d.state.attempts, 1);
});

test("та же поломка повторяется → счётчик растёт", () => {
	let r = rep([["dns_rule","reapply"]]);
	let d1 = decide(r, {}, false);
	let d2 = decide(r, d1.state, false);
	eq(d2.state.attempts, 2);
	eq(d2.action, "reapply");
});

test("не чинится после MAX_ATTEMPTS → сдаёмся, говорим ОДИН раз и замолкаем", () => {
	let r = rep([["dns_rule","reapply"]]);
	let st = {};
	for (let i = 0; i < MAX_ATTEMPTS; i++) st = decide(r, st, false).state;
	let give_up = decide(r, st, false);
	eq(give_up.action, null, "бесконечный ifup/reload каждые 5 минут хуже самой поломки");
	ok(index(give_up.log[0], "нужна ручная проверка") >= 0);
	deep_eq(decide(r, give_up.state, false).log, [], "второй раз про то же не пишем");
});

test("сменился НАБОР поломок → счётчик и тишина начинаются заново", () => {
	let st = { failed: "dns_rule", repair: "reapply", attempts: MAX_ATTEMPTS, quiet: true };
	let d = decide(rep([["killswitch","firewall"]]), st, false);
	eq(d.action, "firewall", "это другая проблема — её мы ещё не пробовали чинить");
	eq(d.state.attempts, 1);
});

test("поломка без подсказки починки → говорим один раз и молчим (руками так руками)", () => {
	let d = decide(rep([["dns_instances", null]]), {}, false);
	eq(d.action, null);
	ok(index(d.log[0], "автоматически не чинятся") >= 0);
	deep_eq(decide(rep([["dns_instances", null]]), d.state, false).log, []);
});
// --- repair_cmd: подсказка инварианта → команда. Ветвление по ШАГУ протокола (ADR 0004). ---
test("repair_cmd: arm зовёт шаг активного протокола, не awg по умолчанию", () => {
	eq(repair_cmd("arm", { protocol: "awg" }, "/e"), "ucode -R /e/steps/vpn/apply.uc --arm");
	eq(repair_cmd("arm", { protocol: "reality" }, "/e"), "ucode -R /e/steps/singbox/apply.uc --arm");
	eq(repair_cmd("arm", { protocol: "hysteria2" }, "/e"), "ucode -R /e/steps/singbox/apply.uc --arm",
		"оба Full-протокола — один шаг");
	eq(repair_cmd("arm", {}, "/e"), "ucode -R /e/steps/vpn/apply.uc --arm", "нет протокола → дефолт awg");
});

test("repair_cmd: reapply/firewall → единая реализация reapply.uc; ifup_wan; doh — с провайдером", () => {
	eq(repair_cmd("reapply", {}, "/e"), "ucode -R /e/install/reapply.uc");
	eq(repair_cmd("firewall", {}, "/e"), "ucode -R /e/install/reapply.uc", "firewall чинится тем же reapply");
	eq(repair_cmd("ifup_wan", {}, "/e"), "ifup wan");
	let d = repair_cmd("doh", { dns_provider: "quad9" }, "/e");
	ok(index(d, '"provider":"quad9"') >= 0, "провайдер из install.json, иначе шаг сбросил бы его на дефолт");
	ok(index(d, "/e/steps/doh/apply.uc") >= 0);
	eq(repair_cmd("bogus", {}, "/e"), null, "неизвестная подсказка → руками");
});

// ШРАМ: кнопка «Туннель» делала `ifup awg0` при любом протоколе и на Reality отвечала «готово»,
// ничего не сделав — единственный путь без SSH при упавшем sing-box был закрыт.
test("restart_tunnel_cmd: AWG — интерфейс; Full-тир — сервис sing-box + netifd-интерфейс над TUN", () => {
	eq(restart_tunnel_cmd({ protocol: "awg" }), "ifdown awg0 2>/dev/null; sleep 1; ifup awg0 2>/dev/null");
	let r = restart_tunnel_cmd({ protocol: "reality" });
	ok(index(r, "/etc/init.d/sing-box restart") >= 0, "мёртвый процесс ifup не оживит");
	ok(index(r, "ifup singtun") >= 0, "half-routes живут на netifd-интерфейсе поверх TUN");
	ok(index(r, "awg0") < 0, "чужой туннель не трогаем");
	eq(restart_tunnel_cmd({ protocol: "hysteria2" }), r, "оба Full-протокола — одна команда");
});

exit(summary());
