// mock-router.mjs — герметичный стенд для e2e-смоука мастера (playwright).
//
// Раздаёт СОБРАННЫЙ бандл (package/cheburnet/files/web — то, что реально едет в пакет)
// и отвечает на POST /ubus как rpcd с движком: happy-path установки. Реальный
// HTTP/ACL-путь проверяет tests/qemu/webui.sh — здесь проверяем рендер и клики.
//
//   node tests/e2e/mock-router.mjs   # слушает :4317 (запускает playwright webServer)

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { join, extname, resolve } from 'node:path';

// E2E_PORT — обход: в WSL mirrored-режиме Windows/Hyper-V иногда резервирует диапазон с 4317.
const PORT = Number(process.env.E2E_PORT ?? 4317);
const WEB_ROOT = resolve(import.meta.dirname, '../../../package/cheburnet/files/web');
const TOKEN = 'TESTTOKEN';

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png' };

// Состояние «роутера»: до установки → в процессе → установлен.
let installed = false;
let installPolls = 0;
// Режим «health-check не прошёл»: движок откатился, done-маркер fail + reason=health.
// Включается POST /__fail-health — проверка адресной диагностики UI.
let failHealth = false;
// Режим «установлено, но туннель не работает» — проверка hero-баннера панели. Для AWG это
// молчащий сервер (handshake=null), для Reality — не поднятый sing-box/TUN.
let vpnDown = false;
// Full-тир и протокол: панель ветвится по full_capable/full_installed/protocol — сценарии
// выставляют их через POST /__set (JSON с любым подмножеством полей ниже).
let fullCapable = false;
let fullInstalled = false;
let protocol = 'awg';
// Исход фоновых операций панели (install_full_tier / switch_to_reality / replace_*):
// 'ok' | 'fail' — сценарии проверяют и успех, и fail-safe-ветку («прежний туннель возвращён»).
let bgResult = 'ok';
// Машинная причина провала фоновой операции (движок пишет её в REASON_FILE): панель по ней
// говорит адресно — например «no-space» для догрузки sing-box вместо совета про интернет.
let bgReason = '';
// Текущая фоновая операция панели (не установка мастером): { polls, method }.
let bg = null;
// adminLocked=true — admin-методы без сессии отбиваются кодом 6 (PERMISSION_DENIED), как
// настоящий rpcd ACL; session.login с ADMIN_PASS выдаёт сессию. Проверка модалки входа.
let adminLocked = false;
const ADMIN_PASS = 'panel-pass-1';
const GOOD_SESSION = 'cafecafecafecafecafecafecafecafe';
// Журнал вызовов методов — сценарии ассертят, что панель зовёт ПРАВИЛЬНЫЙ метод
// (replace_reality_conf при protocol=reality, а не replace_awg_conf).
let calls = [];
// Аргументы последнего install — сценарий проверяет, что accept_risk реально доехал до движка
// (без него preflight в run.uc откажет второй раз, и «красная кнопка» была бы обманом).
let lastInstall = null;
// Аргументы последней фоновой операции панели — ассерт «объявленная скорость доехала до движка».
let lastBg = null;
// Железо роутера для preflight: 'ok' | 'weak' (провалены только soft — флеш/RAM, пропуск
// разрешён) | 'unsupported' (hard-провал arch — пропуск невозможен).
let hw = 'ok';
// Проверки, пропущенные при установке (status.forced) — плашка в панели.
let forced = [];
// Чего не хватает для Full-тира (status.full_missing): сценарий может задать явно, чтобы
// проверить адресность подсказки («не хватает места» ≠ «слабый процессор»).
let fullMissing = null;
// Свой список сайтов напрямую — движок хранит его между вызовами, панель читает его после входа.
let userDomains = ['example.com'];

const ADMIN_METHODS = new Set([
  'set_mode', 'update_list', 'service_restart', 'set_dns_provider',
  'replace_awg_conf', 'replace_reality_conf', 'replace_hysteria2_conf', 'install_full_tier',
  'switch_to_reality', 'switch_to_hysteria2', 'switch_to_awg', 'factory_reset',
  // Диагностика — read, но admin: даже вычищенная, она раскрывает топологию и логи.
  'diagnostics',
  // install_token — тем более admin: токен и есть признак «это владелец» на пути установки.
  'install_token',
  // Свой список — admin в обе стороны (rpcd-acl.json: get_domains в read, set_domains в write):
  // он говорит о привычках дома, поэтому не отдаётся без сессии.
  'get_domains', 'set_domains',
]);

