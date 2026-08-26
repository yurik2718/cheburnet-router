// test_run_paths.uc — host-тест оркестратора install/run.uc: ПУТИ РЕШЕНИЯ и их последствия.
//
// Чистая политика (decide_outcome/snapshot_scope/…) — под test_install.uc; здесь — ПРОВОДКА:
// что реально происходит с системой (sandbox) на каждом исходе. Реальный run.uc гоняется как
// subprocess с фейками команд (см. harness.uc) — так проверяем инварианты надёжности:
//   • abort (preflight / singbox-download) — система НЕ тронута, фантомного installed нет;
//   • commit — wan_if персистится, одноразовый токен снят, снимок выброшен;
//   • rollback — reason-код адресный, install.json-правда восстановлена, teardown вызван.
// Живой data-plane (netifd/fw4) — по-прежнему QEMU; здесь — логика переходов на реальном коде.

import { test, eq, ok, deep_eq, summary } from "../../lib/assert.uc";
import { writefile, readfile, access, mkdir } from "fs";
import { mk_sandbox, with_singbox, run_uc, calls, cleanup, write_stub, shq } from "./harness.uc";

// seed_cfg(sb, extra) — install.json «до этой попытки» (то, что пишет m_install до исхода).
function seed_cfg(sb, name, obj) {
	writefile(sb.etc + "/" + name, sprintf("%J\n", obj));
}

const ALL_STEPS = ["vpn", "dns", "doh", "wifi", "firewall"];

test("preflight-провал: abort до снимка, reason=preflight, фантомный install.json удалён", () => {
	let sb = mk_sandbox();
	writefile(sb.fake + "/apk.rc", "1"); // deps_installable=false → гейткипер отказывает
	seed_cfg(sb, "install.json", { routing_opts: {} }); // .prev нет — «чистая система»
	let r = run_uc(sb, "install/run.uc", null, '{"protocol":"awg","domains":[]}');
	eq(r.rc, 1, "exit 1");
	eq(trim(readfile(sb.reason) ?? ""), "preflight", "машинный код для UI");
	ok(!access(sb.etc + "/install.json"), "правда installed восстановлена (файл удалён)");
	ok(!access(sb.snap), "снимок не создавался — система не тронута");
	cleanup(sb);
});

// --- «Поставить на свой страх и риск» (accept_risk): soft-провалы пропускаются, hard — нет ---
// df-стаб отдаёт «свободно 8 МБ» → soft-провал flash. RAM здесь не подделать (parse_meminfo
// читает /proc/meminfo напрямую), и не нужно: путь один и тот же для любого soft-провала.
const DF_SMALL = "Filesystem           1K-blocks      Used Available Use% Mounted on\n" +
	"/dev/root                20480     12288      8192  60% /overlay\n";

test("soft-провал без accept_risk: обычный abort (пропуск НЕ по умолчанию)", () => {
	let sb = mk_sandbox();
	writefile(sb.fake + "/df.out", DF_SMALL);
	seed_cfg(sb, "install.json", { routing_opts: {} });
	let r = run_uc(sb, "install/run.uc", null, '{"protocol":"awg","domains":[]}');
	eq(r.rc, 1, "гейт закрыт: " + r.out);
	eq(trim(readfile(sb.reason) ?? ""), "preflight");
	ok(!access(sb.snap), "система не тронута");
	cleanup(sb);
});

test("soft-провал + accept_risk: установка идёт, пропуск в логе и в install.json", () => {
	let sb = mk_sandbox();
	writefile(sb.fake + "/df.out", DF_SMALL);
	seed_cfg(sb, "install.json", { user_domains: [], domains: [], routing_opts: {} });
	let payload = sprintf("%J", { protocol: "awg", disable: ALL_STEPS, domains: [],
		routing_opts: {}, accept_risk: true });
	let r = run_uc(sb, "install/run.uc", null, payload);
	eq(r.rc, 0, "установка прошла: " + r.out);
	ok(index(r.out, "! flash") >= 0, "отчёт помечает пропуск, а не молчит");
	ok(index(r.out, "ВНИМАНИЕ") >= 0, "предупреждение осталось в install.log");
	let saved = json(readfile(sb.etc + "/install.json"));
	deep_eq(saved.forced, [ "flash" ], "след решения — панель покажет плашку");
	cleanup(sb);
});

