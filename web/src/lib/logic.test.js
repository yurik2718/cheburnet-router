// logic.test.js — юниты чистой логики мастера/панели (vitest, без DOM и сети).
//
//   npm test   (vitest run)
//
// Проверяем границу с пользователем: валидацию формы Setup (validateSetup зеркалит
// ubus-границу движка), карту причин провала установки (explainFail) и разбор конфигов
// для сводки Confirm — то, что раньше жило внутри компонентов и покрывалось только e2e.

import { describe, it, expect } from 'vitest';
import {
  MIN_PASS, SSID_MAX, WIFI_KEY_MIN, WIFI_KEY_MAX,
  parseDomains, validateSetup, explainFail, STEP_LABELS, installPlan,
  endpoint, tunnelSummary, dnsLabel, hs,
  softRisks, canOverride, SOFT_RISK, FORCED_LABELS,
  heroKind, tunnelFallback, switchTargets, tunnelRowText, fullReasons, explainFullTierFail,
  fullMissingText, FULL_MISSING_LABELS,
  PROTOCOLS, PROTOCOL_ORDER, protocolList, protocolInfo, requiresFull, defaultProtocol,
  withDeclaredSpeed, SPEED_DEFAULTS, SPEED_MAX, SUPPORT, checkConf, BRUTAL_WARNING,
} from './logic.js';

