// doh.uc — DoH-шаг: build_doh_plan(current, opts) → uci-операции https-dns-proxy + dnsmasq (чисто;
// apply.uc применяет). dnsmasq-привязку держим сами, не магией пакета. Подробно: [[encrypted-dns]].
// ИНВАРИАНТ: экземпляров ДВА (через туннель и через WAN) и dnsmasq спрашивает их строго по порядку
// (strictorder) — иначе резервный отвечал бы наперегонки, и DoH уходил бы мимо туннеля постоянно.

import { starts_with } from "../../lib/uci.uc";
import { resolvers_for, default_provider } from "./providers.uc";

const DOH_DEFAULTS = {
	listen_addr: "127.0.0.1",
	dnsmasq_section: "@dnsmasq[0]",
	manage_dnsmasq: true, // отключаем авто-правку dnsmasq пакетом — рулим upstream сами
	strict_order: true,   // спрашивать upstream'ы по порядку, а не наперегонки (см. ИНВАРИАНТ)
	// Дефолт — провайдер по умолчанию из каталога (см. providers.uc). Резолверы каждого
	// провайдера приходят opts.resolvers (их подставляет apply/plan по выбранному id).
	resolvers: resolvers_for(default_provider()),
};

function resolve_opts(opts) {
	let o = {};
	for (let k in DOH_DEFAULTS) o[k] = DOH_DEFAULTS[k];
	if (opts) for (let k in opts) if (exists(DOH_DEFAULTS, k)) o[k] = opts[k];
	return o;
}

// listen_prefix() → префикс НАШИХ dnsmasq-upstream-записей ("127.0.0.1#"). По нему шаг (и
// reset.uc) отличает свои server-записи от чужих — единственный источник, не дрейфует.
function listen_prefix() {
	return DOH_DEFAULTS.listen_addr + "#";
}

