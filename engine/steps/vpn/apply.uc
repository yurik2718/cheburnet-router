// apply.uc — применение VPN-шага (импурно): teardown → uci batch → reload, чтобы netifd поднял awg0.
// План — vpn.uc (тесты: vpn/tests). Флаги: --dry-run | --no-arm (без half-routes, первая установка) |
// --arm (довооружить) | --disarm (снять маршрут, конфиг оставить — аварийный режим) | --teardown.

import { stdin, popen } from "fs";
import { sh, uci_batch } from "../../lib/proc.uc";
import { wait_wan_default } from "../../lib/wan.uc";
import { parse_awg_conf, build_vpn_plan, build_arm_ops, build_disarm_ops,
         owned_sections } from "./vpn.uc";

// dev_present(iface) — создал ли netifd kernel-устройство интерфейса (ip link).
function dev_present(iface) {
	return trim(sh(sprintf("ip link show %s >/dev/null 2>&1; echo $?", iface))) == "0";
}

let teardown = (length(ARGV) > 0 && ARGV[0] == "--teardown");
let disarm   = (length(ARGV) > 0 && ARGV[0] == "--disarm");
let dry      = (length(ARGV) > 0 && ARGV[0] == "--dry-run");
let no_arm   = (length(ARGV) > 0 && ARGV[0] == "--no-arm");
let arm_only = (length(ARGV) > 0 && ARGV[0] == "--arm");

// --arm: довооружить уже применённый (--no-arm) интерфейс — только half-routes + reload, без
// пересборки плана из stdin (его и не подать: соединение уже поднято под предыдущим конфигом).
// Он же путь МИГРАЦИИ установок со старой схемой (route_allowed_ips='1' → '0' + half-routes),
// поэтому идемпотентен и заканчивается проверкой WAN-дефолта.
if (arm_only) {
	let arm = build_arm_ops({});
	// delete по одной через `uci -q`: отсутствие секций — норма (первое вооружение), а uci_batch
	// считает сбоем любой вывод.
	for (let i = 0; i < length(arm.teardown); i++) {
		let d = popen(sprintf("uci -q %s", arm.teardown[i]), "r");
		if (d) d.close();
	}
	let rc = uci_batch(arm.setup, "network");
	if (rc != 0)
		die(sprintf("vpn/apply: uci batch (arm) вернул %d", rc));
	// reload, а НЕ ifup: netifd ставит добавленные route-секции без перезапуска интерфейса
	// (проверено обоими способами в qemu-route-fallback). Перезапуск здесь был бы вреден — туннель мигал
	// бы ровно тогда, когда health-check его только что подтвердил.
	let p = popen("/etc/init.d/network reload >/dev/null 2>&1", "r");
	if (p) p.close();
	let ifname = owned_sections({})[0];
	let wan_ok = wait_wan_default();
	printf("vpn: маршрут вооружён (half-routes на %s, WAN-дефолт %s)\n",
		ifname, wan_ok ? "на месте" : "НЕ вернулся — смотрите wan в netifd");
	exit(0);
}

// --disarm: снять ТОЛЬКО маршрут (аварийный режим). Интерфейс и ключи остаются — вернуть защиту
// можно одним --arm, не спрашивая у человека конфиг заново.
if (disarm) {
	let d = build_disarm_ops({});
	for (let i = 0; i < length(d.teardown); i++) {
		let p = popen(sprintf("uci -q %s", d.teardown[i]), "r");
		if (p) p.close();
	}
	let rc = uci_batch(d.setup, "network");
	if (rc != 0)
		die(sprintf("vpn/apply: uci batch (disarm) вернул %d", rc));
	let p = popen("/etc/init.d/network reload >/dev/null 2>&1", "r");
	if (p) p.close();
	printf("vpn: маршрут снят (half-routes убраны, конфиг %s на месте)\n", owned_sections({})[0]);
	exit(0);
}

// --teardown — снять awg0 (смена протокола awg→reality): ifdown + удалить наши секции network
// (иначе awg0 держит свой default-маршрут и конфликтует с singtun0). Отсутствие секций — норма.
if (teardown) {
	let sects = owned_sections({});
	sh(sprintf("ifdown %s >/dev/null 2>&1", sects[0]));
	let ops = [];
	for (let i = 0; i < length(sects); i++)
		push(ops, "delete network." + sects[i]);
	uci_batch(ops, "network");
	// Следующий шаг (sing-box) обязан достучаться до сервера через WAN (см. lib/wan.uc). Невозврат
	// здесь не фатален: подхватит предусловие следующего шага.
	let wan_back = wait_wan_default();
	printf("vpn: teardown выполнен (интерфейс %s снят из network, WAN-маршрут %s)\n",
		sects[0], wan_back ? "на месте" : "НЕ вернулся — смотрите wan в netifd");
	exit(0);
}

let conf = stdin.read("all") ?? "";
let plan = build_vpn_plan(parse_awg_conf(conf), no_arm ? { arm: false } : {});
if (!plan.ok) {
	for (let i = 0; i < length(plan.errors); i++)
		warn("vpn: " + plan.errors[i] + "\n");
	exit(1);
}

if (dry) {
	for (let i = 0; i < length(plan.teardown); i++) print("  " + plan.teardown[i] + "\n");
	for (let i = 0; i < length(plan.setup); i++) print("  " + plan.setup[i] + "\n");
	exit(0);
}

// teardown по одному с глушением: удаляем старые секции, отсутствие — норма.
for (let i = 0; i < length(plan.teardown); i++) {
	let p = popen(sprintf("uci -q %s", plan.teardown[i]), "r");
	if (p) p.close();
}

// setup атомарно через `uci batch` + commit. rc проверяем: молча упавший batch =
// полуприменённый network-конфиг под видом успеха (контракт lib/proc.uc, урок dns/doh).
let rc = uci_batch(plan.setup, "network");
if (rc != 0)
	die(sprintf("vpn/apply: uci batch упал (код %d)", rc));

// Платформенный квирк (OpenWrt 25.12.4): на свежей установке proto-handler amneziawg только что
// доставлен пакетом, и reload его не подхватывает (proto:none/NO_DEVICE) — нужен restart, который
// перечитывает /lib/netifd/proto/*. На повторных запусках хватает более лёгкого reload.
let p = popen("/etc/init.d/network reload >/dev/null 2>&1", "r");
if (p) p.close();
// Ждём появления kernel-устройства (до 5с). Нет → reload не подхватил свежий proto-handler.
let up = false;
for (let i = 0; i < 5 && !up; i++) { sh("sleep 1"); up = dev_present(plan.interface); }
if (!up) {
	let r = popen("/etc/init.d/network restart >/dev/null 2>&1", "r");
	if (r) r.close();
	// restart перечитывает proto-handlers и поднимает интерфейсы НЕ мгновенно — блокируемся до
	// появления интерфейса (до 15с), чтобы следующие шаги и health-check видели готовое устройство.
	for (let i = 0; i < 15 && !up; i++) { sh("sleep 1"); up = dev_present(plan.interface); }
}
if (!up)
	warn(sprintf("vpn: интерфейс %s не появился после reload+restart — health-check это поймает (см. logread)\n",
		plan.interface));

printf("vpn: применено — интерфейс %s, peer %s%s\n", plan.interface, plan.peer_section,
	no_arm ? " (маршрут ЕЩЁ НЕ вооружён, --no-arm)" : "");
