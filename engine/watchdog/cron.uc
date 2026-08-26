// cron.uc — поставить/снять cron-запись сторожа (импурно, router-side). Идемпотентно.
//
//   ucode -R cron.uc            # поставить (зовут install/run.uc на commit и install/reapply.uc)
//   ucode -R cron.uc --remove   # снять (зовёт install/reset.uc)

import { readfile } from "fs";
import { sh } from "../lib/proc.uc";

// Путь ИМЕНОВАННЫЙ, а не выведенный от себя: строку исполнит cron через часы после нас, и
// путь репозитория (при запуске из dev-дерева) там ничего не значит. ENGINE_DIR — для тестов.
const ENGINE = getenv("ENGINE_DIR") ?? "/usr/share/cheburnet/engine";
const CRONTAB = getenv("CRONTAB_FILE") ?? "/etc/crontabs/root";
// Раз в 5 минут: проверка — несколько форков, а дом без интернета ждёт починки минуты, не часы.
const LINE = sprintf("*/5 * * * * ucode -R %s/watchdog/tick.uc >/dev/null 2>&1", ENGINE);
const MARKER = "watchdog/tick.uc"; // по нему находим СВОЮ строку, не трогая чужие задания

let remove = (length(ARGV) > 0 && ARGV[0] == "--remove");

// Нужное состояние уже на месте → выходим, НЕ трогая crond. Нас зовут на каждый холодный подъём
// WAN и из каждой починки сторожа (сам тик — потомок crond): рестарт «на всякий случай» — это
// лишнее движение ровно там, где движения должны быть редкими.
let cur = split(readfile(CRONTAB) ?? "", "\n");
let has_line = false, has_marker = false;
for (let i = 0; i < length(cur); i++) {
	if (cur[i] == LINE) has_line = true;
	if (index(cur[i], MARKER) >= 0) has_marker = true;
}
if ((remove && !has_marker) || (!remove && has_line)) {
	printf("watchdog: cron-запись уже %s\n", remove ? "снята" : "на месте (*/5)");
	exit(0);
}

// Идемпотентность: удалить-перед-добавить. `grep -v` возвращает 1, когда не осталось строк или
// вход пуст — это норма, отсюда `|| true` (CLAUDE.md, ловушки shell).
sh(sprintf("touch %s", CRONTAB));
sh(sprintf("grep -v '%s' %s > %s.tmp 2>/dev/null || true; mv %s.tmp %s",
	MARKER, CRONTAB, CRONTAB, CRONTAB, CRONTAB));

if (!remove)
	sh(sprintf("printf '%%s\\n' %s >> %s", "'" + LINE + "'", CRONTAB));

// Cron перечитывает crontab сам, но только по своему таймеру; restart делает это сразу и дёшево.
sh("/etc/init.d/cron enable >/dev/null 2>&1");
sh("/etc/init.d/cron restart >/dev/null 2>&1");

printf("watchdog: cron-запись %s\n", remove ? "снята" : "на месте (*/5)");
