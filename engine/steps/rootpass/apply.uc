// apply.uc — установка пароля root (импурно; валидация — rootpass.uc). Пароль НЕ логируем.
//   echo '{"root_password":"…"}' | ucode -R apply.uc [--dry-run]
// JSON со stdin, не сырой текст — иначе двусмысленность с завершающим \n.

import { stdin, popen } from "fs";
import { validate_password } from "./rootpass.uc";

let raw = trim(stdin.read("all") ?? "");
if (substr(raw, 0, 1) != "{")
	die("rootpass/apply: ожидаю JSON {root_password} со stdin");
let req = json(raw);
let pw = req.root_password;
let dry = (length(ARGV) > 0 && ARGV[0] == "--dry-run");

let v = validate_password(pw);
if (!v.ok) {
	for (let i = 0; i < length(v.errors); i++)
		warn("rootpass: " + v.errors[i] + "\n");
	exit(1);
}

if (dry) {
	print("rootpass: --dry-run — установил бы пароль root (значение не показываю)\n");
	exit(0);
}

// passwd читает пароль и подтверждение со stdin. stdout/stderr глушим (prompt'ы не нужны).
let w = popen("passwd root >/dev/null 2>&1", "w");
if (!w) die("rootpass/apply: не смог запустить passwd");
w.write(pw + "\n" + pw + "\n");
let code = w.close(); // popen.close() → код выхода passwd
if (code != 0) {
	warn("rootpass: passwd root завершился с ошибкой — установите пароль вручную по SSH\n");
	exit(1);
}

print("rootpass: пароль root установлен\n");
