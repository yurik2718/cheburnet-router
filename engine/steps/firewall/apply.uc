// apply.uc — применение firewall-шага на роутере (импурно, router-side). Пишет nftables.d-файл,
// hotplug-хук, NAT-зону (uci) и ip rule/route по плану из firewall.uc (детали и инварианты — там).
//   echo '{"domains":["example.com"],"routing_opts":{"wan_if":"eth0"}}' | ucode -R apply.uc
//   ... | ucode -R apply.uc --dry-run | --teardown

import { stdin, writefile, unlink } from "fs";
import { sh, uci_batch } from "../../lib/proc.uc";
import { build_plan } from "../../routing/routing.uc";
import { build_firewall_plan } from "./firewall.uc";
import { wan_user } from "../doh/providers.uc";

function run(cmd) {
	return int(trim(sh(cmd + " >/dev/null 2>&1; echo $?")));
}

let raw = trim(stdin.read("all") ?? "");
if (substr(raw, 0, 1) != "{")
	die("firewall/apply: ожидаю JSON {domains, routing_opts{wan_if}} со stdin");
let req = json(raw);
let arg = (length(ARGV) > 0) ? ARGV[0] : "";
let dry = (arg == "--dry-run");
let teardown_only = (arg == "--teardown"); // снять наши правила (откат грязного шага оркестратором)

// uid резервного DoH-экземпляра: ИМЯ пользователя знает каталог DoH (единственный источник),
// НОМЕР — только живая система, поэтому резолвим здесь, на импурной границе. Пользователя нет
// (чужая сборка) → правило не строим: резервный путь просто не включится, хуже прежнего не станет.
if (type(req.routing_opts) != "object") req.routing_opts = {};
if (req.routing_opts.dns_uid == null) {
	let uid = trim(sh(sprintf("awk -F: '$1==\"%s\"{print $3}' /etc/passwd 2>/dev/null", wan_user())));
	if (match(uid, /^[0-9]+$/))
		req.routing_opts.dns_uid = int(uid);
	else
		warn(sprintf("firewall: нет пользователя %s — резервный путь DNS не включён\n", wan_user()));
}

let routing_plan = build_plan(req.domains ?? [], req.routing_opts);
let plan = build_firewall_plan(routing_plan, req.fw_opts);

// Пути артефактов: env-override ТОЛЬКО для host-тестов в sandbox (тот же приём, что SB_CONFIG у
// Full-тира). Модуль плана остаётся чистым — подмена живёт на импурной границе, здесь.
if (getenv("CHEB_NFT_PATH"))     plan.nft_path = getenv("CHEB_NFT_PATH");
if (getenv("CHEB_HOTPLUG_PATH")) plan.hotplug_path = getenv("CHEB_HOTPLUG_PATH");

// teardown-only: убрать nftables.d-файл (+reload вычистит цепочки), ip-правила и NAT-зону,
// ничего не ставя. Код uci_batch НЕ проверяем: teardown толерантен (отсутствие секций — норма).
if (teardown_only) {
	unlink(plan.nft_path); // отсутствие файла — норма (unlink вернёт false, игнорим)
	unlink(plan.hotplug_path); // хук снимаем вместе с правилами: иначе он вернёт их после ребута
	for (let i = 0; i < length(plan.ip_teardown); i++)
		run(plan.ip_teardown[i]);
	for (let i = 0; i < length(plan.uci_teardown); i++)
		run("uci -q " + plan.uci_teardown[i]);
	run("uci commit firewall");
	run("/etc/init.d/firewall reload");
	// Платформенный квирк: reload не удаляет чужие цепочки/сеты (см. firewall.uc) — добиваем явно.
	for (let i = 0; i < length(plan.nft_teardown); i++)
		run("nft " + plan.nft_teardown[i]);
	print("firewall: teardown выполнен (правила и NAT-зона сняты)\n");
	exit(0);
}

if (!plan.ok) {
	for (let i = 0; i < length(plan.errors); i++)
		warn("firewall: " + plan.errors[i] + "\n");
	exit(1); // отказ без изменений — лучше, чем дырявый/хардкод kill-switch
}

if (dry) {
	print("# uci teardown (NAT, || true)\n"); for (let i = 0; i < length(plan.uci_teardown); i++) print("  " + plan.uci_teardown[i] + "\n");
	print("# uci setup (uci batch) + commit firewall + fw4 reload\n"); for (let i = 0; i < length(plan.uci_setup); i++) print("  " + plan.uci_setup[i] + "\n");
	printf("# nftables.d-файл: %s\n", plan.nft_path);
	print(plan.nft_file);
	print("# ip teardown\n");   for (let i = 0; i < length(plan.ip_teardown); i++)  print("  " + plan.ip_teardown[i] + "\n");
	print("# ip setup\n");      for (let i = 0; i < length(plan.ip_setup); i++)     print("  " + plan.ip_setup[i] + "\n");
	exit(0);
}

// 1) nftables.d-файл — ДО uci-reload, чтобы тот же reload сразу включил его в fw4 (без окна
// без kill-switch).
if (!writefile(plan.nft_path, plan.nft_file))
	die(sprintf("firewall/apply: не смог записать %s", plan.nft_path));

// 1b) hotplug-хук — тоже ДО остального применения: ребут посреди установки должен вернуть уже
// полное состояние. 0755 — его запускает hotplug.
if (!writefile(plan.hotplug_path, plan.hotplug_file))
	die(sprintf("firewall/apply: не смог записать %s", plan.hotplug_path));
run(sprintf("chmod 0755 '%s'", plan.hotplug_path));

// 2) NAT-зона + commit + reload (один reload подхватывает и зону, и наш nftables.d-файл).
// rc ОБЯЗАТЕЛЬНО проверяем: без NAT-зоны kill-switch + default через awg0 = «зелёная»
// установка без интернета у LAN.
for (let i = 0; i < length(plan.uci_teardown); i++)
	run("uci -q " + plan.uci_teardown[i]);
let uci_rc = uci_batch(plan.uci_setup, "firewall");
if (uci_rc != 0)
	die(sprintf("firewall/apply: uci batch (NAT-зона) завершился кодом %d", uci_rc));
let fw_rc = run("/etc/init.d/firewall reload");
if (fw_rc != 0)
	die(sprintf("firewall/apply: fw4 reload завершился кодом %d (файл nftables.d невалиден?)", fw_rc));

// 3) ip teardown затем setup (ip rule add не идемпотентен → del перед add; отсутствие — норма).
// Строки уже полные команды ('ip rule ...' / 'ip route ...') — запускаем как есть.
for (let i = 0; i < length(plan.ip_teardown); i++)
	run(plan.ip_teardown[i]);
for (let i = 0; i < length(plan.ip_setup); i++)
	run(plan.ip_setup[i]);

printf("firewall: применено (kill-switch %s, mode %s)\n",
	length(plan.killswitch) > 0 ? "вкл" : "выкл", routing_plan.opts.mode);
