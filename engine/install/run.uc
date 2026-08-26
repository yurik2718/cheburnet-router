// run.uc — установочный оркестратор (импурно, router-side): preflight → snapshot UCI →
// шаги по порядку → health-check → commit / rollback. Политика — чистое ядро install.uc, под
// тестами; здесь — исполнение через существующие CLI, проверяется в QEMU.
//
//   echo '{"awg_conf":"...","domains":["example.com"]}' | ucode -R run.uc
//   ... | ucode -R run.uc --dry-run     # показать, что будет сделано

import { stdin, readfile, writefile, unlink, access } from "fs";
import { sh, run_stdin } from "../lib/proc.uc";
import { enabled_steps, snapshot_scope, dirty_steps, decide_outcome,
         tunnel_info, disabled_tunnels, default_protocol, handshake_state,
         uses_singbox, tunnel_conf } from "./install.uc";
import { detect_wan } from "../lib/wan.uc";
import { evaluate, soft_failed_ids } from "../preflight/preflight.uc";
import { config_path as sb_config_path } from "../steps/singbox/singbox.uc";
import { tunnel_connectivity } from "./probe.uc";

let SELF = sourcepath(0, true);
let ENGINE = SELF + "/..";              // engine/
const ETC_CHEBURNET = getenv("ETC_CHEBURNET") ?? "/etc/cheburnet";
// config.json Full-тира: env-override для host-тестов в sandbox (тот же приём, что ETC_CHEBURNET).
const SB_CONF = getenv("SB_CONFIG") ?? sb_config_path(null);

// set_step(name) — текущий шаг для install_progress («Шаг: …» в мастере). Путь — env STATE_FILE
// от ubus-слоя (rpcd-cheburnet spawn_bg); нет env (CLI) → no-op.
let STATE_FILE = getenv("STATE_FILE");
function set_step(name) {
	if (STATE_FILE) writefile(STATE_FILE, name + "\n");
}

// set_reason(code) — код исхода (decide_outcome.code) для install_progress.reason: мастер
// различает «VPN-сервер не ответил» / «упал шаг X» / «preflight» адресно, а не одним «не удалось».
let REASON_FILE = getenv("REASON_FILE");
function set_reason(code) {
	if (REASON_FILE) writefile(REASON_FILE, code + "\n");
}

function step_cmd(name, extra) {
	return sprintf("ucode -R %s/steps/%s/apply.uc%s", ENGINE, name, extra ?? "");
}
// stdin для шага по его потребности (install.uc.needs).
function step_stdin(s, cfg) {
	// tunnel_conf: какой текст подать, решает conf_key активного протокола (install.uc) — без
	// ветки «если reality…» здесь, иначе новый протокол требовал бы правки в этом месте.
	if (s.needs == "tunnel_conf") return tunnel_conf(cfg.protocol ?? default_protocol(), cfg);
	if (s.needs == "domains")
		// fw_opts.tunnel_if — для NAT-зоны firewall (routing его игнорирует); payload общий, dns
		// лишний ключ просто не читает.
		return sprintf("%J", { domains: cfg.domains ?? [], routing_opts: cfg.routing_opts,
			fw_opts: { tunnel_if: cfg.routing_opts.tunnel_if } });
	if (s.needs == "wifi")
		return sprintf("%J", { ssid: cfg.ssid, key: cfg.wifi_key }); // нет полей → шаг сделает no-op
	if (s.needs == "doh")
		return sprintf("%J", { provider: cfg.dns_provider }); // нет id → doh берёт дефолт каталога
	return "{}";
}

// tunnel_ok(cfg, iface) → { ok, reason }. Одна проба готовности туннеля (без ожидания). Full-тир:
// connectivity-probe (probe.uc) — reason у неё адресный (process/route/fetch). awg: latest-
// handshakes, готово только на "up" — "none" (awg0 только что применялся, интерфейса ещё нет) НЕ
// считаем готовностью, иначе commit ловил бы мёртвую установку; reason у awg всегда null — там
// нет отдельных стадий отказа, только «рукопожатия нет».
function tunnel_ok(cfg, iface) {
	if (uses_singbox(cfg.protocol ?? default_protocol()))
		return tunnel_connectivity(iface);
	let up = handshake_state(sh(sprintf("awg show %s latest-handshakes 2>/dev/null", iface))) == "up";
	return { ok: up, reason: null };
}

