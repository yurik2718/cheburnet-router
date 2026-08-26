// test_reapply.uc — host-тест восстановления ip-части data-plane (install/reapply.uc) на фейках.
//
// ЗАЧЕМ ЭТОТ КОД ВООБЩЕ ЕСТЬ (оплачено живым прогоном на GL-MT3000, 2026-08-01): nft-часть
// переживает перезагрузку файлом в /etc/nftables.d/, а `ip rule fwmark → table` и default-маршрут
// direct-таблицы живут только в ЯДРЕ и после ребута исчезают. Симптом худший из возможных: панель
// зелёная, туннель поднят, наборы direct наполняются — но помеченный трафик уходит В ТУННЕЛЬ,
// потому что направлять его стало нечем. Split-tunnel, главная функция продукта, молча выключается.
//
// ЧТО ПРОВЕРЯЕМ ЗДЕСЬ: РЕШЕНИЕ переприменения — какой WAN он берёт и что передаёт шагу firewall.
// Сам шаг подменяем заглушкой: полностью он в sandbox не исполним (нет /etc/init.d/firewall), а его
// содержимое проверено своими юнитами. Что правила реально возвращаются после загрузки — уровень
// QEMU (qemu-reboot) и физического роутера.

import { test, eq, ok, summary } from "../../lib/assert.uc";
import { writefile, mkdir, access } from "fs";
import { mk_sandbox, run_uc, cleanup, shq, write_stub } from "./harness.uc";
import { sh } from "../../lib/proc.uc";

// stub_engine(sb) → путь к «движку», где шаги лишь фиксируют факт вызова: firewall пишет
// полученный payload, vpn — свои аргументы (по нему видно, звалась ли миграция маршрута).
function stub_engine(sb) {
	let dir = sb.root + "/engine";
	mkdir(dir, 0o755); mkdir(dir + "/steps", 0o755);
	mkdir(dir + "/steps/firewall", 0o755); mkdir(dir + "/steps/vpn", 0o755);
	writefile(dir + "/steps/firewall/apply.uc",
		sprintf("import { stdin, writefile } from \"fs\";\nwritefile(%s, stdin.read(\"all\") ?? \"\");\n",
			shq(sb.root + "/payload.json")));
	writefile(dir + "/steps/vpn/apply.uc",
		sprintf("import { writefile } from \"fs\";\nwritefile(%s, join(\" \", ARGV) + \"\\n\");\n",
			shq(sb.root + "/vpn-args.txt")));
	return dir;
}

// with_old_route_scheme(sb) — uci отвечает '1' на route_allowed_ips (установка до half-routes).
function with_old_route_scheme(sb) {
	write_stub(sb.bin, "uci",
		'if [ "$1" = "batch" ]; then cat >> "${CALLS:-/dev/null}"; exit 0; fi\n' +
		'case "$*" in *"awg0_peer.route_allowed_ips"*) echo 1; exit 0 ;; esac\n' +
		'case "$*" in *" get "*|"get "*|*"-q get"*) exit 1 ;; esac\nexit 0');
}

function payload_of(sb) {
	return sh(sprintf("cat %s 2>/dev/null", shq(sb.root + "/payload.json")));
}

test("reapply: передаёт шагу домены, туннель и СВЕЖИЙ WAN из netifd", () => {
	let sb = mk_sandbox();
	let eng = stub_engine(sb);
	writefile(sb.etc + "/install.json",
		'{"protocol":"awg","routing_opts":{"wan_if":"eth0","wan_gw":"192.0.2.1","tunnel_if":"awg0"},' +
		'"domains":["example.com"]}\n');
	let r = run_uc(sb, "install/reapply.uc", null, null, sprintf("ENGINE_DIR=%s", shq(eng)));
	eq(r.rc, 0, "exit 0: " + r.out);
	let p = payload_of(sb);
	ok(index(p, '"example.com"') >= 0, "домены взяты из сохранённой конфигурации");
	ok(index(p, '"tunnel_if"') >= 0 && index(p, "awg0") >= 0, "туннель передан (NAT-зона и метки)");
	ok(index(p, "192.0.2.1") >= 0, "шлюз WAN — для default-маршрута direct-таблицы");
	cleanup(sb);
});

test("reapply: WAN берётся ЗАНОВО, а не из install.json (сменился шлюз — правило не устареет)", () => {
	let sb = mk_sandbox();
	let eng = stub_engine(sb);
	// В файле — прежний WAN; netifd (фейк wan.json) отдаёт актуальный eth0 / 192.0.2.1.
	writefile(sb.etc + "/install.json",
		'{"protocol":"awg","routing_opts":{"wan_if":"eth9","wan_gw":"10.9.9.9","tunnel_if":"awg0"},' +
		'"domains":[]}\n');
	let r = run_uc(sb, "install/reapply.uc", null, null, sprintf("ENGINE_DIR=%s", shq(eng)));
	eq(r.rc, 0, "exit 0: " + r.out);
	let p = payload_of(sb);
	ok(index(p, "192.0.2.1") >= 0, "шлюз взят из netifd");
	ok(index(p, "10.9.9.9") < 0, "устаревший шлюз из файла НЕ применён");
	cleanup(sb);
});

