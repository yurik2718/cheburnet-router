// ubus.uc — ЧИСТОЕ ядро RPC-фасада: реестр методов, валидация аргументов, `list`/ACL (тесты: tests/).
// Импурная сторона — rpcd-cheburnet (QEMU).
// ИНВАРИАНТ: вход из ubus RPC — граница доверия, валидируем здесь; внутренним границам доверяем.
// REGISTRY — источник правды для дескриптора `list` и rpcd-acl.json (тест сверяет файл с ним).

// Валидные id DNS-провайдеров — из каталога (единственный источник, enum не дрейфует с providers.uc).
import { provider_ids } from "../steps/doh/providers.uc";
const PROVIDER_IDS = provider_ids();

// Валидные туннельные протоколы — из install.uc (enum не дрейфует с моделью протоколов, ADR 0004).
import { protocol_ids } from "../install/install.uc";
const PROTOCOL_IDS = protocol_ids();

// Реестр методов RPC. Один метод = одна запись (порядок стабилен → стабильны list/ACL).
//   args  — { name, type, required?, enum?, minlen?, maxlen? }; type ∈ string|array|object|bool.
//   access— read | write (ubus-разделение прав в ACL).
//   auth  — anon = доступен из LAN до установки (мутации гейтятся токеном); admin = только
//           авторизованной сессии.
//   token — требует install-токен (значение сверяет импурный слой; здесь лишь обязательность поля).
const REGISTRY = [
	{ name: "preflight", access: "read",  auth: "anon",  token: false, args: [] },
	{ name: "status",    access: "read",  auth: "anon",  token: false, args: [] },
	// apply_lan_ip — anon+токен (как install): пароля root ещё нет, install-токен — единственный
	// идентификатор владельца. Деструктивно (рвёт LAN-соединения) → строгая валидация ip импурно.
	{ name: "check_lan_conflict", access: "read", auth: "anon", token: false, args: [] },
	{ name: "apply_lan_ip", access: "write", auth: "anon", token: true, args: [
		{ name: "ip",    type: "string", required: true },
		{ name: "token", type: "string", required: true },
	] },
	{ name: "install_progress", access: "read", auth: "anon", token: false, args: [] },
	{ name: "install",   access: "write", auth: "anon",  token: true, args: [
		// protocol: awg (Light, дефолт) | reality | hysteria2 (Full, ADR 0004). Конфиг каждого —
		// в своём поле, ВСЕ необязательны здесь: активный туннель-шаг валидирует вход сам,
		// fail-safe при отсутствии.
		{ name: "protocol",       type: "string", enum: PROTOCOL_IDS },
		{ name: "awg_conf",       type: "string" }, // AmneziaWG .conf (protocol=awg)
		{ name: "reality_conf",   type: "string" }, // vless://… или JSON sing-box, секрет → payload 600
		{ name: "hysteria2_conf", type: "string" }, // hysteria2://… или JSON sing-box, секрет → payload 600
		{ name: "root_password", type: "string", required: true, minlen: 8 }, // секрет → payload 600
		// Wi-Fi необязателен: wired-only роутеры ставятся без него (UI спрашивает поля только
		// при status.wireless_present; шаг wifi — no-op без них).
		{ name: "ssid",          type: "string", minlen: 1, maxlen: 32 },
		{ name: "wifi_key",      type: "string", minlen: 8, maxlen: 63 }, // секрет → payload 600
		{ name: "dns_provider",  type: "string", enum: PROVIDER_IDS }, // фильтрация = выбор резолвера
		{ name: "domains",       type: "array" },
		{ name: "routing_opts",  type: "object" },
		// accept_risk: осознанный пропуск SOFT-провалов preflight (флеш/RAM). HARD не пропускает
		// никто (preflight.uc).
		{ name: "accept_risk",   type: "bool" },
		{ name: "token",         type: "string", required: true },
	] },
	{ name: "install_cancel", access: "write", auth: "anon", token: true, args: [
		{ name: "token", type: "string", required: true },
	] },
	{ name: "set_mode",  access: "write", auth: "admin", token: false, args: [
		{ name: "mode", type: "string", required: true, enum: [ "home", "travel" ] },
	] },
	// Аварийный режим: выключить защиту и пустить интернет напрямую — и вернуть обратно.
	// Без него у неспециалиста при мёртвом туннеле оставались ровно два выхода: SSH или
	// factory_reset (снести настройку целиком). Аргументов нет: обе операции обратимы одна
	// другой, а решение фиксируется флагом paused в install.json и видно в status.
	{ name: "pause_protection",  access: "write", auth: "admin", token: false, args: [] },
	{ name: "resume_protection", access: "write", auth: "admin", token: false, args: [] },
	// Источник community-списка — решение проекта (list/list.uc DEFAULT_SOURCE), не настройка.
	{ name: "update_list", access: "write", auth: "admin", token: false, args: [] },
	{ name: "service_restart", access: "write", auth: "admin", token: false, args: [
		// сервисы data-plane (без podkop/sing-box; adblock убран — фильтрация через DNS)
		{ name: "service", type: "string", required: true, enum: [ "vpn", "dns", "doh" ] },
	] },
	// Выбор DNS-провайдера = выбор уровня фильтрации (реклама/семейный/без), см. providers.uc.
	{ name: "set_dns_provider", access: "write", auth: "admin", token: false, args: [
		{ name: "provider", type: "string", required: true, enum: PROVIDER_IDS },
	] },
	// Full-тир — opt-in: бинарь sing-box догружается по кнопке, не при bootstrap.
	{ name: "install_full_tier", access: "write", auth: "admin", token: false, args: [] },
	// In-place смена активного туннеля: приносим только конфиг нового, домены/DNS/режим — из
	// сохранённой конфигурации. Три метода вместо switch_tunnel(protocol, conf) — имя аргумента
	// = имя формата (vless:// ≠ .conf ≠ hysteria2://); импурный путь под ними один общий.
	// Требует уже установленного бинаря sing-box.
	{ name: "switch_to_reality", access: "write", auth: "admin", token: false, args: [
		{ name: "reality_conf", type: "string", required: true },
	] },
	{ name: "switch_to_hysteria2", access: "write", auth: "admin", token: false, args: [
		{ name: "hysteria2_conf", type: "string", required: true },
	] },
	// Обратная смена на AmneziaWG (зеркало переходов выше); sing-box остаётся установленным.
	{ name: "switch_to_awg", access: "write", auth: "admin", token: false, args: [
		{ name: "awg_conf", type: "string", required: true },
	] },
	{ name: "replace_awg_conf", access: "write", auth: "admin", token: false, args: [
		{ name: "awg_conf", type: "string", required: true },
	] },
	// Смена сервера без переустановки (Full): снапшот → применить → probe → commit/restore
	// (общий replace_singbox.uc).
	{ name: "replace_reality_conf", access: "write", auth: "admin", token: false, args: [
		{ name: "reality_conf", type: "string", required: true },
	] },
	{ name: "replace_hysteria2_conf", access: "write", auth: "admin", token: false, args: [
		{ name: "hysteria2_conf", type: "string", required: true },
	] },
	// Диагностика: логи+состояние+версии с ВЫРЕЗАННЫМИ секретами (diagnostics.uc + lib/redact.uc).
	// auth=admin: даже вычищенный пакет раскрывает топологию сети — соседу по LAN не отдаём.
	{ name: "diagnostics", access: "read", auth: "admin", token: false, args: [] },
	// Install-токен для повторной настройки (одноразовый, снимается успешной установкой) —
	// подробно: [[troubleshooting]]. access=write: метод СОЗДАЁТ состояние. auth=admin
	// обязателен — иначе любой в LAN выписал бы себе право пройти мастер на чужом роутере.
	{ name: "install_token", access: "write", auth: "admin", token: false, args: [] },
	{ name: "factory_reset", access: "write", auth: "admin", token: false, args: [
		// защитное слово; значение ("RESET") сверяет импурный слой — здесь лишь обязательность
		{ name: "confirm", type: "string", required: true },
	] },
];

