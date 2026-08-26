// wan.uc — WAN роутера (импурно): одна реализация «какой интерфейс смотрит наружу» для
// оркестратора, reapply, invariants и шагов туннелей. Чистый разбор — route.uc / preflight/parse.uc.

import { sh } from "./proc.uc";
import { pick_wan_fallback } from "./route.uc";
import { parse_wan_route } from "../preflight/parse.uc";
import { tunnel_ifs } from "../install/install.uc";

// detect_wan() → { wan_if, wan_gw|null } или null. netifd — первичный источник (знает WAN, даже
// когда дефолт у туннеля); фолбэк — первый дефолт `ip route` МИМО туннельных интерфейсов.
function detect_wan() {
	let wr = parse_wan_route(sh("ubus call network.interface.wan status 2>/dev/null"));
	return wr ?? pick_wan_fallback(sh("ip -4 route show default 2>/dev/null"), tunnel_ifs());
}

// wait_wan_default(tries?) → bool: в main есть дефолт мимо туннелей; нет — один `ifup wan` и
// ожидание до tries секунд (netifd поднимает интерфейсы асинхронно).
// ШРАМ: старая схема маршрута замещала WAN-дефолт, и после снятия awg0 роутер оставался без пути
// наружу. `ifup wan` — только при реальном отсутствии дефолта, иначе рвал бы живой WAN на ровном месте.
function wait_wan_default(tries) {
	let n = tries ?? 10;
	for (let i = 0; i <= n; i++) {
		if (pick_wan_fallback(sh("ip -4 route show default 2>/dev/null"), tunnel_ifs()) != null)
			return true;
		if (i == 0)
			sh("ifup wan >/dev/null 2>&1");
		sh("sleep 1");
	}
	return false;
}

export { detect_wan, wait_wan_default };