// dns_ok() — ОДНА проба: резолвится ли имя через локальный dnsmasq (127.0.0.1).
function dns_ok() {
	return trim(sh("nslookup openwrt.org 127.0.0.1 >/dev/null 2>&1; echo $?")) == "0";
}

// healthcheck(cfg, tunnel_applied) → { ok, dns_ok, tun_ok, tun_reason }. DNS и туннель должны
// подняться ДО commit. Шрам: мгновенная проверка сразу после шагов ловила тёплый старт сервисов
// (AWG-handshake ~5-15с, https-dns-proxy не мгновенен) и откатывала рабочую установку — поэтому
// поллим ОБА в одном окне (~30с). Разбор по dns_ok/tun_ok/tun_reason — не для этой функции (она
// только меряет), а для decide_outcome (install.uc), которая по ним строит адресный код для UI.
function healthcheck(cfg, tunnel_applied) {
	let iface = cfg.routing_opts.tunnel_if ?? tunnel_info(cfg.protocol ?? default_protocol()).tunnel_if;
	let dns = false, tun = !tunnel_applied, tun_reason = null; // туннель-шаг не применялся → его здоровье не требуем
	for (let i = 0; i < 15; i++) {
		if (!dns) dns = dns_ok();
		if (!tun) {
			let t = tunnel_ok(cfg, iface);
			tun = t.ok;
			tun_reason = t.reason;
		}
		if (dns && tun) break;
		sh("sleep 2");
	}
	return { ok: dns && tun, dns_ok: dns, tun_ok: tun, tun_reason: tun ? null : tun_reason };
}

// rollback_all(steps, cfg) — ЕДИНСТВЕННАЯ реализация отката: вернуть чистые конфиги из снимка
// + снять правила грязных шагов (safe-fail). Зовётся отсюда (упавшая установка) и ubus-слоем
// через `run.uc --rollback` (отмена установки) — знание «как откатывать» не дрейфует по слоям.
function rollback_all(steps, cfg) {
	sh(sprintf("ucode -R %s/rollback/snapshot.uc restore", ENGINE));
	let dirty = dirty_steps(steps);
	for (let i = 0; i < length(dirty); i++)
		run_stdin(step_cmd(dirty[i], " --teardown"), step_stdin({ name: dirty[i], needs: "domains" }, cfg));

	// config.json — внешний файл, uci-snapshot его не покрывает (тот же приём, что в
	// replace_singbox.uc). Вернуть, если установка поверх рабочего Full-тира его перезаписала.
	let sb = SB_CONF;
	if (access(sb + ".prev")) {
		sh(sprintf("mv %s.prev %s 2>/dev/null", sb, sb));
		if (trim(sh("uci -q get sing-box.main.enabled 2>/dev/null")) == "1")
			sh("/etc/init.d/sing-box restart >/dev/null 2>&1");
	}

	// Snapshot вернул uci-конфиги, но рантайм не сойдётся сам: netifd держит маршруты снятого
	// туннеля до RESTART (reload недостаточен), а dnsmasq резолвит через мёртвый DoH.
	// Без этого провал установки оставляет LAN без интернета; краткий разрыв на пути отката приемлем.
	sh("/etc/init.d/network restart >/dev/null 2>&1");
	sh("/etc/init.d/dnsmasq restart >/dev/null 2>&1");
}

// reapply_data_plane() — после отката ПОВЕРХ РАБОЧЕЙ системы вернуть её runtime-data-plane.
// Шрам: teardown грязных шагов (выше) сносит nftables.d/ip rules и на пере-установке оставлял
// восстановленный туннель БЕЗ NAT/policy-routing — LAN без интернета при «installed=true».
// Реализация одна — install/reapply.uc (её же зовёт hotplug-хук после ребута), чтобы «после
// отката» не расходилось с «после ребута».
function reapply_data_plane() {
	if (int(trim(sh(sprintf("ucode -R %s/install/reapply.uc >/dev/null 2>&1; echo $?", ENGINE)))) != 0)
		warn("install: не удалось вернуть firewall прежней системы — примените режим заново в панели\n");
}

