// apply.uc — применение sing-box шага (импурно): config.json → uci-включение → рестарт → ifup TUN.
// План — singbox.uc (тесты: singbox/tests). Флаги как у steps/vpn/apply.uc: --dry-run | --no-arm
// (без ifup, первая установка до health-check) | --arm | --disarm | --teardown. См. [[reliability]].

import { stdin, popen } from "fs";
import { build_singbox_plan, build_net_plan, config_path, service_name, network_sections } from "./singbox.uc";
import { wait_wan_default } from "../../lib/wan.uc";
import { sh, uci_batch } from "../../lib/proc.uc";

let teardown = (length(ARGV) > 0 && ARGV[0] == "--teardown");
let dry      = (length(ARGV) > 0 && ARGV[0] == "--dry-run");
let no_arm   = (length(ARGV) > 0 && ARGV[0] == "--no-arm");
let arm_only = (length(ARGV) > 0 && ARGV[0] == "--arm");

// SB_CONFIG: env-override пути config.json, тот же читают run.uc и replace_singbox.uc —
// все слои должны писать/бэкапить ОДИН файл. Без env — дефолт плана.
const SB_OPTS = getenv("SB_CONFIG") ? { config_path: getenv("SB_CONFIG") } : {};

// writefile(path, text) → атомарная запись файла (tmp + rename).
function writefile(path, text) {
	let dir = replace(path, /\/[^\/]+$/, "");
	let m = popen(sprintf("mkdir -p '%s'", dir), "r"); if (m) m.close();
	let w = popen(sprintf("cat > '%s.tmp'", path), "w");
	if (!w) die("singbox/apply: не смог записать " + path);
	w.write(text);
	w.close();
	let r = popen(sprintf("mv '%s.tmp' '%s'", path, path), "r"); if (r) r.close();
}

// INITD_DIR — env-override ТОЛЬКО для host-тестов (как SB_CONFIG): init-скрипты в sandbox — стабы.
const INITD = getenv("INITD_DIR") ?? "/etc/init.d";
function svc(action, name) {
	let p = popen(sprintf("%s/%s %s >/dev/null 2>&1", INITD, name, action), "r");
	if (p) p.close();
}

// --arm: поднять netifd-интерфейс поверх УЖЕ применённого шага; stdin и config.json не трогает.
// Half-routes живут на TUN, а TUN — на живом sing-box: мёртвый процесс (OOM, исчерпанный respawn)
// `ifup` не оживит — сначала сервис. Так «arm» сторожа чинит и упавший sing-box, а не только маршрут.
if (arm_only) {
	if (trim(sh("pgrep sing-box >/dev/null 2>&1; echo $?")) != "0")
		svc("restart", service_name({}));
	sh(sprintf("ifup %s >/dev/null 2>&1", network_sections({})[0]));
	printf("singbox: маршрут вооружён (%s)\n", network_sections({})[0]);
	exit(0);
}

// --disarm: снять half-routes, не трогая конфиг и сервис (аварийный режим, install/pause.uc).
// Зеркало --arm: там ifup, здесь ifdown — секции network остаются, вернуть можно одним --arm.
if (length(ARGV) > 0 && ARGV[0] == "--disarm") {
	sh(sprintf("ifdown %s >/dev/null 2>&1", network_sections({})[0]));
	printf("singbox: маршрут снят (%s опущен, конфиг на месте)\n", network_sections({})[0]);
	exit(0);
}

if (teardown) {
	let name = service_name({});
	svc("stop", name);
	svc("disable", name);
	// ИНВАРИАНТ: ifdown ДО удаления секций network — иначе netifd оставляет half-route
	// в мёртвый TUN, и LAN лишается интернета.
	sh(sprintf("ifdown %s >/dev/null 2>&1", network_sections({})[0]));
	let nsects = network_sections({});
	let nops = [];
	for (let i = 0; i < length(nsects); i++)
		push(nops, "delete network." + nsects[i]);
	uci_batch(nops, "network");
	// uci-выключение + удаление нашего конфиг-файла (отсутствие — норма).
	uci_batch([ "set sing-box.main.enabled='0'" ], "sing-box");
	let r = popen(sprintf("rm -f '%s'", config_path(SB_OPTS)), "r"); if (r) r.close();
	printf("singbox: teardown выполнен (сервис выключен, маршрут и конфиг убраны)\n");
	exit(0);
}

