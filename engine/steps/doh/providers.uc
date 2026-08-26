// providers.uc — каталог DNS-провайдеров (DoH): выбор фильтрации = выбор резолвера, не
// локальный список. Подробно: [[0005-dns-filtering-not-local-adblock]].
// ИНВАРИАНТ: fallback только В ПРЕДЕЛАХ category — семейный фильтр не должен молча
// расфильтроваться на нефильтрующий резолвер; отсюда 2 bootstrap-IP на провайдера, не кросс-класс.

// ДВА экземпляра одного и того же провайдера — основной и резервный. Основной ходит обычным
// путём (через туннель), резервный прибит к WAN и нужен ровно тогда, когда основной молчит:
// туннель мёртв, провайдер недостижим изнутри туннеля или сам процесс упал. Провайдер у них
// ОДИН — иначе фильтрация молча менялась бы при переключении (см. ИНВАРИАНТ выше).
const SECTION = "cheburnet_doh";      // основной: upstream уходит В ТУННЕЛЬ
const SECTION_WAN = "cheburnet_doh_wan"; // резервный: прибит к WAN
const PORT = 5053;               // локальный порт основного (первый upstream dnsmasq)
const PORT_WAN = 5054;           // локальный порт резервного (второй upstream, strict-order)
// ИНВАРИАНТ: резервный экземпляр отличается от основного ТОЛЬКО владельцем сокетов — по нему
// policy-routing уводит его в table 100 мимо туннеля (`ip rule uidrange`, steps/firewall).
// Метка пакетов в output-хуке для этого НЕ годится: сокет выбирает src-адрес при connect(),
// до попадания в хук, и пакет уходит в WAN с адресом туннеля (проверено в QEMU 2026-08-23).
// Берём существующего системного пользователя OpenWrt — заводить своего ради одного демона не за что.
const WAN_USER = "network";
const MAIN_USER = "nobody";
const DEFAULT_ID = "adguard";    // дефолт: реклама+трекеры, полезно и ничего не ломает

// Каталог. Порядок стабилен (UI рисует в нём же). Эндпоинты — публичные, бесплатные, без аккаунта.
const PROVIDERS = [
	{ id: "adguard",              name: "AdGuard",               category: "ads",
	  description: "Блокирует рекламу и трекеры",
	  url: "https://dns.adguard-dns.com/dns-query",     bootstrap: "94.140.14.14,94.140.15.15" },
	{ id: "adguard-family",       name: "AdGuard Семейный",      category: "family",
	  description: "Реклама, трекеры, сайты 18+ и безопасный поиск",
	  url: "https://family.adguard-dns.com/dns-query",  bootstrap: "94.140.14.15,94.140.15.16" },
	{ id: "cleanbrowsing-family", name: "CleanBrowsing Семейный", category: "family",
	  description: "Сайты 18+ и безопасный поиск",
	  url: "https://doh.cleanbrowsing.org/doh/family-filter/", bootstrap: "185.228.168.168,185.228.169.168" },
	{ id: "quad9",                name: "Quad9",                 category: "plain",
	  description: "Без логов, блокирует вредоносные сайты",
	  url: "https://dns.quad9.net/dns-query",           bootstrap: "9.9.9.9,149.112.112.112" },
	{ id: "cloudflare",           name: "Cloudflare",            category: "plain",
	  description: "Быстрый, без фильтрации",
	  url: "https://cloudflare-dns.com/dns-query",      bootstrap: "1.1.1.1,1.0.0.1" },
];

function find(id) {
	for (let i = 0; i < length(PROVIDERS); i++)
		if (PROVIDERS[i].id == id) return PROVIDERS[i];
	return null;
}

function default_provider() {
	return DEFAULT_ID;
}

// provider_ids() → список валидных id (для enum в ubus-реестре — граница доверия).
function provider_ids() {
	let out = [];
	for (let i = 0; i < length(PROVIDERS); i++) push(out, PROVIDERS[i].id);
	return out;
}

// resolvers_for(id) → список резолверов для doh.build_doh_plan (opts.resolvers), ПО ПОРЯДКУ:
// [0] основной (через туннель), [1] резервный (через WAN). Порядок значим — в нём же они уезжают
// в dnsmasq, а strict-order заставляет его спрашивать сверху вниз.
// Неизвестный/пустой id → дефолт (fail-safe: лучше рабочий DNS, чем пустой). Имена секций
// фиксированы → смена провайдера переписывает те же секции.
function resolvers_for(id) {
	let p = find(id) ?? find(DEFAULT_ID);
	return [
		{ name: SECTION,     url: p.url, port: PORT,     bootstrap: p.bootstrap,
		  user: MAIN_USER, group: "nogroup" },
		// polling: резервный экземпляр раз в N секунд сам перепроверяет адрес резолвера, и этот
		// служебный запрос уходит по его пути — то есть мимо туннеля, ВИДИМО для провайдера, даже
		// когда резервным никто не пользуется. Дефолт пакета (120с) — 720 сигналов в сутки ни за
		// что; час хватает с запасом (адрес всё равно перечитывается при каждом старте демона).
		{ name: SECTION_WAN, url: p.url, port: PORT_WAN, bootstrap: p.bootstrap,
		  user: WAN_USER,  group: WAN_USER, via_wan: true, polling: 3600 },
	];
}

// wan_user() → системный пользователь резервного экземпляра. ЕДИНСТВЕННЫЙ источник: по нему
// steps/firewall строит `ip rule uidrange` (резолвя имя в uid), поэтому имя не должно дрейфовать.
function wan_user() {
	return WAN_USER;
}

// describe(id) → запись каталога { id, name, description, category } или null. Для status.
function describe(id) {
	let p = find(id);
	return p ? { id: p.id, name: p.name, description: p.description, category: p.category } : null;
}

// catalog_for_ui() → [{ id, name, description, category }] для дропдауна веб-мастера (status отдаёт).
function catalog_for_ui() {
	let out = [];
	for (let i = 0; i < length(PROVIDERS); i++)
		push(out, describe(PROVIDERS[i].id));
	return out;
}

export { default_provider, provider_ids, resolvers_for, wan_user, describe, catalog_for_ui };
