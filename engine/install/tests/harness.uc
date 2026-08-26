// harness.uc — sandbox + фейковые системные команды для host-тестов ИМПУРНОГО слоя движка
// (run.uc / replace_vpn.uc / replace_singbox.uc / reset.uc / probe.uc). Не тест — библиотека.
//
// Приём — тот же, что tests/install-singbox-test.sh («изоляция через фейки»): реальные .uc
// гоняются как subprocess, PATH подменяет системные команды стабами, а пути состояния уходят
// в sandbox через env-override'ы (ETC_CHEBURNET / UCI_CONFIG_DIR / SNAPSHOT_DIR / SB_CONFIG).
// Каждый стаб пишет свой вызов в calls-лог (uci batch — включая stdin-операции): тесты
// проверяют ПОСЛЕДОВАТЕЛЬНОСТЬ реальных действий, а не только код выхода.
//
// Поведение стабов задают файлы в <sandbox>/fake/:
//   apk.rc, nslookup.rc, pgrep.rc, fetch.rc      — код выхода (нет файла → дефолт)
//   awg.out, route_get.out, route_default.out     — stdout awg show / ip route get / ip route show default
//   board.json, wan.json, lan.json               — ответы ubus (дефолты пишет mk_sandbox)
// Артефакты, которые шаги пишут в /etc, уезжают в sandbox через CHEB_NFT_PATH/CHEB_HOTPLUG_PATH.

import { writefile, readfile, mkdir } from "fs";
import { sh } from "../../lib/proc.uc";

const ENGINE = sourcepath(0, true) + "/../..";

function shq(s) {
	return "'" + replace(s ?? "", "'", "'\\''") + "'";
}

// Один стаб: лог вызова + сценарное поведение. body — shell-код ПОСЛЕ строки логирования.
function write_stub(bin, name, body) {
	writefile(bin + "/" + name,
		"#!/bin/sh\n" +
		"echo \"" + name + " $*\" >> \"${CALLS:-/dev/null}\"\n" +
		body + "\n");
	sh(sprintf("chmod +x %s", shq(bin + "/" + name)));
}

// mk_sandbox() → объект с путями. Дефолтное состояние: preflight проходит (apk ok, board 25.12,
// WAN eth0 c шлюзом), health по умолчанию НЕ проходит (awg.out пуст, fetch.rc=1) — «зелёные»
// сценарии включают его явно.
function mk_sandbox() {
	let root = trim(sh("mktemp -d"));
	if (length(root) == 0 || substr(root, 0, 1) != "/")
		die("harness: mktemp -d не дал sandbox");
	let sb = {
		root:   root,
		bin:    root + "/bin",
		fake:   root + "/fake",
		etc:    root + "/etc",        // ETC_CHEBURNET
		config: root + "/config",     // UCI_CONFIG_DIR (снимок/восстановление)
		snap:   root + "/snap",       // SNAPSHOT_DIR
		sbconf: root + "/sing-box-config.json", // SB_CONFIG
		nft:    root + "/10-cheburnet.nft",     // CHEB_NFT_PATH (в sandbox нет /etc/nftables.d)
		hotplug: root + "/99-cheburnet",        // CHEB_HOTPLUG_PATH
		state:  root + "/state",      // STATE_FILE
		reason: root + "/reason",     // REASON_FILE
		calls:  root + "/calls.log",
		crontab: root + "/crontab",   // CRONTAB_FILE: сторож ставит cron-запись — в sandbox, не в /etc хоста
	};
	mkdir(sb.bin, 0o755); mkdir(sb.fake, 0o755);
	mkdir(sb.etc, 0o755); mkdir(sb.config, 0o755);

	// ubus: только нужные вызовы; факты — из fake/*.json (сценарий может переписать).
	writefile(sb.fake + "/board.json", '{"release":{"version":"25.12.0"}}\n');
	writefile(sb.fake + "/wan.json",
		'{"l3_device":"eth0","route":[{"target":"0.0.0.0","mask":0,"nexthop":"192.0.2.1"}],' +
		'"ipv4-address":[{"address":"203.0.113.7","mask":24}]}\n');
	writefile(sb.fake + "/lan.json", '{"ipv4-address":[{"address":"192.168.1.1","mask":24}]}\n');
	writefile(sb.fake + "/route_default.out", "default via 192.0.2.1 dev eth0 proto static\n");

	write_stub(sb.bin, "ubus",
		'case "$*" in\n' +
		'  *"system board"*) cat "$FAKE_DIR/board.json" 2>/dev/null ;;\n' +
		'  *"network.interface.wan"*) cat "$FAKE_DIR/wan.json" 2>/dev/null ;;\n' +
		'  *"network.interface.lan"*) cat "$FAKE_DIR/lan.json" 2>/dev/null ;;\n' +
		'esac\nexit 0');
	// uci: batch → операции из stdin в calls-лог; get → «ключа нет» (rc 1) — тесты сеют
	// состояние файлами, а не uci-базой. Остальное — молчаливый успех.
	write_stub(sb.bin, "uci",
		'if [ "$1" = "batch" ]; then cat >> "${CALLS:-/dev/null}"; exit 0; fi\n' +
		'case "$*" in *" get "*|"get "*|*"-q get"*) exit 1 ;; esac\nexit 0');
	write_stub(sb.bin, "apk",   'exit "$(cat "$FAKE_DIR/apk.rc" 2>/dev/null || echo 0)"');
	write_stub(sb.bin, "awg",   'cat "$FAKE_DIR/awg.out" 2>/dev/null\nexit 0');
	write_stub(sb.bin, "nslookup", 'exit "$(cat "$FAKE_DIR/nslookup.rc" 2>/dev/null || echo 0)"');
	write_stub(sb.bin, "pgrep",    'exit "$(cat "$FAKE_DIR/pgrep.rc" 2>/dev/null || echo 1)"');
	write_stub(sb.bin, "uclient-fetch", 'exit "$(cat "$FAKE_DIR/fetch.rc" 2>/dev/null || echo 1)"');
	// df: по умолчанию настоящий (на хосте места вдоволь → preflight проходит). Сценарий
	// подкладывает fake/df.out и получает «мало свободного флеша» — soft-провал гейткипера.
	// Настоящий df зовём по абсолютному пути: PATH начинается с sb.bin, иначе стаб позвал бы себя.
	write_stub(sb.bin, "df",
		'if [ -f "$FAKE_DIR/df.out" ]; then cat "$FAKE_DIR/df.out"; exit 0; fi\n' +
		'for p in /usr/bin/df /bin/df; do [ -x "$p" ] && exec "$p" "$@"; done\nexit 1');
	// ip: два запроса, которые реально читает движок. `route show default` — предусловие Full-тира
	// (sing-box выбирает по нему интерфейс до сервера); дефолт в песочнице = «обычный роутер с WAN»,
	// сценарий про пропавший маршрут обнуляет route_default.out.
	write_stub(sb.bin, "ip",
		'case "$*" in\n' +
		'  *"route show default"*) cat "$FAKE_DIR/route_default.out" 2>/dev/null ;;\n' +
		'  *"route get"*) cat "$FAKE_DIR/route_get.out" 2>/dev/null ;;\n' +
		'esac\nexit 0');
	for (let name in ["nft", "ifup", "ifdown", "wifi", "passwd", "logger"])
		write_stub(sb.bin, name, "exit 0");
	// sleep: мгновенный — health-циклы (15×2с) и ретраи не тянут время теста.
	writefile(sb.bin + "/sleep", "#!/bin/sh\nexit 0\n");
	sh(sprintf("chmod +x %s", shq(sb.bin + "/sleep")));
	return sb;
}

