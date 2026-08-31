<script>
  import { onDestroy } from 'svelte';
  import { cheburnet, login, isLoggedIn, logout, isAccessDenied } from '../ubus.js';
  import { hs, FORCED_LABELS, heroKind, tunnelFallback, switchTargets, tunnelRowText,
           explainFullTierFail, fullMissingText, protocolInfo, checkConf, BRUTAL_WARNING,
           withDeclaredSpeed, SPEED_DEFAULTS, SUPPORT, parseDomains } from '../logic.js';
  import Card from '../ui/Card.svelte';
  import Button from '../ui/Button.svelte';
  import Input from '../ui/Input.svelte';
  import Radio from '../ui/Radio.svelte';
  import Select from '../ui/Select.svelte';
  import ConfCheck from '../ui/ConfCheck.svelte';

  // onReinstall — запустить мастер заново (с preflight).
  let { onReinstall } = $props();

  let s = $state(null);
  let error = $state('');
  // Панель делает восемь разных вещей; развёрнуто по умолчанию только то, ради чего сюда заходят
  // («работает ли?» и перезапуск). Остальное — свёрнуто, но открывается само, когда hero ведёт
  // в блок ссылкой: иначе якорь прыгал бы в закрытый <details>.
  let tunnelOpen = $state(false);
  let dangerOpen = $state(false);
  let action = $state(''); // текст результата/ошибки управляющего действия
  // Где показать это сообщение. Одно место на всю страницу означало, что результат нажатия
  // верхней кнопки появлялся через два экрана вниз — человек его просто не видел. Каждое
  // сообщение печатается у той группы кнопок, которая его вызвала.
  let actionScope = $state('manage'); // manage | restart | dns | replace | switch | full | danger
  let busy = $state(false);
  // Подряд неудачные опросы фоновой операции = страница потеряла роутер (сменился адрес, ребут
  // посреди операции). Раньше catch глотал всё: «Применяю…» висело до F5 при заблокированной
  // панели. Тот же порог, что у мастера (Installing.svelte).
  let pollFails = $state(0);
  function pollLost(scope) {
    pollFails++;
    if (pollFails !== 4) return;
    busy = false;
    actionScope = scope;
    action = 'Страница потеряла связь с роутером — операция продолжается на нём самом. '
      + 'Обновите страницу через минуту; если менялся адрес роутера — откройте новый.';
  }
  // Замена сервера АКТИВНОГО туннеля: одно поле, метод и подпись — из каталога протоколов.
  let replaceConf = $state('');
  let replacePhase = $state('idle'); // idle | running | ok | fail
  let replaceLog = $state('');
  let resetWord = $state('');
  let resetArmed = $state(false);
  let fullPhase = $state('idle'); // догрузка компонента: idle | running | ok | fail
  let fullLog = $state('');
  // Смена туннеля: конфиги хранятся ПО ПРОТОКОЛАМ (переключение выбора не теряет вставленное).
  let switchConfs = $state({ awg: '', reality: '', hysteria2: '' });
  // switchPick — ВЫБРАННОЕ направление (радио), switchTarget — то, что уже переключается.
  // Раньше блоков было по одному на протокол: три похожих поля для ссылок на одной странице, и
  // вставить в чужое — обычное дело. Теперь как в мастере: сначала выбор по симптому, потом одно поле.
  let switchPick = $state('');
  let switchTarget = $state('');  // направление текущего свитча
  let switchPhase = $state('idle');
  let switchLog = $state('');
  // Скорость канала для Hysteria2 (Brutal). По умолчанию — автоматически (BBR): см. logic.js.
  let declareSpeed = $state(false);
  let speedDown = $state(SPEED_DEFAULTS.down);
  let speedUp = $state(SPEED_DEFAULTS.up);
  let timer = null;
  let replaceTimer = null;
  let fullTimer = null;
  let switchTimer = null;

  // Вход (admin-сессия root).
  let loggedIn = $state(isLoggedIn());
  let loginOpen = $state(false);
  let loginPass = $state('');
  let loginError = $state('');
  let loginAttempts = $state(0);
  let loginInput = $state(null);
  // Квирк браузеров: атрибут autofocus не срабатывает на узле, вставленном ПОСЛЕ загрузки
  // страницы, — модалку открывает клик, поэтому фокус ставим сами (закреплено e2e).
  $effect(() => { if (loginOpen) loginInput?.focus(); });

  async function refresh() {
    try {
      s = await cheburnet('status');
      if (!providerSel && s.dns_provider) providerSel = s.dns_provider;
      error = '';
    } catch (e) {
      error = e.message;
    }
  }

  // Управляющие действия — admin-методы. Без сессии (или с протухшей) — отказ доступа
  // (isAccessDenied, ubus.js) — открываем модалку входа, а не показываем голую ошибку.
  async function admin(label, fn, scope = 'manage') {
    busy = true;
    action = '';
    actionScope = scope;
    try {
      await fn();
      // Само действие могло сообщить конкретику («Список обновлён: N доменов») — не затираем её
      // безликим «готово». Раньше затирало, и счётчик доменов, который для этого и считался,
      // до экрана не доезжал.
      if (action === '') action = `${label} — готово.`;
      await refresh();
    } catch (e) {
      if (isAccessDenied(e)) {
        logout(); // протухшую сессию (или её отсутствие) выбрасываем
        loggedIn = false;
        loginOpen = true;
        action = `${label}: нужен вход — введите пароль роутера.`;
      } else {
        action = `${label}: ${e.message}`;
      }
    } finally {
      busy = false;
    }
  }

  // needLogin(e, what) — общая обработка отказа доступа (isAccessDenied — обе его формы, см.
  // ubus.js) для фоновых операций (они не идут через admin(), потому что там свой поллинг
  // прогресса).
  function needLogin(e, what, scope = 'manage') {
    busy = false;
    actionScope = scope;
    if (isAccessDenied(e)) {
      logout(); loggedIn = false; loginOpen = true;
      action = `${what}: нужен вход — введите пароль роутера.`;
    } else {
      action = `${what}: ${e.message}`;
    }
  }

  async function doLogin() {
    loginError = '';
    try {
      await login(loginPass);
      loggedIn = true;
      loginOpen = false;
      loginPass = '';
      loginAttempts = 0;
      actionScope = 'manage';
      action = 'Вход выполнен — повторите действие.';
      loadDomains();
    } catch (e) {
      loginAttempts += 1;
      loginPass = '';
      // Попытки считаем и показываем, но НЕ блокируем поле: опечатка не должна стоить перезагрузки
      // страницы. Защита от перебора здесь всё равно не наша — пароль проверяет rpcd.
      loginError = `Пароль не подошёл (попытка ${loginAttempts}). Нужен пароль роутера, заданный при установке.`;
    }
  }

  function doLogout() {
    logout();
    loggedIn = false;
    actionScope = 'manage';
    action = 'Вы вышли — управление снова требует входа.';
  }

  const setMode = (mode) => admin(`Режим ${mode}`, () => cheburnet('set_mode', { mode }));

  // Свой список сайтов напрямую — правится здесь, без мастера и переустановки (set_domains
  // переприменяет только DNS-шаг). Список читается после входа: он говорит о привычках дома,
  // поэтому движок отдаёт его только admin-сессии.
  let userDomainsText = $state('');
  let domainsLoaded = $state(false);
  async function loadDomains() {
    try {
      const r = await cheburnet('get_domains');
      userDomainsText = (r.user_domains ?? []).join('\n');
      domainsLoaded = true;
    } catch { /* не вошли или роутер не настроен — поле покажет подсказку */ }
  }
  const saveDomains = () =>
    admin('Список сайтов', async () => {
      const r = await cheburnet('set_domains', { domains: parseDomains(userDomainsText) });
      const rej = r.rejected ?? [];
      action = `Сохранено: своих сайтов ${r.user_domains}, напрямую всего ${r.direct_domains}.`
        + (rej.length ? ` Не похожи на домены и пропущены: ${rej.join(', ')}.` : '');
      await loadDomains();
    });
  const updateList = () =>
    admin('Обновление списка', async () => {
      const r = await cheburnet('update_list');
      action = `Список обновлён: ${r.direct_domains} доменов.`;
    });
  const restart = (service, label) =>
    admin(`Перезапуск: ${label}`, () => cheburnet('service_restart', { service }), 'restart');

  // Аварийный режим: последнее средство, когда туннель не поднять, а интернет нужен сейчас.
  // Подтверждение обязательно — человек выключает защиту, и он должен это осознать.
  const pauseProtection = () => {
    if (!confirm('Выключить защиту и пустить интернет напрямую?\n\n'
      + 'Сайты откроются сразу, но трафик перестанет идти через VPN, а kill-switch будет снят.\n'
      + 'Настройки сохранятся — вернуть защиту можно одной кнопкой.')) return;
    return admin('Аварийный режим', () => cheburnet('pause_protection'), 'emergency');
  };
  const resumeProtection = () =>
    admin('Возврат защиты', () => cheburnet('resume_protection'), 'emergency');
  // DNS-провайдер = уровень фильтрации (реклама/семейный/без). Выбор из каталога (status.dns_providers).
  let providerSel = $state('');

  // Главный сигнал панели и запасной путь — чистые функции (logic.js, под vitest). hero знает,
  // ЧЕМ мерить каждый протокол; fallback — куда вести, если активный туннель не поднимается.
  const hero = $derived(heroKind(s));
  const active = $derived(protocolInfo(s?.protocol));
  const fallback = $derived(tunnelFallback(s));
  const targets = $derived(switchTargets(s));
  // Выбранное направление смены туннеля. Эффект, а не $derived: значение принадлежит радио
  // (пользователь его меняет), а список вариантов приходит асинхронно и меняется после каждого
  // переключения — активный протокол из targets уходит. Досеиваем на первый доступный, чтобы поле
  // ссылки и кнопка никогда не остались без протокола.
  $effect(() => {
    if (targets.length > 0 && !targets.some((p) => p.id === switchPick)) switchPick = targets[0].id;
  });
  const pick = $derived(protocolInfo(switchPick));
  // Чего не хватает железу для Full-тира (status.full_missing) — человеческими словами.
  const fullMissing = $derived(fullMissingText(s?.full_missing));
  const setProvider = () =>
    admin(`DNS-провайдер: ${providerSel}`, () => cheburnet('set_dns_provider', { provider: providerSel }), 'dns');

  // Загрузка .conf файлом (только у AmneziaWG — ссылку файлом не приносят).
  async function onReplaceFile(e) {
    const f = e.target.files?.[0];
    if (!f) return;
    replaceConf = await f.text();
  }
  async function onSwitchFile(e, id) {
    const f = e.target.files?.[0];
    if (!f) return;
    switchConfs[id] = await f.text();
  }

  // Диагностика для поддержки: пакет собирает роутер (логи + состояние + версии) с ВЫРЕЗАННЫМИ
  // секретами. Показываем его на экране ДО скачивания — обещание «мы всё вычистили» человек может
  // проверить только глазами, и это единственный честный способ его дать.
  let diagText = $state('');
  let diagRemoved = $state([]);
  let diagPhase = $state('idle'); // idle | running | ok | fail
  async function collectDiagnostics() {
    diagPhase = 'running';
    actionScope = 'support';
    action = '';
    try {
      const r = await cheburnet('diagnostics');
      diagText = r.text ?? '';
      diagRemoved = r.removed ?? [];
      diagPhase = 'ok';
    } catch (e) {
      diagPhase = 'fail';
      needLogin(e, 'Сбор диагностики', 'support');
    }
  }
  // Скачивание через Blob: работает по http без сервера-помощника (панель отдаётся с роутера).
  function downloadDiagnostics() {
    const blob = new Blob([diagText], { type: 'text/plain' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'cheburnet-диагностика.txt';
    a.click();
    URL.revokeObjectURL(a.href);
  }

  // hy2Conf(id, conf) — ссылка Hysteria2 с объявленной скоростью, если владелец её включил.
  // Для остальных протоколов — как есть.
  function hy2Conf(id, conf) {
    return (id === 'hysteria2' && declareSpeed)
      ? withDeclaredSpeed(conf, speedDown, speedUp)
      : conf;
  }

  // Замена сервера активного туннеля: метод и имя аргумента — из каталога протоколов, поэтому
  // третий протокол не потребовал третьей копии этой функции. Фон+poll — общий канал
  // install_progress (тот же, что у установки).
  async function replaceTunnel() {
    const conf = replaceConf.trim();
    actionScope = 'replace';
    // Формат сверяем ДО вызова: замена — фоновая операция со снимком и откатом, и ссылка,
    // вставленная вместо .conf, стоила бы человеку полного цикла ожидания.
    const bad = checkConf(active.id, conf);
    if (bad) {
      action = bad;
      return;
    }
    busy = true;
    action = '';
    replaceLog = '';
    try {
      await cheburnet(active.replaceMethod, { [active.confKey]: hy2Conf(active.id, conf) });
      replacePhase = 'running';
      replaceTimer = setInterval(pollReplace, 2000);
    } catch (e) {
      needLogin(e, 'Замена конфига', 'replace');
    }
  }

  async function pollReplace() {
    try {
      const p = await cheburnet('install_progress');
      pollFails = 0;
      replaceLog = p.log ?? '';
      if (p.done) {
        clearInterval(replaceTimer);
        replaceTimer = null;
        busy = false;
        actionScope = 'replace';
        if (p.result === 'ok') {
          replacePhase = 'ok';
          replaceConf = '';
          action = `Новый сервер применён (${active.name}) — трафик идёт через туннель.`;
        } else {
          replacePhase = 'fail';
          // Честный намёк на случай, когда виноват не сервер, а сеть — иначе пользователь меняет
          // один конфиг на другой по кругу без понимания, почему все падают.
          action = 'Новый сервер тоже не отозвался — прежний возвращён автоматически. Проверьте, что '
            + 'конфиг свежий и сервер жив. Если несколько серверов подряд не работают, дело, скорее '
            + 'всего, не в них: попробуйте другой туннель — блок «Сменить туннель» ниже.';
        }
        await refresh();
      }
    } catch {
      pollLost('replace');
    }
  }

  // obtainToken() — install-токен для мастера: движок отдаёт существующий или выпускает новый
  // (install_token, admin). Нужен и после сброса, и для «Настроить заново»: успешная установка
  // токен снимает как одноразовый, поэтому без этого шага мастер доходил до последней кнопки и
  // получал «токен не найден — запустите bootstrap по SSH». Пусто → ссылку не выдумываем.
  async function obtainToken() {
    try {
      const t = await cheburnet('install_token');
      return t.token ?? '';
    } catch (e) {
      needLogin(e, 'Повторная настройка', 'danger');
      return '';
    }
  }

  // «Настроить заново» из панели: сначала токен, потом мастер — иначе человек заполнит все поля и
  // упрётся в отказ на последнем шаге. Без токена мастер всё равно откроем (там честно скажут,
  // что делать), но пробовать получить его обязаны.
  async function reinstall() {
    const t = await obtainToken();
    if (t) {
      location.search = `?token=${encodeURIComponent(t)}`;
      return;
    }
    onReinstall();
  }

  // Factory reset: двойное подтверждение — ввод слова RESET руками. Ждём ЗАВЕРШЕНИЯ (тот же
  // канал install_progress, что у остальных фоновых операций): раньше панель говорила «запущен» и
  // на этом заканчивала, а человек оставался наедине с роутером в промежуточном состоянии.
  let resetPhase = $state('idle'); // idle | running | ok | fail
  let resetToken = $state('');
  let resetTimer = null;
  // Движок принимает ровно "RESET" (регистр важен) — панель приводит ввод сама: осознанность даёт
  // набранное руками слово, а не раскладка Shift'а. Иначе «reset» оставлял кнопку серой молча.
  const resetOk = $derived(resetWord.trim().toUpperCase() === 'RESET');
  const factoryReset = () =>
    admin('Сброс cheburnet', async () => {  // scope 'danger' — сообщение остаётся в опасной зоне
      await cheburnet('factory_reset', { confirm: resetWord.trim().toUpperCase() });
      action = 'Снимаю конфигурацию — роутер вернётся к обычной маршрутизации.';
      resetWord = '';
      resetArmed = false;
      resetPhase = 'running';
      resetTimer = setInterval(pollReset, 2000);
    }, 'danger');

  async function pollReset() {
    try {
      const p = await cheburnet('install_progress');
      pollFails = 0;
      if (!p.done) return;
      clearInterval(resetTimer); resetTimer = null;
      actionScope = 'danger';
      if (p.result === 'ok') {
        resetPhase = 'ok';
        action = 'Готово: конфигурация cheburnet снята, роутер вернулся к обычной маршрутизации.';
        resetToken = await obtainToken();
      } else {
        resetPhase = 'fail';
        action = 'Сброс завершился с ошибкой — часть настройки могла остаться. '
          + 'Соберите диагностику (блок «Если что-то не работает») и пришлите её.';
      }
      await refresh();
    } catch { pollLost('danger'); }
  }

  refresh();
  if (loggedIn) loadDomains();
  // 15 с, не чаще: каждый опрос — это спавн rpcd-скрипта + shell-батч на роутере (слабое железо).
  timer = setInterval(refresh, 15000);
  onDestroy(() => {
    if (timer) clearInterval(timer);
    if (replaceTimer) clearInterval(replaceTimer);
    if (fullTimer) clearInterval(fullTimer);
    if (switchTimer) clearInterval(switchTimer);
    if (resetTimer) clearInterval(resetTimer);
  });

  // In-place смена туннеля: приносим только конфиг нового туннеля, домены/DNS берутся из
  // сохранённого (мастер не проходим). run.uc делает snapshot → teardown прежнего → apply → health
  // → commit/rollback, прогресс — тот же канал install_progress. При сбое ПРЕЖНИЙ туннель
  // возвращается автоматически. Одна функция на все шесть переходов — метод берём из каталога.
  async function switchTo(p) {
    const conf = (switchConfs[p.id] ?? '').trim();
    actionScope = 'switch';
    const bad = checkConf(p.id, conf);
    if (bad) {
      action = bad;
      return;
    }
    switchTarget = p.id;
    busy = true; action = ''; switchLog = '';
    try {
      await cheburnet(p.switchMethod, { [p.confKey]: hy2Conf(p.id, conf) });
      switchPhase = 'running';
      switchTimer = setInterval(pollSwitch, 2000);
    } catch (e) {
      needLogin(e, 'Переключение', 'switch');
    }
  }

  async function pollSwitch() {
    try {
      const p = await cheburnet('install_progress');
      pollFails = 0;
      switchLog = p.log ?? '';
      if (p.done) {
        clearInterval(switchTimer); switchTimer = null; busy = false;
        actionScope = 'switch';
        const to = protocolInfo(switchTarget).name;
        const from = active.name;
        if (p.result === 'ok') {
          switchPhase = 'ok';
          switchConfs[switchTarget] = '';
          action = `Переключено на ${to} — туннель работает.`;
        } else {
          switchPhase = 'fail';
          action = `Не удалось поднять ${to} — прежний туннель (${from}) возвращён автоматически. `
            + 'Проверьте, что конфиг вставлен целиком и сервер жив.';
        }
        await refresh();
      }
    } catch { pollLost('switch'); }
  }

  // Full-тир (opt-in): кнопка догружает компонент sing-box фоном. Прогресс — тот же канал
  // install_progress. Работающий туннель при этом не трогается (ставим только пакет).
  async function enableFullTier() {
    busy = true; action = ''; fullLog = '';
    try {
      await cheburnet('install_full_tier');
      fullPhase = 'running';
      fullTimer = setInterval(pollFull, 2000);
    } catch (e) {
      needLogin(e, 'Установка запасного туннеля', 'full');
    }
  }

  async function pollFull() {
    try {
      const p = await cheburnet('install_progress');
      pollFails = 0;
      fullLog = p.log ?? '';
      if (p.done) {
        clearInterval(fullTimer); fullTimer = null; busy = false;
        actionScope = 'full';
        if (p.result === 'ok') {
          fullPhase = 'ok';
          action = 'Компонент установлен. Ниже появился блок «Сменить туннель» — вставьте туда ссылку от вашего сервера.';
        } else {
          fullPhase = 'fail';
          // Причина из движка (install-singbox.sh пишет REASON_FILE): совет «проверьте интернет»
          // на забитом флеше отправлял чинить не то, а компонент реально может не влезть.
          action = explainFullTierFail(p.reason);
        }
        await refresh();
      }
    } catch { pollLost('full'); }
  }
</script>

<!-- Результат действия печатается только у той группы кнопок, которая его вызвала (actionScope).
     Одно место на всю страницу означало, что итог нажатия верхней кнопки появлялся под опасной
     зоной — то есть там, куда человек не смотрит. -->
{#snippet actionNote(scope)}
  {#if action && actionScope === scope}<p class="muted">{action}</p>{/if}
{/snippet}

<!-- Скорость канала (Brutal) — сниппет, потому что рендерится РЯДОМ С ПОЛЕМ, к которому относится:
     в замене сервера, если Hysteria2 уже активен, и в смене туннеля, если на него переключаются.
     Раньше блок стоял единожды в конце страницы — то есть НИЖЕ кнопок, которые его применяют, и
     человек нажимал раньше, чем узнавал о настройке. Оба места одновременно не выпадают: активный
     протокол в targets не попадает, поэтому общее состояние declareSpeed однозначно.
     Поле не голое сознательно: завышенная цифра делает связь ХУЖЕ и молча (см. ADR 0004). -->
{#snippet speedFields()}
  <h4>Скорость канала</h4>
  <Radio bind:group={declareSpeed} value={false} disabled={busy}>
    <strong>Подбирать автоматически</strong> — рекомендуем.
  </Radio>
  <Radio bind:group={declareSpeed} value={true} disabled={busy}>
    <strong>Указать вручную</strong> — иногда выжимает больше на канале с потерями.
  </Radio>
  {#if declareSpeed}
    <p class="warn">{BRUTAL_WARNING}</p>
    <label>
      <span>Скорость приёма (Мбит/с)</span>
      <Input type="number" min="1" max="10000" bind:value={speedDown} disabled={busy} />
    </label>
    <label>
      <span>Скорость отдачи (Мбит/с)</span>
      <Input type="number" min="1" max="10000" bind:value={speedUp} disabled={busy} />
    </label>
  {/if}
{/snippet}

<Card title="Состояние">
  {#if error}<p class="warn">{error}</p>{/if}

  {#if s}
    <!-- Аварийный режим — ВЫШЕ всего остального: это главное, что сейчас происходит с роутером.
         Молча снятая защита недопустима, поэтому говорим прямо, что именно выключено, и рядом
         держим кнопку возврата. Пока он включён, hero-статус туннеля не показываем: он бы
         спорил сам с собой («туннель не работает» при осознанно снятой защите). -->
    {#if s.paused}
      <p class="banner">
        <strong>Аварийный режим: защита выключена.</strong> Интернет идёт напрямую, мимо VPN:
        трафик виден провайдеру, kill-switch и разделение по списку сняты. Настройки сохранены.
      </p>
      <div class="row">
        <Button disabled={busy} onclick={resumeProtection}>Вернуть защиту</Button>
      </div>
      {@render actionNote('emergency')}
    {:else}
    <!-- Hero-статус: с ОДНОГО взгляда «всё работает / есть проблема + что делать». Здоровье
         туннеля даёт движок (status.tunnel_health) — он знает, чем мерить активный протокол;
         панель лишь подбирает формулировку и путь к починке (якоря блоков ниже). -->
    {#if hero === 'down'}
      <p class="banner">
        <strong>Туннель не работает ({active.name}).</strong> Открываются только сайты из
        списка «напрямую». Попробуйте кнопку «Туннель» в «Перезапуске сервисов»; не помогло —
        <a href="#replace-tunnel" onclick={() => (tunnelOpen = true)}>вставьте свежий конфиг</a>.
      </p>
      <!-- Честность о деградации: DNS в этот момент работает РЕЗЕРВНЫМ путём мимо туннеля, и
           человек имеет право знать, что именно изменилось в его приватности. Молчаливая
           деградация хуже самой деградации. В поездке резервного пути нет намеренно. -->
      {#if s.mode === 'travel'}
        <p class="note">
          Режим «в поездке»: резервный путь для DNS отключён намеренно — в чужой сети наружу не
          должно уходить ничего, даже запросы к DNS. Поэтому сейчас не открывается ничего.
        </p>
      {:else}
        <p class="note">
          Пока туннель лежит, DNS работает резервным путём мимо туннеля. Запросы остаются
          зашифрованными, но провайдер видит сам факт обращения к DNS-резолверу. Туннель
          поднимется — сторож вернёт DNS в него сам, в течение нескольких минут.
        </p>
      {/if}
      <!-- Ведём к запасному пути ровно в тот момент, когда он нужен, а не прячем его в конце
           страницы. ВАЖНО: с AmneziaWG предлагаем именно VLESS+Reality. Hysteria2 работает по
           UDP, как и AmneziaWG, поэтому сеть, которая режет UDP, ломает их вместе — предлагать
           его как замену «не открывается вообще» значило бы посылать человека по кругу. -->
      {#if fallback?.action === 'install'}
        <p class="note">
          Не помог и свежий конфиг? Похоже, сеть режет сам протокол AmneziaWG (он работает по UDP).
          Тогда помогает <a href="#full-tier" onclick={() => (tunnelOpen = true)}>добавить
          VLESS+Reality</a> — снаружи он выглядит как обычный HTTPS. AmneziaWG никуда не денется.
        </p>
      {:else if fallback?.action === 'switch'}
        <p class="note">
          Не помог и свежий конфиг? Значит дело, скорее всего, не в сервере, а в сети — попробуйте
          другой туннель:
          <!-- Ссылка не только ведёт к блоку, но и ВЫБИРАЕТ там нужный туннель: человек попадает
               на готовое поле, а не выбирает второй раз то, что уже выбрал здесь. href оставлен
               настоящим (работает и без JS, и как обычная ссылка на якорь). -->
          {#each fallback.targets as t, i}{#if i > 0}, {/if}<a href="#switch-tunnel"
            onclick={() => { switchPick = t; tunnelOpen = true; }}>{protocolInfo(t).name}</a>{/each}.
          Если новый не поднимется, прежний вернётся сам.
        </p>
      {/if}
    {:else if hero === 'up' && active.full}
      <!-- Формулировка слабее, чем у AWG, ОСОЗНАННО: у Full-протоколов нет рукопожатия — мы видим,
           что туннель поднят, но не что сервер отвечает. Не обещаем «всё работает». -->
      <p class="ok-msg">{active.name} активен: трафик идёт через туннель.</p>
      <p class="muted small">Сайты не открываются? Сервер мог отключиться — вставьте свежий
        конфиг ниже, прежний вернётся сам при неудаче.</p>
    {:else if hero === 'up'}
      <p class="ok-msg">Всё работает: VPN активен, трафик защищён.</p>
    {/if}

    <!-- Аварийная кнопка — ТОЛЬКО когда туннель действительно не работает: предлагать снять
         защиту на исправной системе значит подталкивать к тому, чего человек не просил. Это
         последнее средство после «перезапустить» и «свежий конфиг», поэтому и стоит последним. -->
    {#if hero === 'down'}
      <p class="note">
        Ничего не помогло, а интернет нужен прямо сейчас? Можно временно выключить защиту —
        трафик пойдёт напрямую, мимо VPN. Настройки сохранятся, вернуть защиту — одной кнопкой.
      </p>
      <div class="row">
        <Button disabled={busy} onclick={pauseProtection}>Выключить защиту (аварийно)</Button>
      </div>
      {@render actionNote('emergency')}
    {/if}
    {/if}

    <!-- Тревожный (красный) баннер — ТОЛЬКО когда direct-доменов вообще нет: тогда split не
         работает и весь трафик реально идёт в туннель. Если у пользователя есть свои домены
         (direct_domains>0), они идут напрямую — красная тревога тут ложна и вводит в заблуждение. -->
    {#if s.installed && s.direct_domains === 0}
      <p class="banner">
        Список «сайты напрямую» пуст — весь трафик идёт через VPN (безопасно, но медленнее).
        Впишите свои сайты в поле ниже или подтяните готовый список.
      </p>
    {:else if s.installed && !s.direct_list_loaded}
      <!-- Необязательный community-список не подтянут — это НЕ проблема (свои домены работают).
           Нейтральная подсказка, не красная тревога. -->
      <p class="note">
        Ваши сайты напрямую работают ({s.direct_domains}). Можно дополнительно подтянуть готовый
        список популярных — кнопка «Обновить готовый список» ниже.
      </p>
    {/if}

    <!-- Роутер поставлен с пропуском проверок железа (install.json.forced). Плашка постоянная и
         нейтральная: это не поломка, но при разборе «тормозит/отваливается» она — первое, что
         должно быть видно (в том числе на скриншоте статуса от пользователя). -->
    {#if s.installed && s.forced?.length > 0}
      <p class="note">
        Роутер слабее рекомендуемого — установлено по вашему решению
        ({s.forced.map((f) => FORCED_LABELS[f] ?? f).join(', ')}). Работает, но стабильность
        не гарантируется: при странных перезагрузках или тормозах это первая причина, куда смотреть.
      </p>
    {/if}

    <ul class="status">
      <li><span>Сайты напрямую</span><strong>{s.direct_domains}</strong></li>
      <li><span>Импортированный список</span><strong>{s.direct_list_loaded ? `${s.imported_domains} доменов` : 'не загружен'}</strong></li>
      <!-- Подпись зависит от протокола: у AWG видно, когда сервер отвечал; у Full-протоколов —
           только что туннель поднят (см. tunnelRowText). Цвет — из единого tunnel_health движка. -->
      <li class:ok={s.tunnel_health === 'up'} class:bad={s.tunnel_health !== 'up'}>
        <span>Туннель ({active.name})
          <!-- Выбор/докачка протокола лежит в свёрнутом details ниже (см. tunnel-group) — без
               этой ссылки в сводке человек с рабочим туннелем не находит её вовсе, потому что
               ничего не подсказывает заглянуть внутрь. -->
          {#if s.full_capable && !s.full_installed}
            <a href="#full-tier" onclick={() => (tunnelOpen = true)}>другие протоколы</a>
          {:else if targets.length > 0}
            <a href="#switch-tunnel" onclick={() => (tunnelOpen = true)}>сменить</a>
          {/if}
        </span>
        <strong>{tunnelRowText(s)}</strong>
      </li>
      <li class:ok={s.dns_up} class:bad={!s.dns_up}><span>DNS</span><strong>{s.dns_up ? 'работает' : 'нет'}</strong></li>
      <li class:ok={s.doh_up} class:bad={!s.doh_up}><span>Шифрованный DNS</span><strong>{s.doh_up ? 'работает' : 'нет'}</strong></li>
      {#if s.wireless_present}
        <li><span>Wi-Fi (SSID)</span><strong>{s.ssid || '—'}</strong></li>
      {/if}
      <li><span>DNS-фильтрация</span><strong>{s.dns_provider_desc ? s.dns_provider_desc.name : (s.dns_provider ?? '—')}</strong></li>
    </ul>

    <h3>Управление</h3>
    <!-- Подсказка про вход — ЗДЕСЬ, перед первой кнопкой. Раньше она стояла в конце страницы:
         человек прокручивал экран серых неактивных кнопок и только внизу узнавал, почему они серые. -->
    {#if loggedIn}
      <p class="muted small">Вы вошли как root. <button class="linklike" onclick={doLogout}>Выйти</button></p>
    {:else}
      <!-- Вход — заметный блок с кнопкой, а не подчёркнутое слово в абзаце: новичок ссылку не
           замечал и решал, что панель «только смотреть». -->
      <div class="login-gate" id="login">
        <p><strong>Настройки ниже защищены паролем.</strong> Войдите, чтобы их менять —
          пароль роутера тот, что задали при установке.</p>
        <Button variant="primary" onclick={() => (loginOpen = true)}>Войти</Button>
      </div>
    {/if}
    <!-- Сегмент, а не кнопка-переключатель: кнопка показывала, КУДА переключит, а строка сводки
         рядом — где сейчас. Одни и те же два слова в двух местах с противоположным смыслом. -->
    <div class="segmented" role="group" aria-label="Режим работы">
      <button class:active={s.mode !== 'travel'} disabled={busy}
              onclick={() => s.mode === 'travel' && setMode('home')}>Дома</button>
      <button class:active={s.mode === 'travel'} disabled={busy}
              onclick={() => s.mode !== 'travel' && setMode('travel')}>В поездке</button>
    </div>
    <p class="muted small">Дома — сайты из списка идут напрямую. В поездке — весь трафик через туннель.</p>
    <!-- Свой список — главная настройка продукта, поэтому она здесь, а не в мастере: поменять
         сайт не должно стоить переустановки. Применяется одним DNS-шагом, без разрыва туннеля. -->
    <label class="domains">
      <span>Сайты напрямую — ваш список</span>
      {#if loggedIn && domainsLoaded}
        <textarea bind:value={userDomainsText} rows="4" disabled={busy}
                  placeholder="ru&#10;example.com" spellcheck="false"></textarea>
      {:else}
        <textarea rows="4" disabled placeholder={loggedIn ? 'Загружаю список…' : 'Войдите, чтобы увидеть и изменить список'}></textarea>
      {/if}
      <small class="muted">Зона (<code>ru</code>) покрывает все сайты в ней; отдельные — своей строкой.
        Остальное — через туннель. Промах безопасен: сайт не в списке — уйдёт через VPN.</small>
    </label>
    <!-- Подпись ПЕРЕД кнопками: сразу под ними печатается результат действия (actionNote), и
         вставленный между ними текст отодвигал бы его от того, что человек только что нажал. -->
    <p class="muted small action-hint">«Обновить готовый список» подтягивает community-список популярных сайтов — он добавляется к вашему.</p>
    <div class="row">
      <!-- Без входа кнопка не серая, а ведёт ко входу: серая кнопка рядом с активной читается как
           «сломано», а не как «нужен пароль». -->
      <Button disabled={busy || (loggedIn && !domainsLoaded)}
              onclick={() => (loggedIn ? saveDomains() : (loginOpen = true))}>Сохранить список</Button>
      <Button disabled={busy} onclick={updateList}>Обновить готовый список</Button>
    </div>
    {@render actionNote('manage')}

    <h3>Перезапуск сервисов</h3>
    <div class="row">
      <Button disabled={busy} onclick={() => restart('vpn', 'туннель')}>Туннель</Button>
      <Button disabled={busy} onclick={() => restart('dns', 'DNS')}>DNS</Button>
      <Button disabled={busy} onclick={() => restart('doh', 'шифрованный DNS')}>Шифрованный DNS</Button>
    </div>
    {@render actionNote('restart')}

    <h3>Фильтрация (DNS)</h3>
    <label>
      <span>Блокировка рекламы / взрослого контента</span>
      <Select bind:value={providerSel} disabled={busy}>
        {#each s.dns_providers ?? [] as p}
          <option value={p.id}>{p.name} — {p.description}</option>
        {/each}
      </Select>
    </label>
    <div class="row">
      <Button disabled={busy || !providerSel || providerSel === s.dns_provider} onclick={setProvider}>Применить</Button>
    </div>
    <p class="muted small">«Семейный» провайдер блокирует сайты 18+ и форсит безопасный поиск.</p>
    {@render actionNote('dns')}

    <!-- Управление туннелем свёрнуто: это самый объёмный блок панели, а нужен он в редкие дни,
         когда что-то сломалось. Открывается сам по ссылкам из hero-баннера (tunnelOpen). -->
    <details class="group" id="tunnel-group" bind:open={tunnelOpen}>
    <summary>Туннель — заменить сервер или сменить протокол</summary>

    <!-- Замена сервера АКТИВНОГО туннеля. Метод, подпись и placeholder — из каталога протоколов. -->
    <h3 id="replace-tunnel">Замена сервера ({active.name})</h3>
    <p class="muted small">Туннель перестал работать — вставьте свежий конфиг от своего сервера.
      Если новый не отзовётся, прежний вернётся сам.</p>
    <label>
      <span>{active.confLabel}</span>
      <textarea bind:value={replaceConf} rows="5" disabled={busy}
        placeholder={active.placeholder}></textarea>
      <ConfCheck id={active.id} text={replaceConf} />
    </label>
    {#if active.file}
      <label class="file">
        <span>…или загрузить файлом</span>
        <input type="file" accept=".conf,text/plain" onchange={onReplaceFile} disabled={busy} />
      </label>
    {/if}
    {#if active.id === 'hysteria2'}{@render speedFields()}{/if}
    <div class="row">
      <Button disabled={busy || replaceConf.trim().length === 0} onclick={replaceTunnel}>
        {replacePhase === 'running' ? 'Применяю…' : 'Заменить конфиг'}
      </Button>
    </div>
    {#if replacePhase === 'running'}
      <p><span class="spinner"></span> Применяю новый конфиг — при сбое прежний вернётся автоматически.</p>
    {/if}
    {@render actionNote('replace')}
    {#if replaceLog && replacePhase !== 'idle'}
      <details open={replacePhase === 'fail'}>
        <summary>Журнал замены</summary>
        <pre class="log">{replaceLog}</pre>
      </details>
    {/if}

    <!-- Full-тир не установлен: либо кнопка догрузки (железо тянет), либо честное объяснение,
         почему её нет. Молчать нельзя — иначе человек не поймёт, почему у него нет функции,
         о которой написано в документации. -->
    {#if !s.full_installed}
      <h3 id="full-tier">Запасные туннели — если этот не выручает</h3>
      {#if s.full_capable}
        <p class="muted small">Два запасных туннеля: <strong>VLESS+Reality</strong> — если интернет
          через VPN вообще не открывается, <strong>Hysteria2</strong> — если открывается, но
          тормозит и рвётся. Кнопка скачает общий для них компонент <code>sing-box</code> (~11 МБ).
          <strong>Текущий туннель продолжит работать.</strong></p>
        <details class="more">
          <summary>Подробнее</summary>
          <p class="muted small">Компонент ставится один раз и занимает на флеше роутера ~42 МБ.
            Переключиться можно потом, когда появится ссылка от сервера, и так же вернуться назад.</p>
        </details>
        <div class="row">
          <Button disabled={busy || fullPhase === 'running'} onclick={enableFullTier}>
            {fullPhase === 'running' ? 'Устанавливаю…' : 'Установить компонент'}
          </Button>
        </div>
        {#if fullPhase === 'running'}
          <p><span class="spinner"></span> Скачиваю компонент — это может занять минуту.</p>
        {/if}
        {#if fullLog && fullPhase !== 'idle'}
          <details open={fullPhase === 'fail'}>
            <summary>Журнал установки</summary>
            <pre class="log">{fullLog}</pre>
          </details>
        {/if}
      {:else}
        <p class="muted small">Два запасных туннеля (VLESS+Reality и Hysteria2)
          <strong>на этом роутере недоступны</strong>{#if fullMissing}: {fullMissing}{/if}. Они
          считаются программой, а не ядром — на слабом железе это медленнее самого интернета.</p>
        {#if s.full_missing?.includes('flash')}
          <p class="muted small">Место можно освободить (по SSH <code>apk del</code> ненужные
            пакеты) или подключить USB-флешку (extroot) — тогда кнопка появится.</p>
        {/if}
      {/if}
    {/if}
    <!-- ЗА пределами {#if !full_installed}: после успешной догрузки блок с кнопкой исчезает, и
         сообщение об успехе исчезло бы вместе с ним — ровно в тот момент, когда его читают. -->
    {@render actionNote('full')}

    <!-- Смена туннеля: СНАЧАЛА выбор направления по симптому (как в мастере), потом одно поле
         ссылки. Раньше здесь было по блоку на протокол — три похожих поля подряд на одной
         странице, и вставить ссылку в чужое поле было проще, чем в своё. AmneziaWG доступен
         всегда, Full-протоколы — когда компонент установлен (иначе выше кнопка догрузки). -->
    {#if targets.length > 0}
      <h3 id="switch-tunnel">Сменить туннель</h3>
      <p class="muted small">Сейчас активен <strong>{active.name}</strong>. Сайты, DNS и режим
        сохранятся, мастер проходить не нужно. Не поднимется — прежний вернётся сам.</p>
      {#each targets as p}
        <Radio bind:group={switchPick} value={p.id} disabled={busy}>
          <strong>{p.symptom}</strong> — {p.why}
          <br /><small class="muted">Протокол: {p.name}</small>
        </Radio>
      {/each}
      <label>
        <span>{pick.confLabel}</span>
        <textarea bind:value={switchConfs[switchPick]} rows="4" disabled={busy}
          placeholder={pick.placeholder}></textarea>
        <ConfCheck id={pick.id} text={switchConfs[switchPick]} />
      </label>
      {#if pick.file}
        <label class="file">
          <span>…или загрузить файлом</span>
          <input type="file" accept=".conf,text/plain" onchange={(e) => onSwitchFile(e, switchPick)} disabled={busy} />
        </label>
      {/if}
      {#if switchPick === 'hysteria2'}{@render speedFields()}{/if}
      <div class="row">
        <Button disabled={busy || (switchConfs[switchPick] ?? '').trim().length === 0} onclick={() => switchTo(pick)}>
          {switchPhase === 'running' && switchTarget === switchPick ? 'Переключаю…' : `Переключиться на ${pick.name}`}
        </Button>
      </div>
      {#if switchPhase === 'running'}
        <p><span class="spinner"></span> Поднимаю {protocolInfo(switchTarget).name} — при сбое
          вернётся {active.name}.</p>
      {/if}
      {@render actionNote('switch')}
      {#if switchLog && switchPhase !== 'idle'}
        <details open={switchPhase === 'fail'}>
          <summary>Журнал переключения</summary>
          <pre class="log">{switchLog}</pre>
        </details>
      {/if}
    {/if}
    </details>

    <!-- Поддержка. Стоит ПЕРЕД опасной зоной и НЕ свёрнута осознанно: человек, у которого не
         работает, должен найти путь «спросить» раньше, чем кнопку «сбросить всё». -->
    <h3 id="support">Если что-то не работает</h3>
    <p class="muted small">Что-то сломалось — или есть идея, как сделать лучше? Напишите мне в
      Telegram — <a href={SUPPORT.telegramUrl} target="_blank"
      rel="noreferrer">{SUPPORT.telegram}</a>: отвечаю всем, и каждое сообщение превращается
      в правку. Проект и документация:
      <a href={SUPPORT.page} target="_blank" rel="noreferrer">на GitHub</a>.</p>
    <p class="muted small">Приложите диагностику: логи, состояние сети, версии.
      <strong>Пароли и ключи вырезаются</strong> — файл вы увидите здесь до отправки, сам он
      никуда не уходит.</p>
    <div class="row">
      <Button disabled={busy || diagPhase === 'running'} onclick={collectDiagnostics}>
        {diagPhase === 'running' ? 'Собираю…' : 'Собрать диагностику'}
      </Button>
      {#if diagPhase === 'ok'}
        <Button onclick={downloadDiagnostics}>Скачать файл</Button>
      {/if}
    </div>
    {@render actionNote('support')}
    {#if diagPhase === 'ok'}
      <p class="muted small">
        {#if diagRemoved.length > 0}
          Вырезано: {diagRemoved.join('; ')}. Адрес сервера оставлен — без него причину не найти.
        {:else}
          Секретов известных форм не нашлось. Всё равно пролистайте текст перед отправкой.
        {/if}
      </p>
      <details open>
        <summary>Что будет отправлено</summary>
        <pre class="log">{diagText}</pre>
      </details>
    {/if}

    <details class="group danger-group" id="danger-group" bind:open={dangerOpen}>
    <summary>Опасная зона</summary>
    {#if !resetArmed}
      <Button variant="danger" disabled={busy} onclick={() => (resetArmed = true)}>Сбросить настройку cheburnet…</Button>
    {:else}
      <!-- Честно перечисляем и то, что останется: «сбросить всё» люди читают как «удалить
           программу», а это не так — и обнаружить расхождение постфактум хуже, чем прочитать
           заранее. Списками, а не прозой: два перечня сравниваются взглядом. -->
      <p class="warn">Роутер вернётся к обычной маршрутизации — весь трафик пойдёт напрямую, без VPN.</p>
      <ul class="small">
        <li><strong>Снимется:</strong> туннель, разделение трафика, шифрованный DNS, фильтрация.</li>
        <li><strong>Останется:</strong> программа и эта панель, Wi-Fi, пароль роутера.</li>
      </ul>
      <p class="muted small">Настроить заново можно сразу отсюда — ссылка на мастер появится после
        сброса. Удалить полностью — <code>apk del cheburnet</code> по SSH.</p>
      <label>
        <span>Введите слово <code>RESET</code> для подтверждения</span>
        <Input type="text" bind:value={resetWord} placeholder="RESET" />
      </label>
      <div class="row">
        <Button disabled={busy} onclick={() => { resetArmed = false; resetWord = ''; }}>Отмена</Button>
        <Button variant="danger" disabled={busy || !resetOk} onclick={factoryReset}>
          Подтвердить сброс
        </Button>
      </div>
    {/if}
    {#if resetPhase === 'running'}
      <p><span class="spinner"></span> Снимаю конфигурацию — роутер на несколько секунд
        перезапустит сеть.</p>
    {/if}
    {@render actionNote('danger')}
    <!-- Путь назад в мастер: ссылка несёт свежий токен, выпущенный сбросом (reset.uc), поэтому
         человек проходит настройку сразу и не упирается в «запустите bootstrap по SSH».
         Токена нет (метод не ответил) — честно показываем путь через SSH, а не битую ссылку. -->
    {#if resetPhase === 'ok'}
      {#if resetToken}
        <p class="ok-msg">Можно настраивать заново:
          <a href="?token={encodeURIComponent(resetToken)}">открыть мастер настройки</a>.</p>
      {:else}
        <p class="muted small">Чтобы настроить заново, запустите команду установки по SSH — она
          напечатает новую ссылку на мастер.</p>
      {/if}
    {/if}
    </details>
  {:else}
    <p class="muted">Загрузка…</p>
  {/if}

  <hr />
  <Button onclick={reinstall}>Настроить заново</Button>
  <!-- Подпись обязательна: кнопка стоит сразу под «Опасной зоной» и без неё читается как второй
       способ всё стереть. -->
  <p class="muted small">Пройти мастер заново. Текущая настройка работает до конца установки.</p>

  {#if loginOpen}
    <div class="modal-back" role="presentation" onclick={() => (loginOpen = false)}>
      <!-- svelte-ignore a11y_no_static_element_interactions, a11y_click_events_have_key_events -->
      <div class="modal" onclick={(e) => e.stopPropagation()}>
        <h3>Вход в управление</h3>
        <p class="muted small">Пароль администратора роутера (root) — тот, что задан при установке.</p>
        <label>
          <span>Пароль</span>
          <Input
            type="password"
            bind:el={loginInput}
            bind:value={loginPass}
            autocomplete="current-password"
            onkeydown={(e) => e.key === 'Enter' && doLogin()}
          />
        </label>
        {#if loginError}<p class="warn">{loginError}</p>{/if}
        <div class="row">
          <Button onclick={() => (loginOpen = false)}>Отмена</Button>
          <Button
            variant="primary"
            disabled={loginPass.length === 0}
            onclick={doLogin}
          >Войти</Button>
        </div>
      </div>
    </div>
  {/if}
</Card>