test("hard-провал + accept_risk: всё равно abort (пакетов под платформу нет)", () => {
	let sb = mk_sandbox();
	writefile(sb.fake + "/apk.rc", "1"); // deps не ставятся — hard
	seed_cfg(sb, "install.json", { routing_opts: {} });
	let payload = sprintf("%J", { protocol: "awg", domains: [], accept_risk: true });
	let r = run_uc(sb, "install/run.uc", null, payload);
	eq(r.rc, 1, "риск не пропускает hard-провал: " + r.out);
	eq(trim(readfile(sb.reason) ?? ""), "preflight");
	ok(!access(sb.snap), "система не тронута");
	cleanup(sb);
});

test("commit на годном железе: forced пуст (прежняя отметка не залипает)", () => {
	let sb = mk_sandbox();
	seed_cfg(sb, "install.json", { user_domains: [], domains: [], routing_opts: {},
		forced: [ "ram" ] }); // как будто прошлая установка была с пропуском
	let payload = sprintf("%J", { protocol: "awg", disable: ALL_STEPS, domains: [], routing_opts: {} });
	let r = run_uc(sb, "install/run.uc", null, payload);
	eq(r.rc, 0, "установка прошла: " + r.out);
	deep_eq(json(readfile(sb.etc + "/install.json")).forced, [], "переустановка стирает отметку");
	cleanup(sb);
});

test("commit-путь: wan_if/wan_gw/tunnel_if персистятся, токен снят, снимок выброшен", () => {
	let sb = mk_sandbox();
	// Все шаги выключены → health = только DNS (nslookup-стаб по умолчанию отвечает).
	seed_cfg(sb, "install.json", { user_domains: [], domains: [], routing_opts: {} });
	writefile(sb.etc + "/install-token", "TOK-123\n");
	let payload = sprintf("%J", { protocol: "awg", disable: ALL_STEPS,
		domains: [], routing_opts: {} });
	let r = run_uc(sb, "install/run.uc", null, payload);
	eq(r.rc, 0, "exit 0: " + r.out);
	ok(index(r.out, "install: успешно") >= 0, "итог напечатан");
	let saved = json(readfile(sb.etc + "/install.json"));
	eq(saved.routing_opts.wan_if, "eth0", "wan_if найден через netifd и персистнут");
	eq(saved.routing_opts.wan_gw, "192.0.2.1", "wan_gw персистнут (ethernet-WAN)");
	eq(saved.routing_opts.tunnel_if, "awg0", "tunnel_if активного туннеля персистнут");
	ok(!access(sb.etc + "/install-token"), "одноразовый токен снят ТОЛЬКО на успехе");
	ok(!access(sb.snap), "снимок выброшен (commit)");
	eq(trim(readfile(sb.state) ?? ""), "health-check", "последний шаг прогресса");
	cleanup(sb);
});

test("шаг упал: rollback c reason=step:vpn, teardown грязных, install.json из .prev", () => {
	let sb = mk_sandbox();
	// Пере-установка ПОВЕРХ рабочей: .prev несёт прежнюю правду (с wan_if — для reapply).
	let prev = { user_domains: ["old.example"], domains: ["old.example"],
		routing_opts: { wan_if: "eth0", tunnel_if: "awg0" }, protocol: "awg" };
	seed_cfg(sb, "install.json", { routing_opts: {} }); // новая попытка уже записала своё
	seed_cfg(sb, "install.json.prev", prev);
	let payload = sprintf("%J", { protocol: "awg", disable: ["dns", "doh", "wifi"],
		awg_conf: "это не AWG-конфиг", domains: [], routing_opts: {} });
	let r = run_uc(sb, "install/run.uc", null, payload);
	eq(r.rc, 1, "exit 1");
	eq(trim(readfile(sb.reason) ?? ""), "step:vpn", "адресный reason для UI");
	ok(index(r.out, "откат") >= 0, "об откате сказано явно");
	let restored = json(readfile(sb.etc + "/install.json"));
	eq(restored.user_domains[0], "old.example", "install.json восстановлен из .prev");
	ok(!access(sb.etc + "/install.json.prev"), ".prev поглощён восстановлением");
	// Firewall — грязный шаг: его teardown обязан быть вызван даже если сам шаг не успел
	// примениться (safe-fail), а reapply_data_plane обязан вернуть firewall прежней системы.
	ok(index(calls(sb), "nft") >= 0, "firewall teardown дошёл до nft");
	cleanup(sb);
});

