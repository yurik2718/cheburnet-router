// apply.uc — применение DoH-шага на роутере (импурно): читает текущее состояние из uci, строит
// план (doh.uc), применяет и перезапускает https-dns-proxy + dnsmasq. Зависит от dnsmasq
// noresolv='1' (ставит DNS-шаг) — без него dnsmasq утечёт в ISP-resolv.conf.
//   ucode -R apply.uc [--dry-run]

import { stdin, popen } from "fs";
import { sh, uci_batch } from "../../lib/proc.uc";
import { build_doh_plan } from "./doh.uc";
import { resolvers_for } from "./providers.uc";

let dry = (length(ARGV) > 0 && ARGV[0] == "--dry-run");

// Вход (опционально): {provider:"<id>"} — выбранный DNS-провайдер. Нет/неизвестный → дефолт
// каталога (fail-safe в resolvers_for). Валидность id гарантирует ubus-граница (enum).
let raw = trim(stdin.read("all") ?? "");
let req = (substr(raw, 0, 1) == "{") ? json(raw) : {};
let resolvers = resolvers_for(req.provider);

// Текущие секции https-dns-proxy: строки вида `https-dns-proxy.<name>=https-dns-proxy`.
let hdp_sections = [];
let show = sh("uci -q show https-dns-proxy 2>/dev/null");
let lines = split(show, "\n");
for (let i = 0; i < length(lines); i++) {
	let m = match(lines[i], /^https-dns-proxy\.([^.=]+)=https-dns-proxy$/);
	if (m) push(hdp_sections, m[1]);
}

// Текущие dnsmasq server (без пробелов в записях → split по whitespace).
let srv_raw = trim(sh("uci -q get dhcp.@dnsmasq[0].server 2>/dev/null"));
let servers = length(srv_raw) > 0 ? split(srv_raw, /[ \t]+/) : [];

// strict-order dnsmasq: держим сами (порядок upstream'ов значим — см. doh.uc).
let strictorder = trim(sh("uci -q get dhcp.@dnsmasq[0].strictorder 2>/dev/null"));

let plan = build_doh_plan({ hdp_sections: hdp_sections, servers: servers,
	options: { strictorder: strictorder } }, { resolvers: resolvers });
if (!plan.ok) {
	for (let i = 0; i < length(plan.errors); i++) warn("doh: " + plan.errors[i] + "\n");
	exit(1);
}

if (dry) {
	for (let i = 0; i < length(plan.hdp_teardown); i++) print("  " + plan.hdp_teardown[i] + "\n");
	for (let i = 0; i < length(plan.hdp_setup); i++)    print("  " + plan.hdp_setup[i] + "\n");
	for (let i = 0; i < length(plan.dnsmasq_ops); i++)  print("  " + plan.dnsmasq_ops[i] + "\n");
	for (let i = 0; i < length(plan.dnsmasq_cleanup ?? []); i++) print("  " + plan.dnsmasq_cleanup[i] + "\n");
	exit(0);
}

for (let i = 0; i < length(plan.hdp_teardown); i++) {
	let p = popen(sprintf("uci -q %s", plan.hdp_teardown[i]), "r");
	if (p) p.close();
}

// Платформенный квирк: `uci batch` выходит 0 даже на ошибках — uci_batch (lib/proc.uc) ловит их
// по выводу. rc ОБЯЗАТЕЛЬНО проверяем, иначе сбой (нет пакета https-dns-proxy) отчитается успехом.
let rc = uci_batch(plan.hdp_setup, "https-dns-proxy");
if (rc != 0)
	die(sprintf("doh/apply: uci batch (https-dns-proxy) не прошёл (код %d; установлен ли пакет?)", rc));
let rc2 = uci_batch(plan.dnsmasq_ops, "dhcp");
if (rc2 != 0)
	die(sprintf("doh/apply: uci batch (dhcp upstream) не прошёл (код %d)", rc2));
// Своим батчем, rc игнорируется осознанно: отсутствие ключей — норма (повторное применение).
// Зачем уборка — см. doh.uc (пакет иначе восстанавливает сток из своих backup-ключей).
uci_batch(plan.dnsmasq_cleanup ?? [], "dhcp");

sh("/etc/init.d/https-dns-proxy restart >/dev/null 2>&1");
sh("/etc/init.d/dnsmasq reload >/dev/null 2>&1 || /etc/init.d/dnsmasq restart >/dev/null 2>&1");
printf("doh: применено — резолверов %d, upstream dnsmasq → %s\n",
	length(plan.servers), join(", ", plan.servers));
