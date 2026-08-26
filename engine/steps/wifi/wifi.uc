// wifi.uc — Wi-Fi-шаг: разбор желаемого состояния радио и идемпотентный UCI-план.
//
// ЧИСТОЕ ЯДРО: validate_wifi (граница доверия — вход пользователя) + build_wifi_plan (→ uci ops).
// Имена секций wifi-iface не хардкодим (различаются по board.json) — их перечисляет apply.uc.
// Выбор шифрования зависит от установленного wpad — тоже решается в apply.uc, приходит опцией.
// Применение uci и QEMU-проверка — apply.uc.

const SSID_MIN = 1, SSID_MAX = 32;  // IEEE 802.11 SSID: 1..32 байта
const KEY_MIN = 8,  KEY_MAX = 63;   // WPA-PSK passphrase: 8..63 символа

// q(s) — значение в одинарных кавычках для `uci batch`: ' → '\'' (как в shell). SSID и пароль —
// свободный ввод пользователя; без экранирования кавычка внутри значения разорвала бы строку batch.
function q(s) {
	return "'" + replace(s ?? "", "'", "'\\''") + "'";
}

// validate_wifi(ssid, key) → { ok, errors }. Граница доверия: длины в пределах стандарта.
function validate_wifi(ssid, key) {
	let errors = [];
	if (type(ssid) != "string" || length(ssid) < SSID_MIN || length(ssid) > SSID_MAX)
		push(errors, sprintf("SSID: %d..%d символов", SSID_MIN, SSID_MAX));
	if (type(key) != "string" || length(key) < KEY_MIN || length(key) > KEY_MAX)
		push(errors, sprintf("пароль Wi-Fi: %d..%d символов", KEY_MIN, KEY_MAX));
	return { ok: length(errors) == 0, errors: errors };
}

// build_wifi_plan(ifaces, opts) → { ok, errors, teardown, setup, applied }. ifaces — секции wifi-iface
// (пусто → no-op); opts — { ssid, key, encryption? (sae-mixed), pmf? }.
// ШРАМ (v1): PMF (ieee80211w) на чистом WPA2 рвёт старых клиентов — в не-SAE режиме его УДАЛЯЕМ.
function build_wifi_plan(ifaces, opts) {
	let o = opts ?? {};
	let enc = o.encryption ?? "sae-mixed";
	let sae = (substr(enc, 0, 3) == "sae");
	let pmf = sae ? (o.pmf ?? "1") : null;

	let v = validate_wifi(o.ssid, o.key);
	if (!v.ok)
		return { ok: false, errors: v.errors, teardown: [], setup: [], applied: false };

	if (!ifaces || length(ifaces) == 0)
		return { ok: true, errors: [], teardown: [], setup: [], applied: false }; // нет радио → no-op

	let teardown = [], setup = [];
	for (let i = 0; i < length(ifaces); i++) {
		let s = ifaces[i];
		push(setup, sprintf("set wireless.%s.ssid=%s", s, q(o.ssid)));
		push(setup, sprintf("set wireless.%s.encryption='%s'", s, enc));
		push(setup, sprintf("set wireless.%s.key=%s", s, q(o.key)));
		if (pmf)
			push(setup, sprintf("set wireless.%s.ieee80211w='%s'", s, pmf));
		else
			push(teardown, sprintf("delete wireless.%s.ieee80211w", s));
		push(setup, sprintf("set wireless.%s.disabled='0'", s));
	}
	return { ok: true, errors: [], teardown: teardown, setup: setup, applied: true };
}

export { validate_wifi, build_wifi_plan };
