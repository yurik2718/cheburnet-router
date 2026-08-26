// gather.uc — сбор фактов для preflight (импурно; разбор — parse.uc). ucode -R gather.uc | ucode -R check.uc
// ИНВАРИАНТ: команда недоступна/упала → поле null/false — «не смог подтвердить» = блокировать, не пропускать.

import { readfile } from "fs";
import { sh } from "../lib/proc.uc";
import { default_requirements, full_requirements } from "./preflight.uc";
import { parse_meminfo, parse_df, parse_arch, parse_board,
         parse_iface_cidr } from "./parse.uc";

// cmd_rc(cmd) → true, если команда завершилась кодом 0. Вывод глушим, читаем только $?.
function cmd_rc(cmd) {
	let out = sh(cmd + " >/dev/null 2>&1; echo $?");
	return int(trim(out)) == 0;
}

let req = default_requirements();

// Зависимости: `apk add --simulate <pkg>` — dry-run, ничего не ставит, лишь проверяет
// доступность пакета под текущую arch/feed. Так узнаём deps_installable ДО реальной установки.
let deps_installable = {};
for (let i = 0; i < length(req.deps); i++) {
	let pkg = req.deps[i];
	deps_installable[pkg] = cmd_rc(sprintf("apk add --simulate %s", pkg));
}
// Full-тир: установимость бинаря sing-box, тем же --simulate, для всех вариантов сборки
// (взаимозаменяемы, см. preflight.uc FULL_REQUIREMENTS).
let fr = full_requirements();
for (let i = 0; i < length(fr.pkgs); i++)
	deps_installable[fr.pkgs[i]] = cmd_rc(sprintf("apk add --simulate %s", fr.pkgs[i]));

// ИНВАРИАНТ: «установлен ли» (бинарь, opt-in — ставится отдельно от bootstrap) отличаем от
// «устанавливаем ли» (--simulate выше); evaluate_tiers различает по этому факту кнопку
// «включить» vs переключение. Проверяем БИНАРЬ, не имя пакета: tiny и полная сборка ставят
// один и тот же /usr/bin/sing-box.
let sing_box_installed = cmd_rc("command -v sing-box");

let facts = {
	arch: parse_arch(sh("uname -m")),
	openwrt_version: parse_board(sh("ubus call system board 2>/dev/null")),
	flash_free_mb: parse_df(sh("df -k /overlay 2>/dev/null || df -k /")),
	ram_total_mb: parse_meminfo(readfile("/proc/meminfo") ?? ""),
	deps_installable: deps_installable,
	sing_box_installed: sing_box_installed,
	lan_cidr: parse_iface_cidr(sh("ubus call network.interface.lan status 2>/dev/null")),
	wan_cidr: parse_iface_cidr(sh("ubus call network.interface.wan status 2>/dev/null")),
};

print(sprintf("%J\n", facts));