test("health-провал (DNS): rollback с reason=health:dns (роутер настроен, DNS не поднялся)", () => {
	let sb = mk_sandbox();
	writefile(sb.fake + "/nslookup.rc", "1"); // DNS так и не поднялся за окно
	seed_cfg(sb, "install.json", { routing_opts: {} });
	// Все туннель/сетевые шаги выключены → tunnel_applied=false → tun_ok сразу true, падает
	// ровно DNS — адресный код должен указывать именно на него, не на «сервер молчит».
	let payload = sprintf("%J", { protocol: "awg", disable: ALL_STEPS,
		domains: [], routing_opts: {} });
	let r = run_uc(sb, "install/run.uc", null, payload);
	eq(r.rc, 1, "exit 1");
	eq(trim(readfile(sb.reason) ?? ""), "health:dns", "reason адресный — DNS, не общий «сервер молчит»");
	ok(!access(sb.etc + "/install.json"), "фантомный installed снят");
	cleanup(sb);
});

test("health-провал (Full-тир, туннель): rollback с reason=health:tunnel:process", () => {
	let sb = mk_sandbox();
	with_singbox(sb); // бинарь «есть» — догрузка не блокирует
	// pgrep.rc не пишем — дефолт «процесса нет» (см. test_probe.uc): singbox-шаг применился,
	// но сам туннельный процесс не встал.
	seed_cfg(sb, "install.json", { routing_opts: {} });
	let payload = sprintf("%J", {
		protocol: "reality",
		reality_conf: "vless://uuid-x@203.0.113.9:443?security=reality&pbk=YQ&sni=example.com",
		disable: [ "dns", "doh", "wifi", "firewall" ], // singbox остаётся включённым
		domains: [], routing_opts: {},
	});
	let r = run_uc(sb, "install/run.uc", null, payload);
	eq(r.rc, 1, "exit 1");
	eq(trim(readfile(sb.reason) ?? ""), "health:tunnel:process",
		"reason адресный — процесс не поднялся, не общий «сервер молчит»");
	cleanup(sb);
});

test("reality без sing-box: провал догрузки = чистый abort ДО снимка, reason=singbox-download", () => {
	let sb = mk_sandbox();
	// apk «успешен», но бинарь sing-box так и не появился в PATH — критерий install-singbox.sh
	// (наличие бинаря, не код apk) обязан сработать и здесь.
	seed_cfg(sb, "install.json", { routing_opts: {} });
	let payload = sprintf("%J", { protocol: "reality", reality_conf: "vless://x",
		domains: [], routing_opts: {} });
	let r = run_uc(sb, "install/run.uc", null, payload);
	eq(r.rc, 1, "exit 1");
	eq(trim(readfile(sb.reason) ?? ""), "singbox-download", "адресный reason");
	ok(!access(sb.snap), "снимка нет — роутер не тронут (откатывать нечего)");
	ok(!access(sb.etc + "/install.json"), "фантомный installed снят");
	eq(trim(readfile(sb.state) ?? ""), "singbox-download", "прогресс показывал догрузку");
	cleanup(sb);
});

// Гейт догрузки ветвится по uses_singbox, а не по имени «reality» — иначе выбор Hysteria2 на
// системе без бинаря дошёл бы до шагов и упал бы уже ПОСЛЕ снимка, с невнятной причиной.
test("hysteria2 без sing-box: тот же чистый abort ДО снимка (гейт по шагу, не по имени)", () => {
	let sb = mk_sandbox();
	seed_cfg(sb, "install.json", { routing_opts: {} });
	let payload = sprintf("%J", { protocol: "hysteria2", hysteria2_conf: "hysteria2://pw@h:443",
		domains: [], routing_opts: {} });
	let r = run_uc(sb, "install/run.uc", null, payload);
	eq(r.rc, 1, "exit 1");
	eq(trim(readfile(sb.reason) ?? ""), "singbox-download", "адресный reason");
	ok(!access(sb.snap), "снимка нет — роутер не тронут");
	ok(!access(sb.etc + "/install.json"), "фантомный installed снят");
	cleanup(sb);
});

