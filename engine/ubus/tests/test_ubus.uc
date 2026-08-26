// test_ubus.uc — юнит-тесты чистого ядра RPC-фасада (валидация/роутинг/ACL), без шины.
//
//   ucode -R engine/ubus/tests/test_ubus.uc   (или make test-engine)

import { test, eq, ok, deep_eq, summary } from "../../lib/assert.uc";
import { readfile } from "fs";
import {
	list_descriptor, validate_request, requires_token,
	acl_split, build_acl, make_error
} from "../ubus.uc";

// --- список методов / дескриптор ---

test("list_descriptor: все методы реестра присутствуют с сигнатурами", () => {
	let d = list_descriptor();
	ok(exists(d, "preflight"), "preflight в дескрипторе");
	ok(exists(d, "install"), "install в дескрипторе");
	ok(exists(d, "set_mode"), "set_mode в дескрипторе");
	// install объявляет свои аргументы; типы — образцы (string→"", array→[], object→{})
	deep_eq(d.install, { protocol: "", awg_conf: "", reality_conf: "", hysteria2_conf: "", root_password: "", ssid: "", wifi_key: "", dns_provider: "", domains: [], routing_opts: {}, accept_risk: false, token: "" }, "сигнатура install");
	deep_eq(d.set_mode, { mode: "" }, "сигнатура set_mode");
	deep_eq(d.preflight, {}, "preflight без аргументов");
});

// --- валидация: граница доверия ---

test("validate: неизвестный метод → ошибка", () => {
	let r = validate_request("nope", {});
	eq(r.ok, false, "ok=false");
	eq(r.error, "unknown method", "текст ошибки");
});

test("validate: метод без аргументов проходит при любом мусоре в args", () => {
	eq(validate_request("status", null).ok, true, "null args ок");
	eq(validate_request("status", { junk: 1 }).ok, true, "лишний ключ игнор");
	deep_eq(validate_request("status", { junk: 1 }).value, {}, "value пустой — лишнее отброшено");
});

test("validate: отсутствует обязательное поле → ошибка с именем", () => {
	let r = validate_request("install", { token: "t" }); // нет root_password
	eq(r.ok, false, "ok=false");
	eq(r.error, "root_password required", "сообщение");
});

test("validate: пустая строка в обязательном строковом поле = отсутствует", () => {
	let r = validate_request("install", { root_password: "", token: "t" });
	eq(r.ok, false, "пустой root_password не проходит");
	eq(r.error, "root_password required", "сообщение");
});

test("validate: protocol enum + туннель-конфиги опциональны (шаг валидирует вход)", () => {
	// awg_conf/reality_conf необязательны на границе ubus — активный туннель-шаг падает fail-safe.
	eq(validate_request("install", { root_password: "s3cretpass", token: "t" }).ok, true,
		"без awg_conf/reality_conf — ubus пропускает (шаг провалится сам)");
	eq(validate_request("install",
		{ root_password: "s3cretpass", token: "t", protocol: "reality", reality_conf: "vless://x" }).ok,
		true, "reality + reality_conf — ок");
	eq(validate_request("install",
		{ root_password: "s3cretpass", token: "t", protocol: "awg", awg_conf: "[Interface]\n" }).ok,
		true, "awg + awg_conf — ок");
	let bad = validate_request("install", { root_password: "s3cretpass", token: "t", protocol: "wireguard" });
	eq(bad.ok, false, "неизвестный протокол отвергнут");
	ok(index(bad.error, "protocol must be one of") >= 0, "сообщение enum protocol");
});

test("validate: неверный тип → ошибка must be <type>", () => {
	let r = validate_request("install", { awg_conf: "x", root_password: "longenough", domains: "notarray", token: "t" });
	eq(r.ok, false, "ok=false");
	eq(r.error, "domains must be array", "тип domains");
	let r2 = validate_request("install", { awg_conf: "x", root_password: "longenough", routing_opts: [1], token: "t" });
	eq(r2.error, "routing_opts must be object", "тип routing_opts");
});

test("validate: root_password — обязателен и не короче 8 символов", () => {
	let miss = validate_request("install", { awg_conf: "c", token: "t" });
	eq(miss.error, "root_password required", "без пароля → required");
	let short = validate_request("install", { awg_conf: "c", root_password: "short7!", token: "t" });
	eq(short.ok, false, "7 символов не проходят");
	eq(short.error, "root_password must be at least 8 chars", "сообщение minlen");
	eq(validate_request("install", { awg_conf: "c", root_password: "12345678", token: "t" }).ok, true, "ровно 8 — ок");
});

