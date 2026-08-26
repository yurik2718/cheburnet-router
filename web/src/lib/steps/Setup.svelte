<script>
  // Props: onSubmit(args для install) / onBack; wirelessPresent (false → без Wi-Fi, null → необязателен);
  // initial («Назад» не теряет введённое); dnsProviders/dnsProviderDefault (каталог из status);
  // fullAvailable (железо тянет Full → доступны Reality/Hysteria2, иначе строки неактивны с причиной
  // из fullReasons); acceptRisk (soft-провалы preflight приняты — флаг едет в install).
  // ГЛАВНОЕ: выбор туннеля идёт ОТ СИМПТОМА, не от названий протоколов — тексты в PROTOCOLS (logic.js).
  import { MIN_PASS, SSID_MAX, WIFI_KEY_MIN, validateSetup, BRUTAL_WARNING, checkConf,
           protocolList, protocolInfo, defaultProtocol, SPEED_DEFAULTS } from '../logic.js';
  import Card from '../ui/Card.svelte';
  import Button from '../ui/Button.svelte';
  import Input from '../ui/Input.svelte';
  import Radio from '../ui/Radio.svelte';
  import Select from '../ui/Select.svelte';
  import ConfCheck from '../ui/ConfCheck.svelte';

  let { onSubmit, onBack, wirelessPresent = null, dnsProviders = [], dnsProviderDefault = '', fullAvailable = false, fullReasons = [], acceptRisk = false, urlToken = '', initial = null } = $props();

  // Показываем Wi-Fi везде, кроме точно-нет-радио. Обязателен только при точно-есть-радио.
  const showWifi = $derived(wirelessPresent !== false);
  const wifiRequired = $derived(wirelessPresent === true);

  const protocols = protocolList();

  // Посев из initial намеренно одноразовый: «Назад» с подтверждения пересоздаёт компонент,
  // и поля должны вернуть ранее введённое, а не следить за пропом.
  // Дефолт: на Full-железе — VLESS+Reality (закрывает самую частую поломку «VPN не поднимается»),
  // на слабом — AmneziaWG без выбора. См. defaultProtocol и ADR 0004.
  // svelte-ignore state_referenced_locally
  let protocol = $state(initial?.protocol ?? defaultProtocol(fullAvailable));
  // Конфиги хранятся ПО ПРОТОКОЛАМ: переключение радио не теряет уже вставленное (человек может
  // сравнить два варианта, не набирая заново).
  // svelte-ignore state_referenced_locally
  let confs = $state({
    awg: initial?.awg_conf ?? '',
    reality: initial?.reality_conf ?? '',
    hysteria2: initial?.hysteria2_conf ?? '',
  });
  // Brutal (Hysteria2): по умолчанию скорость НЕ объявляем — sing-box тогда использует BBR и
  // подстраивается сам. Ручной режим включается осознанно, см. предупреждение в разметке.
  let declareSpeed = $state(false);
  let speedDown = $state(SPEED_DEFAULTS.down);
  let speedUp = $state(SPEED_DEFAULTS.up);
  // svelte-ignore state_referenced_locally
  let rootPass = $state(initial?.root_password ?? '');
  // svelte-ignore state_referenced_locally
  let rootPass2 = $state(initial?.root_password ?? '');
  // svelte-ignore state_referenced_locally
  let ssid = $state(initial?.ssid ?? '');
  // svelte-ignore state_referenced_locally
  let wifiKey = $state(initial?.wifi_key ?? '');
  // Direct-список предзаполнен зонной записью: dnsmasq матчит домены по суффиксу, поэтому одна
  // запись верхнего уровня (например «ru») покрывает все домены этой зоны — без больших списков.
  // Это редактируемый дефолт: содержимое списка решает пользователь.
  // svelte-ignore state_referenced_locally
  let domainsText = $state(initial?.domains?.join('\n') ?? 'ru');
  // Токен: ранее введённый → из ссылки (?token=…) → пусто (ручной ввод).
  // svelte-ignore state_referenced_locally
  let token = $state(initial?.token ?? urlToken ?? '');
  // Токен пришёл из ссылки → поле не показываем (лишний технический вопрос для человека,
  // который просто кликнул по ссылке из терминала); «изменить» раскрывает ручной ввод.
  // svelte-ignore state_referenced_locally
  let tokenEditable = $state(!(urlToken && token === urlToken));
  // DNS-фильтрация: выбранный провайдер (initial → ранее выбранный → дефолт каталога).
  // svelte-ignore state_referenced_locally
  let dnsProvider = $state(initial?.dns_provider ?? dnsProviderDefault ?? '');
  let error = $state('');
  let errorField = $state(''); // виновное поле из validateSetup — подсветка + прокрутка
  const fieldEls = {}; // DOM-узлы полей по имени (bind:this), для scrollIntoView

  // Живые подсказки до сабмита. Показываем после ухода из поля (blur) либо когда второй пароль
  // догнал первый по длине — иначе «не совпадают» дёргается на каждой набранной букве.
  let pass2Left = $state(false);
  let wifiKeyLeft = $state(false);
  const passMismatch = $derived(
    rootPass2.length > 0 && rootPass2 !== rootPass && (pass2Left || rootPass2.length >= rootPass.length)
  );
  const wifiKeyShort = $derived(wifiKeyLeft && wifiKey.length > 0 && wifiKey.length < WIFI_KEY_MIN);

  const active = $derived(protocolInfo(protocol));

  // Живые проверки снимают подсветку прошлого сабмита, как только поле исправлено, — иначе
  // зелёная галка ConfCheck соседствует с красной рамкой.
  $effect(() => {
    if (errorField === 'conf' && (confs[active.id] ?? '').trim()
        && !checkConf(active.id, confs[active.id].trim())) errorField = '';
  });
  $effect(() => {
    if (errorField === 'rootPass2' && rootPass === rootPass2) errorField = '';
  });

  // Загрузка конфига файлом — только у протоколов с `file: true` (.conf у AmneziaWG; ссылку
  // файлом не приносят). Пишем в АКТИВНЫЙ протокол, а не в awg жёстко: иначе появление второго
  // файлового протокола молча уводило бы файл не в то поле.
  async function onFile(e) {
    const f = e.target.files?.[0];
    if (!f) return;
    confs[active.id] = await f.text();
  }

  // Валидация и сборка аргументов install — чистая validateSetup (logic.js, под vitest).
  function submit() {
    error = '';
    errorField = '';
    const r = validateSetup({
      protocol, fullAvailable, confs, declareSpeed, speedDown, speedUp,
      rootPass, rootPass2, showWifi, wifiRequired, ssid, wifiKey,
      dnsProvider, domainsText, token, acceptRisk,
    });
    if (r.error) {
      error = r.error;
      errorField = r.field ?? '';
      fieldEls[errorField]?.scrollIntoView({ behavior: 'smooth', block: 'center' });
      return;
    }
    onSubmit(r.args);
  }
