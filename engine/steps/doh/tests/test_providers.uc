// test_providers.uc — юнит-тесты каталога DNS-провайдеров. Без роутера.
//   ucode -R engine/steps/doh/tests/test_providers.uc

import { test, eq, ok, deep_eq, summary } from "../../../lib/assert.uc";
import { default_provider, provider_ids, resolvers_for, wan_user, describe,
         catalog_for_ui } from "../providers.uc";

test("default_provider — валидный id из каталога", () => {
	let ids = provider_ids();
	ok(index(ids, default_provider()) >= 0, "дефолт есть в каталоге");
	eq(default_provider(), "adguard", "дефолт = AdGuard (реклама)");
});

test("provider_ids — ожидаемый набор", () => {
	deep_eq(provider_ids(),
		[ "adguard", "adguard-family", "cleanbrowsing-family", "quad9", "cloudflare" ]);
});

test("resolvers_for — ДВА экземпляра: основной 5053 и резервный 5054, оба одного провайдера", () => {
	let r = resolvers_for("adguard-family");
	eq(length(r), 2, "основной (через туннель) + резервный (через WAN)");
	eq(r[0].name, "cheburnet_doh", "фиксированные имена секций → чистая замена");
	eq(r[0].port, 5053);
	eq(r[1].name, "cheburnet_doh_wan");
	eq(r[1].port, 5054);
	// Один провайдер на оба — иначе фильтрация молча менялась бы при переключении на резервный
	// (семейный фильтр не должен расфильтроваться в аварии).
	eq(r[0].url, "https://family.adguard-dns.com/dns-query");
	eq(r[1].url, r[0].url, "резервный — ТОТ ЖЕ провайдер и тот же уровень фильтрации");
	eq(r[1].bootstrap, r[0].bootstrap);
	ok(index(r[0].bootstrap, ",") >= 0, "два anycast-эндпоинта (redundancy в классе)");
});

// Единственное отличие резервного экземпляра — владелец сокетов: по нему policy-routing
// (steps/firewall, `ip rule uidrange`) уводит его мимо туннеля.
test("resolvers_for — резервный экземпляр под ОТДЕЛЬНЫМ пользователем", () => {
	let r = resolvers_for("adguard");
	eq(r[0].user, "nobody", "основной — обычный nobody");
	eq(r[1].user, wan_user(), "резервный — пользователь из wan_user()");
	ok(r[1].user != r[0].user, "разные пользователи, иначе правило по uid не различит их");
	ok(r[1].via_wan === true, "резервный помечен как идущий мимо туннеля");
});

test("resolvers_for — неизвестный id → дефолт (fail-safe, рабочий DNS)", () => {
	let r = resolvers_for("nonsense");
	eq(r[0].url, resolvers_for("adguard")[0].url, "откат на дефолт");
	let rnull = resolvers_for(null);
	eq(rnull[0].url, resolvers_for("adguard")[0].url, "null → дефолт");
});

test("describe — дружелюбное описание; категории заданы", () => {
	let d = describe("cloudflare");
	eq(d.category, "plain");
	ok(length(d.description) > 0, "есть описание для UI");
	eq(describe("nope"), null, "неизвестный → null");
});

test("catalog_for_ui — все провайдеры с id/name/description/category", () => {
	let cat = catalog_for_ui();
	eq(length(cat), length(provider_ids()));
	for (let i = 0; i < length(cat); i++) {
		ok(length(cat[i].id) > 0 && length(cat[i].name) > 0, "id+name");
		ok(length(cat[i].description) > 0, "описание");
		ok(index([ "plain", "ads", "family" ], cat[i].category) >= 0, "валидная категория");
	}
});

exit(summary());