// build_doh_plan(current, opts) → { ok, errors, hdp_teardown, hdp_setup, dnsmasq_ops, servers }.
//   current — снимок из apply: { hdp_sections: [имена секций], servers: [server-записи dnsmasq] }.
// Идемпотентность: https-dns-proxy секции пересоздаём (delete-before-set, плюс сносим ВСЕ
// существующие — иначе дефолтная секция пакета на :5053 конфликтует с нашей); dnsmasq server —
// минимальный diff по НАШИМ записям (127.0.0.1#port), чужие upstream не трогаем.
function build_doh_plan(current, opts) {
	let o = resolve_opts(opts);
	let R = o.resolvers;

	let errors = [], names = {}, ports = {};
	if (!R || length(R) == 0)
		push(errors, "пустой список резолверов");
	for (let i = 0; i < length(R); i++) {
		let r = R[i];
		if (!r.name || !r.url || !r.port) { push(errors, "резолвер без name/url/port"); continue; }
		if (names[r.name]) push(errors, sprintf("дубль имени резолвера: %s", r.name));
		if (ports[r.port]) push(errors, sprintf("дубль порта: %d", r.port));
		names[r.name] = true; ports[r.port] = true;
	}
	if (length(errors) > 0)
		return { ok: false, errors: errors, hdp_teardown: [], hdp_setup: [], dnsmasq_ops: [] };

	// teardown: снести ВСЕ существующие секции + наши имена — чистая замена. ШРАМ: анонимные секции
	// пакета удаляются со сдвигом индексов — второй delete промахивался, чужой экземпляр занимал
	// порт 5054 и подменял резервный (qemu-dns-fallback, 2026-08-23). Поэтому анонимные — в обратном
	// порядке индексов и ДО именованных.
	let td = [], seen = {}, anon = [], named = [];
	let existing = (current && current.hdp_sections) ? current.hdp_sections : [];
	for (let i = 0; i < length(existing); i++) {
		let s = existing[i];
		if (seen[s]) continue;
		seen[s] = true;
		let m = match(s, /^@[^\[]+\[(-?[0-9]+)\]$/);
		if (m) push(anon, { name: s, idx: int(m[1]) });
		else push(named, s);
	}
	sort(anon, (a, b) => b.idx - a.idx); // по убыванию индекса — удаление не сдвигает следующие
	for (let i = 0; i < length(anon); i++)
		push(td, sprintf("delete https-dns-proxy.%s", anon[i].name));
	for (let i = 0; i < length(named); i++)
		push(td, sprintf("delete https-dns-proxy.%s", named[i]));
	for (let i = 0; i < length(R); i++) {
		let n = R[i].name;
		if (!seen[n]) { push(td, sprintf("delete https-dns-proxy.%s", n)); seen[n] = true; }
	}

	// setup: отключить авто-привязку dnsmasq пакетом (рулим сами) + секции резолверов.
	let su = [];
	if (o.manage_dnsmasq) {
		// Секцию 'config' (тип main) создаём САМИ: пакет https-dns-proxy её НЕ гарантирует —
		// в свежей установке (проверено на роутере, пакет 2026.03.18) секции нет, и `set` опции
		// падал с 'uci: Invalid argument'. `set …=main` идемпотентен (повторно — no-op).
		push(su, "set https-dns-proxy.config=main");
		// Платформенный квирк: имя опции менялось между версиями пакета (update_dnsmasq_config →
		// dnsmasq_config_update) — пишем ОБА, неактуальное просто инертно. ШРАМ: без '-' init пакета
		// на каждом старте вписывает свои инстансы в dhcp.server, и чужой резолвер (dns.google)
		// оказывается upstream'ом мимо выбранной фильтрации (живой прогон, 2026-07-08).
		push(su, "set https-dns-proxy.config.update_dnsmasq_config='-'");
		push(su, "set https-dns-proxy.config.dnsmasq_config_update='-'");
	}
	for (let i = 0; i < length(R); i++) {
		let r = R[i];
		push(su, sprintf("set https-dns-proxy.%s=https-dns-proxy", r.name));
		push(su, sprintf("set https-dns-proxy.%s.listen_addr='%s'", r.name, o.listen_addr));
		push(su, sprintf("set https-dns-proxy.%s.listen_port='%d'", r.name, r.port));
		push(su, sprintf("set https-dns-proxy.%s.resolver_url='%s'", r.name, r.url));
		if (r.bootstrap)
			push(su, sprintf("set https-dns-proxy.%s.bootstrap_dns='%s'", r.name, r.bootstrap));
		// user/group — из каталога: у резервного экземпляра ОТДЕЛЬНЫЙ владелец, по нему
		// steps/firewall уводит его сокеты мимо туннеля (см. ИНВАРИАНТ в providers.uc).
		push(su, sprintf("set https-dns-proxy.%s.user='%s'", r.name, r.user ?? "nobody"));
		push(su, sprintf("set https-dns-proxy.%s.group='%s'", r.name, r.group ?? "nogroup"));
		// polling_interval — только если каталог его задал (см. providers.uc): у резервного
		// экземпляра служебные перепроверки адреса резолвера видны провайдеру, поэтому они редкие.
		if (r.polling)
			push(su, sprintf("set https-dns-proxy.%s.polling_interval='%d'", r.name, r.polling));
	}

	// dnsmasq upstream: server = listen_addr#port каждого резолвера, В ПОРЯДКЕ каталога. Чужие
	// upstream-серверы пользователя не трогаем — работаем только со своими (listen_addr#).
	// ПОРЯДОК ЗНАЧИМ (strict-order), поэтому сверяем СПИСКОМ, а не множеством: разошёлся порядок —
	// переписываем свои записи целиком. Совпал — не трогаем вовсе (идемпотентность).
	let desired = [];
	for (let i = 0; i < length(R); i++)
		push(desired, sprintf("%s#%d", o.listen_addr, R[i].port));
	let cur_servers = (current && current.servers) ? current.servers : [];
	let owned = [];
	for (let i = 0; i < length(cur_servers); i++)
		if (starts_with(cur_servers[i], o.listen_addr + "#"))
			push(owned, cur_servers[i]);
	let dops = [], sect = o.dnsmasq_section;
	if (join("\n", owned) != join("\n", desired)) {
		for (let i = 0; i < length(owned); i++)
			push(dops, sprintf("del_list dhcp.%s.server='%s'", sect, owned[i]));
		for (let i = 0; i < length(desired); i++)
			push(dops, sprintf("add_list dhcp.%s.server='%s'", sect, desired[i]));
	}
	// strict-order — идемпотентный set (см. ИНВАРИАНТ в шапке).
	let cur_opts = (current && current.options) ? current.options : {};
	if (o.strict_order && cur_opts.strictorder != "1")
		push(dops, sprintf("set dhcp.%s.strictorder='1'", sect));

	// ШРАМ: https-dns-proxy восстанавливает dnsmasq из СВОИХ backup-ключей (doh_backup_*) при
	// каждой остановке/ребуте, даже после того как мы забрали upstream себе — шифрование тихо
	// отключалось после первого же ребута (qemu-reboot, 2026-07-31). Подробно: [[encrypted-dns]].
	// ОТДЕЛЬНЫМ списком (не dnsmasq_ops): uci_batch считает сбоем любой вывод, включая «Entry not
	// found» — отсутствие ключей это норма (повторный запуск). rc игнорируется осознанно (apply.uc).
	let cleanup = [];
	if (o.manage_dnsmasq) {
		push(cleanup, sprintf("delete dhcp.%s.doh_backup_noresolv", sect));
		push(cleanup, sprintf("delete dhcp.%s.doh_backup_server", sect));
		push(cleanup, sprintf("delete dhcp.%s.doh_server", sect));
	}

	return {
		ok: true, errors: [],
		hdp_teardown: td, hdp_setup: su, dnsmasq_ops: dops,
		dnsmasq_cleanup: cleanup,
		servers: desired,
	};
}

export { listen_prefix, build_doh_plan };