</script>

<Card title="Настройка">
  {#if acceptRisk}
    <p class="note">Установка идёт на роутер слабее рекомендуемого — по вашему решению.
      Стабильность не гарантируем; при сбое изменения откатятся автоматически.</p>
  {/if}

  <h3>Каким туннелем пользоваться</h3>
  <p class="muted small">Ошибиться не страшно — туннель меняется потом из панели.</p>

  {#each protocols as p}
    {@const locked = p.full && !fullAvailable}
    <Radio bind:group={protocol} value={p.id} disabled={locked}>
      <strong>{p.symptom}</strong>{#if locked}<span class="badge-locked">недоступно</span>{/if} — {p.why}
      <!-- &nbsp; намеренно: Svelte срезает ведущий пробел внутри {#if}, и получалось
           «VLESS+Reality· недоступен». -->
      <br /><small class="muted">Протокол: {p.name}{#if locked}&nbsp;· недоступен на этом роутере{/if}</small>
    </Radio>
  {/each}

  <!-- Причина — ОДНА строка под списком, а не под каждой запертой строкой: она общая для обоих
       Full-протоколов, и продублированная жирным дважды была самым заметным текстом на экране,
       где человек вообще-то выбирает туннель. -->
  {#if !fullAvailable && fullReasons.length > 0}
    <p class="muted small">Почему недоступны: {fullReasons.join('; ')}.</p>
  {/if}

  <details class="more">
    <summary>Чем они отличаются подробнее</summary>
    <ul class="small">
      {#each protocols as p}
        <li><strong>{p.name}</strong> — {p.whyMore}</li>
      {/each}
    </ul>
  </details>

  {#if fullAvailable}
    <p class="muted small">Для VLESS+Reality и Hysteria2 нужен компонент <code>sing-box</code> —
      он скачается сам во время установки (~11 МБ).</p>
  {/if}

  <label bind:this={fieldEls.conf} class:field-invalid={errorField === 'conf'}>
    <span>{active.confLabel}</span>
    <textarea
      bind:value={confs[active.id]}
      rows={active.file ? 8 : 6}
      placeholder={active.placeholder}
    ></textarea>
    <ConfCheck id={active.id} text={confs[active.id]} hint={active.confHint} />
    {#if !(confs[active.id] ?? '').trim()}
      <small class="muted">Нет ни подписки, ни сервера?
        <a href="https://github.com/andreiyurik/cheburnet-router#что-нужно-и-сколько-стоит"
          target="_blank" rel="noreferrer">Как получить — за 10–15 минут</a></small>
    {/if}
  </label>
  {#if active.file}
    <label class="file">
      <span>…или загрузить файлом</span>
      <input type="file" accept=".conf,text/plain" onchange={onFile} />
    </label>
  {/if}

  <!-- Brutal только у Hysteria2. Голое поле «Мбит/с» здесь было бы вредным: завышенное значение
       раздувает очередь и делает связь ХУЖЕ, причём молча — ошибок в логах не будет. Поэтому
       по умолчанию режим автоматический, а ручной снабжён прямым предупреждением. -->
  {#if protocol === 'hysteria2'}
    <h3>Скорость канала</h3>
    <Radio bind:group={declareSpeed} value={false}>
      <strong>Подбирать автоматически</strong> — рекомендуем. Туннель сам определяет,
      сколько может взять, и подстраивается под канал.
    </Radio>
    <Radio bind:group={declareSpeed} value={true}>
      <strong>Указать вручную</strong> — иногда выжимает больше на канале с потерями,
      но только если цифры честные.
    </Radio>
    {#if declareSpeed}
      <p class="warn">{BRUTAL_WARNING} Не знаете точных цифр — выберите «автоматически».</p>
      <label bind:this={fieldEls.speed} class:field-invalid={errorField === 'speed'}>
        <span>Скорость приёма (Мбит/с)</span>
        <Input type="number" min="1" max="10000" bind:value={speedDown} />
      </label>
      <label class:field-invalid={errorField === 'speed'}>
        <span>Скорость отдачи (Мбит/с)</span>
        <Input type="number" min="1" max="10000" bind:value={speedUp} />
      </label>
    {/if}
  {/if}

  <label>
    <span>Сайты напрямую</span>
    <textarea
      bind:value={domainsText}
      rows="3"
      placeholder="ru&#10;example.com"
    ></textarea>
    <small class="muted">Остальное — через туннель. Запись зоны (<code>ru</code>) покрывает все
      сайты в ней; отдельные — своей строкой.</small>
  </label>

  <h3>Пароль роутера</h3>
  <label bind:this={fieldEls.rootPass} class:field-invalid={errorField === 'rootPass'}>
    <span>Пароль администратора (root)</span>
    <Input type="password" bind:value={rootPass} autocomplete="new-password" placeholder="минимум {MIN_PASS} символов" />
    <small class="muted">Им вы входите в роутер по SSH и в панель управления. Запомните его.</small>
  </label>
  <label bind:this={fieldEls.rootPass2} class:field-invalid={errorField === 'rootPass2' || passMismatch}>
    <span>Повторите пароль</span>
    <Input type="password" bind:value={rootPass2} autocomplete="new-password" placeholder="ещё раз тот же пароль"
      onblur={() => (pass2Left = true)} />
    {#if passMismatch}<small class="warn">Пароли не совпадают.</small>{/if}
  </label>

  {#if showWifi}
    <h3>Wi-Fi {#if wifiRequired}<em class="req">(обязательно)</em>{:else}<em>(необязательно)</em>{/if}</h3>
    {#if wifiRequired}
      <p class="muted small">У этого роутера есть Wi-Fi — задайте имя сети и пароль, чтобы включить его.</p>
    {/if}
    <label bind:this={fieldEls.ssid} class:field-invalid={errorField === 'ssid'}>
      <span>Имя сети (SSID)</span>
      <Input type="text" bind:value={ssid} maxlength={SSID_MAX} placeholder="например, MyHome" />
    </label>
    <label bind:this={fieldEls.wifiKey} class:field-invalid={errorField === 'wifiKey' || wifiKeyShort}>
      <span>Пароль Wi-Fi</span>
      <Input type="password" bind:value={wifiKey} autocomplete="new-password" placeholder="минимум {WIFI_KEY_MIN} символов"
        onblur={() => (wifiKeyLeft = true)} />
      {#if wifiKeyShort}
        <small class="warn">Минимум {WIFI_KEY_MIN} символов — сейчас {wifiKey.length}.</small>
      {:else}
        <small class="muted">WPA2/WPA3 (если доступно).</small>
      {/if}
    </label>
    {#if wirelessPresent === null}
      <small class="muted">Не удалось узнать, есть ли у роутера Wi-Fi — заполните, если он есть; иначе оставьте пустым.</small>
    {/if}
  {/if}

  {#if dnsProviders.length > 0}
    <h3>Фильтрация (DNS)</h3>
    <label>
      <span>Блокировка рекламы / взрослого контента</span>
      <Select bind:value={dnsProvider}>
        {#each dnsProviders as p}
          <option value={p.id}>{p.name} — {p.description}</option>
        {/each}
      </Select>
      <small class="muted">«Семейный» провайдер дополнительно блокирует сайты 18+ и форсит безопасный поиск.</small>
    </label>
  {/if}

  {#if tokenEditable}
    <label bind:this={fieldEls.token} class:field-invalid={errorField === 'token'}>
      <span>Код установки</span>
      <Input type="text" bind:value={token} placeholder="напечатан в терминале после команды установки" />
    </label>
    <small class="muted">Проще: откройте в браузере всю ссылку из терминала (начинается на
      http://192.168.1.1/cheburnet/?token=…) — код уже в ней, вводить вручную не придётся.</small>
  {:else}
    <p class="muted small">✓ Код установки получен из ссылки.
      <Button variant="link" type="button" onclick={() => (tokenEditable = true)}>Изменить</Button>
    </p>
  {/if}

  {#if error}<p class="warn">{error}</p>{/if}

  <div class="row">
    <Button onclick={onBack}>Назад</Button>
    <Button variant="primary" onclick={submit}>Установить</Button>
  </div>
</Card>