// --- вход ---
let raw = trim(stdin.read("all") ?? "");
let cfg = (substr(raw, 0, 1) == "{") ? json(raw) : {};
let dry = (length(ARGV) > 0 && ARGV[0] == "--dry-run");

// Протокол туннеля: awg (Light, дефолт) | reality | hysteria2 (Full, общий sing-box). tunnel_if
// кладём в routing_opts — health-check и firewall (fw_opts) его используют, routing игнорирует.
let protocol = cfg.protocol ?? default_protocol();
let tinfo = tunnel_info(protocol);
if (type(cfg.routing_opts) != "object") cfg.routing_opts = {};
cfg.routing_opts.tunnel_if = tinfo.tunnel_if;

// WAN для kill-switch и default-маршрута direct-таблицы — динамически (lib/wan.uc), не хардкод
// (урок v1): мастер имена интерфейсов не вводит. Шлюз обязателен для ethernet (без via ARP на
// публичные IP молчит, прогон 2026-07-08), но не для PPPoE/p2p (маршрут без nexthop).
if (type(cfg.routing_opts.wan_if) != "string" || length(cfg.routing_opts.wan_if) == 0) {
	let wr = detect_wan();
	if (wr) {
		cfg.routing_opts.wan_if = wr.wan_if;
		if (wr.wan_gw)
			cfg.routing_opts.wan_gw = wr.wan_gw;
	}
}

// Отключаем неактивные туннель-шаги (vpn/singbox взаимоисключающие) + пользовательский disable.
let tunnel_disable = disabled_tunnels(protocol); // именно туннели — их ещё и teardown'им ниже
let disable = [];
for (let i = 0; i < length(tunnel_disable); i++) push(disable, tunnel_disable[i]);
if (type(cfg.disable) == "array")
	for (let i = 0; i < length(cfg.disable); i++) push(disable, cfg.disable[i]);

let steps = enabled_steps({ disable: disable });
let scope = snapshot_scope(steps);

// restore_cfg_truth() — вернуть install.json к состоянию ДО этой попытки установки: был прежний
// (пере-установка) — восстановить из .prev, не было — удалить. Шрам: без этого провал/отмена
// оставляли фантомное installed=true, и мастер после отката открывал «панель» пустой системы.
function restore_cfg_truth() {
	let f = ETC_CHEBURNET + "/install.json";
	let out = sh(sprintf("[ -f %s.prev ] && mv %s.prev %s && echo restored", f, f, f));
	if (index(out, "restored") < 0)
		unlink(f);
}

// --rollback: только откат, без установки. stdin — {domains?, routing_opts?, protocol?}.
// Teardown'им дирти-шаги ВСЕХ туннелей, не только активного протокола: отменённая установка
// могла быть любого, а teardown идемпотентен — иначе отмена reality без protocol оставляла бы
// живой sing-box с credentials.
if (length(ARGV) > 0 && ARGV[0] == "--rollback") {
	let rb_steps = enabled_steps({ disable: (type(cfg.disable) == "array") ? cfg.disable : [] });
	rollback_all(rb_steps, cfg);
	restore_cfg_truth();
	reapply_data_plane();
	warn("install: откат выполнен (--rollback)\n");
	exit(0);
}

// --- 1. preflight (гейткипер) ---
// accept_risk (из мастера, «поставить на свой страх и риск») ослабляет гейт ТОЛЬКО на soft-провалы
// — нехватку флеша/RAM. hard (arch/версия/пакеты/LAN-конфликт) он не пропускает: там apk просто не
// найдёт файлы, и «пропуск» обещал бы невозможное. Решение владельца, а не движка (см. preflight.uc).
set_step("preflight");
let accept_risk = (cfg.accept_risk === true);
let facts = sh(sprintf("ucode -R %s/preflight/gather.uc", ENGINE));
let pf_rc = run_stdin(sprintf("ucode -R %s/preflight/check.uc%s", ENGINE,
	accept_risk ? " --allow-soft" : ""), facts);
let preflight = { ok: (pf_rc == 0) };

