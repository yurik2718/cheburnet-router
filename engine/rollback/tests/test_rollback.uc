// test_rollback.uc — юнит-тесты реестра чистых конфигов. Без роутера.
//   ucode -R engine/rollback/tests/test_rollback.uc

import { test, eq, ok, deep_eq, summary } from "../../lib/assert.uc";
import { protected_configs, is_clean_config } from "../rollback.uc";

test("is_clean_config: наши uci-конфиги чистые, прочее — нет", () => {
	ok(is_clean_config("network"));
	ok(is_clean_config("dhcp"));
	ok(is_clean_config("firewall"));
	ok(is_clean_config("https-dns-proxy"));
	ok(is_clean_config("wireless"));
	ok(is_clean_config("sing-box"));
	ok(!is_clean_config("kmod-amneziawg"));
	ok(!is_clean_config("awg0-link"));
});

test("protected_configs: полный список и копия (мутация не ломает внутренний)", () => {
	let a = protected_configs();
	deep_eq(a, [ "network", "dhcp", "firewall", "https-dns-proxy", "wireless", "sing-box" ]);
	push(a, "hacked");
	ok(index(protected_configs(), "hacked") < 0, "внутренний список не затронут");
});

exit(summary());