// Контакт поддержки показывается на трёх экранах и вшивается в прошивку на годы. Проверяем
// инвариант, который ломается копипастой: ссылка и подпись должны указывать на одного адресата.
describe('SUPPORT — контакт поддержки', () => {
  it('ссылка Telegram соответствует показанному имени', () => {
    expect(SUPPORT.telegram.startsWith('@')).toBe(true);
    expect(SUPPORT.telegramUrl).toBe(`https://t.me/${SUPPORT.telegram.slice(1)}`);
  });
  it('указана долговечная страница проекта — её содержимое правится без перепрошивки', () => {
    expect(SUPPORT.page).toMatch(/^https:\/\//);
  });
  it('ссылка поддержки проекта (футер) — https и вшивается на годы', () => {
    expect(SUPPORT.donateUrl).toMatch(/^https:\/\//);
  });
});

// Валидная база формы: каждый тест ломает ровно одно поле. Конфиги — по протоколам (confs),
// как их и хранит Setup: переключение выбора не должно терять уже вставленное.
function fields(over = {}) {
  return {
    protocol: 'awg',
    fullAvailable: false,
    confs: { awg: '[Interface]\nPrivateKey = x\n', reality: '', hysteria2: '' },
    declareSpeed: false,
    rootPass: 'longenough',
    rootPass2: 'longenough',
    showWifi: false,
    wifiRequired: false,
    ssid: '',
    wifiKey: '',
    dnsProvider: '',
    domainsText: 'ru',
    token: 'TOK',
    ...over,
  };
}

describe('parseDomains', () => {
  it('режет по строкам, запятым и пробелам, отбрасывая пустое', () => {
    expect(parseDomains('ru\nexample.com, example.org  test.net')).toEqual([
      'ru', 'example.com', 'example.org', 'test.net',
    ]);
  });

  it('пустой и чисто-пробельный вход → пустой список', () => {
    expect(parseDomains('')).toEqual([]);
    expect(parseDomains('  \n , ,\n')).toEqual([]);
  });
});

// Каталог протоколов — источник соответствия «протокол → поле конфига → ubus-метод» для всего UI.
// Он обязан совпадать с PROTOCOLS движка: разъезд тут = панель зовёт метод не того протокола.
describe('каталог протоколов (три оси покрытия)', () => {
  it('порядок показа и полнота: awg, reality, hysteria2', () => {
    expect(PROTOCOL_ORDER).toEqual(['awg', 'reality', 'hysteria2']);
    expect(protocolList().map((p) => p.id)).toEqual(PROTOCOL_ORDER);
  });

  // why видно у всех трёх вариантов сразу — там ровно одна мысль; остальное уезжает в whyMore
  // («Подробнее»). Разъезд обратно в три абзаца делает экран выбора нечитаемым.
  it('короткое объяснение остаётся коротким, длинное живёт отдельно', () => {
    for (const p of protocolList()) {
      expect(p.why.length).toBeLessThanOrEqual(110);
      expect(p.whyMore.length).toBeGreaterThan(20);
    }
  });

  it('у каждого протокола есть симптом, объяснение и имена ubus-полей/методов', () => {
    for (const p of protocolList()) {
      expect(p.symptom.length).toBeGreaterThan(10);
      expect(p.why.length).toBeGreaterThan(20);
      expect(p.confKey).toMatch(/_conf$/);
      expect(p.switchMethod).toBe(`switch_to_${p.id}`);
      expect(p.replaceMethod.startsWith('replace_')).toBe(true);
    }
  });

  it('confKey совпадает с ключами движка (awg_conf / reality_conf / hysteria2_conf)', () => {
    expect(PROTOCOLS.awg.confKey).toBe('awg_conf');
    expect(PROTOCOLS.reality.confKey).toBe('reality_conf');
    expect(PROTOCOLS.hysteria2.confKey).toBe('hysteria2_conf');
  });

  it('Full-тир требуют только userspace-протоколы; неизвестный id → дефолт (fail-safe)', () => {
    expect(requiresFull('awg')).toBe(false);
    expect(requiresFull('reality')).toBe(true);
    expect(requiresFull('hysteria2')).toBe(true);
    expect(protocolInfo('bogus').id).toBe('awg');
    expect(requiresFull('bogus')).toBe(false);
  });

  // Дефолт мастера: на слабом железе выбора нет, на Full-железе предвыбираем Reality — он
  // закрывает самую частую поломку «VPN вообще не поднимается» (ADR 0004, «Дефолты и гейтинг»).
  it('дефолт мастера зависит от железа', () => {
    expect(defaultProtocol(false)).toBe('awg');
    expect(defaultProtocol(true)).toBe('reality');
  });
});

// Проверка формата ДО отправки. Движок отказал бы и сам, но его отказ стоит цикла «установка →
// откат» (в панели — с фоновой операцией и снимком). Ссылка, вставленная вместо .conf, — самая
// частая путаница, потому что оба поля выглядят одинаково.
describe('checkConf — формат конфига ловится в форме', () => {
  it('пусто → просьба вставить (для .conf — ещё и загрузить файлом)', () => {
    expect(checkConf('awg', '   ')).toMatch(/загрузите/i);
    expect(checkConf('reality', '')).toMatch(/vless:\/\//);
    expect(checkConf('hysteria2', null)).toMatch(/hysteria2:\/\//);
  });

  it('правильный формат проходит, включая JSON-конфиг sing-box у Full-протоколов', () => {
    expect(checkConf('awg', '[Interface]\nPrivateKey = x')).toBe('');
    expect(checkConf('reality', 'vless://u@h:443?security=reality')).toBe('');
    expect(checkConf('hysteria2', 'hy2://pw@h:443')).toBe('');
    expect(checkConf('hysteria2', 'hysteria2://pw@h:443')).toBe('');
    expect(checkConf('reality', '{"outbounds":[]}')).toBe('');
    expect(checkConf('hysteria2', '  {"outbounds":[]}')).toBe('');
  });

  it('перепутанные форматы отбиваются с подсказкой про нужный', () => {
    expect(checkConf('awg', 'vless://u@h:443')).toMatch(/\[Interface\]/);
    expect(checkConf('reality', '[Interface]\nPrivateKey = x')).toMatch(/vless:\/\//);
    expect(checkConf('hysteria2', 'vless://u@h:443')).toMatch(/hysteria2:\/\//);
  });

  // Обрезанный конфиг — вторая частая беда: человек копирует со второй строки.
  it('конфиг без шапки [Interface] не принимается', () => {
    expect(checkConf('awg', 'PrivateKey = x\nAddress = 10.0.0.2/32')).toMatch(/\[Interface\]/);
  });
});

describe('validateSetup — конфиг туннеля', () => {
  it('ссылка вместо .conf ловится до отправки (иначе цикл установка → откат)', () => {
    const r = validateSetup(fields({ confs: { awg: 'vless://u@h:443' } }));
    expect(r.error).toMatch(/\[Interface\]/);
    expect(r.args).toBeUndefined();
  });

  it('awg: пустой конфиг → просьба вставить/загрузить', () => {
    const r = validateSetup(fields({ confs: { awg: '   ' } }));
    expect(r.error).toMatch(/загрузите/i);
  });

  it('reality при fullAvailable: пустая ссылка → просьба про vless://', () => {
    const r = validateSetup(fields({ protocol: 'reality', fullAvailable: true, confs: { reality: ' ' } }));
    expect(r.error).toMatch(/vless:\/\//);
  });

  it('hysteria2 при fullAvailable: пустая ссылка → просьба именно про hysteria2://', () => {
    const r = validateSetup(fields({ protocol: 'hysteria2', fullAvailable: true, confs: { hysteria2: '' } }));
    expect(r.error).toMatch(/hysteria2:\/\//);
  });

  it('Full-протокол БЕЗ fullAvailable форсится в awg (железо не тянет)', () => {
    for (const proto of ['reality', 'hysteria2']) {
      const r = validateSetup(fields({
        protocol: proto, fullAvailable: false,
        confs: { awg: '[Interface]\nPrivateKey = x\n', reality: 'vless://x', hysteria2: 'hy2://pw@h:443' },
      }));
      expect(r.error).toBeUndefined();
      expect(r.args.protocol).toBe('awg');
      expect(r.args.awg_conf).toBeDefined();
      expect(r.args.reality_conf).toBeUndefined();
      expect(r.args.hysteria2_conf).toBeUndefined();
    }
  });

  // Конфиги других протоколов остаются в форме (человек мог их сравнивать), но в args уходит
  // РОВНО один — чужие credentials в payload установки незачем.
  it('в args уходит только конфиг активного протокола', () => {
    const all = { awg: '[Interface]\n', reality: 'vless://x', hysteria2: 'hysteria2://pw@h:443' };
    const r = validateSetup(fields({ protocol: 'hysteria2', fullAvailable: true, confs: all }));
    expect(r.args.protocol).toBe('hysteria2');
    expect(r.args.hysteria2_conf).toBe('hysteria2://pw@h:443');
    expect('reality_conf' in r.args).toBe(false);
    expect('awg_conf' in r.args).toBe(false);
  });
});

// Brutal: скорость канала объявляет ТОЛЬКО владелец и только осознанно. Дефолт (без up/down) —
// это BBR в sing-box; выдуманная цифра включила бы Brutal и могла сделать связь хуже молча.
describe('validateSetup — скорость канала для Hysteria2 (Brutal)', () => {
  const hy2 = (over = {}) => fields({
    protocol: 'hysteria2', fullAvailable: true,
    confs: { hysteria2: 'hysteria2://pw@h.example.com:443?sni=s' },
    ...over,
  });

  it('без ручного режима ссылка не переписывается (остаётся BBR)', () => {
    const r = validateSetup(hy2());
    expect(r.args.hysteria2_conf).toBe('hysteria2://pw@h.example.com:443?sni=s');
  });

  it('ручной режим дописывает down/up в ссылку', () => {
    const r = validateSetup(hy2({ declareSpeed: true, speedDown: 80, speedUp: 20 }));
    expect(r.args.hysteria2_conf).toBe('hysteria2://pw@h.example.com:443?sni=s&down=80&up=20');
  });

  it('нецелая/нулевая/запредельная скорость → ошибка, а не молчаливое искажение', () => {
    expect(validateSetup(hy2({ declareSpeed: true, speedDown: 0, speedUp: 10 })).error).toMatch(/Скорость/);
    expect(validateSetup(hy2({ declareSpeed: true, speedDown: 1.5, speedUp: 10 })).error).toMatch(/Скорость/);
    expect(validateSetup(hy2({ declareSpeed: true, speedDown: '', speedUp: 10 })).error).toMatch(/Скорость/);
    expect(validateSetup(hy2({ declareSpeed: true, speedDown: SPEED_MAX + 1, speedUp: 10 })).error)
      .toMatch(new RegExp(String(SPEED_MAX)));
  });

  it('ручной режим у других протоколов ничего не меняет (Brutal есть только у Hysteria2)', () => {
    const r = validateSetup(fields({ declareSpeed: true, speedDown: 80, speedUp: 20 }));
    expect(r.args.awg_conf).toBe('[Interface]\nPrivateKey = x');
  });

  // Предупреждение показывается в мастере и в панели. Две копии одного текста разъезжаются при
  // первой правке, поэтому оно одно — и обязано называть последствие («хуже»), иначе человек не
  // свяжет завышенную цифру с обрывами: ошибок в логах при этом не будет.
  it('предупреждение про завышенную скорость одно на весь UI и называет последствие', () => {
    expect(BRUTAL_WARNING).toMatch(/хуже/);
    expect(BRUTAL_WARNING).toMatch(/реально держит/);
  });

  it('консервативные подсказки существуют и отдача не больше приёма', () => {
    expect(SPEED_DEFAULTS.down).toBeGreaterThan(0);
    expect(SPEED_DEFAULTS.up).toBeGreaterThan(0);
    expect(SPEED_DEFAULTS.up).toBeLessThanOrEqual(SPEED_DEFAULTS.down);
  });
});

describe('withDeclaredSpeed — наши локальные параметры полосы', () => {
  it('добавляет параметры к ссылке без query и с query', () => {
    expect(withDeclaredSpeed('hysteria2://pw@h:443', 50, 10)).toBe('hysteria2://pw@h:443?down=50&up=10');
    expect(withDeclaredSpeed('hy2://pw@h:443?sni=s', 50, 10)).toBe('hy2://pw@h:443?sni=s&down=50&up=10');
  });

  // #fragment — метка подключения; параметры ПОСЛЕ него парсер не увидит вовсе.
  it('вставляет параметры ДО #метки, а не в конец строки', () => {
    expect(withDeclaredSpeed('hysteria2://pw@h:443?sni=s#Дом', 50, 10))
      .toBe('hysteria2://pw@h:443?sni=s&down=50&up=10#Дом');
  });

  it('уже указанную владельцем полосу не переписываем (уважаем вставленное)', () => {
    const link = 'hysteria2://pw@h:443?up=5&down=5';
    expect(withDeclaredSpeed(link, 100, 100)).toBe(link);
  });

  it('не-hy2 вход не трогаем вовсе (JSON-конфиг, vless, пусто)', () => {
    expect(withDeclaredSpeed('{"outbounds":[]}', 50, 10)).toBe('{"outbounds":[]}');
    expect(withDeclaredSpeed('vless://u@h:443', 50, 10)).toBe('vless://u@h:443');
    expect(withDeclaredSpeed('', 50, 10)).toBe('');
    expect(withDeclaredSpeed(null, 50, 10)).toBe('');
  });

  it('мусорные значения → ссылка без полосы (лучше BBR, чем выдуманный Brutal)', () => {
    expect(withDeclaredSpeed('hysteria2://pw@h:443', 0, 10)).toBe('hysteria2://pw@h:443');
    expect(withDeclaredSpeed('hysteria2://pw@h:443', 'быстро', 10)).toBe('hysteria2://pw@h:443');
    expect(withDeclaredSpeed('hysteria2://pw@h:443', SPEED_MAX + 1, 10)).toBe('hysteria2://pw@h:443');
  });
});

describe('validateSetup — пароль роутера', () => {
  it(`короче ${MIN_PASS} → ошибка с минимумом`, () => {
    const r = validateSetup(fields({ rootPass: '1234567', rootPass2: '1234567' }));
    expect(r.error).toContain(String(MIN_PASS));
  });

  it('пароль не обрезается: пробелы значимы и в длине, и в сравнении', () => {
    // 8 символов с ведущим пробелом — валиден как есть.
    const ok = validateSetup(fields({ rootPass: ' 1234567', rootPass2: ' 1234567' }));
    expect(ok.error).toBeUndefined();
    expect(ok.args.root_password).toBe(' 1234567');
    // Расхождение только в пробеле → «не совпадают».
    const bad = validateSetup(fields({ rootPass: 'longenough', rootPass2: 'longenough ' }));
    expect(bad.error).toMatch(/не совпадают/);
  });
});

describe('validateSetup — Wi-Fi', () => {
  it('секция скрыта (нет радио) → поля игнорируются даже заполненные', () => {
    const r = validateSetup(fields({ showWifi: false, ssid: 'X', wifiKey: 'short' }));
    expect(r.error).toBeUndefined();
    expect(r.args.ssid).toBeUndefined();
  });

  it('необязательный и пустой → в args не попадает', () => {
    const r = validateSetup(fields({ showWifi: true, wifiRequired: false }));
    expect(r.error).toBeUndefined();
    expect(r.args.ssid).toBeUndefined();
    expect(r.args.wifi_key).toBeUndefined();
  });

  it('обязательный (радио точно есть) и пустой → ошибка про SSID', () => {
    const r = validateSetup(fields({ showWifi: true, wifiRequired: true }));
    expect(r.error).toMatch(/SSID/);
  });

  it('необязательный, но начатый → валидируется целиком (ключ короче минимума)', () => {
    const r = validateSetup(fields({ showWifi: true, ssid: 'MyHome', wifiKey: '1234567' }));
    expect(r.error).toContain(String(WIFI_KEY_MIN));
  });

  it('SSID длиннее лимита → ошибка', () => {
    const r = validateSetup(fields({
      showWifi: true, ssid: 'x'.repeat(SSID_MAX + 1), wifiKey: 'goodkey123',
    }));
    expect(r.error).toContain(String(SSID_MAX));
  });

  it('ключ длиннее WPA-максимума → ошибка', () => {
    const r = validateSetup(fields({
      showWifi: true, ssid: 'MyHome', wifiKey: 'x'.repeat(WIFI_KEY_MAX + 1),
    }));
    expect(r.error).toContain(String(WIFI_KEY_MAX));
  });

  it('SSID обрезается, ключ — нет (значимые пробелы)', () => {
    const r = validateSetup(fields({ showWifi: true, ssid: ' MyHome ', wifiKey: ' pass1234' }));
    expect(r.error).toBeUndefined();
    expect(r.args.ssid).toBe('MyHome');
    expect(r.args.wifi_key).toBe(' pass1234');
  });
});

describe('validateSetup — токен и сборка args', () => {
  it('пустой токен → ошибка про код установки', () => {
    const r = validateSetup(fields({ token: '  ' }));
    expect(r.error).toMatch(/код установки/i);
  });

  it('полный happy-path: домены разобраны, токен обрезан, провайдер попал в args', () => {
    const r = validateSetup(fields({
      dnsProvider: 'adguard', domainsText: 'ru, example.com', token: ' TOK ',
    }));
    expect(r.error).toBeUndefined();
    expect(r.args).toEqual({
      protocol: 'awg',
      // Конфиг обрезается по краям: хвостовой перевод строки от копипасты значения не несёт.
      awg_conf: '[Interface]\nPrivateKey = x',
      root_password: 'longenough',
      dns_provider: 'adguard',
      domains: ['ru', 'example.com'],
      token: 'TOK',
    });
  });

  it('без dnsProvider ключ dns_provider не подмешивается (движок возьмёт дефолт)', () => {
    const r = validateSetup(fields());
    expect('dns_provider' in r.args).toBe(false);
  });

  it('acceptRisk доезжает до args (иначе движок откажет на своём preflight)', () => {
    expect(validateSetup(fields({ acceptRisk: true })).args.accept_risk).toBe(true);
  });

  it('без acceptRisk ключа нет вовсе — риск не должен «включаться» молча', () => {
    expect('accept_risk' in validateSetup(fields()).args).toBe(false);
    expect('accept_risk' in validateSetup(fields({ acceptRisk: false })).args).toBe(false);
  });
});

// Пропуск проверок железа: решение принимает движок (overridable), UI лишь объясняет.
describe('softRisks / canOverride — установка на слабом железе', () => {
  const report = (over = {}) => ({
    passed: false, failed: 1, total: 6, hard_failed: 0, soft_failed: 1, overridable: true,
    checks: [
      { id: 'arch', ok: true, severity: 'hard', detail: 'arch = mips' },
      { id: 'flash', ok: false, severity: 'soft', detail: 'свободный флеш ≈ 12 МБ', fix: 'нужно ≥ 16 МБ свободно' },
    ],
    ...over,
  });

  it('пройденный preflight → пропускать нечего', () => {
    expect(canOverride({ passed: true, overridable: false, checks: [] })).toBe(false);
  });

  it('только soft-провалы → кнопка риска разрешена', () => {
    expect(canOverride(report())).toBe(true);
  });

  it('решение движка не переигрываем: overridable=false → кнопки нет', () => {
    const r = report({ overridable: false, hard_failed: 1 });
    expect(canOverride(r)).toBe(false);
  });

  it('нет отчёта (проверка не ответила) → кнопки нет', () => {
    expect(canOverride(null)).toBe(false);
    expect(canOverride(undefined)).toBe(false);
  });

  it('softRisks объясняет каждый soft-провал: чем грозит и что сделать вместо риска', () => {
    const risks = softRisks(report());
    expect(risks).toHaveLength(1);
    expect(risks[0].id).toBe('flash');
    expect(risks[0].title).toBe(SOFT_RISK.flash.title);
    expect(risks[0].fixes.length).toBeGreaterThan(0);
  });

  it('пройденные и hard-проверки в объяснения не попадают', () => {
    const r = report({
      checks: [
        { id: 'arch', ok: false, severity: 'hard', detail: 'arch = ppc' },
        { id: 'ram', ok: true, severity: 'soft', detail: 'RAM ≈ 512 МБ' },
      ],
    });
    expect(softRisks(r)).toEqual([]);
  });

  it('незнакомый soft-id (движок ушёл вперёд UI) не теряется — берём текст движка', () => {
    const r = report({
      checks: [{ id: 'cpu', ok: false, severity: 'soft', detail: 'CPU 1 ядро', fix: 'нужно ≥ 2' }],
    });
    const risks = softRisks(r);
    expect(risks[0]).toMatchObject({ id: 'cpu', title: 'CPU 1 ядро', risk: 'нужно ≥ 2', fixes: [] });
  });

  it('подписи для плашки панели есть на каждый известный soft-провал', () => {
    for (const id of Object.keys(SOFT_RISK)) expect(FORCED_LABELS[id]).toBeTruthy();
  });
});

describe('explainFail — адресная диагностика провала установки', () => {
  it('health: главный кейс — сервер молчит, конфиг/подписка, а не Wi-Fi', () => {
    const ex = explainFail('health');
    expect(ex.error).toMatch(/VPN-сервер не ответил/);
    expect(ex.advice.items.join(' ')).toMatch(/подписка/);
    expect(ex.advice.action).toBe('Загрузить другой конфиг');
  });

  it('health:tunnel:fetch без protocol — тот же текст, что health (это её конкретизация)', () => {
    expect(explainFail('health:tunnel:fetch')).toEqual(explainFail('health'));
  });

  it('health:tunnel:fetch + protocol=reality/hysteria2 — доп. совет про xray-core/3x-ui', () => {
    for (const protocol of ['reality', 'hysteria2']) {
      const ex = explainFail('health:tunnel:fetch', protocol);
      expect(ex.advice.items.join(' ')).toMatch(/xray-core/);
      expect(ex.advice.items.join(' ')).toMatch(/3x-ui/);
    }
  });

  it('health:tunnel:fetch + protocol=awg — БЕЗ совета про xray-core (к AWG не относится)', () => {
    const ex = explainFail('health:tunnel:fetch', 'awg');
    expect(ex.advice.items.join(' ')).not.toMatch(/xray-core/);
  });

  it('health:dns — не про сервер: явно снимает подозрение с VPN-конфига', () => {
    const ex = explainFail('health:dns');
    expect(ex.error).toMatch(/DNS/);
    expect(ex.advice.items.join(' ')).toMatch(/конфиг тут ни при чём/);
    expect(ex.advice.items.join(' ')).not.toMatch(/подписка/);
  });

  it('health:tunnel:process и health:tunnel:route — про роутер, не про сервер, зовут в саппорт', () => {
    for (const reason of ['health:tunnel:process', 'health:tunnel:route']) {
      const ex = explainFail(reason);
      const text = ex.advice.title + ' ' + ex.advice.items.join(' ');
      expect(text).toMatch(/на самом роутере/);
      expect(text).toMatch(/Telegram/);
      expect(text).not.toMatch(/подписка/);
    }
    expect(explainFail('health:tunnel:process').error).toMatch(/не запустилась/);
    expect(explainFail('health:tunnel:route').error).toMatch(/не смог направить/);
  });

  it('step:vpn: адресно про файл конфига', () => {
    const ex = explainFail('step:vpn');
    expect(ex.error).toMatch(/VPN-конфиг не принят/);
    expect(ex.advice.items.join(' ')).toMatch(/\[Interface\]/);
  });

  it('step:<известный> подставляет человеческую подпись шага', () => {
    const ex = explainFail('step:firewall');
    expect(ex.error).toContain(STEP_LABELS.firewall);
  });

  it('step:<неизвестный> показывает сырое имя шага (не падает)', () => {
    const ex = explainFail('step:new-step');
    expect(ex.error).toContain('new-step');
  });

  it('singbox-download и preflight — свои ветки', () => {
    expect(explainFail('singbox-download').error).toMatch(/компонент/);
    expect(explainFail('preflight').error).toMatch(/проверку/);
  });

  it('без кода причины: error=null (текст вызывающего сохраняется), генерик-советы', () => {
    const ex = explainFail(null);
    expect(ex.error).toBeNull();
    expect(ex.advice.title).toBe('Что делать');
  });
});

describe('endpoint / tunnelSummary — сводка без секретов', () => {
  const AWG = '[Interface]\nPrivateKey = SECRET\n[Peer]\nEndpoint = vpn.example.com:51820\n';

  it('endpoint достаёт Endpoint из [Peer], не выдавая ключей', () => {
    expect(endpoint(AWG)).toBe('vpn.example.com:51820');
    expect(endpoint('нет такой строки')).toBe('—');
    expect(endpoint(null)).toBe('—');
  });

  it('awg-сводка: протокол + endpoint', () => {
    expect(tunnelSummary({ protocol: 'awg', awg_conf: AWG })).toBe(
      'AmneziaWG → vpn.example.com:51820'
    );
  });

  it('reality-сводка: host:port из vless://, без uuid и параметров', () => {
    const s = tunnelSummary({
      protocol: 'reality',
      reality_conf: 'vless://uuid-123@srv.example.net:443?security=reality&pbk=KEY#name',
    });
    expect(s).toBe('VLESS+Reality → srv.example.net:443');
    expect(s).not.toContain('uuid-123');
    expect(s).not.toContain('pbk');
  });

  // В hy2-ссылке до '@' стоит ПАРОЛЬ — он не должен попасть ни на экран подтверждения, ни в
  // скриншот, который человек пришлёт с вопросом.
  it('hysteria2-сводка: host:port без пароля и параметров обфускации', () => {
    const s = tunnelSummary({
      protocol: 'hysteria2',
      hysteria2_conf: 'hysteria2://SUPERSECRET@srv.example.net:8443?obfs=salamander&obfs-password=OBFSSECRET#дом',
    });
    expect(s).toBe('Hysteria2 → srv.example.net:8443');
    expect(s).not.toContain('SUPERSECRET');
    expect(s).not.toContain('OBFSSECRET');
  });

  it('hysteria2 с port hopping: показываем адрес как есть, диапазон не теряем', () => {
    expect(tunnelSummary({ protocol: 'hysteria2', hysteria2_conf: 'hysteria2://pw@srv.example.net:443,5000-6000' }))
      .toBe('Hysteria2 → srv.example.net:443,5000-6000');
  });

  it('Full-протокол без разбираемого хоста → просто имя протокола', () => {
    expect(tunnelSummary({ protocol: 'reality', reality_conf: '{"json": true}' })).toBe('VLESS+Reality');
    expect(tunnelSummary({ protocol: 'hysteria2', hysteria2_conf: '{"json": true}' })).toBe('Hysteria2');
  });
});

describe('dnsLabel / hs — метки панели', () => {
  const providers = [{ id: 'adguard', name: 'AdGuard', description: 'блокирует рекламу' }];

  it('dnsLabel: найденный провайдер → имя и описание; чужой id → как есть; пусто → дефолт', () => {
    expect(dnsLabel('adguard', providers)).toBe('AdGuard — блокирует рекламу');
    expect(dnsLabel('other', providers)).toBe('other');
    expect(dnsLabel(null, providers)).toBe('по умолчанию');
  });

  it('hs: null → нет ответа; свежий — в секундах; старый — в минутах', () => {
    expect(hs(null)).toBe('нет ответа от сервера');
    expect(hs(-5)).toBe('—');
    expect(hs(45)).toBe('отвечал 45 с назад');
    expect(hs(150)).toBe('отвечал 2 мин назад');
  });
});

// Full-тир как ЗАПАСНОЙ путь: панель обязана верно судить о туннеле любого протокола и вести к
// Reality именно тогда, когда AmneziaWG не поднимается.
// Full-тир как ЗАПАСНОЙ путь: панель обязана верно судить о туннеле любого протокола и вести к
// подходящей замене именно тогда, когда активный туннель не поднимается.
describe('heroKind / tunnelFallback / switchTargets / tunnelRowText — состояние туннеля в панели', () => {
  const st = (over = {}) => ({ installed: true, protocol: 'awg', tunnel_health: 'up', ...over });

  it('до установки баннера нет', () => {
    expect(heroKind({ installed: false })).toBe('none');
    expect(heroKind(null)).toBe('none');
  });

  it('здоровье берётся из движка, а не из локальных догадок', () => {
    expect(heroKind(st())).toBe('up');
    expect(heroKind(st({ tunnel_health: 'down' }))).toBe('down');
  });

  // Регресс: рабочий Reality показывался как «VPN не работает», потому что панель искала
  // AWG-рукопожатие, которого у VLESS нет в принципе. То же верно и для Hysteria2.
  it('Full-протоколы: рабочий туннель зелёный без AWG-рукопожатия', () => {
    for (const [proto, label] of [['reality', 'VLESS+Reality'], ['hysteria2', 'Hysteria2']]) {
      const s = st({ protocol: proto, awg_handshake_age: null });
      expect(heroKind(s)).toBe('up');
      expect(tunnelRowText(s)).toBe(`поднят (${label})`);
      const dead = st({ protocol: proto, tunnel_health: 'down', awg_handshake_age: null });
      expect(heroKind(dead)).toBe('down');
      expect(tunnelRowText(dead)).toBe('не поднят');
    }
  });

  it('AWG: строка сводки остаётся возрастом рукопожатия (сервер отвечал)', () => {
    expect(tunnelRowText(st({ awg_handshake_age: 45 }))).toBe('отвечал 45 с назад');
    expect(tunnelRowText(st({ tunnel_health: 'down', awg_handshake_age: null }))).toBe('нет ответа от сервера');
  });

  it('запасной путь при мёртвом AWG: сначала догрузка, потом переключение', () => {
    expect(tunnelFallback(st({ full_capable: true, full_installed: false })))
      .toEqual({ action: 'install' });
    expect(tunnelFallback(st({ full_capable: true, full_installed: true })))
      .toEqual({ action: 'switch', targets: ['reality'] });
    expect(tunnelFallback(st({ full_capable: false }))).toBe(null);
    expect(tunnelFallback({ installed: false })).toBe(null);
  });

  // КЛЮЧЕВОЕ: с AmneziaWG ведём ТОЛЬКО на Reality. Hysteria2 тоже работает по UDP, поэтому сеть,
  // которая режет UDP, ломает их вместе — предлагать его как лечение «не открывается вообще»
  // значило бы гонять человека по кругу (ADR 0004: общая ось → фолбэк бесполезен).
  it('с AmneziaWG фолбэк НЕ предлагает Hysteria2 (та же UDP-ось)', () => {
    const f = tunnelFallback(st({ full_capable: true, full_installed: true }));
    expect(f.targets).not.toContain('hysteria2');
  });

  it('с активного Full-протокола предлагаем и другой Full, и возврат на AmneziaWG', () => {
    expect(tunnelFallback(st({ protocol: 'reality', full_installed: true })))
      .toEqual({ action: 'switch', targets: ['hysteria2', 'awg'] });
    expect(tunnelFallback(st({ protocol: 'hysteria2', full_installed: true })))
      .toEqual({ action: 'switch', targets: ['reality', 'awg'] });
  });

  it('switchTargets: активный протокол не показываем; Full — только когда компонент стоит', () => {
    expect(switchTargets(st({ full_installed: false })).map((p) => p.id)).toEqual([]);
    expect(switchTargets(st({ full_installed: true })).map((p) => p.id)).toEqual(['reality', 'hysteria2']);
    expect(switchTargets(st({ protocol: 'reality', full_installed: true })).map((p) => p.id))
      .toEqual(['awg', 'hysteria2']);
    expect(switchTargets(st({ protocol: 'hysteria2', full_installed: true })).map((p) => p.id))
      .toEqual(['awg', 'reality']);
  });
});

describe('fullReasons / explainFullTierFail — почему Full-тир недоступен и почему не поставился', () => {
  it('тянет → причин нет', () => {
    expect(fullReasons({ tiers: { full: true, full_checks: [] } })).toEqual([]);
  });

  it('не тянет → человеческие причины из движка (не безликое «недоступно»)', () => {
    const report = { tiers: { full: false, full_checks: [
      { id: 'full_arch', ok: true, detail: 'arch = aarch64' },
      { id: 'full_ram', ok: false, detail: 'RAM ≈ 120 МБ', fix: 'Full-тиру нужно ≥ 240 МБ' },
    ] } };
    expect(fullReasons(report)).toEqual(['RAM ≈ 120 МБ (Full-тиру нужно ≥ 240 МБ)']);
  });

  it('нет отчёта/тиров → пустой список, не падаем', () => {
    expect(fullReasons(null)).toEqual([]);
    expect(fullReasons({})).toEqual([]);
  });

  it('нет места ≠ нет интернета: советы разные', () => {
    expect(explainFullTierFail('no-space')).toMatch(/не хватило места/i);
    expect(explainFullTierFail('no-space')).toMatch(/extroot/);
    expect(explainFullTierFail('download')).toMatch(/в интернете/);
    expect(explainFullTierFail(undefined)).toMatch(/в интернете/);
  });
});

describe('fullMissingText — почему кнопки Full-тира нет', () => {
  it('каждая машинная причина имеет человеческую подпись', () => {
    for (const id of ['arch', 'ram', 'flash']) expect(FULL_MISSING_LABELS[id]).toBeTruthy();
  });

  it('флеш — причина, которую человек устранит сам, поэтому названа конкретно', () => {
    expect(fullMissingText(['flash'])).toMatch(/места/);
    expect(fullMissingText(['flash'])).toMatch(/44 МБ/); // = preflight FULL_REQUIREMENTS.min_flash_mb
  });

  it('несколько причин перечисляются, пустой список → пусто', () => {
    expect(fullMissingText(['ram', 'flash'])).toContain('; ');
    expect(fullMissingText([])).toBe('');
    expect(fullMissingText(undefined)).toBe('');
  });
});

// Чеклист установки: план шагов зависит от протокола и наличия Wi-Fi — и обязан совпадать
// по порядку с движком, иначе «пройденные» шаги будут врать.
describe('installPlan — план шагов для чеклиста Installing', () => {
  it('awg без Wi-Fi: ни догрузки sing-box, ни шага wifi', () => {
    expect(installPlan({ protocol: 'awg' }).map((s) => s.id)).toEqual(
      ['preflight', 'snapshot', 'vpn', 'dns', 'doh', 'firewall', 'health-check']);
  });

  it('reality с Wi-Fi: singbox-download до snapshot, wifi между doh и firewall', () => {
    expect(installPlan({ protocol: 'reality', ssid: 'Home' }).map((s) => s.id)).toEqual(
      ['preflight', 'singbox-download', 'snapshot', 'singbox', 'dns', 'doh', 'wifi', 'firewall', 'health-check']);
  });

  it('у каждого шага плана есть человеческая подпись из STEP_LABELS', () => {
    for (const s of installPlan({ protocol: 'hysteria2', ssid: 'x' })) expect(s.label).toBeTruthy();
  });
});

// Подсветка виновного поля: каждая ошибка validateSetup называет field — Setup по нему
// подсвечивает и прокручивает. Ошибка без field молча оставит человека искать поле самому.
describe('validateSetup — field называет виновное поле', () => {
  it.each([
    ['conf', { confs: { awg: '' } }],
    ['rootPass', { rootPass: 'short' }],
    ['rootPass2', { rootPass2: 'другой-пароль-9' }],
    ['ssid', { showWifi: true, wifiRequired: true, ssid: ' ', wifiKey: 'wifi-pass-1' }],
    ['wifiKey', { showWifi: true, ssid: 'Home', wifiKey: 'short' }],
    ['token', { token: '  ' }],
  ])('%s', (field, patch) => {
    const r = validateSetup(fields(patch));
    expect(r.error).toBeTruthy();
    expect(r.field).toBe(field);
  });

  it('speed — при кривых цифрах ручного режима Hysteria2', () => {
    const r = validateSetup(fields({
      protocol: 'hysteria2', fullAvailable: true,
      confs: { hysteria2: 'hy2://pw@h:443' },
      declareSpeed: true, speedDown: 0, speedUp: 10,
    }));
    expect(r.field).toBe('speed');
  });
});
