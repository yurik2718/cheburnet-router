// test_doh.uc — юнит-тесты DoH-шага. Без роутера.
//   ucode -R engine/steps/doh/tests/test_doh.uc

import { test, eq, ok, deep_eq, summary } from "../../../lib/assert.uc";
import { build_doh_plan, listen_prefix } from "../doh.uc";

function has(arr, s) {
	for (let i = 0; i < length(arr); i++) if (arr[i] == s) return true;
	return false;
}

// --- дефолтный провайдер из каталога: AdGuard, одна секция cheburnet_doh:5053 ---
test("дефолт: секция cheburnet_doh (AdGuard) на порту 5053", () => {
	let p = build_doh_plan({ hdp_sections: [], servers: [] }, null);
	ok(p.ok);
	ok(has(p.hdp_setup, "set https-dns-proxy.cheburnet_doh=https-dns-proxy"));
	ok(has(p.hdp_setup, "set https-dns-proxy.cheburnet_doh.listen_port='5053'"));
	ok(has(p.hdp_setup, "set https-dns-proxy.cheburnet_doh.resolver_url='https://dns.adguard-dns.com/dns-query'"));
	ok(has(p.hdp_setup, "set https-dns-proxy.cheburnet_doh.bootstrap_dns='94.140.14.14,94.140.15.15'"));
});

test("сами рулим dnsmasq: создаём секцию config + отключаем авто-привязку ОБОИМИ именами", () => {
	let p = build_doh_plan({ hdp_sections: [], servers: [] }, null);
	// секцию создаём САМИ (пакет не гарантирует) — иначе set опции падал 'Invalid argument'
	ok(has(p.hdp_setup, "set https-dns-proxy.config=main"));
	// имя опции менялось между версиями пакета: старое update_… + текущее dnsmasq_… — оба '-',
	// иначе init сам вписывает свои инстансы (dns.google) в dhcp.server мимо фильтрации
	ok(has(p.hdp_setup, "set https-dns-proxy.config.update_dnsmasq_config='-'"));
	ok(has(p.hdp_setup, "set https-dns-proxy.config.dnsmasq_config_update='-'"));
});

// --- dnsmasq upstream: свежая система → add нашего локального порта ---
// ПОРЯДОК upstream'ов значим: первым основной (через туннель), вторым резервный (через WAN).
// Перепутанный порядок = DoH постоянно уходит мимо туннеля, и это никак не заметно снаружи.
test("dnsmasq upstream: чистая система → оба порта ПО ПОРЯДКУ + strict-order", () => {
	let p = build_doh_plan({ hdp_sections: [], servers: [] }, null);
	deep_eq(p.dnsmasq_ops, [
		"add_list dhcp.@dnsmasq[0].server='127.0.0.1#5053'",
		"add_list dhcp.@dnsmasq[0].server='127.0.0.1#5054'",
		"set dhcp.@dnsmasq[0].strictorder='1'",
	]);
});

test("dnsmasq upstream: порядок разошёлся → наши записи переписываются целиком", () => {
	let p = build_doh_plan({ hdp_sections: [], servers: [ "127.0.0.1#5054", "127.0.0.1#5053" ],
		options: { strictorder: "1" } }, null);
	deep_eq(p.dnsmasq_ops, [
		"del_list dhcp.@dnsmasq[0].server='127.0.0.1#5054'",
		"del_list dhcp.@dnsmasq[0].server='127.0.0.1#5053'",
		"add_list dhcp.@dnsmasq[0].server='127.0.0.1#5053'",
		"add_list dhcp.@dnsmasq[0].server='127.0.0.1#5054'",
	], "иначе резервный отвечал бы первым и DoH шёл бы мимо туннеля");
});

// --- идемпотентность upstream: уже настроено → no-op ---
test("dnsmasq upstream: уже настроено → пустой diff", () => {
	let p = build_doh_plan({
		hdp_sections: [ "cheburnet_doh", "cheburnet_doh_wan" ],
		servers: [ "127.0.0.1#5053", "127.0.0.1#5054" ],
		options: { strictorder: "1" },
	}, null);
	deep_eq(p.dnsmasq_ops, []);
});

// --- чужой upstream пользователя не трогаем ---
test("чужой upstream-сервер (не 127.0.0.1#) сохраняется", () => {
	let p = build_doh_plan({
		hdp_sections: [],
		servers: [ "8.8.8.8", "127.0.0.1#5053", "127.0.0.1#5054" ],
		options: { strictorder: "1" },
	}, null);
	deep_eq(p.dnsmasq_ops, [], "наши на месте и в порядке, чужой 8.8.8.8 не тронут");
});