const PROVIDERS = [
  { id: 'adguard', name: 'AdGuard DNS', description: 'блокирует рекламу и трекеры' },
  { id: 'adguard-family', name: 'AdGuard Family', description: 'реклама + сайты 18+' },
];

function ubusReply(method, args, session) {
  calls.push(method);
  // ACL как у настоящего rpcd: admin-методы без сессии → статус 6 (PERMISSION_DENIED).
  if (adminLocked && ADMIN_METHODS.has(method) && session !== GOOD_SESSION)
    return [6, null];
  switch (method) {
    case 'status':
      return [0, {
        installed,
        wireless_present: true,
        dns_providers: PROVIDERS,
        dns_provider: 'adguard',
        dns_provider_desc: PROVIDERS[0],
        protocol,
        full_capable: fullCapable,
        // Чего не хватает для Full — движок отдаёт списком, панель называет причину (не прячет
        // кнопку молча). Слабое железо в сценариях = не хватает RAM.
        full_missing: fullMissing ?? (fullCapable ? [] : ['ram']),
        full_installed: fullInstalled,
        forced,
        ...((installed || vpnDown) && {
          installed: true,
          mode: 'home', direct_domains: userDomains.length, direct_list_loaded: true, imported_domains: 0,
          // Здоровье туннеля движок отдаёт ОДНИМ полем для любого протокола. Раньше мок возвращал
          // handshake=12 и при protocol=reality — врал в пользу зелёного и скрыл реальный баг
          // (панель судила о Reality по AWG-рукопожатию и показывала «VPN не работает»).
          tunnel_health: vpnDown ? 'down' : 'up',
          // У Full-протоколов рукопожатия НЕТ — поле обязано быть null, как на живом роутере.
          awg_handshake_age: protocol === 'awg' ? (vpnDown ? null : 12) : null,
          dns_up: true, doh_up: true, ssid: 'TestWifi',
        }),
      }];
    // Фоновые операции панели: старт → done за 2 поллинга, исход по bgResult.
    case 'install_full_tier':
    case 'switch_to_reality':
    case 'switch_to_hysteria2':
    case 'switch_to_awg':
    case 'replace_reality_conf':
    case 'replace_hysteria2_conf':
    case 'replace_awg_conf':
      bg = { polls: 0, method, args };
      lastBg = { method, args };
      return [0, { status: 'started', pid: 111 }];
    // Диагностика: движок отдаёт УЖЕ вычищенный текст и список вырезанного. Мок возвращает текст
    // с маской внутри — так e2e проверяет, что панель показывает содержимое человеку до отправки
    // и честно называет, что убрано (обещание «мы вычистили» иначе непроверяемо).
    case 'diagnostics':
      return [0, {
        status: 'ok',
        text: '════ cheburnet — диагностика ════\nPrivateKey = <удалено>\nEndpoint = 203.0.113.10:51820\n',
        removed: ['ключи туннеля', 'пароль Wi-Fi'],
      }];
    // Сброс — такая же фоновая операция, как замена/переключение: панель ждёт завершения через
    // общий канал install_progress, а не говорит «запущен» и умывает руки.
    case 'factory_reset':
      if (args.confirm !== 'RESET') return [0, { error: 'confirm должен быть ровно "RESET"' }];
      bg = { polls: 0, method, args };
      lastBg = { method, args };
      return [0, { status: 'started', pid: 222 }];
    // Свежий токен после сброса: движок выпускает его в reset.uc, панель ведёт им в мастер.
    case 'install_token':
      return [0, { status: 'ok', token: TOKEN }];
    // Свой список сайтов напрямую. Движок отбраковывает строки, не похожие на домен, и возвращает
    // их отдельно — панель обязана назвать пропущенное, а не молча сохранить остаток.
    case 'get_domains':
      return [0, { user_domains: userDomains }];
    case 'set_domains': {
      const given = args.domains ?? [];
      const rejected = given.filter((d) => !/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9-]+)*$/i.test(d));
      userDomains = given.filter((d) => !rejected.includes(d));
      return [0, { user_domains: userDomains.length, direct_domains: userDomains.length, rejected }];
    }
    case 'check_lan_conflict':
      return [0, { conflict: false }];
    case 'preflight':
      // Слабое железо: провалены ТОЛЬКО soft-проверки (флеш/RAM) → движок отдаёт overridable,
      // мастер предлагает установку на свой страх и риск.
      if (hw === 'weak')
        return [0, {
          passed: false, total: 6, failed: 2, hard_failed: 0, soft_failed: 2, overridable: true,
          checks: [
            { id: 'arch', ok: true, severity: 'hard', detail: 'arch = mips' },
            { id: 'flash', ok: false, severity: 'soft', detail: 'свободный флеш ≈ 12 МБ', fix: 'нужно ≥ 16 МБ свободно' },
            { id: 'ram', ok: false, severity: 'soft', detail: 'RAM ≈ 60 МБ', fix: 'нужно ≥ 112 МБ' },
          ],
          tiers: { light: false, full: false },
        }];
      // Неподдерживаемая платформа: hard-провал — пакетов под неё нет, пропуск невозможен.
      if (hw === 'unsupported')
        return [0, {
          passed: false, total: 6, failed: 2, hard_failed: 1, soft_failed: 1, overridable: false,
          checks: [
            { id: 'arch', ok: false, severity: 'hard', detail: 'arch = ppc', fix: 'нужна одна из поддерживаемых' },
            { id: 'ram', ok: false, severity: 'soft', detail: 'RAM ≈ 60 МБ', fix: 'нужно ≥ 112 МБ' },
          ],
          tiers: { light: false, full: false },
        }];
      // hw='full' — железо ТЯНЕТ Full-тир: мастер даёт выбор протокола (и предвыбирает Reality).
      return [0, {
        passed: true, total: 6, failed: 0, hard_failed: 0, soft_failed: 0, overridable: false,
        checks: [
          { id: 'arch', ok: true, severity: 'hard', detail: 'arch = aarch64' },
          { id: 'ram', ok: true, severity: 'soft', detail: 'RAM ≈ 485 МБ' },
          { id: 'deps', ok: true, severity: 'hard', detail: 'зависимости устанавливаются' },
        ],
        tiers: hw === 'full'
          ? { light: true, full: true, full_checks: [] }
          : {
              light: true, full: false,
              full_checks: [
                { id: 'full_ram', ok: false, detail: 'RAM ≈ 120 МБ', fix: 'Full-тиру нужно ≥ 240 МБ' },
              ],
            },
      }];
    case 'install':
      if (args.token !== TOKEN) return [0, { error: 'неверный install-токен' }];
      installPolls = 0;
      lastInstall = args;
      // Движок пишет пропущенные проверки в install.json → панель их показывает.
      if (args.accept_risk === true) forced = ['flash', 'ram'];
      return [0, { started: true }];
    case 'install_progress':
      // Канал общий с фоновыми операциями панели — они в приоритете, если запущены.
      if (bg) {
        bg.polls += 1;
        if (bg.polls < 2) return [0, { done: false, step: bg.method, log: `${bg.method}…` }];
        const op = bg; bg = null;
        if (bgResult === 'ok') {
          if (op.method === 'install_full_tier') fullInstalled = true;
          // Сброс возвращает роутер в ненастроенное состояние — как на живой системе.
          if (op.method === 'factory_reset') installed = false;
          // switch_to_<id> → активным становится <id>: так мок не приходится править на каждый
          // новый протокол (и он не может «забыть» один из них).
          const sw = op.method.match(/^switch_to_(.+)$/);
          if (sw) protocol = sw[1];
          return [0, { done: true, result: 'ok', step: 'готово', log: `${op.method}: ok` }];
        }
        return [0, { done: true, result: 'fail', reason: bgReason, step: op.method,
                     log: `${op.method}: откат — прежнее состояние возвращено` }];
      }
      installPolls += 1;
      if (installPolls < 2) return [0, { done: false, step: 'vpn', log: 'шаг vpn…' }];
      // Ещё один незавершённый тик на шаге health-check — самый долгий (поднятие туннеля).
      // Даёт UI показать усиленный текст предупреждения про обрыв связи именно здесь.
      if (installPolls < 3 && !failHealth)
        return [0, { done: false, step: 'health-check', log: 'проверка связи через туннель…' }];
      if (failHealth)
        return [0, { done: true, result: 'fail', reason: 'health', step: 'health-check',
                     log: 'install: откат — health-check не пройден\ninstall: откат выполнен' }];
      installed = true;
      return [0, { done: true, result: 'ok', step: 'готово', log: 'установка завершена' }];
    default:
      return [0, {}];
  }
}

