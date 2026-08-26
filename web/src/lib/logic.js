// logic.js — чистая логика мастера и панели, вынесенная из Svelte-компонентов под vitest.
//
// Здесь нет DOM/сети/состояния — только функции «вход → значение»: валидация формы Setup,
// разбор конфигов для сводки Confirm, карта причин провала для Installing, форматтеры Status.
// Компоненты остаются тонкими (состояние + разметка), а границу с пользователем проверяют юниты.

// Лимиты формы Setup. MIN_PASS зеркалит ubus-границу (install.root_password.minlen);
// SSID/WPA-PSK — из стандартов (IEEE 802.11 / WPA).
export const MIN_PASS = 8;
export const SSID_MAX = 32;
export const WIFI_KEY_MIN = 8;
export const WIFI_KEY_MAX = 63;

// Куда писать, если не работает — одно место на весь UI (копии на трёх экранах разъезжались).
// Страница проекта рядом с личным контактом: ссылка, вшитая в прошивку, живёт годами, канал связи
// может смениться — страница долговечный ориентир, Telegram — быстрый путь сегодня.
export const SUPPORT = {
  telegram: '@industrialprofi',
  telegramUrl: 'https://t.me/industrialprofi',
  page: 'https://github.com/andreiyurik/cheburnet-router',
  donateUrl: 'https://pay.cloudtips.ru/p/61fe8ef3',
};

