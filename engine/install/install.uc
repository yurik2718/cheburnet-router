// install.uc — оркестрация установки: ЧИСТАЯ политика связывания кирпичей (реестр шагов,
// snapshot-область, решение commit/rollback/abort). Выполнение — в run.uc (импурно, QEMU);
// здесь только логика, под юнит-тестами.
// ИНВАРИАНТ: ЧИСТЫЕ шаги откатываются uci-snapshot'ом; ГРЯЗНЫЙ (firewall — runtime nft/ip)
// чистится своим teardown (safe-fail), не иллюзией uci-отката.

import { is_clean_config } from "../rollback/rollback.uc";

// Реестр шагов в порядке применения. configs — uci-конфиги, которые шаг меняет (для snapshot).
// rollback: clean = откатывается uci-snapshot'ом; dirty = состояние ядра, safe-fail через teardown.
// needs — что шагу подать на stdin (для run.uc): awg_conf | domains | none.
const STEPS = [
	// needs=tunnel_conf у ОБОИХ туннель-шагов: какой именно текст подать (AWG .conf / vless:// /
	// hysteria2://), решает conf_key активного протокола — см. PROTOCOLS и step_stdin в run.uc.
	// Так добавление протокола не требует новой ветки в раздаче stdin.
	{ name: "vpn",      configs: [ "network" ],                  rollback: "clean", needs: "tunnel_conf" },
	// singbox — альтернативный туннель (Full-тир). Взаимоисключающий с vpn (см. PROTOCOLS).
	// Гибрид: uci sing-box + network (чистый откат snapshot'ом) + config.json/сервис (dirty).
	{ name: "singbox",  configs: [ "sing-box", "network" ],      rollback: "dirty", needs: "tunnel_conf" },
	{ name: "dns",      configs: [ "dhcp" ],                     rollback: "clean", needs: "domains" },
	{ name: "doh",      configs: [ "https-dns-proxy", "dhcp" ],  rollback: "clean", needs: "doh" },
	// wifi — перед firewall: настройка радио независима от split-routing. Нет радио/ключа → no-op.
	{ name: "wifi",     configs: [ "wireless" ],                 rollback: "clean", needs: "wifi" },
	// firewall — последним: пометка/ip rule/kill-switch поверх поднятого туннеля. Гибрид: NAT-зона —
	// uci firewall (чистый откат snapshot'ом), цепочки/ip rule — runtime → шаг dirty (teardown).
	{ name: "firewall", configs: [ "firewall" ],                 rollback: "dirty", needs: "domains" },
];

// Туннельные протоколы — три оси покрытия, каждая лечит свою поломку (ADR 0004): awg — ядро,
// слабое железо, дефолт; reality — трафик не проходит (DPI/блок UDP); hysteria2 — тот же
// sing-box, трафик проходит но плохо (потери/троттлинг).
// ИНВАРИАНТ: оба Full-протокола делят ОДИН шаг и интерфейс — весь data-plane переиспользуется
// без изменений, третий протокол на sing-box не приносит своей семантики здоровья.
// conf_key — ключ конфига протокола в payload установки (run.uc/step_stdin).
const PROTOCOLS = {
	awg:       { step: "vpn",     tunnel_if: "awg0",     conf_key: "awg_conf" },
	reality:   { step: "singbox", tunnel_if: "singtun0", conf_key: "reality_conf" },
	hysteria2: { step: "singbox", tunnel_if: "singtun0", conf_key: "hysteria2_conf" },
};
const DEFAULT_PROTOCOL = "awg";
const TUNNEL_STEPS = [ "vpn", "singbox" ]; // взаимоисключающие шаги (ровно один активен)
const SINGBOX_STEP = "singbox";

// protocol_ids() → список валидных протоколов (для enum в ubus-реестре — граница доверия).
function protocol_ids() {
	let out = [];
	for (let k in PROTOCOLS) push(out, k);
	return out;
}

function default_protocol() {
	return DEFAULT_PROTOCOL;
}

// tunnel_info(protocol) → { step, tunnel_if, conf_key } активного протокола
// (неизвестный → дефолт, fail-safe).
function tunnel_info(protocol) {
	return PROTOCOLS[protocol] ?? PROTOCOLS[DEFAULT_PROTOCOL];
}

// uses_singbox(protocol) → едет ли протокол на sing-box. Спрашивает про ШАГ, не имя — новый
// протокол на sing-box автоматически подхватывается везде, где есть эта проверка.
function uses_singbox(protocol) {
	return tunnel_info(protocol).step == SINGBOX_STEP;
}

