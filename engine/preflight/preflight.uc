// preflight.uc — гейткипер железа/версии/зависимостей: evaluate(facts, req) → отчёт (чистая логика,
// тесты: tests/). Факты собирает gather.uc (импурно, QEMU). Подробно: [[reliability]], [[hardware-requirements]].

// Требования по умолчанию.
// ИНВАРИАНТ: пороги калиброваны по MemTotal/свободному overlay, а не по паспорту железа — kernel
// резервирует память сверх MemTotal, и паспортный порог отказывал бы поддерживаемому железу
// (замер и разбор: [[hardware-requirements]]).
const REQUIREMENTS = {
	arch: [ "arm", "aarch64", "mips", "mipsel", "x86_64" ],
	min_openwrt: "25.12",   // apk-based ветка OpenWrt
	min_flash_mb: 16,       // пакеты + конфиги влезут
	min_ram_mb: 112,        // dnsmasq + awg не упадут под нагрузкой
	deps: [ "kmod-amneziawg", "https-dns-proxy", "dnsmasq" ],
};

// resolve_req(req) — REQUIREMENTS, перекрытые переданными значениями (известные ключи).
function resolve_req(req) {
	let r = {};
	for (let k in REQUIREMENTS)
		r[k] = REQUIREMENTS[k];
	if (req)
		for (let k in req)
			if (exists(REQUIREMENTS, k))
				r[k] = req[k];
	return r;
}

// default_requirements() — копия дефолтных требований (для gather/UI; источник правды списка
// зависимостей и порогов — здесь, чтобы не разъезжалось между модулями).
function default_requirements() {
	return resolve_req(null);
}

// cmp_version(a, b) → -1|0|1. Точечные числовые версии; SNAPSHOT новее любого релиза.
function cmp_version(a, b) {
	if (a == b) return 0;
	if (a == "SNAPSHOT") return 1;
	if (b == "SNAPSHOT") return -1;
	let pa = split(a, "."), pb = split(b, ".");
	let n = (length(pa) > length(pb)) ? length(pa) : length(pb);
	for (let i = 0; i < n; i++) {
		let x = int(pa[i] ?? "0"); // отсутствующий сегмент → 0 (25.12 vs 25.12.0)
		let y = int(pb[i] ?? "0");
		if (x > y) return 1;
		if (x < y) return -1;
	}
	return 0;
}

// ip4_to_int(ip) → целое или null, если не валидный IPv4-литерал.
function ip4_to_int(ip) {
	let p = split(ip, ".");
	if (length(p) != 4) return null;
	let n = 0;
	for (let i = 0; i < 4; i++) {
		if (!match(p[i], /^[0-9]+$/)) return null;
		let o = int(p[i]);
		if (o < 0 || o > 255) return null;
		n = n * 256 + o; // без bitwise: 64-бит ucode-int держит 2^32 точно
	}
	return n;
}

function parse_cidr(c) {
	let parts = split(c, "/");
	if (length(parts) != 2) return null;
	let ip = ip4_to_int(parts[0]);
	if (ip == null || !match(parts[1], /^[0-9]+$/)) return null;
	let pfx = int(parts[1]);
	if (pfx < 0 || pfx > 32) return null;
	return { ip: ip, pfx: pfx };
}

// cidr_overlap(a, b) → true, если две IPv4-подсети пересекаются. Сравниваем сетевые части
// по меньшему префиксу: если совпали — одна вложена в другую (или равны) → пересечение.
// Непарсимый вход → false: не выдаём ложный «конфликт» из-за неизвестного формата.
function cidr_overlap(a, b) {
	let A = parse_cidr(a), B = parse_cidr(b);
	if (!A || !B) return false;
	let p = (A.pfx < B.pfx) ? A.pfx : B.pfx;
	let div = 1;
	for (let i = 0; i < 32 - p; i++) div = div * 2; // 2^(host-битов)
	return int(A.ip / div) == int(B.ip / div);       // int(x/div) = обнуление младших битов
}