test("reapply: на ненастроенном роутере — тихий no-op (хук зовётся на каждый ifup WAN)", () => {
	let sb = mk_sandbox();
	let eng = stub_engine(sb);
	let r = run_uc(sb, "install/reapply.uc", null, null, sprintf("ENGINE_DIR=%s", shq(eng)));
	eq(r.rc, 0, "успех без конфигурации: " + r.out);
	eq(trim(r.out), "__rc=0", "ни строчки в лог — иначе log-snapshot забьётся шумом на каждом ifup");
	eq(trim(payload_of(sb)), "", "шаг не запускался");
	cleanup(sb);
});

test("reapply: протокол Full-тира → в шаг уезжает singtun0, а не awg0", () => {
	let sb = mk_sandbox();
	let eng = stub_engine(sb);
	// tunnel_if в старых установках мог не сохраниться — выводим из протокола.
	writefile(sb.etc + "/install.json",
		'{"protocol":"reality","routing_opts":{"wan_if":"eth0","wan_gw":"192.0.2.1"},"domains":[]}\n');
	let r = run_uc(sb, "install/reapply.uc", null, null, sprintf("ENGINE_DIR=%s", shq(eng)));
	eq(r.rc, 0, "exit 0: " + r.out);
	let p = payload_of(sb);
	ok(index(p, "singtun0") >= 0, "NAT-зона и метки должны смотреть на активный туннель");
	ok(index(p, "awg0") < 0, "чужой туннель в план не попадает");
	cleanup(sb);
});

test("reapply: WAN ещё не поднят → НЕ применяем половину (правило без маршрута хуже, чем ничего)", () => {
	let sb = mk_sandbox();
	let eng = stub_engine(sb);
	writefile(sb.etc + "/install.json",
		'{"protocol":"awg","routing_opts":{"wan_if":"eth0","wan_gw":"192.0.2.1","tunnel_if":"awg0"},' +
		'"domains":["example.com"]}\n');
	// netifd молчит про wan и дефолт-маршрута в ядре тоже нет — ровно первые секунды после загрузки.
	writefile(sb.fake + "/wan.json", "");
	writefile(sb.fake + "/route_default.out", "");
	let r = run_uc(sb, "install/reapply.uc", null, null, sprintf("ENGINE_DIR=%s", shq(eng)));
	eq(r.rc, 2, "код 2 — «WAN не найден»: hotplug его игнорирует, set_mode по нему отвечает честно: " + r.out);
	eq(trim(payload_of(sb)), "", "шаг не запускался — иначе правило увело бы трафик в пустую таблицу");
	cleanup(sb);
});

// --- миграция маршрута туннеля на half-routes (инцидент «WAN забрал дефолт обратно») ---
// Пакет обновляется без переустановки, поэтому старая схема (route_allowed_ips='1') должна
// сняться сама. Иначе роутер остаётся уязвимым: подъём WAN возвращает netifd'у его default,
// вытесняет туннельный, и kill-switch режет весь не-direct трафик при живом туннеле.
test("reapply: старая схема route_allowed_ips='1' → зовёт vpn/apply.uc --arm", () => {
	let sb = mk_sandbox();
	let eng = stub_engine(sb);
	with_old_route_scheme(sb);
	writefile(sb.etc + "/install.json",
		'{"protocol":"awg","routing_opts":{"wan_if":"eth0","tunnel_if":"awg0"},"domains":[]}\n');
	let r = run_uc(sb, "install/reapply.uc", null, null, sprintf("ENGINE_DIR=%s", shq(eng)));
	eq(r.rc, 0, "exit 0: " + r.out);
	ok(index(sh(sprintf("cat %s 2>/dev/null", shq(sb.root + "/vpn-args.txt"))), "--arm") >= 0,
		"вооружение переприменено — половинные маршруты вместо замещающего default");
	cleanup(sb);
});

test("reapply: схема уже новая → vpn-шаг НЕ трогаем (миграция одноразовая по факту)", () => {
	let sb = mk_sandbox(); // дефолтный uci-стаб: get отвечает «ключа нет»
	let eng = stub_engine(sb);
	writefile(sb.etc + "/install.json",
		'{"protocol":"awg","routing_opts":{"wan_if":"eth0","tunnel_if":"awg0"},"domains":[]}\n');
	let r = run_uc(sb, "install/reapply.uc", null, null, sprintf("ENGINE_DIR=%s", shq(eng)));
	eq(r.rc, 0, "exit 0: " + r.out);
	ok(!access(sb.root + "/vpn-args.txt"),
		"hotplug зовёт reapply на каждый холодный ifup — лишний reload сети тут недопустим");
	cleanup(sb);
});

test("reapply: Full-тир со старым значением в uci → миграция AWG не запускается", () => {
	let sb = mk_sandbox();
	let eng = stub_engine(sb);
	with_old_route_scheme(sb);
	writefile(sb.etc + "/install.json",
		'{"protocol":"reality","routing_opts":{"wan_if":"eth0","tunnel_if":"singtun0"},"domains":[]}\n');
	run_uc(sb, "install/reapply.uc", null, null, sprintf("ENGINE_DIR=%s", shq(eng)));
	ok(!access(sb.root + "/vpn-args.txt"), "активен sing-box — awg0 вооружать нечего");
	cleanup(sb);
});

exit(summary());