createServer(async (req, res) => {
  // Сброс состояния между тестами (spec зовёт в beforeEach) — иначе installed=true
  // от первого прохода утекает во второй и мастер открывает сразу панель.
  if (req.method === 'POST' && req.url === '/__reset') {
    installed = false;
    installPolls = 0;
    failHealth = false;
    vpnDown = false;
    fullCapable = false;
    fullInstalled = false;
    protocol = 'awg';
    bgResult = 'ok';
    bgReason = '';
    bg = null;
    adminLocked = false;
    calls = [];
    lastInstall = null;
    lastBg = null;
    hw = 'ok';
    forced = [];
    fullMissing = null;
    userDomains = ['example.com'];
    res.end('ok');
    return;
  }
  // Установить произвольное подмножество состояния (сценарии панели/Full-тира).
  if (req.method === 'POST' && req.url === '/__set') {
    let body = '';
    for await (const chunk of req) body += chunk;
    const st = JSON.parse(body);
    if ('installed' in st) installed = st.installed;
    if ('fullCapable' in st) fullCapable = st.fullCapable;
    if ('fullInstalled' in st) fullInstalled = st.fullInstalled;
    if ('protocol' in st) protocol = st.protocol;
    if ('bgResult' in st) bgResult = st.bgResult;
    if ('bgReason' in st) bgReason = st.bgReason;
    if ('adminLocked' in st) adminLocked = st.adminLocked;
    if ('hw' in st) hw = st.hw;
    if ('forced' in st) forced = st.forced;
    if ('fullMissing' in st) fullMissing = st.fullMissing;
    res.end('ok');
    return;
  }
  // Журнал вызванных методов — ассерты «панель позвала правильный метод».
  if (req.method === 'GET' && req.url === '/__calls') {
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify(calls));
    return;
  }
  // Аргументы последнего install — ассерт «accept_risk доехал до движка».
  if (req.method === 'GET' && req.url === '/__last-bg') {
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify(lastBg));
    return;
  }
  if (req.method === 'GET' && req.url === '/__last-install') {
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify(lastInstall));
    return;
  }
  if (req.method === 'POST' && req.url === '/__fail-health') {
    failHealth = true;
    res.end('ok');
    return;
  }
  if (req.method === 'POST' && req.url === '/__vpn-down') {
    vpnDown = true;
    res.end('ok');
    return;
  }
  if (req.method === 'POST' && req.url === '/ubus') {
    let body = '';
    for await (const chunk of req) body += chunk;
    const rpc = JSON.parse(body);
    const [session, object, method, args] = rpc.params;
    let result;
    if (object === 'cheburnet') {
      result = ubusReply(method, args ?? {}, session);
    } else if (object === 'session' && method === 'login') {
      // Как настоящий rpcd: верный пароль → сессия, неверный → отказ доступа.
      result = (args?.password === ADMIN_PASS)
        ? [0, { ubus_rpc_session: GOOD_SESSION }]
        : [6, null];
    } else {
      result = [0, {}];
    }
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({ jsonrpc: '2.0', id: rpc.id, result }));
    return;
  }

  // Статика: /cheburnet/ → index.html, /cheburnet/assets/* → файлы бандла.
  let path = req.url.split('?')[0];
  if (path === '/cheburnet' || path === '/cheburnet/') path = '/cheburnet/index.html';
  try {
    const data = await readFile(join(WEB_ROOT, path.replace('/cheburnet/', '')));
    res.setHeader('Content-Type', MIME[extname(path)] ?? 'application/octet-stream');
    res.end(data);
  } catch {
    res.statusCode = 404;
    res.end('not found');
  }
}).listen(PORT, () => console.log(`mock-router на http://127.0.0.1:${PORT}/cheburnet/`));