// find_spec(method) → запись реестра или null.
function find_spec(method) {
	for (let i = 0; i < length(REGISTRY); i++)
		if (REGISTRY[i].name == method)
			return REGISTRY[i];
	return null;
}

// Плейсхолдер-значение для типа в дескрипторе `list` (rpcd берёт ТИП образца, не значение).
function type_placeholder(t) {
	if (t == "array")  return [];
	if (t == "object") return {};
	if (t == "bool")   return false;
	return ""; // string
}

// list_descriptor() → объект протокола rpcd `list`: { method: { arg: <образец-типа> } }.
// Скрипт-обработчик печатает его на действие `list`, чтобы rpcd знал сигнатуры методов.
function list_descriptor() {
	let out = {};
	for (let i = 0; i < length(REGISTRY); i++) {
		let m = REGISTRY[i], sig = {};
		for (let j = 0; j < length(m.args); j++)
			sig[m.args[j].name] = type_placeholder(m.args[j].type);
		out[m.name] = sig;
	}
	return out;
}

// type_ok(val, t) — соответствует ли значение объявленному типу аргумента.
function type_ok(val, t) {
	let vt = type(val);
	if (t == "string") return vt == "string";
	if (t == "array")  return vt == "array";
	if (t == "object") return vt == "object";
	if (t == "bool")   return vt == "bool";
	return false;
}

