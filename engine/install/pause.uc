// pause.uc — АВАРИЙНЫЙ РЕЖИМ: пустить интернет напрямую, сняв защиту (импурно, router-side).
//   ucode -R pause.uc            # выключить защиту (снять маршрут туннеля и kill-switch)
//   ucode -R pause.uc --resume   # вернуть защиту
// Зачем и как — [[troubleshooting]] («туннель не поднять, а интернет нужен»). Тест: qemu-emergency.
// ИНВАРИАНТ: флаг paused в install.json пишем ПЕРВЫМ — упади мы на полпути, панель скажет «защита
// выключена», а сторож не вернёт её молча; обратный порядок дал бы снятую защиту, о которой никто не знает.

import { readfile, writefile } from "fs";
import { sh, run_stdin } from "../lib/proc.uc";
import { tunnel_info, default_protocol } from "./install.uc";

let SELF = sourcepath(0, true);
let ENGINE = SELF + "/..";
const ETC = getenv("ETC_CHEBURNET") ?? "/etc/cheburnet";
const CFG = ETC + "/install.json";

let resume = (length(ARGV) > 0 && ARGV[0] == "--resume");

let raw = readfile(CFG);
if (!raw || substr(trim(raw), 0, 1) != "{") {
	warn("pause: роутер не настроен — аварийный режим не к чему применять\n");
	exit(1);
}
let cfg = json(raw);
let ro = (type(cfg.routing_opts) == "object") ? cfg.routing_opts : {};
let step = tunnel_info(cfg.protocol ?? default_protocol()).step;

cfg.paused = !resume;
if (!writefile(CFG, sprintf("%J\n", cfg)))
	die("pause: не смог записать install.json — состояние осталось бы неизвестным");

if (!resume) {
	// 1) снять маршрут туннеля (иначе трафик продолжит уходить в мёртвый туннель),
	// 2) снять правила защиты (kill-switch дропал бы всё, что идёт мимо туннеля).
	sh(sprintf("ucode -R %s/steps/%s/apply.uc --disarm >/dev/null 2>&1", ENGINE, step));
	run_stdin(sprintf("ucode -R %s/steps/firewall/apply.uc --teardown", ENGINE),
		sprintf("%J", { domains: [], routing_opts: ro }));
	// dnsmasq перезапускаем: он мог накопить отрицательные ответы, пока резолва не было.
	sh("/etc/init.d/dnsmasq restart >/dev/null 2>&1");
	print("pause: аварийный режим ВКЛЮЧЁН — интернет идёт напрямую, защита снята\n");
	exit(0);
}

// Возврат: сначала data-plane (правила + маршрут direct-таблицы по СВЕЖЕМУ WAN), потом вооружение
// туннеля. Порядок важен: kill-switch должен встать раньше, чем трафик пойдёт в туннель.
let rc = sh(sprintf("ucode -R %s/install/reapply.uc >/dev/null 2>&1; echo $?", ENGINE));
if (int(trim(rc)) != 0)
	warn("pause: data-plane вернуть не удалось — проверьте панель (см. logread)\n");
sh(sprintf("ucode -R %s/steps/%s/apply.uc --arm >/dev/null 2>&1", ENGINE, step));
sh("/etc/init.d/dnsmasq restart >/dev/null 2>&1");
print("pause: защита ВЕРНУЛАСЬ — трафик снова идёт через туннель\n");
exit(0);