// with_singbox(sb) — «бинарь sing-box установлен» (command -v его находит).
function with_singbox(sb) {
	write_stub(sb.bin, "sing-box", "exit 0");
}

function env_prefix(sb) {
	return sprintf(
		"PATH=%s:$PATH CALLS=%s FAKE_DIR=%s UCI_CONFIG_DIR=%s SNAPSHOT_DIR=%s " +
		"ETC_CHEBURNET=%s SB_CONFIG=%s STATE_FILE=%s REASON_FILE=%s SB_SLEEP=0 SB_RETRIES=2 " +
		// Без override cron.uc правил бы /etc/crontabs/root ХОСТА (а CI ходит под root).
		"CRONTAB_FILE=%s " +
		// Артефакты, которые шаг firewall пишет в /etc: в sandbox таких каталогов нет.
		"CHEB_NFT_PATH=%s CHEB_HOTPLUG_PATH=%s",
		sb.bin, sb.calls, sb.fake, sb.config, sb.snap,
		sb.etc, sb.sbconf, sb.state, sb.reason, sb.crontab, sb.nft, sb.hotplug);
}

// run_uc(sb, rel, args?, stdin_text?, extra_env?) → { rc, out } — запустить engine/<rel> в sandbox
// (rel с ведущим «/» — абсолютный путь, для тестовых обёрток вне engine/). extra_env — строка
// «VAR=val …» перед командой: ею подменяют то, что иначе пришлось бы держать в проде (например
// ENGINE_DIR, чтобы подставить шаг-заглушку).
// stdout+stderr вместе: тесты проверяют и сообщения об откате (warn).
function run_uc(sb, rel, args, stdin_text, extra_env) {
	let path = (substr(rel, 0, 1) == "/") ? rel : ENGINE + "/" + rel;
	let cmd = sprintf("%s %s ucode -R %s%s 2>&1", env_prefix(sb), extra_env ?? "", path,
		args ? " " + args : "");
	if (stdin_text != null)
		cmd = sprintf("printf '%%s' %s | %s", shq(stdin_text), cmd);
	let out = sh("{ " + cmd + "; echo __rc=$?; } 2>&1");
	let m = match(out, /__rc=([0-9]+)\s*$/);
	return { rc: m ? int(m[1]) : -1, out: out };
}

function calls(sb) {
	return readfile(sb.calls) ?? "";
}

function reset_calls(sb) {
	writefile(sb.calls, "");
}

function cleanup(sb) {
	sh(sprintf("rm -rf %s", shq(sb.root)));
}

export { mk_sandbox, with_singbox, run_uc, calls, reset_calls, cleanup, write_stub, shq, ENGINE };