// validate_request(method, args) → { ok, error?, value? }.
// Граница доверия: метод существует? обязательные поля на месте? типы? enum? Лишние ключи
// отбрасываем (берём только объявленные). Не падаем на мусоре — возвращаем структурную ошибку
// (её импурный слой отдаёт клиенту как {"error":...}). Значение ТОКЕНА здесь не проверяем —
// это сравнение с файлом (импурно); здесь лишь требуем, что поле присутствует и строковое.
function validate_request(method, args) {
	let spec = find_spec(method);
	if (!spec)
		return { ok: false, error: "unknown method" };

	let a = (type(args) == "object") ? args : {};
	let value = {};
	for (let i = 0; i < length(spec.args); i++) {
		let p = spec.args[i];
		let v = a[p.name];

		// required: отсутствует (null) или пустая строка для строкового поля.
		let missing = (v == null) || (p.type == "string" && type(v) == "string" && length(v) == 0);
		if (p.required && missing)
			return { ok: false, error: sprintf("%s required", p.name) };

		if (v == null)
			continue; // необязательное и не передано — пропускаем

		if (!type_ok(v, p.type))
			return { ok: false, error: sprintf("%s must be %s", p.name, p.type) };

		if (p.enum && index(p.enum, v) < 0)
			return { ok: false, error: sprintf("%s must be one of: %s", p.name, join(", ", p.enum)) };

		// Границы длины строки (только для строк): синхронная отбраковка слишком коротких/длинных
		// значений (пароль, SSID) — пользователь получает ответ сразу, а не на середине установки.
		if (p.type == "string") {
			if (p.minlen != null && length(v) < p.minlen)
				return { ok: false, error: sprintf("%s must be at least %d chars", p.name, p.minlen) };
			if (p.maxlen != null && length(v) > p.maxlen)
				return { ok: false, error: sprintf("%s must be at most %d chars", p.name, p.maxlen) };
		}

		value[p.name] = v;
	}
	return { ok: true, value: value };
}

// requires_token(method) → нужен ли install-токен (импурный слой сверяет значение с файлом).
function requires_token(method) {
	let s = find_spec(method);
	return s ? (s.token === true) : false;
}

// acl_split() → { unauth:{read,write}, admin:{read,write} } — имена методов по тирам, выведенные
// из реестра. unauth = anon-методы (мутации всё равно гейтятся токеном); admin видит ВСЕ методы
// (анонимные + admin-only). Из этого собирается rpcd-acl.json (build_acl).
function acl_split() {
	let ur = [], uw = [], ar = [], aw = [];
	for (let i = 0; i < length(REGISTRY); i++) {
		let m = REGISTRY[i];
		if (m.access == "read")  push(ar, m.name); else push(aw, m.name);
		if (m.auth == "anon") {
			if (m.access == "read") push(ur, m.name); else push(uw, m.name);
		}
	}
	return {
		unauth: { read: ur, write: uw },
		admin:  { read: ar, write: aw },
	};
}

// build_acl() → полный объект rpcd-acl.json (готов к печати). Два тира:
//   unauthenticated — первичная установка из LAN (мутации защищены install-токеном);
//   cheburnet-admin — пост-установочное управление (выдаётся авторизованной сессии).
// Источник правды прав — REGISTRY (acl_split); описания статичны.
function build_acl() {
	let s = acl_split();
	return {
		unauthenticated: {
			description: "cheburnet web wizard — первичная установка (LAN-only). Мутации защищены install-токеном.",
			read:  { ubus: { cheburnet: s.unauth.read } },
			write: { ubus: { cheburnet: s.unauth.write } },
		},
		"cheburnet-admin": {
			description: "cheburnet — пост-установочное управление (выдаётся авторизованной сессии).",
			read:  { ubus: { cheburnet: s.admin.read } },
			write: { ubus: { cheburnet: s.admin.write } },
		},
	};
}

// make_error(msg, extra?) → { error: msg, ...extra }. Единообразный ответ-ошибка для RPC.
function make_error(msg, extra) {
	let o = { error: msg };
	if (extra) for (let k in extra) o[k] = extra[k];
	return o;
}

export { list_descriptor, validate_request, requires_token, acl_split, build_acl, make_error };