test("validate: Wi-Fi необязателен, но при наличии — в границах длины", () => {
	eq(validate_request("install", { awg_conf: "c", root_password: "s3cretpass", token: "t" }).ok,
		true, "без ssid/wifi_key — ок (wired-only)");
	let short_key = validate_request("install",
		{ awg_conf: "c", root_password: "s3cretpass", token: "t", ssid: "Home", wifi_key: "short7!" });
	eq(short_key.error, "wifi_key must be at least 8 chars", "короткий ключ Wi-Fi");
	let long_ssid = "X"; for (let i = 0; i < 6; i++) long_ssid += long_ssid; // 2^6 = 64 символа
	let big = validate_request("install",
		{ awg_conf: "c", root_password: "s3cretpass", token: "t", ssid: long_ssid });
	eq(big.error, "ssid must be at most 32 chars", "слишком длинный SSID");
	eq(validate_request("install",
		{ awg_conf: "c", root_password: "s3cretpass", token: "t", ssid: "Home", wifi_key: "password123" }).ok,
		true, "валидный Wi-Fi");
});

test("validate: install со всеми полями → ok, value содержит только объявленные", () => {
	let r = validate_request("install", {
		awg_conf: "[Interface]\n", root_password: "s3cretpass", domains: [ "example.com" ],
		routing_opts: { mode: "home" }, token: "abc", junk: "drop-me",
	});
	eq(r.ok, true, "ok=true");
	deep_eq(r.value, {
		awg_conf: "[Interface]\n", root_password: "s3cretpass", domains: [ "example.com" ],
		routing_opts: { mode: "home" }, token: "abc",
	}, "value без junk");
});

// accept_risk — согласие владельца на пропуск soft-проверок железа. Граница обязана быть строгой
// по ТИПУ: строка "false"/"0" не должна проезжать как согласие (импурный слой сверяет === true,
// но лучше отбить мусор здесь — с внятной ошибкой).
test("validate: accept_risk — bool, необязателен", () => {
	let r = validate_request("install", { awg_conf: "c", root_password: "s3cretpass",
		token: "t", accept_risk: true });
	eq(r.ok, true, "true проходит");
	eq(r.value.accept_risk, true, "значение доехало до импурного слоя");
	eq(validate_request("install", { awg_conf: "c", root_password: "s3cretpass",
		token: "t", accept_risk: false }).value.accept_risk, false, "false тоже валиден");
	let bad = validate_request("install", { awg_conf: "c", root_password: "s3cretpass",
		token: "t", accept_risk: "yes" });
	eq(bad.ok, false, "строка отвергнута");
	eq(bad.error, "accept_risk must be bool");
});

test("validate: необязательные поля можно опускать", () => {
	let r = validate_request("install", { awg_conf: "c", root_password: "s3cretpass", token: "t" });
	eq(r.ok, true, "ok без domains/routing_opts");
	deep_eq(r.value, { awg_conf: "c", root_password: "s3cretpass", token: "t" }, "только переданное");
});

test("validate: enum mode — только home|travel", () => {
	eq(validate_request("set_mode", { mode: "home" }).ok, true, "home ок");
	eq(validate_request("set_mode", { mode: "travel" }).ok, true, "travel ок");
	let r = validate_request("set_mode", { mode: "vpn" });
	eq(r.ok, false, "чужое значение отвергнуто");
	eq(r.error, "mode must be one of: home, travel", "сообщение enum");
});

test("validate: set_domains — массив обязателен; get_domains — без аргументов", () => {
	eq(validate_request("set_domains", {}).ok, false, "без domains → ошибка");
	eq(validate_request("set_domains", { domains: "ru" }).ok, false, "строка вместо массива → ошибка");
	eq(validate_request("set_domains", { domains: [] }).ok, true, "пустой список — законно (всё в туннель)");
	eq(validate_request("get_domains", {}).ok, true);
	let s = acl_split();
	ok(index(s.admin.write, "set_domains") >= 0 && index(s.unauth.write, "set_domains") < 0, "запись — только admin");
	ok(index(s.admin.read, "get_domains") >= 0 && index(s.unauth.read, "get_domains") < 0,
		"чтение тоже admin: список говорит о привычках дома");
});

test("validate: update_list — без аргументов; источник списка — решение проекта, не настройка", () => {
	let r = validate_request("update_list", { url: "https://e/x" });
	eq(r.ok, true);
	ok(!exists(r.value, "url"), "чужой url отброшен на границе доверия");
});