// Ключ конфига выбирается по протоколу (conf_key): если бы run.uc продолжал читать reality_conf,
// hysteria2-установка ушла бы в singbox-шаг с ПУСТЫМ stdin и упала бы «непонятно почему».
test("hysteria2: конфиг доезжает до singbox-шага по conf_key (dry-run печатает hysteria2-outbound)", () => {
	let sb = mk_sandbox();
	with_singbox(sb); // бинарь «есть» → догрузка пропускается
	let r = run_uc(sb, "install/run.uc", "--dry-run", sprintf("%J", {
		protocol: "hysteria2",
		hysteria2_conf: "hysteria2://HY2PASS@203.0.113.5:8443?sni=example.com",
		domains: [], routing_opts: {},
	}));
	eq(r.rc, 0, "exit 0: " + r.out);
	ok(index(r.out, "\"type\": \"hysteria2\"") >= 0, "singbox-шаг получил hy2-ссылку: " + r.out);
	ok(index(r.out, "HY2PASS") >= 0, "пароль из ссылки доехал в конфиг");
	ok(index(r.out, "singtun") >= 0, "маршрут в общий TUN-интерфейс");
	cleanup(sb);
});

test("--rollback (отмена): teardown ОБОИХ туннелей + возврат install.json и config.json", () => {
	let sb = mk_sandbox();
	let prev = { routing_opts: { wan_if: "eth0" }, protocol: "reality" };
	seed_cfg(sb, "install.json", { routing_opts: {} });
	seed_cfg(sb, "install.json.prev", prev);
	// Рабочий Full-тир: config.json уже подменён установкой, .prev ждёт возврата.
	writefile(sb.sbconf, "НОВЫЙ (от прерванной установки)\n");
	writefile(sb.sbconf + ".prev", "ПРЕЖНИЙ РАБОЧИЙ\n");
	let r = run_uc(sb, "install/run.uc", "--rollback",
		'{"protocol":"reality","routing_opts":{}}');
	eq(r.rc, 0, "exit 0: " + r.out);
	let log = calls(sb);
	// vpn — clean-шаг: его возвращает snapshot restore; teardown'ятся только dirty
	// (singbox + firewall) — отменённая reality-установка не оставляет живой sing-box.
	ok(index(log, "ifdown singtun") >= 0, "singbox teardown вызван — sing-box не остаётся жить");
	ok(index(log, "nft") >= 0, "firewall teardown вызван (safe-fail)");
	eq(readfile(sb.sbconf), "ПРЕЖНИЙ РАБОЧИЙ\n", "config.json возвращён из .prev");
	ok(!access(sb.sbconf + ".prev"), "бэкап config.json поглощён");
	eq(json(readfile(sb.etc + "/install.json")).protocol, "reality",
		"install.json восстановлен из .prev");
	cleanup(sb);
});

test("--dry-run: план напечатан, система не тронута", () => {
	let sb = mk_sandbox();
	let r = run_uc(sb, "install/run.uc", "--dry-run",
		'{"protocol":"awg","awg_conf":"мусор","domains":[],"routing_opts":{}}');
	eq(r.rc, 0, "exit 0");
	ok(index(r.out, "# snapshot scope:") >= 0, "область снимка показана");
	ok(index(r.out, "# шаги:") >= 0, "список шагов показан");
	ok(!access(sb.snap), "снимок не создан");
	cleanup(sb);
});

// --- --no-arm/--arm: половина дома не переключается на непроверенный туннель (см. план в
// docs/kb/architecture/reliability.md, инцидент 2026-08-19 — kill-switch срабатывал раньше
// health-check и ронял интернет всему дому при провале). Сначала точечно на уровне apply.uc,
// потом сквозь run.uc — что реально произойдёт при провале/успехе первой установки.

const AWG_CONF =
	"[Interface]\nPrivateKey = cHJpdmF0ZXByaXZhdGVwcml2YXRlcHJpdmF0ZXByaXZhdGUwMA==\n" +
	"Address = 10.0.0.2/32\n\n[Peer]\nPublicKey = cHVibGljcHVibGljcHVibGljcHVibGljcHVibGljMDA=\n" +
	"Endpoint = vpn.example.com:51820\n";
const REALITY_CONF = "vless://uuid-x@203.0.113.9:443?security=reality&pbk=YQ&sni=example.com";

test("vpn/apply.uc --no-arm: half-routes НЕ создаются, интерфейс всё равно поднимается", () => {
	let sb = mk_sandbox();
	let r = run_uc(sb, "steps/vpn/apply.uc", "--no-arm", AWG_CONF);
	eq(r.rc, 0, "exit 0: " + r.out);
	ok(index(calls(sb), "awg0_route4lo=route") < 0, "маршрут НЕ вооружён");
	ok(index(calls(sb), "route_allowed_ips='0'") >= 0, "но proto-handler свой default тоже не ставит");
	ok(index(calls(sb), "route_allowed_ips='1'") < 0, "старая схема не просочилась");
	cleanup(sb);
});

