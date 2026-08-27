// invariants.uc — ЧТО ДОЛЖНО БЫТЬ ИСТИННО на настроенном роутере (чистая логика; факты — gather.uc).
// ИНВАРИАНТ: один список на диагностику, QEMU-тесты, сторожа и панель — знание «что должно быть на
// месте» живёт в одном месте (оба инцидента, маршрут-без-фолбэка и DNS-без-резерва, прожили при
// зелёных тестах именно потому, что оно было размазано). Тесты: tests/. Подробно: [[reliability]].

import { pick_wan_fallback } from "../lib/route.uc";

// severity: critical — дом без интернета или утечка наружу; important — деградация, которую
// человек заметит не сразу (сломанный split, нет резервного DNS).
// repair — машинная подсказка для watchdog'а: КЕМ чинится. null = руками.
//   "ifup_wan" | "arm" | "reapply" | "firewall" | "doh". facts.tunnel_alive — живость туннеля.
function check(id, ok, title, detail, fix, severity, repair) {
	return { id: id, ok: ok, title: title, detail: detail, fix: ok ? null : fix,
	         severity: severity ?? "critical", repair: ok ? null : (repair ?? null) };
}

// has_line(text, re) — есть ли в выводе строка, подходящая под regex.
function has_line(text, re) {
	let lines = split(trim(text ?? ""), "\n");
	for (let i = 0; i < length(lines); i++)
		if (match(trim(lines[i]), re))
			return true;
	return false;
}

// has_substr(text, needle) — есть ли строка, СОДЕРЖАЩАЯ подстроку. Квирк ucode: строка вместо
// regex в match() молча не матчится, поэтому фиксированные образцы («fwmark 0x1 lookup 100»)
// ищем подстрокой, а не собранной на лету регуляркой (поймано юнитом на здоровых фактах).
function has_substr(text, needle) {
	let lines = split(trim(text ?? ""), "\n");
	for (let i = 0; i < length(lines); i++)
		if (index(lines[i], needle) >= 0)
			return true;
	return false;
}

// default_via_iface(route_text, iface) — есть ли дефолт ИМЕННО через этот интерфейс. Токен после
// " dev " сравниваем целиком: dev eth1 ≠ dev eth10 (тот же приём, что route_uses_iface).
function default_via_iface(route_text, iface) {
	if (!iface) return false;
	let lines = split(trim(route_text ?? ""), "\n");
	for (let i = 0; i < length(lines); i++) {
		let l = trim(lines[i]);
		if (index(l, "default") != 0) continue;
		let m = match(l, /dev ([^ ]+)/);
		if (m && m[1] == iface) return true;
	}
	return false;
}

// half_routes_present(route_text, iface) — обе половинки 0.0.0.0/1 и 128.0.0.0/1 через iface.
// ИНВАРИАНТ: именно ОБЕ. Одна половина — это «полдома в туннеле, полдома мимо», и снаружи
// выглядит как «интернет работает через раз» (см. [[policy-routing]]).
function half_routes_present(route_text, iface) {
	if (!iface) return false;
	let lo = false, hi = false;
	let lines = split(trim(route_text ?? ""), "\n");
	for (let i = 0; i < length(lines); i++) {
		let l = trim(lines[i]);
		if (index(l, " dev " + iface) < 0) continue;
		if (index(l, "0.0.0.0/1 ") == 0) lo = true;
		if (index(l, "128.0.0.0/1 ") == 0) hi = true;
	}
	return lo && hi;
}

// ps_uid(line) — второе поле строки `ps w` (busybox печатает имя пользователя, а не uid).
function ps_uid(line) {
	let f = split(trim(line), /[ \t]+/);
	return (length(f) > 1) ? f[1] : null;
}

