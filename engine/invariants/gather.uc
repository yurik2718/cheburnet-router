// gather.uc — сбор фактов о ЖИВОМ data-plane для invariants (импурно; разбор — invariants.uc).
//   ucode -R gather.uc | ucode -R check.uc         # факты → чек-лист инвариантов
// Имена цепочек, таблица, метка, пользователь резервного DNS — из модулей-владельцев, не хардкод.

import { readfile } from "fs";
import { sh } from "../lib/proc.uc";
import { default_opts } from "../routing/routing.uc";
import { chain_names } from "../steps/firewall/firewall.uc";
import { wan_user, resolvers_for } from "../steps/doh/providers.uc";
import { tunnel_info, tunnel_ifs, default_protocol, tunnel_health, uses_singbox } from "../install/install.uc";
import { detect_wan } from "../lib/wan.uc";

const ETC = getenv("ETC_CHEBURNET") ?? "/etc/cheburnet";

let raw = readfile(ETC + "/install.json");
let saved = (raw && substr(trim(raw), 0, 1) == "{") ? json(raw) : null;
let installed = (saved != null);

let ro = (saved && type(saved.routing_opts) == "object") ? saved.routing_opts : {};
let o = default_opts();
let table = ro.table ?? o.table;
let mark  = ro.mark ?? o.mark;
let protocol = saved ? (saved.protocol ?? default_protocol()) : default_protocol();

// WAN берём ЗАНОВО, а не из install.json: протухший wan_if — ровно та тихая поломка, которую
// инвариант direct_table и ловит.
let wr = detect_wan();

// uid резервного DoH-экземпляра: имя знает каталог DoH, номер — только живая система.
// Нет пользователя → null, и invariants просто не выдумывает проверку (см. evaluate).
let uid_raw = trim(sh(sprintf("awk -F: '$1==\"%s\"{print $3}' /etc/passwd 2>/dev/null", wan_user())));
let dns_uid = match(uid_raw, /^[0-9]+$/) ? int(uid_raw) : null;

// Живость туннеля — тем же признаком, что у панели (tunnel_health): по нему invariants решает,
// есть ли смысл перезапускать основной DoH (на мёртвом туннеле он упадёт снова).
let tif = ro.tunnel_if ?? tunnel_info(protocol).tunnel_if;
let hs = trim(sh(sprintf("awg show %s latest-handshakes 2>/dev/null | awk 'NR==1{print $2}'", tif)));
let tunnel_alive = tunnel_health(protocol, {
	hs_age: match(hs, /^[0-9]+$/) && int(hs) > 0 ? time() - int(hs) : null,
	sb_running: trim(sh("pgrep sing-box >/dev/null 2>&1 && echo up")) == "up",
	tun_up: trim(sh(sprintf("ip link show dev %s 2>/dev/null | grep -qE '[<,]UP[,>]' && echo up", tif))) == "up",
}) == "up";

let chains = chain_names(null);
let facts = {
	installed: installed,
	// Аварийный режим (install/pause.uc): защита снята ОСОЗНАННО. Проверять «на месте ли она»
	// в этот момент — значит требовать от системы того, чего человек сам просил не делать.
	paused: (saved && saved.paused === true),
	mode: ro.mode ?? "home",
	protocol: protocol,
	tunnel_if: tif,
	tunnel_alive: tunnel_alive,
	tunnel_ifs: tunnel_ifs(),
	wan_if: wr ? wr.wan_if : null,
	table: table,
	mark: mark,
	dns_uid: dns_uid,
	dns_url: resolvers_for(saved ? saved.dns_provider : null)[0].url,
	// Порты — из каталога DoH (единственный источник): по ним инварианты различают основной
	// экземпляр и резервный, а не считают процессы «сколько-нибудь».
	dns_ports: { main: resolvers_for(saved ? saved.dns_provider : null)[0].port,
	             wan:  resolvers_for(saved ? saved.dns_provider : null)[1].port },
	ip_rule: sh("ip rule show 2>/dev/null"),
	// Дефолты и полная таблица — РАЗНЫЕ факты: по первому судим «есть ли путь наружу», по второй
	// ищем half-routes туннеля. Смешать их — значит принять любой маршрут за дефолт.
	route_default: sh("ip -4 route show default 2>/dev/null"),
	route_main: sh("ip -4 route show 2>/dev/null"),
	route_direct: sh(sprintf("ip route show table %d 2>/dev/null", table)),
	// Цепочку берём ЦЕЛИКОМ, с правилами: пустая hooked-цепочка после fw4 reload — реальный
	// шрам, и «цепочка есть» о защите не говорит ничего (см. invariants.killswitch).
	nft_mark: sh(sprintf("nft list chain inet fw4 %s 2>/dev/null", chains[0])),
	nft_ks:   sh(sprintf("nft list chain inet fw4 %s 2>/dev/null", chains[1])),
	// [h] в классе — чтобы grep не нашёл сам себя (busybox ps w печатает и его командную строку).
	hdp_ps: sh("ps w 2>/dev/null | grep '[h]ttps-dns-proxy'"),
};

print(sprintf("%J\n", facts));