test("vpn/apply.uc --arm: half-routes + reload, конфиг туннеля не трогает", () => {
	let sb = mk_sandbox();
	let r = run_uc(sb, "steps/vpn/apply.uc", "--arm");
	eq(r.rc, 0, "exit 0: " + r.out);
	ok(index(calls(sb), "awg0_route4lo.target='0.0.0.0/1'") >= 0, "маршрут довооружён");
	// netifd применяет route-секции по reload — перезапускать туннель сразу после health-check
	// не за что (обе ветки прогнаны в qemu-route-fallback).
	ok(index(calls(sb), "ifup awg0") < 0, "туннель не дёргаем: reload ставит маршруты сам");
	ok(index(calls(sb), "private_key") < 0, "конфиг туннеля не переписывается");
	cleanup(sb);
});

// --arm — он же путь миграции со старой схемы: route_allowed_ips='1' обязан быть перебит, иначе
// netifd оставит свой ЗАМЕЩАЮЩИЙ default и подъём WAN снова отберёт маршрут у туннеля.
test("vpn/apply.uc --arm: перебивает route_allowed_ips на '0' (миграция старой установки)", () => {
	let sb = mk_sandbox();
	run_uc(sb, "steps/vpn/apply.uc", "--arm");
	ok(index(calls(sb), "route_allowed_ips='0'") >= 0, "старая схема снята");
	// WAN-дефолт в песочнице есть (route_default.out) → гасить и поднимать wan не за чем.
	ok(index(calls(sb), "ifup wan") < 0, "живой WAN не дёргаем на ровном месте");
	cleanup(sb);
});

test("singbox/apply.uc --no-arm: ifup НЕ вызывается", () => {
	let sb = mk_sandbox();
	with_singbox(sb);
	let r = run_uc(sb, "steps/singbox/apply.uc", "--no-arm", REALITY_CONF);
	eq(r.rc, 0, "exit 0: " + r.out);
	ok(index(calls(sb), "ifup") < 0, "маршрут НЕ вооружён");
	cleanup(sb);
});

test("singbox/apply.uc --arm при живом sing-box: ifup singtun, сервис не трогаем", () => {
	let sb = mk_sandbox();
	writefile(sb.fake + "/pgrep.rc", "0\n"); // sing-box жив
	mkdir(sb.root + "/initd", 0o755); write_stub(sb.root + "/initd", "sing-box", "exit 0");
	let r = run_uc(sb, "steps/singbox/apply.uc", "--arm", null, sprintf("INITD_DIR=%s", shq(sb.root + "/initd")));
	eq(r.rc, 0, "exit 0: " + r.out);
	ok(index(calls(sb), "ifup singtun") >= 0, "маршрут довооружён");
	ok(index(calls(sb), "sing-box restart") < 0, "живой туннель не мигаем ровно тогда, когда health его подтвердил");
	cleanup(sb);
});

// Half-routes живут на TUN, а TUN — на живом sing-box: после OOM/исчерпанного respawn «arm» сторожа
// делал `ifup` в пустоту три раза и замолкал — дом без интернета до SSH.
test("singbox/apply.uc --arm при МЁРТВОМ sing-box: сначала рестарт сервиса, потом ifup", () => {
	let sb = mk_sandbox();
	// pgrep.rc по умолчанию 1 → процесса нет
	mkdir(sb.root + "/initd", 0o755); write_stub(sb.root + "/initd", "sing-box", "exit 0");
	let r = run_uc(sb, "steps/singbox/apply.uc", "--arm", null, sprintf("INITD_DIR=%s", shq(sb.root + "/initd")));
	eq(r.rc, 0, "exit 0: " + r.out);
	let c = calls(sb);
	ok(index(c, "sing-box restart") >= 0, "сервис поднят");
	ok(index(c, "sing-box restart") < index(c, "ifup singtun"), "рестарт ДО ifup: netifd ставит маршрут на живой TUN");
	cleanup(sb);
});

// --- Сквозь run.uc: главный регресс-тест инцидента ---
test("первая установка (AWG), health провалился → half-routes НИ РАЗУ не вооружались", () => {
	let sb = mk_sandbox();
	// awg.out по умолчанию пуст (нет рукопожатия) → health-check не пройдёт.
	seed_cfg(sb, "install.json", { routing_opts: {} });
	let payload = sprintf("%J", { protocol: "awg", awg_conf: AWG_CONF,
		disable: [ "dns", "doh", "wifi", "firewall" ], domains: [], routing_opts: {} });
	let r = run_uc(sb, "install/run.uc", null, payload);
	eq(r.rc, 1, "exit 1: " + r.out);
	eq(trim(readfile(sb.reason) ?? ""), "health:tunnel:fetch");
	ok(index(calls(sb), "awg0_route4lo=route") < 0,
		"дом НЕ переключался на непроверенный туннель — раньше здесь была утечка/потеря интернета");
	ok(index(calls(sb), "amneziawg_awg0") >= 0, "но интерфейс поднимался (--no-arm) — health-check мог его проверить");
	cleanup(sb);
});