// --- валидация: admin-методы Фазы B ---

test("validate: service_restart — только сервисы (без podkop/adblock)", () => {
	eq(validate_request("service_restart", { service: "vpn" }).ok, true, "vpn ок");
	eq(validate_request("service_restart", { service: "doh" }).ok, true, "doh ок");
	eq(validate_request("service_restart", { service: "podkop" }).ok, false, "podkop вырезан в v2");
	eq(validate_request("service_restart", { service: "adblock" }).ok, false, "adblock убран (фильтрация через DNS)");
	eq(validate_request("service_restart", {}).ok, false, "service обязателен");
});

test("validate: install_full_tier — admin, без аргументов и токена (opt-in sing-box)", () => {
	eq(validate_request("install_full_tier", {}).ok, true, "без аргументов — ок");
	eq(validate_request("install_full_tier", { junk: 1 }).ok, true, "лишнее отбрасывается");
	eq(requires_token("install_full_tier"), false, "admin-метод, не pre-install — токен не нужен");
});

test("validate: switch_to_reality — admin, reality_conf обязателен, без токена", () => {
	eq(validate_request("switch_to_reality", { reality_conf: "vless://…" }).ok, true);
	eq(validate_request("switch_to_reality", {}).ok, false, "reality_conf обязателен");
	eq(requires_token("switch_to_reality"), false, "admin-метод — токен не нужен");
});

test("validate: switch_to_hysteria2 — admin, hysteria2_conf обязателен, без токена", () => {
	eq(validate_request("switch_to_hysteria2", { hysteria2_conf: "hysteria2://pw@h:443" }).ok, true);
	eq(validate_request("switch_to_hysteria2", {}).ok, false, "hysteria2_conf обязателен");
	// Имя аргумента = имя формата: reality_conf в hysteria2-метод не подсунуть (и наоборот).
	eq(validate_request("switch_to_hysteria2", { reality_conf: "vless://x" }).ok, false,
		"чужое поле не подменяет обязательное");
	eq(requires_token("switch_to_hysteria2"), false, "admin-метод — токен не нужен");
});

test("validate: switch_to_awg — admin, awg_conf обязателен, без токена (обратный свитч)", () => {
	eq(validate_request("switch_to_awg", { awg_conf: "[Interface]\n" }).ok, true);
	eq(validate_request("switch_to_awg", {}).ok, false, "awg_conf обязателен");
	eq(requires_token("switch_to_awg"), false, "admin-метод — токен не нужен");
});

test("validate: set_dns_provider — enum из каталога; dns_provider в install опционален", () => {
	eq(validate_request("set_dns_provider", { provider: "adguard" }).ok, true, "каталожный id ок");
	eq(validate_request("set_dns_provider", { provider: "adguard-family" }).ok, true, "семейный ок");
	eq(validate_request("set_dns_provider", { provider: "nonsense" }).ok, false, "чужой id отвергнут");
	eq(validate_request("set_dns_provider", {}).ok, false, "provider обязателен");
	// в install dns_provider опционален (дефолт подставит handler), но при наличии — из enum
	eq(validate_request("install",
		{ awg_conf: "c", root_password: "s3cretpass", token: "t", dns_provider: "quad9" }).ok,
		true, "валидный провайдер в install");
	eq(validate_request("install",
		{ awg_conf: "c", root_password: "s3cretpass", token: "t", dns_provider: "bad" }).ok,
		false, "невалидный провайдер в install");
});

test("validate: replace_awg_conf/replace_reality_conf и factory_reset — обязательные строки", () => {
	eq(validate_request("replace_awg_conf", { awg_conf: "[Interface]\n" }).ok, true);
	eq(validate_request("replace_awg_conf", {}).ok, false, "awg_conf обязателен");
	eq(validate_request("replace_reality_conf", { reality_conf: "vless://…" }).ok, true);
	eq(validate_request("replace_reality_conf", {}).ok, false, "reality_conf обязателен");
	eq(validate_request("replace_hysteria2_conf", { hysteria2_conf: "hy2://pw@h:443" }).ok, true);
	eq(validate_request("replace_hysteria2_conf", {}).ok, false, "hysteria2_conf обязателен");
	eq(validate_request("factory_reset", { confirm: "RESET" }).ok, true);
	eq(validate_request("factory_reset", {}).ok, false, "confirm обязателен");
});

// --- токен ---