// --- замена дефолтной секции пакета (конфликт по порту) ---
test("teardown сносит существующие секции пакета + нашу (чистая замена провайдера)", () => {
	let p = build_doh_plan({ hdp_sections: [ "cfg01" ], servers: [] }, null);
	ok(has(p.hdp_teardown, "delete https-dns-proxy.cfg01"), "дефолтная секция пакета снесена");
	ok(has(p.hdp_teardown, "delete https-dns-proxy.cheburnet_doh"), "наша секция (смена провайдера)");
});

// --- кастомные резолверы заменяют дефолт ---
test("кастомный резолвер заменяет дефолт", () => {
	let p = build_doh_plan({ hdp_sections: [], servers: [] }, {
		resolvers: [ { name: "mullvad", url: "https://dns.mullvad.net/dns-query", port: 5053 } ],
	});
	ok(has(p.hdp_setup, "set https-dns-proxy.mullvad.resolver_url='https://dns.mullvad.net/dns-query'"));
	ok(!has(p.hdp_setup, "set https-dns-proxy.quad9=https-dns-proxy"), "quad9 не появляется");
	deep_eq(p.dnsmasq_ops, [ "add_list dhcp.@dnsmasq[0].server='127.0.0.1#5053'",
		"set dhcp.@dnsmasq[0].strictorder='1'" ]);
});

test("резолвер без bootstrap → строки bootstrap_dns нет", () => {
	let p = build_doh_plan({ hdp_sections: [], servers: [] }, {
		resolvers: [ { name: "r1", url: "https://r1/dns-query", port: 5053 } ],
	});
	ok(index(join("\n", p.hdp_setup), "bootstrap_dns") < 0);
});

// --- manage_dnsmasq=false ---
test("manage_dnsmasq=false: строк отключения авто-привязки нет (оба имени)", () => {
	let p = build_doh_plan({ hdp_sections: [], servers: [] }, { manage_dnsmasq: false });
	ok(index(join("\n", p.hdp_setup), "update_dnsmasq_config") < 0);
	ok(index(join("\n", p.hdp_setup), "dnsmasq_config_update") < 0);
});

// Регресс, найденный qemu-reboot: пакет восстанавливает dnsmasq из своих служебных ключей при
// каждой остановке (в т.ч. при ребуте) — и уносил наш noresolv с апстримом. Шифрованный DNS
// отключался сам, молча, при живом split-routing. Забрали управление → служебные ключи обязаны
// исчезнуть: восстанавливать нечего, значит ломать нечего.
test("manage_dnsmasq=true: служебные ключи пакета в секции dnsmasq снимаются", () => {
	let p = build_doh_plan({ hdp_sections: [], servers: [] }, {});
	let ops = join("\n", p.dnsmasq_cleanup);
	// В обязательный батч они попасть НЕ должны: «Entry not found» там роняет шаг на повторе.
	ok(index(join("\n", p.dnsmasq_ops), "doh_backup") < 0, "уборка идёт отдельным списком");
	ok(index(ops, "delete dhcp.@dnsmasq[0].doh_backup_noresolv") >= 0, "снят бэкап noresolv");
	ok(index(ops, "delete dhcp.@dnsmasq[0].doh_backup_server") >= 0, "снят бэкап server");
	ok(index(ops, "delete dhcp.@dnsmasq[0].doh_server") >= 0, "снят маркер своих upstream-записей");
});
test("manage_dnsmasq=false: служебные ключи пакета НЕ трогаем (управляет он)", () => {
	let p = build_doh_plan({ hdp_sections: [], servers: [] }, { manage_dnsmasq: false });
	ok(index(join("\n", p.dnsmasq_cleanup), "doh_backup") < 0, "чужим владением не распоряжаемся");
});

// --- валидация ---
test("валидация: пустой список резолверов → ok=false", () => {
	let p = build_doh_plan({ hdp_sections: [], servers: [] }, { resolvers: [] });
	ok(!p.ok);
});
test("валидация: дубль порта → ok=false", () => {
	let p = build_doh_plan({ hdp_sections: [], servers: [] }, {
		resolvers: [
			{ name: "a", url: "https://a/dns-query", port: 5053 },
			{ name: "b", url: "https://b/dns-query", port: 5053 },
		],
	});
	ok(!p.ok);
});

