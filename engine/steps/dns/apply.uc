// apply.uc — применение DNS-шага (импурно): текущее состояние из uci → план (dns.uc, тесты: tests/)
// → `uci batch` + commit → reload dnsmasq.
//   echo '{"domains":["example.com"]}' | ucode -R apply.uc [--dry-run]

import { stdin } from "fs";
import { sh, uci_batch } from "../../lib/proc.uc";
import { build_plan } from "../../routing/routing.uc";
import { owned_sections, build_dns_plan } from "./dns.uc";

let raw = trim(stdin.read("all") ?? "");
if (substr(raw, 0, 1) != "{")
	die("dns/apply: ожидаю JSON {domains, routing_opts?, dns_opts?} со stdin");
let req = json(raw);
let dry = (length(ARGV) > 0 && ARGV[0] == "--dry-run");

let section = (req.dns_opts && req.dns_opts.section) ? req.dns_opts.section : "@dnsmasq[0]";

// list_get(key) — uci-список одной строкой (элементы через пробел; наши значения без пробелов).
function list_get(key) {
	let v = trim(sh(sprintf("uci -q get %s 2>/dev/null", key)));
	return length(v) > 0 ? split(v, /[ \t]+/) : [];
}

// Снимок наших ipset-секций: отсутствующая секция → нет ключа в sections.
let sections = {};
let owned = owned_sections(req.dns_opts);
for (let i = 0; i < length(owned); i++) {
	let sect = owned[i];
	if (length(trim(sh(sprintf("uci -q get dhcp.%s 2>/dev/null", sect)))) == 0)
		continue;
	sections[sect] = {
		name: list_get("dhcp." + sect + ".name"),
		domain: list_get("dhcp." + sect + ".domain"),
		family: trim(sh(sprintf("uci -q get dhcp.%s.family 2>/dev/null", sect))),
	};
}
let cur_noresolv = trim(sh(sprintf("uci -q get dhcp.%s.noresolv 2>/dev/null", section)));

let current = { sections: sections, options: { noresolv: cur_noresolv } };
let routing_plan = build_plan(req.domains ?? [], req.routing_opts);
let plan = build_dns_plan(routing_plan, current, req.dns_opts);

if (!plan.changed) {
	print("dns: уже применено — изменений нет\n");
	exit(0);
}

for (let i = 0; i < length(plan.ops); i++)
	print("  " + plan.ops[i] + "\n");

if (dry) {
	print("dns: --dry-run, не применяю\n");
	exit(0);
}

// rc проверяем: молча упавший batch = полуприменённый конфиг под видом успеха. Платформенный
// квирк `uci batch` (exit 0 даже на ошибках) разобран в lib/proc.uc:uci_batch.
let rc = uci_batch(plan.ops, "dhcp");
if (rc != 0)
	die(sprintf("dns/apply: uci batch упал (код %d)", rc));

sh("/etc/init.d/dnsmasq reload >/dev/null 2>&1 || /etc/init.d/dnsmasq restart >/dev/null 2>&1");
printf("dns: применено (%d direct-доменов)\n", length(plan.domains));