test("requires_token: pre-install мутации install, install_cancel, apply_lan_ip", () => {
	eq(requires_token("install"), true, "install требует токен");
	eq(requires_token("install_cancel"), true, "отмена — тем же токеном");
	eq(requires_token("apply_lan_ip"), true, "смена LAN-IP — деструктив, токен");
	eq(requires_token("set_mode"), false, "set_mode — admin, без токена");
	eq(requires_token("status"), false, "status — read, без токена");
	eq(requires_token("nope"), false, "неизвестный — false");
});

test("validate: apply_lan_ip — ip и token обязательны", () => {
	eq(validate_request("apply_lan_ip", { ip: "192.168.2.1", token: "t" }).ok, true);
	eq(validate_request("apply_lan_ip", { token: "t" }).error, "ip required", "без ip");
	eq(validate_request("check_lan_conflict", {}).ok, true, "детект — без аргументов");
});

// --- ACL выводится из реестра ---

// Аварийный режим — мутация уровня владельца: анониму из LAN нельзя снимать защиту чужого
// роутера, а токен тут не при чём (он про этап установки, а не про жизнь после неё).
test("validate: pause_protection/resume_protection — admin, без аргументов и токена", () => {
	for (let m in [ "pause_protection", "resume_protection" ]) {
		let r = validate_request(m, {});
		ok(r.ok, m + " не требует аргументов");
		ok(!requires_token(m), m + " не требует install-токена");
	}
	let acl = acl_split();
	ok(index(acl.admin.write, "pause_protection") >= 0, "pause_protection — только админу");
	ok(index(acl.admin.write, "resume_protection") >= 0, "resume_protection — только админу");
	ok(index(acl.unauth.write, "pause_protection") < 0, "и точно не аноним из LAN");
});

test("acl_split: тиры выведены из реестра", () => {
	let s = acl_split();
	deep_eq(s.unauth.read, [ "preflight", "status", "check_lan_conflict", "install_progress" ], "anon read");
	deep_eq(s.unauth.write, [ "apply_lan_ip", "install", "install_cancel" ], "anon write (токен-гейт)");
	// admin видит все методы
	ok(index(s.admin.write, "set_mode") >= 0, "set_mode в admin write");
	ok(index(s.admin.write, "update_list") >= 0, "update_list в admin write");
	ok(index(s.admin.write, "install") >= 0, "install тоже доступен admin");
	ok(index(s.admin.write, "service_restart") >= 0, "service_restart в admin write");
	ok(index(s.admin.write, "factory_reset") >= 0, "factory_reset в admin write");
	deep_eq(s.admin.read, [ "preflight", "status", "check_lan_conflict", "install_progress", "get_domains", "diagnostics" ],
		"admin read = все read");
	// install_token — write, а не read: метод ВЫПУСКАЕТ токен, если его нет. Классифицировать
	// создание состояния как чтение было бы нечестно по отношению к ACL.
	ok(index(s.admin.write, "install_token") >= 0, "install_token в admin write (он создаёт состояние)");
	ok(index(s.admin.read, "install_token") < 0, "install_token НЕ числится чтением");
	// Диагностика — ТОЛЬКО admin: даже с вырезанными секретами она раскрывает топологию сети и
	// содержимое логов, поэтому соседу по LAN недоступна (в anon-тир попасть не должна).
	ok(index(s.unauth.read, "diagnostics") < 0, "diagnostics недоступна без входа");
	// Выдача install-токена — тем более: токен и есть признак «это владелец» на пути установки.
	// Попади метод в anon-тир, любой в LAN выписал бы себе право пройти мастер на чужом роутере.
	ok(index(s.unauth.read, "install_token") < 0, "install_token недоступен без входа (read)");
	ok(index(s.unauth.write, "install_token") < 0, "install_token недоступен без входа (write)");
});

test("rpcd-acl.json синхронен с реестром (build_acl)", () => {
	// Коммитнутый файл должен совпадать с генерацией из реестра — иначе права разъехались.
	// Меняешь REGISTRY → перегенери: ucode -R engine/ubus/acl.uc > engine/ubus/rpcd-acl.json
	let path = sourcepath(0, true) + "/../rpcd-acl.json";
	let raw = readfile(path);
	ok(raw != null, "rpcd-acl.json читается");
	deep_eq(json(raw), build_acl(), "файл == build_acl()");
});

// --- ответы ---

test("make_error: базовая и с extra", () => {
	deep_eq(make_error("oops"), { error: "oops" }, "только error");
	deep_eq(make_error("busy", { pid: 7 }), { error: "busy", pid: 7 }, "error + extra");
});

exit(summary());