test("listen_prefix: префикс наших dnsmasq-upstream (источник для reset)", () => {
	eq(listen_prefix(), "127.0.0.1#");
});

// --- удаление УСТАРЕВШЕГО нашего upstream'а (смена схемы портов / провайдера) ---
test("dnsmasq upstream: наш устаревший порт удаляется, чужой сервер не трогается", () => {
	let p = build_doh_plan({ hdp_sections: [], servers: [ "127.0.0.1#5054", "8.8.8.8" ] }, null);
	ok(p.ok);
	// remove-ветка reconcile по owned-префиксу: без неё мёртвый upstream остаётся у dnsmasq
	// навсегда («годы без обслуживания» → перемежающийся медленный DNS).
	ok(has(p.dnsmasq_ops, "del_list dhcp.@dnsmasq[0].server='127.0.0.1#5054'"));
	ok(has(p.dnsmasq_ops, "add_list dhcp.@dnsmasq[0].server='127.0.0.1#5053'"));
	ok(!has(p.dnsmasq_ops, "del_list dhcp.@dnsmasq[0].server='8.8.8.8'"), "чужой upstream сохраняем");
});

// Резервный экземпляр обязан получить СВОЕГО владельца: по нему (и только по нему) firewall
// уводит его мимо туннеля. Совпали пользователи — правило по uid перестаёт различать экземпляры,
// и «резервный» путь тихо оказывается тем же самым, что основной.
test("user/group берутся из записи резолвера, а не хардкодятся", () => {
	let p = build_doh_plan({ hdp_sections: [], servers: [] }, null);
	ok(has(p.hdp_setup, "set https-dns-proxy.cheburnet_doh.user='nobody'"));
	ok(has(p.hdp_setup, "set https-dns-proxy.cheburnet_doh_wan.user='network'"));
	ok(!has(p.hdp_setup, "set https-dns-proxy.cheburnet_doh_wan.user='nobody'"),
		"иначе `ip rule uidrange` не отличит резервный экземпляр от основного");
});

// Служебные перепроверки резервного экземпляра уходят мимо туннеля и видны провайдеру, даже
// когда резервным никто не пользуется — поэтому они редкие, а у основного остаётся дефолт пакета.
// Регресс: секции пакета анонимные, и удаление сдвигает индексы. Снёс [0] — бывший [1] стал [0],
// второй delete промахивается, чужой экземпляр выживает и занимает наш порт 5054, подменяя
// резервный резолвер на dns.google мимо выбранной фильтрации.
test("teardown: анонимные секции сносятся ПО УБЫВАНИЮ индекса (иначе одна выживает)", () => {
	let p = build_doh_plan({ hdp_sections: [ "@https-dns-proxy[0]", "@https-dns-proxy[1]" ],
		servers: [] }, null);
	let first = p.hdp_teardown[0], second = p.hdp_teardown[1];
	eq(first, "delete https-dns-proxy.@https-dns-proxy[1]", "сначала последний индекс");
	eq(second, "delete https-dns-proxy.@https-dns-proxy[0]");
});

test("teardown: анонимные идут ДО именованных (индекс считается среди всех секций типа)", () => {
	let p = build_doh_plan({ hdp_sections: [ "cheburnet_doh", "@https-dns-proxy[1]" ],
		servers: [] }, null);
	eq(p.hdp_teardown[0], "delete https-dns-proxy.@https-dns-proxy[1]");
	ok(index(p.hdp_teardown, "delete https-dns-proxy.cheburnet_doh") > 0);
});

test("polling_interval ставится ТОЛЬКО резервному экземпляру", () => {
	let p = build_doh_plan({ hdp_sections: [], servers: [] }, null);
	ok(has(p.hdp_setup, "set https-dns-proxy.cheburnet_doh_wan.polling_interval='3600'"));
	ok(index(join("\n", p.hdp_setup), "cheburnet_doh.polling_interval") < 0,
		"основной экземпляр ходит туннелем — экономить его сигналы не за чем");
});

test("strict-order не переписывается, если уже стоит (идемпотентность)", () => {
	let p = build_doh_plan({ hdp_sections: [], servers: [ "127.0.0.1#5053", "127.0.0.1#5054" ],
		options: { strictorder: "1" } }, null);
	ok(index(join("\n", p.dnsmasq_ops), "strictorder") < 0);
});

exit(summary());