// suggest_lan(wan_cidr) → "192.168.X.1" — кандидат нового LAN-IP, чья /24 НЕ пересекается с
// WAN (проверка той же cidr_overlap — никаких префикс-сравнений «на глаз», урок v1). Набор
// кандидатов из v1 (частые домашние, но не дефолтные у провайдерских модемов). null —
// практически недостижимо (WAN-подсеть накрывает максимум один кандидат).
const LAN_CANDIDATES = [ 2, 3, 4, 8, 9, 10, 11 ];

function suggest_lan(wan_cidr) {
	for (let i = 0; i < length(LAN_CANDIDATES); i++) {
		let net = sprintf("192.168.%d.0/24", LAN_CANDIDATES[i]);
		if (!cidr_overlap(net, wan_cidr))
			return sprintf("192.168.%d.1", LAN_CANDIDATES[i]);
	}
	return null;
}

// valid_lan_ip(ip) → bool. Граница доверия apply_lan_ip: принимаем ТОЛЬКО 192.168.X.Y с
// валидными октетами и host-частью 1..254 — подделанный запрос не уронит роутер в
// 0.0.0.0/255.255.255.255 (safety guard из v1, ужесточённый: v1 пускал октеты до 999).
function valid_lan_ip(ip) {
	let m = match(ip ?? "", /^192\.168\.([0-9]{1,3})\.([0-9]{1,3})$/);
	if (!m) return false;
	let x = int(m[1]), y = int(m[2]);
	return x >= 0 && x <= 255 && y >= 1 && y <= 254;
}

// check(id, ok, detail, fix, severity) — один результат; fix только при провале. severity: "hard"
// (дефолт: arch/версия/пакеты — apk просто не найдёт файлы, пропуск обещал бы невозможное) |
// "soft" (флеш/RAM впритык — установка может пройти; пропускается осознанно, accept_risk).
function check(id, ok, detail, fix, severity) {
	return { id: id, ok: ok, detail: detail, fix: ok ? null : fix,
	         severity: severity ?? "hard" };
}

// evaluate(facts, req) → { passed, checks, hard_failed, soft_failed, overridable }. passed=false →
// движок систему не трогает; overridable = все провалы soft → владелец вправе поставить как есть.
// facts: { arch, openwrt_version, flash_free_mb, ram_total_mb, deps_installable: {pkg: bool}, lan_cidr, wan_cidr }
function evaluate(facts, req) {
	let r = resolve_req(req);
	let checks = [];

	// arch
	push(checks, check("arch", index(r.arch, facts.arch) >= 0,
		sprintf("arch = %s", facts.arch ?? "?"),
		sprintf("нужна одна из поддерживаемых: %s", join(", ", r.arch))));

	// версия OpenWrt
	let ver = facts.openwrt_version ?? "";
	push(checks, check("openwrt", ver != "" && cmp_version(ver, r.min_openwrt) >= 0,
		sprintf("OpenWrt %s", ver != "" ? ver : "?"),
		sprintf("нужна версия ≥ %s (apk-based)", r.min_openwrt)));

	// флеш (soft: не хватило — apk честно упадёт, установка откатится)
	let flash = facts.flash_free_mb ?? -1;
	push(checks, check("flash", flash >= r.min_flash_mb,
		sprintf("свободный флеш ≈ %d МБ", flash),
		sprintf("нужно ≥ %d МБ свободно", r.min_flash_mb), "soft"));

	// RAM (soft: мало памяти = риск OOM под нагрузкой, а не невозможность установки)
	let ram = facts.ram_total_mb ?? -1;
	push(checks, check("ram", ram >= r.min_ram_mb,
		sprintf("RAM ≈ %d МБ", ram),
		sprintf("нужно ≥ %d МБ", r.min_ram_mb), "soft"));

	// зависимости устанавливаются — ГЛАВНЫЙ чек: иначе install упрётся на середине
	let di = facts.deps_installable ?? {};
	let missing = [];
	for (let i = 0; i < length(r.deps); i++) {
		let d = r.deps[i];
		if (di[d] !== true)
			push(missing, d);
	}
	push(checks, check("deps", length(missing) == 0,
		length(missing) == 0 ? sprintf("все зависимости ставятся (%d)", length(r.deps))
		                      : sprintf("не ставятся: %s", join(", ", missing)),
		"проверьте feed/arch — нужные пакеты не доступны под эту платформу"));

	// конфликт LAN/WAN — только если обе подсети известны (иначе нечего сравнивать)
	if (facts.lan_cidr && facts.wan_cidr) {
		let clash = cidr_overlap(facts.lan_cidr, facts.wan_cidr);
		push(checks, check("lan_wan", !clash,
			sprintf("LAN %s / WAN %s", facts.lan_cidr, facts.wan_cidr),
			"LAN и WAN пересекаются — смените подсеть LAN, иначе потеряете доступ"));
	}

	let failed = 0, hard_failed = 0, soft_failed = 0;
	for (let i = 0; i < length(checks); i++) {
		if (checks[i].ok) continue;
		failed++;
		if (checks[i].severity == "soft") soft_failed++; else hard_failed++;
	}

	return {
		passed: failed == 0, failed: failed, total: length(checks),
		hard_failed: hard_failed, soft_failed: soft_failed,
		overridable: (hard_failed == 0 && soft_failed > 0),
		checks: checks,
	};
}