// Сторож — единственное, что смотрит за роутером ПОСЛЕ установки. Не поставился на успешном
// пути — обещание «работает годами» опирается только на удачу.
test("успешная установка ставит сторожа в cron; провал — не ставит", () => {
	let sb = mk_sandbox();
	writefile(sb.fake + "/awg.out", "pubkeyXXX\t5\n"); // свежее рукопожатие → health ok
	seed_cfg(sb, "install.json", { routing_opts: {} });
	let payload = sprintf("%J", { protocol: "awg", awg_conf: AWG_CONF,
		disable: [ "dns", "doh", "wifi", "firewall" ], domains: [], routing_opts: {} });
	eq(run_uc(sb, "install/run.uc", null, payload).rc, 0);
	ok(index(readfile(sb.crontab) ?? "", "watchdog/tick.uc") >= 0, "cron-запись на месте");
	cleanup(sb);

	let sb2 = mk_sandbox(); // awg.out пуст → health не пройдёт → откат
	seed_cfg(sb2, "install.json", { routing_opts: {} });
	eq(run_uc(sb2, "install/run.uc", null, payload).rc, 1);
	ok(index(readfile(sb2.crontab) ?? "", "watchdog/tick.uc") < 0,
		"на откате сторожить нечего — запись не ставим");
	cleanup(sb2);
});

test("первая установка (AWG), health прошёл → half-routes вооружены (arm вызван)", () => {
	let sb = mk_sandbox();
	writefile(sb.fake + "/awg.out", "pubkeyXXX\t5\n"); // свежее рукопожатие → up
	seed_cfg(sb, "install.json", { routing_opts: {} });
	let payload = sprintf("%J", { protocol: "awg", awg_conf: AWG_CONF,
		disable: [ "dns", "doh", "wifi", "firewall" ], domains: [], routing_opts: {} });
	let r = run_uc(sb, "install/run.uc", null, payload);
	eq(r.rc, 0, "exit 0: " + r.out);
	ok(index(calls(sb), "awg0_route4lo=route") >= 0, "туннель подтверждён — теперь вооружён");
	cleanup(sb);
});

test("первая установка (Reality), health провалился → ifup singtun НИ РАЗУ не вызывался", () => {
	let sb = mk_sandbox();
	with_singbox(sb);
	// pgrep.rc по умолчанию 1 (процесса нет) → tunnel_connectivity=false сразу, health не пройдёт.
	seed_cfg(sb, "install.json", { routing_opts: {} });
	let payload = sprintf("%J", { protocol: "reality", reality_conf: REALITY_CONF,
		disable: [ "dns", "doh", "wifi", "firewall" ], domains: [], routing_opts: {} });
	let r = run_uc(sb, "install/run.uc", null, payload);
	eq(r.rc, 1, "exit 1: " + r.out);
	ok(index(calls(sb), "ifup singtun") < 0,
		"дом НЕ переключался на непроверенный туннель — раньше здесь была утечка/потеря интернета");
	cleanup(sb);
});

test("первая установка (Reality), health прошёл → ifup singtun вызван (arm)", () => {
	let sb = mk_sandbox();
	with_singbox(sb);
	writefile(sb.fake + "/pgrep.rc", "0");
	writefile(sb.fake + "/route_get.out", "1.1.1.1 dev singtun0 src 10.9.0.2\n");
	writefile(sb.fake + "/fetch.rc", "0");
	seed_cfg(sb, "install.json", { routing_opts: {} });
	let payload = sprintf("%J", { protocol: "reality", reality_conf: REALITY_CONF,
		disable: [ "dns", "doh", "wifi", "firewall" ], domains: [], routing_opts: {} });
	let r = run_uc(sb, "install/run.uc", null, payload);
	eq(r.rc, 0, "exit 0: " + r.out);
	ok(index(calls(sb), "ifup singtun") >= 0, "туннель подтверждён — теперь вооружён");
	cleanup(sb);
});

exit(summary());
