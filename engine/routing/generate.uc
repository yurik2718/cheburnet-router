// generate.uc — CLI генератора split-routing (routing.uc) для тестов и отладки.
//   echo '{"what":"nft","domains":["example.com"],"opts":{"ipv6":false}}' | ucode -R generate.uc
//   printf 'example.com\nexample.org\n' | ucode -R generate.uc       # what="all" → JSON render_all
// Stdin — граница доверия: JSON { domains, opts, what } или строки-домены.

import { stdin } from "fs";
import { build_plan, render_all, render_dnsmasq,
         render_nft, render_iprules } from "./routing.uc";

let raw = stdin.read("all") ?? "";
let domains = [], opts = {}, what = "all";

if (substr(trim(raw), 0, 1) == "{") {
	let req = json(raw); // кинет при битом JSON — пусть падает: это явный мусор на входе
	domains = req.domains ?? [];
	opts = req.opts ?? {};
	what = req.what ?? "all";
} else {
	// Строковый режим: каждая непустая строка без ведущего '#' — домен.
	let lines = split(raw, "\n");
	for (let i = 0; i < length(lines); i++) {
		let line = trim(lines[i]);
		if (length(line) == 0 || substr(line, 0, 1) == "#")
			continue;
		// Первый токен: домен не содержит пробелов/'#', поэтому inline-комментарий
		// ('example.com # note') и hosts-подобные строки безопасно отсечь по разделителю.
		let m = match(line, /^[^\s#]+/);
		push(domains, m ? m[0] : line);
	}
}

let plan = build_plan(domains, opts);

function emit_lines(arr) {
	for (let i = 0; i < length(arr); i++)
		print(arr[i] + "\n");
}

if (what == "all")
	print(sprintf("%J\n", render_all(plan)));
else if (what == "dnsmasq")
	emit_lines(render_dnsmasq(plan));
else if (what == "nft")
	emit_lines(render_nft(plan));
else if (what == "iprules")
	emit_lines(render_iprules(plan));
else
	die(sprintf("unknown 'what': %s", what));
