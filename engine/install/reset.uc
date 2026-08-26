// reset.uc — полный teardown cheburnet-конфигурации (импурно, router-side): ucode -R reset.uc
//
// Возвращает роутер к до-cheburnet состоянию: nft/ip-правила + NAT-зона (firewall --teardown),
// наши uci-секции (network, dhcp, https-dns-proxy), /etc/cheburnet. Пакеты, Wi-Fi, пароль root
// НЕ трогает. Идемпотентно (uci -q семантика). Запускается в фоне (setsid), проверяется в QEMU.

import { readfile, unlink, rmdir, lsdir } from "fs";
import { sh, run_stdin, uci_batch } from "../lib/proc.uc";
import { owned_sections } from "../steps/vpn/vpn.uc";
import { owned_sections as dns_owned_sections } from "../steps/dns/dns.uc";
import { listen_prefix } from "../steps/doh/doh.uc";
import { config_path as sb_config, service_name as sb_service,
         network_sections as sb_net_sections } from "../steps/singbox/singbox.uc";

let SELF = sourcepath(0, true);
let ENGINE = SELF + "/..";              // engine/
const ETC_CHEBURNET = getenv("ETC_CHEBURNET") ?? "/etc/cheburnet";

// routing_opts из сохранённой конфигурации — teardown firewall использует их же (mark/table).
let raw = readfile(ETC_CHEBURNET + "/install.json");
let cfg = (raw && substr(trim(raw), 0, 1) == "{") ? json(raw) : {};
let ro = (type(cfg.routing_opts) == "object") ? cfg.routing_opts : {};

// Сторожа снимаем ПЕРВЫМ: тик посреди сброса начал бы «чинить» ровно то, что мы разбираем.
print("reset: снимаю сторожа (cron)\n");
sh(sprintf("ucode -R %s/watchdog/cron.uc --remove >/dev/null 2>&1", ENGINE));

print("reset: снимаю data-plane (nft/ip/NAT-зона)\n");
run_stdin(sprintf("ucode -R %s/steps/firewall/apply.uc --teardown", ENGINE),
	sprintf("%J", { domains: [], routing_opts: ro }));

// ИНВАРИАНТ: «что считать нашим» не хардкодим — имена секций берём из шагов-владельцев
// (owned_sections/listen_prefix), переименование в шаге подхватывается тут без дрейфа.
// Снимаем секции обоих туннелей независимо от активного протокола — reset чистит всё наше.
print("reset: убираю туннель из network\n");
let net = owned_sections(null);
for (let i = 0; i < length(sb_net_sections(null)); i++)
	push(net, sb_net_sections(null)[i]);
let nops = [];
for (let i = 0; i < length(net); i++)
	push(nops, "delete network." + net[i]);
uci_batch(nops, "network");

// dhcp: наши ipset-секции (имена из dns.owned_sections), DoH-upstream'ы (префикс из doh),
// noresolv. Teardown толерантен — код batch не проверяем (отсутствие записей — норма).
print("reset: чищу dnsmasq-привязки\n");
let ops = [];
let dns_sects = dns_owned_sections(null);
for (let i = 0; i < length(dns_sects); i++)
	if (length(trim(sh(sprintf("uci -q get dhcp.%s 2>/dev/null", dns_sects[i])))) > 0)
		push(ops, sprintf("delete dhcp.%s", dns_sects[i]));
let pfx = listen_prefix();
let srv = trim(sh("uci -q get dhcp.@dnsmasq[0].server 2>/dev/null"));
let stoks = length(srv) > 0 ? split(srv, /[ \t]+/) : [];
for (let i = 0; i < length(stoks); i++)
	if (substr(stoks[i], 0, length(pfx)) == pfx)
		push(ops, sprintf("del_list dhcp.@dnsmasq[0].server='%s'", stoks[i]));
push(ops, "delete dhcp.@dnsmasq[0].noresolv");
// strictorder ставил doh-шаг (порядок upstream'ов значим только с нашими двумя экземплярами) —
// снимаем вместе с ними, иначе чужой upstream пользователя останется под нашей политикой.
push(ops, "delete dhcp.@dnsmasq[0].strictorder");
uci_batch(ops, "dhcp");

// https-dns-proxy: стоп + снести все секции (наш шаг и так владел конфигом целиком).
print("reset: убираю https-dns-proxy\n");
sh("/etc/init.d/https-dns-proxy stop >/dev/null 2>&1");
let hdp = trim(sh("uci -q show https-dns-proxy 2>/dev/null | awk -F'[.=]' '/^https-dns-proxy\\.[^.=]+=/{print $2}' | sort -u"));
let hsects = length(hdp) > 0 ? split(hdp, /\n+/) : [];
let hops = [];
for (let i = 0; i < length(hsects); i++)
	push(hops, sprintf("delete https-dns-proxy.%s", hsects[i]));
if (length(hops) > 0)
	uci_batch(hops, "https-dns-proxy");

// sing-box (Full-тир): выключить сервис + снять uci-секцию и config.json. Только если ставился
// (Light его не трогает) — иначе не плодим стороннего /etc/config/sing-box. Идемпотентно.
if (trim(sh("[ -f /etc/config/sing-box ] && echo y || true")) == "y") {
	print("reset: убираю sing-box (Full-тир)\n");
	sh(sprintf("/etc/init.d/%s stop >/dev/null 2>&1", sb_service()));
	sh(sprintf("/etc/init.d/%s disable >/dev/null 2>&1", sb_service()));
	uci_batch([ "delete sing-box.main" ], "sing-box");
	unlink(sb_config());
}

print("reset: удаляю /etc/cheburnet\n");
let files = lsdir(ETC_CHEBURNET) ?? [];
for (let i = 0; i < length(files); i++)
	unlink(ETC_CHEBURNET + "/" + files[i]);
rmdir(ETC_CHEBURNET);
// Install-токен здесь НЕ выпускаем: это отдельный ubus-метод install_token, зовётся владельцем
// по запросу, а не автоматически при сбросе.

// RESTART, не reload: сброс снимает интерфейсы обоих тиров, и netifd после reload не всегда
// возвращает маршруты снятого (шрам старой схемы маршрута — см. HALF_ROUTES в steps/vpn/vpn.uc).
sh("/etc/init.d/network restart >/dev/null 2>&1");
sh("/etc/init.d/dnsmasq restart >/dev/null 2>&1");

print("reset: готово — cheburnet-конфигурация снята, роутер вернулся к обычной маршрутизации\n");