// dns_instance(ps_text, url, port) → { state, user }. Разбор `ps w`-вывода экземпляров
// https-dns-proxy ПО ПОРТУ: state ∈ "ok" (наш резолвер) | "foreign" (чужой занял порт) |
// "missing" (не запущен). user — владелец процесса (по нему различаются основной и резервный).
// ШРАМ: чужой экземпляр пакета (dns.google) выживал и занимал порт резервного — фильтрация
// пользователя обходилась молча. Поэтому смотрим не количество, а чей резолвер на каждом порту.
function dns_instance(ps_text, url, port) {
	let lines = split(trim(ps_text ?? ""), "\n");
	let needle = sprintf("-p %d", port);
	for (let i = 0; i < length(lines); i++) {
		let l = trim(lines[i]);
		if (length(l) == 0 || index(l, "https-dns-proxy") < 0 || index(l, needle) < 0) continue;
		return { state: (url && index(l, url) >= 0) ? "ok" : "foreign", user: ps_uid(l) };
	}
	return { state: "missing", user: null };
}

// report(checks) — свести проверки в отчёт (общая концовка обеих веток evaluate).
function report(checks) {
	let failed = 0, critical_failed = 0;
	for (let i = 0; i < length(checks); i++) {
		if (checks[i].ok) continue;
		failed++;
		if (checks[i].severity == "critical") critical_failed++;
	}
	return { ok: failed == 0, failed: failed, total: length(checks),
	         critical_failed: critical_failed, checks: checks, installed: true };
}

