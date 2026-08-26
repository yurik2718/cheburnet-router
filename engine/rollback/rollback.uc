// rollback.uc — реестр uci-конфигов, которые откатываются транзакцией (чисто). snapshot.uc — I/O.
// ИНВАРИАНТ: транзакцией накрыты ТОЛЬКО uci-конфиги; грязное (kmod/сервис/ядро) — teardown шага,
// не иллюзия отката. Подробно: [[reliability]].

// UCI-конфиги, которые трогают наши шаги и которые откатываются ЧИСТО.
const CLEAN_CONFIGS = [ "network", "dhcp", "firewall", "https-dns-proxy", "wireless", "sing-box" ];

// protected_configs() → копия списка защищаемых конфигов (копия, чтобы не мутировали внутренний).
function protected_configs() {
	let out = [];
	for (let i = 0; i < length(CLEAN_CONFIGS); i++) push(out, CLEAN_CONFIGS[i]);
	return out;
}

// is_clean_config(name) → true, если это наш uci-конфиг с чистым откатом.
function is_clean_config(name) {
	return index(CLEAN_CONFIGS, name) >= 0;
}

export { protected_configs, is_clean_config };
