// diagnostics.uc — сборка диагностического пакета для поддержки (импурно, router-side): собирает
// роутер, человек скачивает файл и отправляет сам (по SSH целевой пользователь не пойдёт).
//
//   ucode -R engine/install/diagnostics.uc            # человеку в терминал
//   ucode -R engine/install/diagnostics.uc --json     # для ubus/UI: { text, removed }

import { readfile } from "fs";
import { sh } from "../lib/proc.uc";
import { redact } from "../lib/redact.uc";
import { tunnel_info } from "./install.uc";

const STATE_DIR     = getenv("STATE_DIR")     ?? "/tmp/cheburnet";
const ETC_CHEBURNET = getenv("ETC_CHEBURNET") ?? "/etc/cheburnet";
const LOG_FILE      = STATE_DIR + "/install.log";
const CFG_FILE      = ETC_CHEBURNET + "/install.json";

// Хвост важнее начала — ошибка почти всегда в конце, а читает человек в чате, не машина.
const INSTALL_LOG_TAIL_BYTES = 8000;
const SYSLOG_TAIL_LINES      = 120;

function has_flag(name) {
	for (let i = 0; i < length(ARGV); i++)
		if (ARGV[i] == name) return true;
	return false;
}

// section(title, body) — единый вид секции. Пустое тело подписываем явно: «пусто» — это факт
// (например, молчащий watchdog — норма), а не повод оставить читателя в неведении.
function section(title, body) {
	let b = trim(body ?? "");
	return sprintf("──── %s ────\n%s\n\n", title, length(b) > 0 ? b : "(пусто)");
}

let cfg = {};
let raw_cfg = readfile(CFG_FILE);
if (raw_cfg != null) {
	try { cfg = json(raw_cfg) ?? {}; } catch (e) { cfg = {}; }
}
// Инварианты собираем тем же CLI, что зовут тесты и (в будущем) watchdog — одна реализация
// на всех потребителей. Ошибка сборки не должна валить весь пакет: диагностика нужна ИМЕННО
// когда что-то сломано, поэтому берём что вышло.
let ENGINE_DIR = getenv("ENGINE_DIR") ?? (sourcepath(0, true) + "/..");
let invariants = trim(sh(sprintf(
	"ucode -R %s/invariants/gather.uc 2>/dev/null | ucode -R %s/invariants/check.uc 2>&1",
	ENGINE_DIR, ENGINE_DIR)));

let protocol = cfg.protocol ?? "awg";
let tun_if = tunnel_info(protocol).tunnel_if;

// ── железо и версии ──────────────────────────────────────────────────────────
// Одним батчем: каждый форк на слабом роутере заметен, а полей нужно много.
let env = sh(
	"echo \"date=$(date '+%Y-%m-%d %H:%M:%S %Z')\"; " +
	"echo \"uptime=$(uptime 2>/dev/null | sed 's/^ *//')\"; " +
	"echo \"model=$(ubus call system board 2>/dev/null | grep -o '\"model\": *\"[^\"]*\"' | head -1)\"; " +
	"echo \"release=$(. /etc/openwrt_release 2>/dev/null; echo $DISTRIB_RELEASE $DISTRIB_TARGET)\"; " +
	"echo \"arch=$(uname -m)\"; " +
	"echo \"kernel=$(uname -r)\"; " +
	"echo \"ram=$(awk '/MemTotal/{printf \"%d\", $2/1024}' /proc/meminfo 2>/dev/null) МБ, свободно " +
		"$(awk '/MemAvailable/{printf \"%d\", $2/1024}' /proc/meminfo 2>/dev/null) МБ\"; " +
	"echo \"flash=$( (df -k /overlay 2>/dev/null || df -k /) | awk 'NR>1{for(i=1;i<=NF;i++) " +
		"if ($i ~ /^[0-9]+$/) {n++; if (n==3) {printf \"%d\", $i/1024; exit}}}' ) МБ свободно\"; " +
	"echo \"singbox=$(sing-box version 2>/dev/null | head -1)\"; " +
	"echo \"cheburnet=$(apk list -I 2>/dev/null | grep -m1 '^cheburnet-' || echo '(пакет не найден)')\"; " +
	"true"
);

