// redact.uc — вырезание секретов из диагностики: redact(text) → { text, removed[] } (чисто; тесты: tests/).
// ИНВАРИАНТ: адрес и порт сервера НЕ вырезаем — без них диагноз невозможен, подключиться по ним нельзя.
// Квирк ucode: POSIX-ERE без \s, \d и (?:…) — `\s` внутри [...] молча исключает букву «s»; поэтому
// только [[:space:]] и захватывающие группы.

const MASK = "<удалено>";

// Правила чистки. Каждое — { label, apply }: label попадёт в removed[], если правило что-то
// изменило. Пересечения правил допустимы: лишняя маскировка безопасна, пропущенный секрет — нет.
const RULES = [
	{
		// WireGuard/AmneziaWG .conf: приватный и пресхаред-ключ.
		label: "ключи туннеля",
		apply: function(t) {
			return replace(t, /(PrivateKey|PresharedKey)([[:space:]]*=[[:space:]]*)[^[:space:]]+/g,
				(m, a, b) => a + b + MASK);
		},
	},
	{
		// Ключ WireGuard в чистом виде (32 байта base64) — ловим, даже если он попал в лог
		// без имени поля: вывод `awg show`, дампы конфига, сообщения об ошибках.
		label: "ключи туннеля",
		apply: function(t) {
			return replace(t, /[A-Za-z0-9+\/]{43}=/g, MASK);
		},
	},
	{
		// Учётная часть ссылки до «@»: пароль Hysteria2, UUID у VLESS.
		label: "пароли из ссылок",
		apply: function(t) {
			return replace(t, /([a-z0-9]+:\/\/)[^@[:space:]\/]+@/g, (m, a) => a + MASK + "@");
		},
	},
	{
		// Параметры ссылки: pbk/sid у Reality, пароль обфускации у Hysteria2.
		label: "параметры ссылок (pbk, sid, пароли обфускации)",
		apply: function(t) {
			return replace(t, /([?&](pbk|sid|obfs-password|obfs_password|password|passwd|key|auth)=)[^&[:space:]]+/g,
				(m, a) => a + MASK);
		},
	},
	{
		// JSON-конфиг sing-box: попадает в лог целыми строками при провале `sing-box check`.
		label: "пароли и ключи из конфигов",
		apply: function(t) {
			return replace(t, /("(private_key|password|passwd|psk|obfs|auth|key)"[[:space:]]*:[[:space:]]*")[^"]*"/g,
				(m, a) => a + MASK + '"');
		},
	},
	{
		// UCI: wireless.*.key, root_password, password. Регистр важен: PublicKey/PrivateKey не
		// совпадут с lowercase `key` — публичный ключ не секрет, приватный ловится правилом выше.
		label: "пароль Wi-Fi",
		apply: function(t) {
			return replace(t, /((key|wifi_key|root_password|password)[[:space:]]*=?[[:space:]]*['"])[^'"]*(['"])/g,
				(m, a, b, c) => a + MASK + c);
		},
	},
	{
		// UUID пользователя VLESS — идентификатор доступа к серверу.
		label: "UUID",
		apply: function(t) {
			return replace(t, /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/g, MASK);
		},
	},
];

// redact(text) → { text, removed }. removed — метки сработавших правил без повторов, в порядке
// правил (стабильный вывод: UI показывает один и тот же список при том же входе).
function redact(text) {
	let t = (type(text) == "string") ? text : "";
	let removed = [];
	for (let i = 0; i < length(RULES); i++) {
		let before = t;
		t = RULES[i].apply(t);
		if (t != before && index(removed, RULES[i].label) < 0)
			push(removed, RULES[i].label);
	}
	return { text: t, removed: removed };
}

export { redact, MASK };