let input = stdin.read("all") ?? "";
let plan = build_singbox_plan(input, SB_OPTS);
if (!plan.ok) {
	for (let i = 0; i < length(plan.errors); i++)
		warn("singbox: " + plan.errors[i] + "\n");
	exit(1);
}

// ИНВАРИАНТ: перед стартом в main обязан быть WAN-дефолт мимо ОБОИХ туннелей — иначе
// auto_detect_interface не дозвонится до сервера (инцидент: [[0004-multi-protocol-tiers]]).
if (!dry && !wait_wan_default()) {
	warn("singbox: в main-таблице нет маршрута по умолчанию мимо туннелей — sing-box не сможет дозвониться до сервера\n");
	warn("singbox: проверьте WAN (uci show network.wan; ip route show default) — шаг не применён, туннель не тронут\n");
	exit(1);
}

let config_text = sprintf("%J\n", plan.config);

if (dry) {
	printf("  config → %s (source: %s)\n", plan.config_path, plan.source);
	print(config_text);
	for (let i = 0; i < length(plan.uci_teardown); i++) print("  " + plan.uci_teardown[i] + "\n");
	for (let i = 0; i < length(plan.uci_setup); i++) print("  " + plan.uci_setup[i] + "\n");
	for (let i = 0; i < length(plan.net_teardown); i++) print("  " + plan.net_teardown[i] + "\n");
	for (let i = 0; i < length(plan.net_setup); i++) print("  " + plan.net_setup[i] + "\n");
	exit(0);
}

// ИНВАРИАНТ: конфиг гоняем через `sing-box check` ДО того, как он станет живым — семантику
// (в отличие от структуры) знает только бинарь. Подробно (инцидент): [[0004-multi-protocol-tiers]].
// Гейт по наличию бинаря: в dry-run/host-тестах sing-box может отсутствовать — тогда health-check
// поймает проблему позже, но валить шаг здесь не за что.
let staged = plan.config_path + ".check";
writefile(staged, config_text);
if (trim(sh("command -v sing-box 2>/dev/null")) != "") {
	let chk = sh(sprintf("sing-box check -c '%s' 2>&1; echo __rc=$?", staged));
	let m = match(chk, /__rc=([0-9]+)/);
	if (!m || m[1] != "0") {
		sh(sprintf("rm -f '%s'", staged));
		warn("singbox: sing-box отверг сгенерированный конфиг — шаг не применён, туннель не тронут\n");
		warn(trim(replace(chk, /__rc=[0-9]+\s*$/, "")) + "\n");
		exit(1);
	}
}
sh(sprintf("mv '%s' '%s'", staged, plan.config_path));

// teardown по одному с глушением (отсутствие секции — норма), затем setup атомарно.
for (let i = 0; i < length(plan.uci_teardown); i++) {
	let p = popen(sprintf("uci -q %s", plan.uci_teardown[i]), "r");
	if (p) p.close();
}
let rc = uci_batch(plan.uci_setup, "sing-box");
if (rc != 0)
	die(sprintf("singbox/apply: uci batch (sing-box) вернул %d", rc));

// netifd-маршрут (отдельный конфиг network): setup — с проверкой rc, тот же урок, что dns/doh/vpn.
for (let i = 0; i < length(plan.net_teardown); i++) {
	let p = popen(sprintf("uci -q %s", plan.net_teardown[i]), "r");
	if (p) p.close();
}
let nrc = uci_batch(plan.net_setup, "network");
if (nrc != 0)
	die(sprintf("singbox/apply: uci batch (network) вернул %d", nrc));

svc("enable", plan.service);
svc("restart", plan.service);

// Поднять netifd-интерфейс поверх TUN: netifd поставит half-routes, как только sing-box создаст
// устройство (и переустановит при пересоздании — рестарт sing-box). ifup идемпотентен.
// --no-arm: пропускаем — вызывающий (run.uc, первая установка) вооружит отдельно через --arm
// ПОСЛЕ health-check, чтобы неудачный туннель не переключал дом на себя раньше подтверждения.
if (!no_arm)
	sh(sprintf("ifup %s >/dev/null 2>&1", plan.net_iface ?? "singtun"));

printf("singbox: применено — конфиг %s, сервис %s, TUN %s%s\n",
	plan.config_path, plan.service, plan.tun,
	no_arm ? ", маршрут ЕЩЁ НЕ вооружён (--no-arm)" : sprintf(", маршрут через netifd (%s)", network_sections({})[0]));