// Какие soft-проверки пропущены — та же evaluate по уже собранным фактам (gather не повторяем,
// apk --simulate дорог). След нужен в install.json: видно, что роутер поставлен с пропуском
// проверок, а не гадать по логам при жалобе «тормозит».
let forced = [];
if (accept_risk && preflight.ok && substr(trim(facts), 0, 1) == "{") {
	let f = json(facts);
	forced = soft_failed_ids(evaluate(f, f.requirements));
	if (length(forced) > 0)
		warn(sprintf("install: ВНИМАНИЕ — установка с пропуском проверок железа (%s) по решению владельца: стабильность не гарантируется\n",
			join(", ", forced)));
}

if (!preflight.ok) {
	// Отчёт уже напечатан check.uc (stdout унаследован). abort гейткипера — такой же не-успех, как
	// rollback: тоже возвращаем правду install.json, иначе фантомное installed=true.
	restore_cfg_truth();
	let d = decide_outcome({ preflight: preflight });
	set_reason(d.code);
	warn(sprintf("install: %s\n", d.reason));
	exit(1);
}

if (dry) {
	printf("# preflight: ok\n# snapshot scope: %s\n# шаги: ", join(", ", scope));
	for (let i = 0; i < length(steps); i++) printf("%s ", steps[i].name);
	printf("\n# dirty (teardown при rollback): %s\n", join(", ", dirty_steps(steps)));
	for (let i = 0; i < length(steps); i++)
		run_stdin(step_cmd(steps[i].name, " --dry-run"), step_stdin(steps[i], cfg));
	exit(0);
}

// --- 1b. Full-тир: догрузка sing-box ДО любых изменений ---
// sing-box — userspace-бинарь, opt-in (не при bootstrap). Первая установка Full → качаем ПЕРВЫМ,
// до snapshot и шагов: провал apk (нет интернета) = чистый abort, роутер не тронут. Идемпотентно
// (бинарь уже есть на switch_to_*/переустановке — пропуск). install-singbox.sh несёт ретраи.
if (uses_singbox(protocol) && length(trim(sh("command -v sing-box 2>/dev/null"))) == 0) {
	set_step("singbox-download");
	if (run_stdin(sprintf("sh %s/install/install-singbox.sh", ENGINE), "") != 0) {
		restore_cfg_truth();
		set_reason("singbox-download");
		warn("install: не удалось догрузить sing-box — проверьте интернет на роутере\n");
		exit(1);
	}
}

// --- 2. snapshot UCI (для чистого отката) ---
set_step("snapshot");
sh(sprintf("ucode -R %s/rollback/snapshot.uc save", ENGINE));

// Full-тир: config.json бэкапим ДО teardown'ов — uci-snapshot внешний файл не покрывает, а
// teardown удаляет его безвозвратно. Возврат — в rollback_all; на commit зачищается ниже.
if (access(SB_CONF))
	sh(sprintf("cp %s %s.prev 2>/dev/null", SB_CONF, SB_CONF));

// Смена протокола: снять НЕактивный туннель начисто (awg0 при reality и наоборот) — иначе оба
// держат свой default-маршрут и конфликтуют. Снимок выше (network в scope) вернёт при откате.
// Идемпотентно: не был установлен → no-op. vpn/singbox поддерживают --teardown.
for (let i = 0; i < length(tunnel_disable); i++)
	run_stdin(step_cmd(tunnel_disable[i], " --teardown"), "");

// --- 3. шаги по порядку (fail-fast) ---
let results = [];
for (let i = 0; i < length(steps); i++) {
	let s = steps[i];
	set_step(s.name); // веб-мастер покажет «Шаг: vpn/dns/doh/wifi/firewall»
	// Туннель-шаг на ПЕРВОЙ установке — БЕЗ вооружения half-routes (--no-arm): дом не должен
	// переключиться на непроверенный туннель раньше, чем health-check его подтвердит. Довооружаем
	// (--arm) только на commit-пути ниже. См. [[reliability]], план: половина дома не должна
	// терять интернет из-за сбоя, который выявится только через 30с health-check.
	let extra = (s.name == tinfo.step) ? " --no-arm" : null;
	let code = run_stdin(step_cmd(s.name, extra), step_stdin(s, cfg));
	push(results, { name: s.name, ok: (code == 0) });
	if (code != 0) {
		warn(sprintf("install: шаг %s упал (код %d)\n", s.name, code));
		break;
	}
}

