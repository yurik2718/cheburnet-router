// reapply.uc — вернуть runtime-часть data-plane из /etc/cheburnet/install.json (импурно).
//   ucode -R reapply.uc      # коды: 0 применено/нечего применять, 1 шаг упал, 2 WAN не найден
// ЕДИНСТВЕННАЯ реализация «переприменить» — её зовут hotplug-хук, откат run.uc, set_mode (rpcd),
// resume (pause.uc) и сторож: «после ребута» не должно расходиться с «после смены режима».

import { readfile } from "fs";
import { sh, run_stdin } from "../lib/proc.uc";
import { tunnel_info, default_protocol } from "./install.uc";
import { detect_wan } from "../lib/wan.uc";

const ETC = getenv("ETC_CHEBURNET") ?? "/etc/cheburnet";
// Путь к движку выводим от себя (как run.uc), а не хардкодим: тот же файл работает и из репозитория,
// и из /usr/share/cheburnet на роутере. ENGINE_DIR — override ТОЛЬКО для host-тестов: полный
// firewall-шаг в sandbox не исполним (в нём нет /etc/init.d/firewall), поэтому там подставляется
// шаг-заглушка, и проверяется решение переприменения — какой WAN взят и что уехало шагу.
let ENGINE = getenv("ENGINE_DIR") ?? (sourcepath(0, true) + "/..");

// ИНВАРИАНТ: ip-часть policy-routing (`ip rule fwmark → table` + default таблицы через WAN)
// живёт только в ЯДРЕ и не переживает перезагрузку (nft-часть переживает файлом в
// /etc/nftables.d/). Без переприменения direct-трафик молча уходит В ТУННЕЛЬ — безопасно, но
// split-tunnel тихо выключается; hotplug-хук поэтому ждёт оба артефакта, nft-правило и route
// (см. steps/firewall/firewall.uc render_hotplug).
let raw = readfile(ETC + "/install.json");
let saved = (raw && substr(trim(raw), 0, 1) == "{") ? json(raw) : null;
// Не настроен — молча выходим: hotplug зовётся на каждый подъём WAN, в том числе на чистом роутере.
if (!saved || type(saved.routing_opts) != "object")
	exit(0);

// Аварийный режим — осознанный выбор человека, и он обязан пережить перезагрузку: иначе роутер
// вернётся с защитой и снова без интернета, а человек уже не поймёт, почему «само сломалось».
// Сторожа при этом НЕ снимаем (он тоже видит paused и не вмешивается) — вернуть защиту можно
// одной кнопкой в панели.
if (saved.paused === true) {
	sh(sprintf("ucode -R %s/watchdog/cron.uc >/dev/null 2>&1", ENGINE));
	exit(0);
}

let ro = saved.routing_opts;

// ШРАМ: первый ifup после загрузки (~20с) опережает готовность WAN. Применить с сохранённым wan_if
// тогда хуже, чем ничего (правило есть, маршрут в пустоту) — без свежего WAN не применяем вовсе:
// следующий ifup доведёт, а синхронный вызывающий (set_mode) по коду 2 скажет честно.
let wr = detect_wan();
if (!wr) {
	warn("cheburnet: WAN не найден — data-plane не переприменён\n");
	exit(2);
}
ro.wan_if = wr.wan_if;
if (wr.wan_gw)
	ro.wan_gw = wr.wan_gw;

// tunnel_if мог не попасть в сохранённый конфиг (старые установки) — выводим из протокола.
if (!ro.tunnel_if)
	ro.tunnel_if = tunnel_info(saved.protocol ?? default_protocol()).tunnel_if;

let payload = sprintf("%J", {
	domains: saved.domains ?? [],
	routing_opts: ro,
	fw_opts: { tunnel_if: ro.tunnel_if },
});

let rc = run_stdin(sprintf("ucode -R %s/steps/firewall/apply.uc", ENGINE), payload);
if (rc != 0) {
	warn("cheburnet: не удалось переприменить data-plane (см. logread)\n");
	exit(1);
}

// Сторож мог не появиться на роутере, поставленном до него (пакет обновляется без переустановки),
// или его cron-запись могла пропасть с чужой правкой crontab. Запись идемпотентна — просто
// гарантируем её на каждом холодном подъёме WAN.
sh(sprintf("ucode -R %s/watchdog/cron.uc >/dev/null 2>&1", ENGINE));

// МИГРАЦИЯ установок со старой схемой маршрута (route_allowed_ips='1' → half-routes, см. HALF_ROUTES
// в steps/vpn/vpn.uc): пакет обновляется без переустановки (postinst зовёт нас). Гейт — само старое
// значение, повторные запуски ничего не делают.
if ((saved.protocol ?? default_protocol()) == "awg" &&
    trim(sh("uci -q get network.awg0_peer.route_allowed_ips 2>/dev/null")) == "1") {
	sh("logger -t cheburnet 'миграция маршрута туннеля: route_allowed_ips=1 → half-routes'");
	if (int(trim(sh(sprintf("ucode -R %s/steps/vpn/apply.uc --arm >/dev/null 2>&1; echo $?", ENGINE)))) != 0)
		warn("cheburnet: миграция маршрута туннеля не удалась (см. logread)\n");
}
exit(0);