// evaluate(facts) → { ok, failed, total, critical_failed, checks }. facts — см. gather.uc: installed,
// paused, mode, tunnel_if(s), wan_if, table, mark, dns_uid/url/ports и СЫРОЙ вывод ip rule / ip route
// (default, main, table N) / nft list chain / ps w. Не настроен → пустой отчёт ok=true.
function evaluate(facts) {
	let f = facts ?? {};
	let checks = [];
	if (f.installed !== true)
		return { ok: true, failed: 0, total: 0, critical_failed: 0, checks: checks,
		         installed: false };
	// Аварийный режим: человек сам снял защиту, чтобы выйти в сеть. Инварианты защиты сейчас
	// нарушены ПО ЕГО РЕШЕНИЮ — это не поломка, и сторожу тут делать нечего. Отчёт при этом
	// НЕ молчит: paused едет наверх, и панель с диагностикой говорят об этом прямо.
	if (f.paused === true)
		return { ok: true, failed: 0, total: 0, critical_failed: 0, checks: checks,
		         installed: true, paused: true };

	let mode = f.mode ?? "home";
	let table = f.table ?? 100;
	let mark = f.mark ?? "0x1";
	let travel = (mode == "travel");

	// 1. Путь наружу с фолбэком: дефолт МИМО туннелей обязан быть в main всегда (см. HALF_ROUTES в
	// steps/vpn/vpn.uc). ШРАМ: по ПОЛНОЙ таблице pick_wan_fallback принимал за дефолт любой маршрут
	// («default через tun0» при отсутствии дефолта) — поэтому только `ip route show default`.
	let wan = pick_wan_fallback(f.route_default ?? "", f.tunnel_ifs ?? []);
	push(checks, check("wan_default", wan != null,
		"у роутера есть путь наружу помимо туннеля",
		wan != null ? sprintf("default через %s", wan.wan_if) : "в main нет дефолта мимо туннеля",
		"ifup wan — и проверьте, что туннель не забрал дефолт себе (half-routes, steps/vpn)",
		"critical", "ifup_wan"));

	// 2. Туннель забирает трафик. Без этого «всё в туннель» тихо выключается: панель зелёная,
	// а трафик уходит открытым WAN (и его режет kill-switch — то есть просто не идёт).
	push(checks, check("tunnel_route", half_routes_present(f.route_main, f.tunnel_if),
		"трафик уходит в туннель (half-routes)",
		sprintf("0.0.0.0/1 + 128.0.0.0/1 через %s", f.tunnel_if ?? "?"),
		"ucode -R engine/steps/vpn/apply.uc --arm (или steps/singbox для Full-тира)",
		"critical", "arm"));

	// 3. Kill-switch. ШРАМ: цепочка оставалась, но ПУСТЕЛА после fw4 reload — «зелёная» система
	// без защиты. Поэтому мало наличия цепочки: требуем в ней правило drop.
	let ks = trim(f.nft_ks ?? "");
	push(checks, check("killswitch", length(ks) > 0 && index(ks, "drop") >= 0,
		"kill-switch заряжен (непрямой трафик не утечёт в WAN)",
		length(ks) == 0 ? "цепочки нет в ядре" : (index(ks, "drop") >= 0 ? "правило drop на месте" : "цепочка ЕСТЬ, но ПУСТАЯ"),
		"ucode -R engine/steps/firewall/apply.uc — правила живут в /etc/nftables.d/",
		"critical", "firewall"));

	if (travel) {
		// В поездке мимо туннеля не уходит НИЧЕГО: ни direct, ни резервный DNS. Правила
		// направления в этом режиме обязаны ОТСУТСТВОВАТЬ — иначе «поездка» врёт.
		let leaky = has_line(f.ip_rule, /fwmark/) || has_line(f.ip_rule, /uidrange/);
		push(checks, check("travel_closed", !leaky,
			"режим «в поездке»: мимо туннеля не уходит ничего",
			leaky ? "остались правила направления мимо туннеля" : "правил направления нет — верно",
			"переприменить режим в панели (set_mode travel)",
			"critical", "reapply"));
		return report(checks);
	}

	// 4-5. Split-routing: правило направления И живой маршрут в таблице. Проверяем ОБА и по
	// ТЕКУЩЕМУ WAN: правило с маршрутом в протухший шлюз выглядит целым, а direct-сайты мертвы.
	push(checks, check("direct_rule", has_substr(f.ip_rule, sprintf("fwmark %s lookup %d", mark, table)),
		"direct-трафик направляется мимо туннеля",
		sprintf("ip rule fwmark %s lookup %d", mark, table),
		"ucode -R engine/install/reapply.uc", "critical", "reapply"));

	let direct_ok = false, direct_detail = "в таблице нет дефолта";
	if (default_via_iface(f.route_direct, f.wan_if)) {
		direct_ok = true;
		direct_detail = sprintf("default через %s (текущий WAN)", f.wan_if);
	} else if (has_substr(f.route_direct, "default")) {
		direct_detail = "дефолт есть, но НЕ через текущий WAN — маршрут протух";
	}
	push(checks, check("direct_table", direct_ok,
		sprintf("таблица %d ведёт в текущий WAN", table), direct_detail,
		"ucode -R engine/install/reapply.uc — он берёт WAN заново, а не из install.json",
		"critical", "reapply"));

	// 6. Пометка. Без неё в таблицу направления никто не попадёт — split молча выключен.
	let mk = trim(f.nft_mark ?? "");
	push(checks, check("mark_chain", length(mk) > 0 && index(mk, "mark set") >= 0,
		"адреса из direct-списка помечаются",
		length(mk) == 0 ? "цепочки пометки нет в ядре" : (index(mk, "mark set") >= 0 ? "правила пометки на месте" : "цепочка есть, но правил нет"),
		"ucode -R engine/steps/firewall/apply.uc", "important", "firewall"));

	// 7. Резервный путь DNS. Без него смерть туннеля уносит ВЕСЬ резолв — не открываются даже
	// сайты из direct-списка (см. [[encrypted-dns]]).
	if (f.dns_uid != null)
		push(checks, check("dns_rule",
			has_substr(f.ip_rule, sprintf("uidrange %d-%d lookup %d", f.dns_uid, f.dns_uid, table)),
			"DNS переживёт смерть туннеля",
			sprintf("ip rule uidrange %d-%d lookup %d", f.dns_uid, f.dns_uid, table),
			"ucode -R engine/install/reapply.uc", "important", "reapply"));

	// 8-9. Экземпляры DoH — ПО ОТДЕЛЬНОСТИ. При мёртвом туннеле основной гарантированно в crash-loop
	// (c-ares на молчащих bootstrap-серверах — баг апстрима, пулом не лечится), а резолв несёт
	// резервный — вот его отсутствие и есть поломка. Подробно: [[encrypted-dns]].
	let ports = f.dns_ports ?? {};
	let main_i = dns_instance(f.hdp_ps, f.dns_url, ports.main ?? 5053);
	let wan_i  = dns_instance(f.hdp_ps, f.dns_url, ports.wan ?? 5054);

	push(checks, check("dns_fallback", wan_i.state == "ok",
		"резервный DoH жив (он несёт резолв, когда туннель мёртв)",
		sprintf("порт %d: %s", ports.wan ?? 5054, wan_i.state),
		"ucode -R engine/steps/doh/apply.uc — без него смерть туннеля уносит весь резолв",
		"important", "doh"));

	// Основной мёртв → весь резолв идёт резервным путём, то есть мимо туннеля. Дом работает, но
	// приватность уже не та, что обещана в норме, — человек имеет право об этом знать.
	// Чиним (перезапуск DoH) ТОЛЬКО при ЖИВОМ туннеле (facts.tunnel_alive — тот же признак, что у
	// панели). ШРАМ (GL-MT3000, 2026-08-27): гейт «критичные инварианты целы» пропускал мёртвый
	// туннель с целыми маршрутами — сторож перезапускал DoH каждые 5 минут, тот на секунду оживал,
	// «инварианты восстановлены», и по кругу. Когда туннель вернулся, а procd исчерпал respawn, —
	// без этой починки основной не встал бы никогда.
	let tunnel_ok = (f.tunnel_alive === true);
	push(checks, check("dns_main", main_i.state == "ok",
		"основной DoH жив (резолв идёт через туннель)",
		sprintf("порт %d: %s", ports.main ?? 5053, main_i.state),
		"перезапустить: /etc/init.d/https-dns-proxy restart. Падает снова — смотрите туннель: "
		+ "на молчащих bootstrap-серверах демон уходит в crash-loop (баг апстрима)",
		"important", tunnel_ok ? "doh" : null));

	// Владелец сокетов — единственное, чем резервный отличается от основного: совпали — правило
	// uidrange их не различит, и «резервный» путь окажется тем же самым.
	if (main_i.user != null && wan_i.user != null)
		push(checks, check("dns_owners", main_i.user != wan_i.user,
			"у экземпляров DoH разные владельцы (иначе резервный путь фиктивен)",
			sprintf("%s / %s", main_i.user, wan_i.user),
			"ucode -R engine/steps/doh/apply.uc", "important", "doh"));

	return report(checks);
}