// --- Каталог туннельных протоколов (три оси покрытия, ADR 0004) ---
// Зеркалит PROTOCOLS движка (engine/install/install.uc; синхронность стережёт engine-sync.test.js)
// плюс то, чего в движке быть не должно: как объяснить протокол ЧЕЛОВЕКУ — от поломки, не от
// названия. why — одна строка у всех трёх сразу; whyMore — под «Подробнее»; sniff/sniffError —
// дешёвая проверка формата ДО отправки (отказ движка стоит трёх минут установки и отката).
export const PROTOCOLS = {
  awg: {
    id: 'awg',
    name: 'AmneziaWG',
    confKey: 'awg_conf',
    // Симптом, при котором этот протокол — верный выбор.
    symptom: 'Роутер слабый или хочется максимально быстро',
    why: 'Считается прямо в ядре роутера: самая высокая скорость, минимум нагрузки.',
    whyMore: 'Ядро маршрутизирует пакеты без промежуточной программы, поэтому процессор почти не греется, а скорость упирается в канал, а не в роутер.',
    // Что просим вставить.
    confLabel: 'VPN-конфиг (AmneziaWG, файл .conf)',
    confHint: 'Его выдаёт ваш VPN-провайдер (конфиг «для роутеров») или ваш собственный сервер.',
    placeholder: '[Interface]\nPrivateKey = …\nAddress = …\n[Peer]\nPublicKey = …\nEndpoint = host:port',
    sniff: /\[Interface\]/i,
    sniffError: 'Похоже, это не конфиг AmneziaWG: в нём должна быть строка [Interface]. Вставьте файл .conf целиком или загрузите его кнопкой ниже.',
    // Загрузка файлом уместна только для .conf (ссылку удобнее вставить).
    file: true,
    full: false,
    switchMethod: 'switch_to_awg',
    replaceMethod: 'replace_awg_conf',
  },
  reality: {
    id: 'reality',
    name: 'VLESS+Reality',
    confKey: 'reality_conf',
    symptom: 'Интернет через VPN вообще не открывается',
    why: 'Снаружи выглядит как обычный HTTPS-сайт, поэтому проходит там, где другие туннели не поднимаются.',
    whyMore: 'Считается не в ядре, а в обычной программе — процессору тяжелее, чем с AmneziaWG, поэтому нужен роутер помощнее.',
    confLabel: 'Ссылка vless:// или конфиг sing-box',
    confHint: 'Возьмите ссылку в панели своего сервера (3x-ui / Hiddify и подобные).',
    placeholder: 'vless://uuid@host:443?security=reality&pbk=…&sni=…&sid=…&flow=xtls-rprx-vision#name\n…или JSON-конфиг sing-box',
    sniff: /^\s*(vless:\/\/|\{)/i,
    sniffError: 'Похоже, это не ссылка VLESS: она начинается с vless://. Вставьте ссылку целиком (или JSON-конфиг sing-box).',
    file: false,
    full: true,
    switchMethod: 'switch_to_reality',
    replaceMethod: 'replace_reality_conf',
  },
  hysteria2: {
    id: 'hysteria2',
    name: 'Hysteria2',
    confKey: 'hysteria2_conf',
    symptom: 'Интернет открывается, но тормозит и рвётся',
    why: 'Держит скорость на канале, который теряет пакеты: мобильный интернет, дальний Wi-Fi, вечерняя перегрузка.',
    whyMore: 'Умеет прыгать по портам, если провайдер душит какой-то один. Тоже считается в программе, а не в ядре — процессору тяжелее.',
    confLabel: 'Ссылка hysteria2:// или конфиг sing-box',
    confHint: 'Возьмите ссылку в панели своего сервера Hysteria2 (подходит и короткая форма hy2://).',
    placeholder: 'hysteria2://пароль@host:443?sni=example.com&obfs=salamander&obfs-password=…#name\n…или JSON-конфиг sing-box',
    sniff: /^\s*(hysteria2:\/\/|hy2:\/\/|\{)/i,
    sniffError: 'Похоже, это не ссылка Hysteria2: она начинается с hysteria2:// или hy2://. Вставьте ссылку целиком (или JSON-конфиг sing-box).',
    file: false,
    full: true,
    switchMethod: 'switch_to_hysteria2',
    replaceMethod: 'replace_hysteria2_conf',
  },
};

// checkConf(id, text) → '' | текст ошибки. Одна проверка на мастер и на панель: замена сервера и
// смена туннеля упираются в тот же формат, и там цена ошибки та же (фоновая операция + откат).
export function checkConf(id, text) {
  const info = protocolInfo(id);
  const s = (text ?? '').trim();
  if (s.length === 0)
    return `Вставьте ${info.file ? 'или загрузите ' : ''}${info.confLabel.toLowerCase()}.`;
  return info.sniff.test(s) ? '' : info.sniffError;
}

// Порядок показа в мастере и панели. Reality перед Hysteria2 осознанно: «не открывается вообще» —
// более частая и более срочная поломка, чем «медленно».
export const PROTOCOL_ORDER = ['awg', 'reality', 'hysteria2'];

export function protocolList() {
  return PROTOCOL_ORDER.map((id) => PROTOCOLS[id]);
}

export function protocolInfo(id) {
  return PROTOCOLS[id] ?? PROTOCOLS.awg; // неизвестный → дефолт (fail-safe, как в движке)
}

// Протокол требует Full-тира (userspace-бинарь sing-box)?
export function requiresFull(id) {
  return protocolInfo(id).full === true;
}

// defaultProtocol(fullAvailable) → что предвыбрать в мастере.
// Слабое железо: AmneziaWG, выбора нет (остальное туда не влезет).
// Full-железо: VLESS+Reality — закрывает самую частую поломку («VPN не поднимается»), а запас
// железа есть, чтобы за проходимость заплатить. См. ADR 0004, «Дефолты и гейтинг».
export function defaultProtocol(fullAvailable) {
  return fullAvailable ? 'reality' : 'awg';
}

// --- Brutal: объявленная скорость канала (Hysteria2) ---
// Объявленная скорость включает Brutal: он не ищет полосу, а держит названную; завышение = очередь,
// пинг и «стало хуже» без ошибок в логах. Поэтому по умолчанию не объявляем (BBR), а в ручном режиме
// подставляем скромные значения и предупреждаем. Подробно: docs/kb/concepts/hysteria2.md.
export const SPEED_DEFAULTS = { down: 50, up: 10 };
export const SPEED_MAX = 10000;

// Предупреждение про завышенную цифру. Одно на весь UI: оно нужно в мастере и в панели (замена
// сервера, смена туннеля), а две копии одного предупреждения разъезжаются при первой же правке.
// Текст длинный намеренно — без «станет ХУЖЕ» человек не свяжет причину со следствием: ошибок в
// логах при этом не появится.
export const BRUTAL_WARNING = 'Указывайте скорость, которую интернет реально держит, и лучше немного '
  + 'меньше. Если написать больше, чем есть, связь станет хуже: вырастут задержки и начнутся '
  + 'обрывы — и никакой ошибки при этом не появится.';

// withDeclaredSpeed(link, down, up) → ссылка с нашими локальными параметрами down/up.
// ПОЧЕМУ параметры дописываем мы, а не автор ссылки: официальная спецификация hy2-URI прямо
// требует не класть полосу в ссылку — она индивидуальна и «не предназначена для слепого
// применения». Значит это решение ВЛАДЕЛЬЦА роутера, и вносит его наш UI.
// Ссылка, уже несущая up/down (некоторые панели их добавляют), не переписывается: уважаем то,
// что человек вставил, и не спорим с ним молча.
export function withDeclaredSpeed(link, down, up) {
  const s = (link ?? '').trim();
  if (!s || !/^(hysteria2|hy2):\/\//i.test(s)) return s; // JSON-конфиг и прочее не трогаем
  if (/[?&](up|down)=/.test(s)) return s;
  const d = Number(down), u = Number(up);
  if (!Number.isInteger(d) || !Number.isInteger(u) || d <= 0 || u <= 0) return s;
  if (d > SPEED_MAX || u > SPEED_MAX) return s;
  // Параметры дописываем ДО #fragment — иначе они уехали бы в метку и парсер их не увидел.
  const hash = s.indexOf('#');
  const body = hash >= 0 ? s.slice(0, hash) : s;
  const frag = hash >= 0 ? s.slice(hash) : '';
  return `${body}${body.includes('?') ? '&' : '?'}down=${d}&up=${u}${frag}`;
}

// Direct-домены: по строке или через запятую → массив. Пустые/пробелы отбрасываем
// (движок всё равно валидирует и отбрасывает мусор — fail-safe, см. routing.build_plan).
export function parseDomains(text) {
  return text
    .split(/[\s,]+/)
    .map((d) => d.trim())
    .filter((d) => d.length > 0);
}

// --- Пропуск проверок железа («на свой страх и риск») ---
//
// Движок делит проверки preflight на hard (пропустить нельзя — пакетов под эту платформу просто
// нет) и soft (железо впритык: флеш/RAM). Мастер предлагает установку с пропуском ТОЛЬКО когда
// все провалы soft (report.overridable), и обязан сначала объяснить: что грозит и что можно
// сделать ВМЕСТО риска. Кнопка — последний вариант, а не первый (см. engine/preflight/preflight.uc).
export const SOFT_RISK = {
  flash: {
    title: 'Мало свободного места в памяти роутера (флеш)',
    risk: 'Пакеты могут не поместиться. Тогда установка прервётся на середине и сама вернёт роутер в исходное состояние — но времени это займёт.',
    fixes: [
      'освободить место: по SSH удалить ненужные пакеты командой apk del — часто это лишние темы и приложения LuCI;',
      'подключить USB-флешку и вынести систему на неё (extroot) — после этого места хватает с запасом.',
    ],
  },
  ram: {
    title: 'Мало оперативной памяти (RAM)',
    risk: 'Установка, скорее всего, пройдёт, но под нагрузкой роутер может тормозить или перезагружаться из-за нехватки памяти.',
    fixes: [
      'держать список доменов прямого доступа коротким — одна запись зоны покрывает все домены внутри неё;',
      'включить сжатый swap в оперативной памяти — пакет zram-swap, он сглаживает пики.',
    ],
  },
};

// softRisks(report) → пояснения по каждой провалившейся soft-проверке (в порядке отчёта).
// Незнакомый id (движок добавил soft-проверку раньше UI) не теряем — показываем текст движка.
export function softRisks(report) {
  return (report?.checks ?? [])
    .filter((c) => !c.ok && c.severity === 'soft')
    .map((c) => {
      const known = SOFT_RISK[c.id];
      return known
        ? { id: c.id, ...known }
        : { id: c.id, title: c.detail, risk: c.fix ?? '', fixes: [] };
    });
}

// Подписи пропущенных проверок для плашки в панели (status.forced приходит из install.json).
export const FORCED_LABELS = { flash: 'мало свободного места', ram: 'мало оперативной памяти' };

// Чего не хватает железу для Full-тира (status.full_missing) — человеческими словами.
// Молчаливо спрятанная кнопка выглядит как «функцию убрали»; названная причина — как выбор.
export const FULL_MISSING_LABELS = {
  arch: 'нужен 64-битный процессор с AES (у этого роутера другой)',
  ram: 'нужно от 256 МБ оперативной памяти',
  flash: 'не хватает свободного места: компоненту нужно не меньше 44 МБ',
};

export function fullMissingText(missing) {
  return (missing ?? []).map((m) => FULL_MISSING_LABELS[m] ?? m).join('; ');
}

// explainFullTierFail(reason) → текст для панели, когда догрузка компонента не удалась.
// reason пишет install-singbox.sh: "no-space" — не влез на флеш, "download" (или ничего) — сеть.
// Смысл разделения тот же, что у explainFail: не отправлять человека чинить не то.
export function explainFullTierFail(reason) {
  if (reason === 'no-space')
    return 'Не хватило места на роутере: компонент скачивается (~11 МБ), а после установки занимает ' +
      'около 42 МБ. Освободите место (по SSH: apk del ненужные пакеты) или подключите USB-флешку ' +
      '(extroot). Текущий туннель не затронут — он продолжает работать.';
  return 'Не удалось скачать компонент — проверьте, что роутер в интернете, и попробуйте ещё раз. ' +
    'Текущий туннель не затронут.';
}

// fullReasons(report) → почему Full-тир (VLESS+Reality) недоступен, человеческими фразами из
// движка (tiers.full_checks: «RAM ≈ 120 МБ → Full-тиру нужно ≥ 240 МБ»). Пусто, если тянет.
// Reality — запасной путь на случай, когда AmneziaWG режут; человек должен понимать, почему
// этот путь ему закрыт, а не видеть безликое «недоступно».
export function fullReasons(report) {
  if (report?.tiers?.full === true) return [];
  return (report?.tiers?.full_checks ?? [])
    .filter((c) => !c.ok)
    .map((c) => `${c.detail}${c.fix ? ` (${c.fix})` : ''}`);
}

// canOverride(report) → показывать ли кнопку «установить на свой страх и риск».
// Источник правды — движок (overridable = провалы есть и все они soft); UI его не переигрывает.
export function canOverride(report) {
  return report?.passed !== true && report?.overridable === true;
}

// validateSetup(f) → { error, field } | { args } — проверка полей Setup и сборка аргументов install.
// field (conf|speed|rootPass|rootPass2|ssid|wifiKey|token) — Setup подсвечивает и прокручивает к
// нему: на длинной форме ошибка у кнопки оказывалась за два экрана от поля. f — поля формы Setup.
export function validateSetup(f) {
  // Активный протокол: Full-протоколы доступны только при fullAvailable — если железо не тянет,
  // форсим AmneziaWG даже когда protocol пришёл из initial (fail-safe направление, как в движке).
  const proto = requiresFull(f.protocol) && !f.fullAvailable ? 'awg' : (f.protocol ?? 'awg');
  const info = protocolInfo(proto);
  let conf = (f.confs?.[proto] ?? '').trim();
  const confError = checkConf(proto, conf);
  if (confError) return { error: confError, field: 'conf' };

  // Скорость канала для Brutal — только когда владелец включил ручной режим (иначе BBR).
  if (proto === 'hysteria2' && f.declareSpeed) {
    const d = Number(f.speedDown), u = Number(f.speedUp);
    if (!Number.isInteger(d) || !Number.isInteger(u) || d <= 0 || u <= 0)
      return { error: 'Скорость канала — целые числа Мбит/с больше нуля (или выключите ручной режим).', field: 'speed' };
    if (d > SPEED_MAX || u > SPEED_MAX)
      return { error: `Скорость канала — не больше ${SPEED_MAX} Мбит/с.`, field: 'speed' };
    conf = withDeclaredSpeed(conf, d, u);
  }

  // Пароль НЕ обрезаем (в нём могут быть значимые пробелы) — сравниваем как есть.
  if (f.rootPass.length < MIN_PASS)
    return { error: `Пароль роутера — минимум ${MIN_PASS} символов.`, field: 'rootPass' };
  if (f.rootPass !== f.rootPass2)
    return { error: 'Пароли роутера не совпадают.', field: 'rootPass2' };

  // Wi-Fi: собираем только если секция показана и (обязательна ИЛИ хоть одно поле заполнено).
  // Пароль Wi-Fi НЕ обрезаем (значимые пробелы); SSID — да (крайние пробелы — частая опечатка).
  let wifiArgs = {};
  if (f.showWifi) {
    const ssidTrim = f.ssid.trim();
    const wifiFilled = ssidTrim.length > 0 || f.wifiKey.length > 0;
    if (f.wifiRequired || wifiFilled) {
      if (ssidTrim.length < 1 || ssidTrim.length > SSID_MAX)
        return { error: `Имя Wi-Fi (SSID) — от 1 до ${SSID_MAX} символов.`, field: 'ssid' };
      if (f.wifiKey.length < WIFI_KEY_MIN || f.wifiKey.length > WIFI_KEY_MAX)
        return { error: `Пароль Wi-Fi — от ${WIFI_KEY_MIN} до ${WIFI_KEY_MAX} символов.`, field: 'wifiKey' };
      wifiArgs = { ssid: ssidTrim, wifi_key: f.wifiKey };
    }
  }

  if (f.token.trim().length === 0)
    return { error: 'Введите код установки — он напечатан в терминале после команды установки.', field: 'token' };

  return {
    args: {
      protocol: proto,
      // Конфиг кладём под ключом протокола (confKey) — тем же, что читает движок по PROTOCOLS.
      [info.confKey]: conf,
      root_password: f.rootPass,
      ...wifiArgs,
      ...(f.dnsProvider ? { dns_provider: f.dnsProvider } : {}),
      domains: parseDomains(f.domainsText),
      // Согласие на пропуск soft-проверок железа несём до самой установки: preflight в движке
      // выполняется ЕЩЁ РАЗ перед snapshot'ом и без этого флага честно откажет.
      ...(f.acceptRisk ? { accept_risk: true } : {}),
      token: f.token.trim(),
    },
  };
}

// Понятные подписи технических шагов движка (STATE_FILE) — что именно идёт сейчас.
export const STEP_LABELS = {
  starting: 'Запуск…',
  preflight: 'Проверка роутера',
  'singbox-download': 'Загрузка компонента для туннеля (~11 МБ)',
  snapshot: 'Сохранение точки отката',
  vpn: 'Настройка VPN-туннеля',
  singbox: 'Настройка VPN-туннеля',
  dns: 'Настройка DNS и split-routing',
  doh: 'Шифрованный DNS',
  wifi: 'Настройка Wi-Fi',
  firewall: 'Firewall и kill-switch',
  'health-check': 'Проверка связи (поднятие туннеля, до ~30 сек)',
};

// installPlan(args) → [{ id, label }] — ожидаемая последовательность шагов этой установки
// для чеклиста Installing: singbox-download только у Full-протоколов, wifi — только при SSID.
// ИНВАРИАНТ: порядок повторяет последовательность шагов движка (как в STEP_LABELS).
export function installPlan(args) {
  const full = requiresFull(args?.protocol);
  const ids = ['preflight'];
  if (full) ids.push('singbox-download');
  ids.push('snapshot', full ? 'singbox' : 'vpn', 'dns', 'doh');
  if (args?.ssid) ids.push('wifi');
  ids.push('firewall', 'health-check');
  return ids.map((id) => ({ id, label: STEP_LABELS[id] }));
}

// explainFail(reason, protocol?) → { error, advice } — адресная диагностика по коду исхода
// (install_progress.reason; error=null → компонент оставляет свой текст). protocol — не показывать
// AWG-пользователю совет про xray-core. ШРАМ: все health:* схлопывались в «сервер молчит, проверьте
// подписку», а причиной бывал баг на роутере (health:dns, health:tunnel:process/route) — код и
// совет обязаны совпадать 1:1 с install.uc.decide_outcome.
export function explainFail(reason, protocol) {
  if (reason === 'health:dns') {
    return {
      error: 'DNS на роутере не ответил.',
      advice: {
        title: 'Роутер настроен правильно, туннель до сервера в порядке — не откликнулся резолвер DNS на самом роутере. Изменения откатаны. Обычно это значит:',
        items: [
          'разовый сбой при первом старте службы — чаще всего помогает просто попробовать ещё раз;',
          'если повторяется — попробуйте другого DNS-провайдера на шаге настройки;',
          'ваш VPN-конфиг тут ни при чём — трогать его не нужно.',
        ],
        action: 'Попробовать снова',
      },
    };
  }
  if (reason === 'health:tunnel:process' || reason === 'health:tunnel:route') {
    return {
      error: reason === 'health:tunnel:process'
        ? 'Служба туннеля не запустилась на роутере.'
        : 'Роутер не смог направить трафик в туннель.',
      advice: {
        title: 'Изменения откатаны. Это похоже на сбой на самом роутере, а не на сервере из вашего конфига:',
        items: [
          'попробуйте ещё раз — разовые сбои при старте службы случаются;',
          'если повторяется — скопируйте журнал ниже и напишите нам в Telegram: конфиг сервера тут ни при чём, чинить нужно не его.',
        ],
        action: 'Попробовать снова',
      },
    };
  }
  if (reason === 'health' || reason === 'health:tunnel:fetch') {
    const items = [
      'подписка у VPN-провайдера закончилась или сервер отключён — проверьте личный кабинет;',
      'конфиг устарел — скачайте свежий файл .conf и загрузите его заново;',
      'провайдер интернета мешает VPN-протоколу — попробуйте конфиг с другим сервером.',
    ];
    // Full-тир на своём сервере (3x-ui) — известная внешняя проблема: свежий xray-core (≥26.7.11)
    // отвергает sing-box-клиента (нашего) на КАЖДОЙ попытке, конфиг при этом выглядит идеально.
    // AWG её не касается (свой протокол, не xray-core) — показываем только по делу.
    if (protocol === 'reality' || protocol === 'hysteria2')
      items.push('сервер на своём VPS через 3x-ui: если сертификаты/подписка точно в порядке — ' +
        'проверьте версию xray-core, актуальные (≥26.7.11) несовместимы с нашим клиентом, нужна v26.6.27 или ниже ' +
        '(docs/kb/concepts/vless-reality.md#серверная-сторона).');
    return {
      error: 'VPN-сервер не ответил — туннель не поднялся.',
      advice: {
        title: 'Роутер настроен правильно, но сервер из вашего VPN-конфига молчит. Изменения откатаны. Чаще всего это значит:',
        items,
        action: 'Загрузить другой конфиг',
      },
    };
  }
  if (reason === 'step:vpn') {
    return {
      error: 'VPN-конфиг не принят.',
      advice: {
        title: 'Изменения откатаны. Проверьте файл конфига:',
        items: [
          'он вставлен целиком — от строки [Interface] до конца;',
          'это конфиг AmneziaWG/WireGuard «для роутеров» (.conf), а не ссылка или QR-код.',
        ],
        action: 'Исправить конфиг',
      },
    };
  }
  if (reason === 'step:singbox') {
    return {
      error: 'Ссылка на сервер не принята.',
      advice: {
        title: 'Изменения откатаны, роутер в исходном состоянии. Проверьте ссылку:',
        items: [
          'она вставлена целиком — от vless:// или hysteria2:// до конца строки;',
          'ссылка свежая: у некоторых панелей она меняется при пересоздании подключения;',
          'если в журнале ниже упоминается конкретный параметр — попросите у сервера ссылку без него.',
        ],
        action: 'Исправить ссылку',
      },
    };
  }
  if (reason && reason.startsWith('step:')) {
    const s = reason.slice(5);
    return {
      error: `Сбой на этапе «${STEP_LABELS[s] ?? s}».`,
      advice: {
        title: 'Изменения откатаны — роутер в исходном состоянии. Что можно сделать:',
        items: [
          'попробуйте ещё раз — разовые сбои случаются;',
          'если повторяется — скопируйте журнал ниже и приложите его к вопросу в сообществе проекта.',
        ],
        action: 'Попробовать снова',
      },
    };
  }
  if (reason === 'singbox-download') {
    return {
      error: 'Не удалось загрузить компонент для этого туннеля.',
      advice: {
        title: 'Изменений на роутере нет. Для VLESS+Reality и Hysteria2 нужно скачать компонент (~11 МБ) с серверов OpenWrt:',
        items: [
          'проверьте, что роутер подключён к интернету (кабель WAN на месте);',
          'иногда загрузка рвётся из-за сети провайдера — просто попробуйте ещё раз;',
          'либо вернитесь и выберите AmneziaWG — он не требует догрузки.',
        ],
        action: 'Попробовать снова',
      },
    };
  }
  if (reason === 'preflight') {
    return {
      error: 'Роутер не прошёл проверку.',
      advice: {
        title: 'Изменений нет. Вернитесь назад — с экрана настройки кнопка «Назад» запустит проверку заново и покажет, что именно не так.',
        items: [],
        action: 'Назад к настройке',
      },
    };
  }
  // Код не пришёл (старый пакет / crash) — прежний общий текст.
  return {
    error: null,
    advice: {
      title: 'Что делать',
      items: [
        'Изменения откатаны — роутер в исходном состоянии, можно пробовать снова.',
        'Частые причины: опечатка в AWG-конфиге (вставлен не целиком), нет интернета на WAN, недоступен сервер VPN-провайдера.',
        'Не получается — скопируйте журнал ниже и приложите его к вопросу в сообществе проекта.',
      ],
      action: 'Изменить данные и повторить',
    },
  };
}

// Первая строка [Peer]→Endpoint — единственное, что безопасно показать из AWG-конфига.
export function endpoint(conf) {
  const m = (conf ?? '').match(/^\s*Endpoint\s*=\s*(.+)$/m);
  return m ? m[1].trim() : '—';
}

// Краткая сводка туннеля без секретов: протокол + адрес сервера.
// Для ссылочных протоколов берём то, что ПОСЛЕ последнего '@' — иначе пароль/uuid (а в hy2-ссылке
// это именно пароль) попал бы на экран подтверждения и в скриншоты.
export function tunnelSummary(args) {
  const info = protocolInfo(args?.protocol);
  if (info.id === 'awg') return `${info.name} → ${endpoint(args?.awg_conf)}`;
  const raw = (args?.[info.confKey] ?? '').trim();
  const at = raw.lastIndexOf('@');
  const host = at >= 0 ? raw.slice(at + 1).match(/^[^?#/]+/) : null;
  return host ? `${info.name} → ${host[0]}` : info.name;
}

// Человекочитаемая метка фильтрации по выбранному id (или дефолт-описание).
export function dnsLabel(id, providers) {
  const p = (providers ?? []).find((x) => x.id === id);
  return p ? `${p.name} — ${p.description}` : (id ?? 'по умолчанию');
}

// --- Состояние туннеля в панели (протокол-независимо) ---
//
// Здоровье приходит из движка одним полем status.tunnel_health ("up"|"down") — он знает, чем
// мерить каждый протокол (AWG — рукопожатие сервера, Reality — живой sing-box + поднятый TUN).
// Панель НЕ пересчитывает это сама: раньше она судила по AWG-рукопожатию и на рабочем Reality
// показывала «VPN не работает», ведя заменять AWG-конфиг (движок такую замену и не принял бы).

// heroKind(s) → какой главный баннер показать: 'none' | 'up' | 'down'. Протокол берётся отдельно
// (heroProtocol), потому что ФОРМУЛИРОВКА зависит от него: у AWG есть доказательство «сервер
// отвечал N сек назад», у Full-протоколов — только «туннель поднят», поэтому обещать «всё
// работает» там нельзя (см. tunnel_health в engine/install/install.uc).
export function heroKind(s) {
  if (!s?.installed) return 'none';
  return s.tunnel_health === 'up' ? 'up' : 'down';
}

// tunnelFallback(s) → что предложить, когда активный туннель не поднимается.
//   { action: 'install' } — железо тянет Full, но бинаря нет: предложить догрузку;
//   { action: 'switch', targets: [...] } — куда можно переключиться прямо сейчас;
//   null — предлагать нечего (слабое железо и активен AWG).
// Ключевое: с AmneziaWG (UDP) ведём на Reality (TCP) — Hysteria2 тоже UDP и упал бы вместе с AWG,
// поэтому он в подсказке «не открывается» НЕ фигурирует (ADR 0004: оси общие → фолбэк бесполезен).
export function tunnelFallback(s) {
  if (!s?.installed) return null;
  const active = protocolInfo(s.protocol).id;
  if (active === 'awg') {
    if (s.full_installed) return { action: 'switch', targets: ['reality'] };
    if (s.full_capable) return { action: 'install' };
    return null;
  }
  // Активен Full-протокол: другой Full рядом (бинарь уже стоит) + всегда доступный возврат на AWG.
  const other = active === 'reality' ? 'hysteria2' : 'reality';
  return { action: 'switch', targets: [other, 'awg'] };
}

// switchTargets(s) → протоколы, на которые можно переключиться из текущего состояния.
// AWG доступен всегда; Full-протоколы — только когда бинарь уже стоит (иначе сначала кнопка
// догрузки, см. tunnelFallback).
export function switchTargets(s) {
  const active = protocolInfo(s?.protocol).id;
  return protocolList().filter((p) => p.id !== active && (!p.full || s?.full_installed === true));
}

// tunnelRowText(s) → значение строки «Туннель» в сводке. У AWG — возраст рукопожатия (сервер
// отвечал), у Full-протоколов — факт поднятого туннеля, без обещаний про сервер.
export function tunnelRowText(s) {
  const info = protocolInfo(s?.protocol);
  if (info.full)
    return s?.tunnel_health === 'up' ? `поднят (${info.name})` : 'не поднят';
  return hs(s?.awg_handshake_age);
}

// Возраст последнего AWG-handshake → человеческая строка для панели.
export function hs(age) {
  if (age == null) return 'нет ответа от сервера';
  if (age < 0) return '—';
  if (age < 120) return `отвечал ${age} с назад`;
  return `отвечал ${Math.floor(age / 60)} мин назад`;
}