// tunnel_ifs() → интерфейсы ВСЕХ туннелей (awg0, singtun0). Единственный источник для тех, кто
// ищет WAN «мимо туннелей» (lib/wan.uc) — хардкод чужого туннеля в шаге разъезжался бы молча.
function tunnel_ifs() {
	let out = [];
	for (let k in PROTOCOLS)
		if (index(out, PROTOCOLS[k].tunnel_if) < 0) push(out, PROTOCOLS[k].tunnel_if);
	return out;
}

// disabled_tunnels(protocol) → имена туннель-шагов, которые НЕ применяем (все, кроме активного).
// run.uc передаёт их в enabled_steps({disable}) → в установке остаётся ровно один туннель.
function disabled_tunnels(protocol) {
	let active = tunnel_info(protocol).step;
	let out = [];
	for (let i = 0; i < length(TUNNEL_STEPS); i++)
		if (TUNNEL_STEPS[i] != active) push(out, TUNNEL_STEPS[i]);
	return out;
}

function copy_step(s) {
	let c = [];
	for (let i = 0; i < length(s.configs); i++) push(c, s.configs[i]);
	return { name: s.name, configs: c, rollback: s.rollback, needs: s.needs };
}

// tunnel_conf(protocol, cfg) → текст конфига активного туннеля из payload (по conf_key).
// ЧИСТАЯ: run.uc раздаёт результат туннель-шагу на stdin; ключ живёт в PROTOCOLS, не в if'ах.
function tunnel_conf(protocol, cfg) {
	let key = tunnel_info(protocol).conf_key;
	let v = (cfg ?? {})[key];
	return (type(v) == "string") ? v : "";
}

// enabled_steps(opts) → шаги к применению. opts.disable — список имён, которые пропустить.
function enabled_steps(opts) {
	let disable = (opts && opts.disable) ? opts.disable : [];
	let out = [];
	for (let i = 0; i < length(STEPS); i++)
		if (index(disable, STEPS[i].name) < 0)
			push(out, copy_step(STEPS[i]));
	return out;
}

// snapshot_scope(steps) → uci-конфиги для snapshot: объединение configs всех шагов, только
// реально откатываемые (is_clean_config), без дублей, в порядке встречи. Классификация шага
// dirty НЕ исключает его uci-configs: у гибридного шага (firewall) uci-часть (NAT-зона)
// откатывается snapshot'ом, а runtime-часть (nft/ip) — его собственным teardown'ом.
function snapshot_scope(steps) {
	let seen = {}, out = [];
	for (let i = 0; i < length(steps); i++) {
		let s = steps[i];
		for (let j = 0; j < length(s.configs); j++) {
			let c = s.configs[j];
			if (is_clean_config(c) && !seen[c]) { seen[c] = true; push(out, c); }
		}
	}
	return out;
}

// dirty_steps(steps) → имена грязных шагов (их откат при сбое — teardown, не uci-restore).
function dirty_steps(steps) {
	let out = [];
	for (let i = 0; i < length(steps); i++)
		if (steps[i].rollback == "dirty") push(out, steps[i].name);
	return out;
}

// decide_outcome(results) → { action, code, reason, failed }. action ∈ abort | rollback | commit.
//   results = { preflight:{ok}, steps:[{name,ok}...], health:{ok, dns_ok?, tun_ok?, tun_reason?}|null }
// ИНВАРИАНТ (fail-safe): нет preflight → abort; упал шаг или health → rollback; всё ок → commit.
// code — машинный код для UI (logic.js explainFail): туннель-причина (process/route/fetch)
// приоритетнее DNS — мёртвый туннель обычно и есть причина, почему DNS через него не резолвится;
// у AWG стадий нет (tun_reason null) и дефолт "fetch" = «сервер не ответил» верен и для него.
function decide_outcome(results) {
	if (!results || !results.preflight || results.preflight.ok !== true)
		return { action: "abort", code: "preflight", reason: "preflight не пройден — изменений нет", failed: [] };

	let failed = [];
	let steps = results.steps ?? [];
	for (let i = 0; i < length(steps); i++)
		if (steps[i].ok !== true) push(failed, steps[i].name);
	if (length(failed) > 0)
		return { action: "rollback", code: "step:" + failed[0],
			reason: sprintf("шаги упали: %s", join(", ", failed)), failed: failed };

	if (results.health && results.health.ok !== true) {
		let h = results.health, code = "health";
		if (h.tun_ok === false) code = "health:tunnel:" + (h.tun_reason ?? "fetch");
		else if (h.dns_ok === false) code = "health:dns";
		return { action: "rollback", code: code, reason: "health-check не пройден", failed: [] };
	}

	return { action: "commit", code: "ok", reason: "все фазы успешны", failed: [] };
}