// failed_ids(report) → id провалившихся проверок. Нужен всем, кто говорит о состоянии словами:
// watchdog (что пишем в лог), панель, тесты. Единственный источник — здесь.
function failed_ids(report) {
	let out = [];
	for (let i = 0; i < length(report.checks); i++)
		if (!report.checks[i].ok) push(out, report.checks[i].id);
	return out;
}

// repairs(report) → список repair-подсказок провалившихся проверок, БЕЗ дублей и в порядке
// проверок. Это вход будущего watchdog'а: он чинит по этому списку, а не по своему знанию.
function repairs(report) {
	let out = [], seen = {};
	for (let i = 0; i < length(report.checks); i++) {
		let c = report.checks[i];
		if (c.ok || !c.repair || seen[c.repair]) continue;
		seen[c.repair] = true;
		push(out, c.repair);
	}
	return out;
}

// render_report(report) → строки для человека (диагностика, CLI). Формат тот же, что у
// preflight: галочка + заголовок, детали в скобках, подсказка только у провалов.
function render_report(rep) {
	let out = [];
	if (!rep.installed) {
		push(out, "Роутер не настроен — проверять нечего.");
		return out;
	}
	if (rep.paused) {
		push(out, "АВАРИЙНЫЙ РЕЖИМ: защита выключена по решению владельца.");
		push(out, "    интернет идёт напрямую, kill-switch и split-tunnel сняты;");
		push(out, "    вернуть — кнопка «Вернуть защиту» в панели.");
		return out;
	}
	for (let i = 0; i < length(rep.checks); i++) {
		let c = rep.checks[i];
		push(out, sprintf("%s %s — %s", c.ok ? "✓" : "✗", c.title, c.detail));
		if (!c.ok)
			push(out, sprintf("    как чинить: %s", c.fix));
	}
	push(out, sprintf("%s: %d из %d в порядке%s",
		rep.ok ? "ИТОГ" : "ИТОГ (есть отклонения)", rep.total - rep.failed, rep.total,
		rep.critical_failed > 0 ? sprintf(", критичных провалов %d", rep.critical_failed) : ""));
	return out;
}

export { evaluate, failed_ids, repairs, render_report, half_routes_present, default_via_iface,
         dns_instance, ps_uid };
