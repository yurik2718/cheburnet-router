// tick.uc — ОДИН тик сторожа (импурно, router-side): собрать инварианты → решить → починить.
//   ucode -R tick.uc          # так его зовёт cron (раз в 5 минут, см. cron.uc)
// ЧТО должно быть истинно — engine/invariants; ЧЕМ чинить — те же шаги, что зовёт установка
// (watchdog.repair_cmd, под юнитами). Здесь только склейка и лог.

import { readfile, writefile, access, mkdir } from "fs";
import { sh, shellquote } from "../lib/proc.uc";
import { evaluate } from "../invariants/invariants.uc";
import { decide, repair_cmd } from "./watchdog.uc";

const STATE_DIR = getenv("STATE_DIR")     ?? "/tmp/cheburnet";
const ETC       = getenv("ETC_CHEBURNET") ?? "/etc/cheburnet";
const STATE_FILE = STATE_DIR + "/watchdog.json";
let ENGINE = getenv("ENGINE_DIR") ?? (sourcepath(0, true) + "/..");

// busy() — идёт длинная операция движка? Конвенция та же, что у ubus-слоя: pid-файл + done-маркер
// (переиспользованный pid — реальный случай, поэтому done-маркер гасит проверку).
function busy() {
	if (access(STATE_DIR + "/done")) return false;
	let pid = trim(readfile(STATE_DIR + "/pid") ?? "");
	if (length(pid) == 0) return false;
	return trim(sh(sprintf("kill -0 %s 2>/dev/null; echo $?", pid))) == "0";
}

function load_cfg() {
	let raw = readfile(ETC + "/install.json");
	return (raw && substr(trim(raw), 0, 1) == "{") ? json(raw) : {};
}

function log(line) {
	sh(sprintf("logger -t cheburnet-watchdog %s", shellquote(line)));
}

// Факты собираем тем же gather, что зовут диагностика и тесты. Не собрались (нет команд, битый
// вывод) — молча выходим: сторож не имеет права действовать по недостоверным фактам.
let facts_raw = trim(sh(sprintf("ucode -R %s/invariants/gather.uc 2>/dev/null", ENGINE)));
if (substr(facts_raw, 0, 1) != "{")
	exit(0);

let raw_state = readfile(STATE_FILE);
let state = (raw_state && substr(trim(raw_state), 0, 1) == "{") ? json(raw_state) : {};

// uptime — первое число /proc/uptime (секунды). Не прочиталось → null: гейт не выдумываем.
let up_m = match(trim(readfile("/proc/uptime") ?? ""), /^([0-9]+)/);
let uptime = up_m ? int(up_m[1]) : null;

let d = decide(evaluate(json(facts_raw)), state, busy(), uptime);

for (let i = 0; i < length(d.log); i++)
	log(d.log[i]);

if (d.action) {
	// Перечитываем install.json ПЕРЕД починкой: между сбором фактов и этим местом человек мог нажать
	// «Выключить защиту» (install/pause.uc) — вернуть ему маршрут в мёртвый туннель значило бы
	// отменить его решение и снова оставить дом без интернета.
	let cfg = load_cfg();
	let cmd = (cfg.paused === true) ? null : repair_cmd(d.action, cfg, ENGINE);
	if (cmd) {
		let rc = int(trim(sh(cmd + " >/dev/null 2>&1; echo $?")));
		// Успех не логируем: следующий тик либо промолчит (починилось), либо посчитает попытку.
		if (rc != 0)
			log(sprintf("починка (%s) вернула код %d", d.action, rc));
	}
}

if (!access(STATE_DIR))
	mkdir(STATE_DIR, 0o755);
writefile(STATE_FILE, sprintf("%J\n", d.state));
exit(0);