// handshake_state(hs) — состояние по выводу `awg show <if> latest-handshakes` (строки
// "<pubkey>\t<секунд>"). ЧИСТАЯ — под тестами; run.uc её поллит вместо одноразового чтения
// (Шрам: раньше health читал handshake один раз сразу после firewall-шага и откатывал рабочую
// установку, увидев "waiting"). "none" — пустой вывод; "up" — ненулевой timestamp у peer'а;
// "waiting" — peer есть, рукопожатия ещё нет. Разбор по строкам, не regex "\t0$" — корректно
// для нескольких peer сразу.
function handshake_state(hs) {
	let s = trim(hs ?? "");
	if (length(s) == 0) return "none";
	let lines = split(s, "\n");
	for (let i = 0; i < length(lines); i++) {
		let f = split(trim(lines[i]), "\t");      // [pubkey, секунд]; pubkey — base64, без табов
		if (length(f) >= 2 && int(f[length(f) - 1]) > 0)
			return "up";
	}
	return "waiting";
}

// Свежесть AWG-рукопожатия для панели: сервер отвечал не позже этого окна (сек). Живой AWG
// пингует peer'а раз в ~2 мин; 300 с даёт запас на один пропуск, не объявляя туннель мёртвым.
const HANDSHAKE_FRESH_S = 300;

// tunnel_health(protocol, facts) → "up"|"down": один признак здоровья для панели на любой
// протокол. ЧИСТАЯ. Шрам: раньше судили только по AWG-рукопожатию — рабочий Reality (нет awg0)
// показывался как «не работает». Ветвится по ШАГУ (см. ИНВАРИАНТ у PROTOCOLS), не по имени.
// facts: hs_age (сек с рукопожатия|null), sb_running, tun_up. awg — свежий hs = up. sing-box —
// процесс+TUN живы = up (слабее: не тождественно трафику; настоящая достижимость — probe.uc,
// дороже, не на каждый поллинг).
function tunnel_health(protocol, facts) {
	let f = facts ?? {};
	if (uses_singbox(protocol ?? default_protocol()))
		return (f.sb_running === true && f.tun_up === true) ? "up" : "down";
	let age = f.hs_age;
	return (type(age) == "int" && age >= 0 && age < HANDSHAKE_FRESH_S) ? "up" : "down";
}

// fresh_handshake(hs, started) — есть ли у КАКОГО-ЛИБО peer'а рукопожатие не старше started
// (unix-время). ЧИСТАЯ: replace_vpn решает по ней commit/restore 30с-гейта. Шрам: как и в
// handshake_state, единый regex по многострочному выводу multi-peer конфига фейлил и ложно
// откатывал рабочий конфиг — разбор построчный.
function fresh_handshake(hs, started) {
	let s = trim(hs ?? "");
	if (length(s) == 0) return false;
	let lines = split(s, "\n");
	for (let i = 0; i < length(lines); i++) {
		// последний токен строки = секунды; принимает и сырой вывод awg, и урезанный (числа)
		let f = split(trim(lines[i]), /[ \t]+/);
		let ts = f[length(f) - 1];
		if (match(ts, /^[0-9]+$/) && int(ts) >= started)
			return true;
	}
	return false;
}

// route_uses_iface(route_out, iface) — идёт ли маршрут через iface по выводу `ip route get <ip>`.
// ЧИСТАЯ: probe.uc этим подтверждает, что форсированный host-route лёг именно на туннель, а не
// утёк на WAN. Формат первой строки: "<ip> dev <iface> ..."; токен берём строго ПОСЛЕ "dev" —
// не подстрокой (dev singtun0 ≠ dev singtun00).
function route_uses_iface(route_out, iface) {
	let s = trim(route_out ?? "");
	if (length(s) == 0 || length(iface ?? "") == 0) return false;
	let first = split(s, "\n")[0];
	let toks = split(trim(first), /[ \t]+/);
	for (let i = 0; i + 1 < length(toks); i++)
		if (toks[i] == "dev" && toks[i + 1] == iface)
			return true;
	return false;
}

export { protocol_ids, default_protocol, tunnel_info, tunnel_ifs, uses_singbox, tunnel_conf,
         disabled_tunnels, enabled_steps, snapshot_scope, dirty_steps, decide_outcome,
         handshake_state, fresh_handshake, tunnel_health, HANDSHAKE_FRESH_S,
         route_uses_iface };