// soft_failed_ids(report) → id провалившихся soft-проверок (["flash","ram"]). Нужны и UI
// (объяснить каждый пропуск адресно), и install.json (запомнить, ЧТО именно пропущено).
function soft_failed_ids(report) {
	let out = [];
	for (let i = 0; i < length(report.checks); i++) {
		let c = report.checks[i];
		if (!c.ok && c.severity == "soft")
			push(out, c.id);
	}
	return out;
}

// Full-тир (Reality/Hysteria2 через sing-box) — более жёсткие требования, замер и разбор
// порогов: [[hardware-requirements]]. arch — proxy для AES-ускорения (точная проверка cpuinfo —
// gather, router-side).
const FULL_REQUIREMENTS = {
	arch: [ "aarch64", "x86_64" ],  // ARMv8/x86 с AES; mips/armv7 исключены
	min_flash_mb: 44,                // sing-box-tiny + config.json + логи (замер: make qemu-hysteria)
	min_ram_mb: 240,                 // = плата на 256 МБ (MemTotal < паспорта, см. REQUIREMENTS)
	// ИНВАРИАНТ: любой пакет из pkgs подходит — sing-box-tiny и sing-box взаимозаменяемы
	// (PROVIDES:=sing-box, тот же бинарь и init-скрипт); tiny предпочтителен, sing-box — фолбэк.
	pkgs: [ "sing-box-tiny", "sing-box" ],
};

function resolve_full_req(req) {
	let r = {};
	for (let k in FULL_REQUIREMENTS)
		r[k] = FULL_REQUIREMENTS[k];
	if (req)
		for (let k in req)
			if (exists(FULL_REQUIREMENTS, k))
				r[k] = req[k];
	return r;
}

// full_requirements() — копия дефолтных требований Full-тира (для gather/UI; источник правды здесь).
function full_requirements() {
	return resolve_full_req(null);
}

// num_or(v, fallback) — целое из значения, пришедшего из shell-батча (строка/мусор/пусто).
// Не-число → fallback: для гейтов это -1 (fail-safe «не подтвердили → не обещаем»).
function num_or(v, fallback) {
	if (type(v) == "int") return v;
	return match("" + (v ?? ""), /^[0-9]+$/) ? int(v) : fallback;
}

// full_hw_missing(arch, ram_mb, flash_mb, req) → чего не хватает железу для Full-тира: массив
// из "arch"|"ram"|"flash" (пусто = тянет). Лёгкие признаки для панели (видимость кнопки
// «Включить VLESS+Reality»), БЕЗ apk --simulate — авторитетный гейт остаётся за preflight
// при установке. flash_mb == null (факт не собран) → флеш не виним, а не гадаем.
function full_hw_missing(arch, ram_mb, flash_mb, req) {
	let r = resolve_full_req(req);
	let out = [];
	if (index(r.arch, arch ?? "") < 0) push(out, "arch");
	if (num_or(ram_mb, -1) < r.min_ram_mb) push(out, "ram");
	if (flash_mb != null && flash_mb !== "" && num_or(flash_mb, -1) < r.min_flash_mb)
		push(out, "flash");
	return out;
}