// --- 4. health-check (только если все шаги прошли) ---
let all_ok = true;
for (let i = 0; i < length(results); i++) if (!results[i].ok) all_ok = false;
if (all_ok) set_step("health-check"); // поднятие туннеля+DNS — самый долгий этап (до ~30с)
let tunnel_applied = false;
for (let i = 0; i < length(steps); i++)
	if (steps[i].name == tinfo.step) tunnel_applied = true;
let health = all_ok ? healthcheck(cfg, tunnel_applied) : null;

// --- 5. решение: commit / rollback ---
let outcome = decide_outcome({ preflight: preflight, steps: results, health: health });
if (outcome.action == "commit") {
	// Health-check подтвердил туннель — теперь, и только теперь, вооружаем half-routes
	// (--arm), переключая дом на него. tunnel_applied=false (весь тоннель отключён владельцем) →
	// вооружать нечего.
	if (tunnel_applied)
		run_stdin(step_cmd(tinfo.step, " --arm"), "");
	sh(sprintf("ucode -R %s/rollback/snapshot.uc commit", ENGINE));
	// Сторож: с этого момента роутер живёт годами сам, и раз в 5 минут кто-то должен смотреть,
	// на месте ли data-plane (engine/watchdog). Ставим ТОЛЬКО на успешном пути — на откате
	// сторожить нечего.
	sh(sprintf("ucode -R %s/watchdog/cron.uc >/dev/null 2>&1", ENGINE));
	// WAN нашли МЫ (детект выше), мастер его не знает — персистим в install.json: set_mode
	// переприменяет firewall без run.uc, а без wan_if kill-switch не строится.
	let cfg_file = ETC_CHEBURNET + "/install.json";
	let saved_raw = readfile(cfg_file);
	let saved = (saved_raw && substr(trim(saved_raw), 0, 1) == "{") ? json(saved_raw) : null;
	if (saved && (cfg.routing_opts.wan_if || accept_risk)) {
		if (cfg.routing_opts.wan_if) {
			if (type(saved.routing_opts) != "object") saved.routing_opts = {};
			saved.routing_opts.wan_if = cfg.routing_opts.wan_if;
			if (cfg.routing_opts.wan_gw)
				saved.routing_opts.wan_gw = cfg.routing_opts.wan_gw;
			saved.routing_opts.tunnel_if = cfg.routing_opts.tunnel_if;
		}
		// forced — какие проверки железа пропущены (пустой массив стирает прежнюю отметку).
		saved.forced = forced;
		writefile(cfg_file, sprintf("%J\n", saved));
	}
	// Пароль root — не транзакция (см. steps/rootpass): применяем на успешном пути, отдельно от
	// uci-снимка. Сбой passwd не валит установку — честный warning, пароль вторичен к data-plane.
	if (cfg.root_password) {
		let rc = run_stdin(sprintf("ucode -R %s/steps/rootpass/apply.uc", ENGINE),
			sprintf("%J", { root_password: cfg.root_password }));
		if (rc != 0)
			warn("install: пароль root не применился — установите вручную по SSH\n");
	}
	// Install-токен одноразовый: установка удалась → пропуск использован, снимаем его (иначе он
	// продолжал бы пускать install/apply_lan_ip любого в LAN). Только на commit-пути: при откате
	// токен ОСТАЁТСЯ, чтобы пользователь исправил данные и повторил тем же токеном без bootstrap.
	unlink(ETC_CHEBURNET + "/install-token");
	unlink(ETC_CHEBURNET + "/install.json.prev"); // бэкап прежнего cfg больше не нужен
	unlink(SB_CONF + ".prev");                    // и бэкап прежнего config.json (Full-тир)
	printf("install: успешно — %s\n", outcome.reason);
	exit(0);
}

// rollback: единая реализация (см. rollback_all выше).
set_reason(outcome.code);
warn(sprintf("install: откат — %s\n", outcome.reason));
rollback_all(steps, cfg);
restore_cfg_truth();
reapply_data_plane(); // пере-установка поверх рабочей: вернуть её firewall (см. контракт функции)
warn("install: откат выполнен — система возвращена к состоянию до установки\n");
exit(1);
