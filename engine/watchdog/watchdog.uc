// watchdog.uc — РЕШЕНИЕ сторожа: чинить ли сейчас, чем (repair_cmd) и что писать в лог (чисто; тесты:
// tests/). ЧТО должно быть истинно — engine/invariants; ЧЕМ чинить — шаги. Исполняет tick.uc.
// ИНВАРИАНТ: молчим при норме — cron-лог каждые 5 минут забил бы диагностику; пустой журнал = норма.

import { failed_ids, repairs } from "../invariants/invariants.uc";
import { tunnel_info, default_protocol, uses_singbox } from "../install/install.uc";
import { service_name as sb_service, network_sections as sb_net } from "../steps/singbox/singbox.uc";

// Сколько раз подряд пробуем ОДНУ И ТУ ЖЕ починку, прежде чем признать, что само не чинится.
// Больше — это бесконечная порча сети (ifup wan каждые 5 минут); меньше — сдаёмся на первом
// же переходном состоянии (netifd поднимает интерфейсы не мгновенно).
const MAX_ATTEMPTS = 3;

// Сколько секунд после загрузки сторож НЕ вмешивается. Сразу после ребута netifd ещё поднимает
// интерфейсы, procd — сервисы, и половина инвариантов честно «не на месте» просто потому, что
// загрузка не кончилась. Починка в этот момент — это драка с загрузкой (bounce WAN, лишний
// перезапуск DoH) на ровном месте. Три минуты с запасом перекрывают и netifd, и procd.
const SETTLE_S = 180;

// decide(report, state, busy, uptime) → { action, log, state }. report — invariants.evaluate;
// state — { failed, repair, attempts, quiet } с прошлого тика; busy — идёт длинная операция;
// uptime — секунд с загрузки (null → не гейтим). action → команда через repair_cmd.
// ИНВАРИАНТ: за тик — НЕ БОЛЕЕ ОДНОЙ починки: каскад не разобрать по логу, следующий тик проверит.
function decide(report, state, busy, uptime) {
	let st = state ?? {};

	// Три случая, когда тик пропускается ЦЕЛИКОМ и молча:
	//   • идёт установка/замена сервера — она сама двигает сеть (тот же взаимный замок, что у
	//     ubus-методов: «операция уже выполняется»);
	//   • система только что загрузилась (см. SETTLE_S);
	//   • включён аварийный режим — защита снята ОСОЗНАННО, и «починить» её значило бы отменить
	//     решение человека и снова оставить дом без интернета.
	if (busy || report.paused === true || (uptime != null && uptime < SETTLE_S))
		return { action: null, log: [], state: st };

	if (report.ok) {
		// О восстановлении сообщаем ОДИН раз — иначе в поддержке видно «сломалось» и не видно,
		// что оно уже починилось.
		let recovered = (st.repair || st.quiet) ? [ "инварианты восстановлены" ] : [];
		return { action: null, log: recovered, state: {} };
	}

	let failed = failed_ids(report);
	let key = join(",", failed);
	// Набор поломок сменился — это ДРУГАЯ проблема: счётчик попыток и тишину начинаем заново.
	if (st.failed != key)
		st = {};

	let acts = repairs(report);
	let action = length(acts) > 0 ? acts[0] : null;

	if (!action)
		return { action: null,
		         log: st.quiet ? [] : [ sprintf("нарушены инварианты: %s — автоматически не чинятся", key) ],
		         state: { failed: key, quiet: true } };

	let attempts = (st.repair == action) ? (st.attempts ?? 0) : 0;
	if (attempts >= MAX_ATTEMPTS)
		return { action: null,
		         log: st.quiet ? [] : [ sprintf("после %d попыток не чинится: %s — нужна ручная проверка",
		                                        MAX_ATTEMPTS, key) ],
		         state: { failed: key, repair: action, attempts: attempts, quiet: true } };

	return { action: action,
	         log: [ sprintf("нарушены инварианты: %s — чиню (%s), попытка %d", key, action, attempts + 1) ],
	         state: { failed: key, repair: action, attempts: attempts + 1, quiet: false } };
}

// shq(s) — одинарные кавычки для аргумента команды (lib/proc.shellquote импурен по модулю, а
// здесь всё чистое — под юнитами).
function shq(s) {
	return "'" + replace(s ?? "", "'", "'\\''") + "'";
}

// repair_cmd(action, cfg, engine) → команда починки или null. ЕДИНСТВЕННОЕ место, где подсказка
// инварианта становится командой; все починки — существующие шаги, сторож сам чинить не умеет.
// ЧИСТАЯ (строка по входу) — под юнитами; tick.uc её исполняет.
function repair_cmd(action, cfg, engine) {
	let c = cfg ?? {};
	let protocol = c.protocol ?? default_protocol();
	if (action == "ifup_wan")
		return "ifup wan";
	// reapply переприменяет firewall-шаг со СВЕЖИМ WAN — он же лечит и протухшую таблицу.
	if (action == "reapply" || action == "firewall")
		return sprintf("ucode -R %s/install/reapply.uc", engine);
	// arm = вернуть маршрут туннеля. Full-тир: half-routes живут на TUN, а TUN — на живом
	// sing-box; мёртвый процесс `ifup` не поднимет — сначала сервис (см. singbox/apply.uc --arm).
	if (action == "arm")
		return sprintf("ucode -R %s/steps/%s/apply.uc --arm", engine, tunnel_info(protocol).step);
	if (action == "doh")
		return sprintf("printf '%%s' %s | ucode -R %s/steps/doh/apply.uc",
			shq(sprintf("{\"provider\":\"%s\"}", c.dns_provider ?? "")), engine);
	return null;
}

// restart_tunnel_cmd(cfg) → команда «перезапустить туннель» для кнопки панели (service_restart).
// Ветвится по ШАГУ протокола (ADR 0004): у Full-тира туннель — это сервис sing-box + netifd-
// интерфейс над его TUN; у AWG — только интерфейс. ШРАМ: кнопка делала `ifup awg0` при любом
// протоколе и на Reality отвечала «готово», ничего не сделав.
function restart_tunnel_cmd(cfg) {
	let protocol = (cfg ?? {}).protocol ?? default_protocol();
	if (uses_singbox(protocol))
		return sprintf("/etc/init.d/%s restart >/dev/null 2>&1; sleep 1; ifup %s >/dev/null 2>&1",
			sb_service(null), sb_net(null)[0]);
	let tif = tunnel_info(protocol).tunnel_if;
	return sprintf("ifdown %s 2>/dev/null; sleep 1; ifup %s 2>/dev/null", tif, tif);
}

export { decide, repair_cmd, restart_tunnel_cmd, MAX_ATTEMPTS, SETTLE_S };
