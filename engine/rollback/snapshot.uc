// snapshot.uc — снимок/восстановление UCI-конфигов (импурно, router-side; политику «что чистое»
// даёт rollback.uc, под юнит-тестами).
//
//   ucode -R snapshot.uc save     [dir]   # сохранить /etc/config/<c> защищаемых конфигов
//   ucode -R snapshot.uc restore  [dir]   # вернуть их из снимка + reload сервисов
//   ucode -R snapshot.uc commit   [dir]   # успех: выбросить снимок

import { readfile, writefile, mkdir, unlink, rmdir } from "fs";
import { sh } from "../lib/proc.uc";
import { protected_configs } from "./rollback.uc";

// Пути через env-override (host-тесты гоняют snapshot в sandbox — тот же приём, что
// ETC_CHEBURNET в run.uc/rpcd-cheburnet). Без env — боевые значения.
const CONFIG_DIR = getenv("UCI_CONFIG_DIR") ?? "/etc/config";

let action = (length(ARGV) > 0) ? ARGV[0] : "";
let dir = (length(ARGV) > 1) ? ARGV[1] : (getenv("SNAPSHOT_DIR") ?? "/tmp/cheburnet-rollback");
let configs = protected_configs();

if (action == "save") {
	mkdir(dir, 0700); // существует — вернёт ошибку, игнорируем
	let saved = [];
	for (let i = 0; i < length(configs); i++) {
		let c = configs[i];
		let text = readfile(CONFIG_DIR + "/" + c);
		if (text != null) {
			writefile(dir + "/" + c, text);
			push(saved, c);
		}
	}
	printf("snapshot: сохранено в %s — %s\n", dir, join(", ", saved));
} else if (action == "restore") {
	let restored = [];
	for (let i = 0; i < length(configs); i++) {
		let c = configs[i];
		let text = readfile(dir + "/" + c);
		if (text != null) {
			writefile(CONFIG_DIR + "/" + c, text);
			push(restored, c);
		}
	}
	// Перечитать конфиги сервисами (uci читает файлы заново).
	sh("/etc/init.d/network reload >/dev/null 2>&1");
	sh("/etc/init.d/firewall reload >/dev/null 2>&1");
	sh("/etc/init.d/dnsmasq reload >/dev/null 2>&1 || /etc/init.d/dnsmasq restart >/dev/null 2>&1");
	sh("/etc/init.d/https-dns-proxy restart >/dev/null 2>&1");
	printf("snapshot: восстановлено из %s — %s\n", dir, join(", ", restored));
} else if (action == "commit") {
	for (let i = 0; i < length(configs); i++)
		unlink(dir + "/" + configs[i]); // нет файла — вернёт ошибку, игнорируем
	rmdir(dir);
	printf("snapshot: снимок %s выброшен (commit)\n", dir);
} else {
	die("snapshot: действие save|restore|commit обязательно (ucode -R snapshot.uc save [dir])");
}
