// check.uc — CLI инвариантов: факты (gather.uc, stdin) → чек-лист «что на месте».
//   ucode -R gather.uc | ucode -R check.uc [--json | --repairs]
// ИНВАРИАНТ: exit 0 = отклонений нет, 1 = есть (по нему судят QEMU-тесты и диагностика).

import { stdin } from "fs";
import { evaluate, render_report, repairs } from "./invariants.uc";

function has_flag(name) {
	for (let i = 0; i < length(ARGV); i++)
		if (ARGV[i] == name) return true;
	return false;
}

let raw = trim(stdin.read("all") ?? "");
if (length(raw) == 0 || substr(raw, 0, 1) != "{")
	die("invariants: ожидаю JSON с фактами на stdin (см. gather.uc)");

let report = evaluate(json(raw));

if (has_flag("--json")) {
	print(sprintf("%J\n", report));
} else if (has_flag("--repairs")) {
	let r = repairs(report);
	for (let i = 0; i < length(r); i++)
		print(r[i] + "\n");
} else {
	let lines = render_report(report);
	for (let i = 0; i < length(lines); i++)
		print(lines[i] + "\n");
}

exit(report.ok ? 0 : 1);