// ── состояние туннеля и сервисов ─────────────────────────────────────────────
let state = sh(
	sprintf("echo '--- интерфейс %s ---'; ip addr show dev %s 2>&1 | head -6; ", tun_if, tun_if) +
	"echo '--- AmneziaWG ---'; awg show 2>&1 | head -20; " +
	"echo '--- сервисы ---'; " +
	"for s in dnsmasq https-dns-proxy sing-box; do " +
	"  printf '%s: ' \"$s\"; /etc/init.d/$s status 2>/dev/null || echo '(нет такого сервиса)'; done; " +
	"echo '--- маршруты по умолчанию и таблицы ---'; ip -4 route show 2>&1 | head -12; " +
	"echo '--- правила policy routing ---'; ip -4 rule show 2>&1 | head -12; " +
	// Домены считаем, а не печатаем: список бывает в тысячи строк, и он говорит о том, что человек
	// открывает. В диагностике нужен размер, а не содержимое.
	"echo '--- nft-наборы (размер) ---'; " +
	"for set in direct direct6; do " +
	"  printf 'inet fw4 %s: ' \"$set\"; " +
	"  nft -j list set inet fw4 $set 2>/dev/null | grep -o '\"elem\"' | wc -l || echo '?'; done; " +
	"true"
);

let install_log = sh(sprintf("tail -c %d %s 2>/dev/null", INSTALL_LOG_TAIL_BYTES, LOG_FILE));

// Системный журнал — только строки про наш стек: в общем logread шум забивает сигнал, а читать
// это человеку.
let syslog = sh(sprintf(
	"logread 2>/dev/null | grep -E 'cheburnet|sing-box|dnsmasq|https-dns-proxy|netifd|amneziawg|awg|firewall' " +
	"| tail -%d", SYSLOG_TAIL_LINES));

let cfg_lines = [
	sprintf("протокол: %s", protocol),
	sprintf("режим: %s", cfg.mode ?? "(нет)"),
	sprintf("доменов прямого доступа (свои): %d", length(cfg.user_domains ?? [])),
	sprintf("DNS-провайдер: %s", cfg.dns_provider ?? "(нет)"),
	sprintf("установлено с пропуском проверок железа: %s",
		length(cfg.forced ?? []) > 0 ? join(", ", cfg.forced) : "нет"),
];

let body =
	// Чек-лист инвариантов ПЕРВЫМ: разбор жалобы начинается с «что не на месте», а не с чтения
	// сырых дампов. Провал строкой прямо говорит, чем чинится (engine/invariants).
	section("что на месте (инварианты data-plane)", invariants) +
	section("роутер и версии", env) +
	section("конфигурация (без секретов)", join("\n", cfg_lines)) +
	section("состояние сети и сервисов", state) +
	section(sprintf("журнал установки (последние %d КБ)", INSTALL_LOG_TAIL_BYTES / 1000), install_log) +
	section(sprintf("системный журнал, наши сервисы (последние %d строк)", SYSLOG_TAIL_LINES), syslog);

// ИНВАРИАНТ: redact() — один раз над ВСЕМ текстом, не точечно по секциям (иначе секцию можно
// забыть). Роутер сам никуда не отправляет (исходящий канал как раз может быть сломан в момент
// поломки, а зашитый токен бота вытащит кто угодно) — файл уходит руками пользователя.
let r = redact(body);

// Шапка — ПОСЛЕ чистки, мимо неё: иначе список вырезанного сам мог попасть под правило.
let removed_line = length(r.removed) > 0
	? "Вырезано перед сохранением: " + join("; ", r.removed) + "."
	: "Секретов известных форм в этом пакете не нашлось.";

let head = "════ cheburnet — диагностика ════\n" +
	removed_line + "\n" +
	"Адрес и порт вашего сервера оставлены намеренно: подключиться по ним нельзя, а без них\n" +
	"причину не найти. Перед отправкой пролистайте файл — вы отправляете именно то, что видите.\n\n";

if (has_flag("--json")) {
	print(sprintf("%J\n", { text: head + r.text, removed: r.removed }));
} else {
	print(head + r.text);
}