// evaluate_tiers(facts, req) → { light, full, full_installed, full_checks, full_failed }: light —
// базовый гейт; full — железо ПОТЯНЕТ Full (light ∧ AES-arch ∧ RAM/флеш ∧ бинарь установим);
// full_installed — sing-box реально стоит (capable ≠ installed). req.full — пороги Full (тесты).
// ИНВАРИАНТ: гейт железа ОДИН на оба Full-протокола — ветвление по шагу, не по протоколу.
function evaluate_tiers(facts, req) {
	let light = evaluate(facts, req);
	let fr = resolve_full_req(req ? req.full : null);

	let checks = [];
	push(checks, check("full_arch", index(fr.arch, facts.arch) >= 0,
		sprintf("arch = %s", facts.arch ?? "?"),
		sprintf("Full-тир нужен AES-arch: %s", join(", ", fr.arch))));

	let ram = facts.ram_total_mb ?? -1;
	push(checks, check("full_ram", ram >= fr.min_ram_mb,
		sprintf("RAM ≈ %d МБ", ram),
		sprintf("Full-тиру нужно ≥ %d МБ", fr.min_ram_mb)));

	let flash = facts.flash_free_mb ?? -1;
	push(checks, check("full_flash", flash >= fr.min_flash_mb,
		sprintf("свободный флеш ≈ %d МБ", flash),
		sprintf("Full-тиру нужно ≥ %d МБ", fr.min_flash_mb)));

	// Пакет Full-тира: достаточно ЛЮБОГО из pkgs (они взаимозаменяемы — см. FULL_REQUIREMENTS).
	let di = facts.deps_installable ?? {};
	let sb_pkg = null;
	for (let i = 0; i < length(fr.pkgs); i++)
		if (sb_pkg == null && di[fr.pkgs[i]] === true) sb_pkg = fr.pkgs[i];
	push(checks, check("full_dep", sb_pkg != null,
		sb_pkg != null ? sprintf("%s ставится", sb_pkg)
		               : sprintf("не ставится ни один из: %s", join(", ", fr.pkgs)),
		sprintf("пакеты %s недоступны под эту платформу/feed", join(" / ", fr.pkgs))));

	let failed = 0;
	for (let i = 0; i < length(checks); i++)
		if (!checks[i].ok) failed++;

	return {
		light: light.passed,
		full: light.passed && failed == 0,
		full_installed: facts.sing_box_installed === true,
		full_checks: checks,
		full_failed: failed,
	};
}

// render_report(report, allow_soft) — человекочитаемые строки для CLI/лога. allow_soft=true —
// режим «владелец согласился на риск»: soft-провалы помечаем «!» (пропущено) вместо «✗», и итог
// говорит, что установка идёт С ПРОПУСКОМ — это остаётся в install.log как след решения.
function render_report(report, allow_soft) {
	let out = [];
	for (let i = 0; i < length(report.checks); i++) {
		let c = report.checks[i];
		let soft_skipped = !c.ok && c.severity == "soft" && allow_soft;
		let mark = c.ok ? "✓" : (soft_skipped ? "!" : "✗");
		let line = sprintf("%s %-8s %s", mark, c.id, c.detail);
		if (!c.ok && c.fix)
			line += sprintf("  → %s%s", c.fix, soft_skipped ? " (пропущено по решению владельца)" : "");
		push(out, line);
	}
	if (report.passed)
		push(out, sprintf("preflight OK — железо подходит (%d проверок)", report.total));
	else if (allow_soft && report.hard_failed == 0)
		push(out, sprintf("preflight ПРОПУЩЕН — %d проверок железа не пройдено, установка на свой риск: стабильность не гарантируется",
			report.soft_failed));
	else
		push(out, sprintf("preflight ОТКАЗ — провалено %d из %d", report.failed, report.total));
	return out;
}

export { default_requirements, cmp_version, cidr_overlap, suggest_lan, valid_lan_ip, evaluate, soft_failed_ids, full_requirements, full_hw_missing, evaluate_tiers, render_report };
