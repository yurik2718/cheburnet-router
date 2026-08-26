# engine/steps/singbox — Full-тир: VLESS+Reality и Hysteria2 через sing-box

Тяжёлый тир для мощного железа (см.
[0004-multi-protocol-tiers](../../../docs/kb/decisions/0004-multi-protocol-tiers.md)). Два
протокола, **разные поломки**: `vless://…` (VLESS+Reality) — когда трафик вообще не проходит;
`hysteria2://…` / `hy2://…` — когда проходит, но теряет пакеты. Плюс сырой JSON-конфиг sing-box
(advanced). Шаг разбирает вход, генерирует `/etc/sing-box/config.json` и включает сервис.
`singtun0` — дефолт-маршрут для всего, что не помечено `direct` (как `awg0` в Light-тире).

## Один шаг на два протокола (это инвариант, а не совпадение)

Протокол-специфичны РОВНО две чистые функции на каждый: разбор ссылки и сборка объекта
`outbound`. TUN-инбаунд, netifd-секции, half-routes, `sing-box check`, сервис и teardown —
**общие**. Отсюда и общий туннельный интерфейс: firewall/policy-routing/NAT-зона не знают, какой
протокол активен, а проба и признак здоровья одни на оба (ADR 0004, «единый контракт транспорта»).

## Инвариант (у AWG — тот же самый механизм, см. `steps/vpn`)

> **`auto_route: false`** — маршрутизацией управляет **ядро**
> ([policy-routing](../../../docs/kb/concepts/policy-routing.md)), а **не** sing-box. sing-box
> лишь презентует TUN-интерфейс `singtun0`; помеченный трафик в него направляет тот же
> firewall/routing-слой, что и для `awg0`. Так туннель становится **взаимозаменяемым**
> (Light ↔ Full) без переписывания data-plane.

`auto_detect_interface: true` — серверное соединение sing-box уходит в реальный WAN, не
зацикливаясь обратно в TUN.

## Кто ставит маршрут «весь трафик в туннель»

Раз `auto_route: false`, маршрут в `singtun0` держит **netifd**, а не sing-box (та же схема, что
у AWG в `steps/vpn` — half-routes на интерфейсе туннеля). Шаг создаёт тонкий интерфейс
`network.singtun` (`proto none` поверх устройства `singtun0` — адрес назначает сам sing-box) и
две **half-route** `0.0.0.0/1` + `128.0.0.0/1`. Они специфичнее WAN-дефолта `0.0.0.0/0`, поэтому
побеждают его в main-таблице **без удаления WAN** (приём `redirect-gateway def1` у OpenVPN). WAN
обязан остаться: по нему уходит direct-трафик (policy-routing) и сам sing-box коннектится к
Reality-серверу. netifd переустанавливает маршрут при пересоздании TUN (рестарт sing-box) и
откатывается обычным uci-snapshot'ом. IPv4-only: TUN у нас v4; от утечки IPv6 защищает
kill-switch firewall-шага, а не blackhole в v4-only TUN.

## Почему sing-box возвращается (осознанно)

ADR 0001 убрал sing-box из v1 ради образовательности (no black box). Full-тир возвращает его
**опционально**, под приоритеты «устойчивость к фильтрации» и «работа на плохом канале» — там, где
AmneziaWG не выручает. Light-тир (AWG в ядре) остаётся дефолтом и образовательным сердцем;
sing-box гейтится preflight'ом по железу. Бинарь — предпочтительно `sing-box-tiny`: те же нужные
теги (`with_utls` → Reality, `with_quic` → Hysteria2), но легче.

## Чистое ядро vs импурный apply

- **`singbox.uc`** — `parse_vless_link` / `parse_hysteria2_link` (ссылка → поля),
  `build_singbox_config` / `build_hysteria2_config` (поля → outbound), `wrap_outbound` (общая
  обвязка: TUN + route), `parse_port_ranges` (port hopping), `parse_input` (диспетч по префиксу),
  `build_singbox_plan` (→ config + uci). **Чистые функции**, тесты — [tests/](tests/).
- **`apply.uc`** — **router-side**: запись во временный файл → **`sing-box check`** → атомарный
  `mv` на место → uci-включение сервиса (`sing-box.main`) → `enable`+`restart`. Порядок важен:
  битый конфиг не становится живым даже на миг, а причина отказа (текст sing-box) уезжает в
  install-лог вместо безликого «туннель не поднялся» через 30 с. `--teardown` выключает сервис и
  убирает конфиг. QEMU.
- **`plan.uc`** — CLI чистого ядра: вход со stdin → конфиг + uci-операции, без применения.

## Граница доверия и валидация

Вход — **пользовательский** → валидируем (CLAUDE.md). Reality требует `uuid`/`host`/`port`/
`pbk`/`sni`; `security`, если задан, обязан быть `reality` («голый» VLESS ценности не несёт, ADR
0004). `sid`/`fp`/`flow` опциональны (дефолты `xtls-rprx-vision` / `chrome`; пустой `sid` → ключа
нет). Hysteria2 требует пароль (часть до `@`) и `host`; порт можно опустить (→ 443).

Часть параметров hy2-ссылки sing-box **не умеет**, и мы отвергаем их ГРОМКО — молчание отправило
бы человека к 30-секундной пробе без причины: `pinSHA256` без `insecure=1` (пиннинг не
поддерживается, а подставить `insecure` самим = тихо снять проверку сертификата), `ech`,
`obfs=gecko` (sing-box умеет только `salamander`), `obfs` без пароля, полоса, указанная лишь с
одной стороны. Полоса (`up_mbps`/`down_mbps`) **дефолта не имеет**: пусто = BBR в sing-box, а
выдуманная цифра включила бы Brutal, который берёт объявленную скорость силой.

Нет обязательного поля или битый JSON → `plan.ok=false`, шаг **не трогает систему**.

## Идемпотентность

Именованная секция `sing-box.main` + `delete`-before-`set` → повторный запуск сходится к тому
же состоянию. Конфиг пишется атомарно (`*.tmp` → `mv`), чтобы sing-box не прочитал полу-файл.

## Использование

```sh
echo 'vless://…'     | ucode -R engine/steps/singbox/plan.uc        # конфиг + uci-план
echo 'hysteria2://…' | ucode -R engine/steps/singbox/plan.uc        # то же для Hysteria2
echo 'vless://…'     | ucode -R engine/steps/singbox/apply.uc --dry-run
ucode -R engine/steps/singbox/apply.uc --teardown                   # снять
```

## Тесты

`make test-engine` — два файла: `tests/test_singbox.uc` (Reality) и `tests/test_hysteria2.uc`
(Hysteria2). Разделены нарочно: их ломают разные правки, и при провале сразу видно, какая ось
поехала. Покрыто: разбор обеих ссылок (urldecode, `[ipv6]:port`, CRLF-хвост, порт вне диапазона,
голый IPv6 → отказ), port hopping (`443,5000-6000`, форма `mport=`, перевёрнутый диапазон),
валидация обоих протоколов и границы поддержки hy2-параметров, генерация outbound (типы значений,
`server_ports` без `server_port`), **инвариант `auto_route=false`** и общий `singtun0`, опт-ин
полосы, диспетч ссылка/ссылка/JSON/мусор, план (uci enable + conffile, teardown).

Живьём (`make qemu-hysteria`): сборка sing-box РЕАЛЬНО принимает наш hysteria2-конфиг, битый
конфиг отвергается ДО подмены рабочего, TUN и маршруты встают, teardown чистит.

## Не здесь (отдельные фазы)

- **preflight-гейт** Full-тира (AES-arch / RAM / бинарь ставится) — `engine/preflight`. Гейт ОДИН
  на оба протокола: тот же бинарь, тот же TUN, та же цена в userspace.
- **Маршрутизация** в `singtun0` и kill-switch — `engine/steps/firewall` (параметр tunnel-iface).
  Портов в правилах нет → port hopping Hysteria2 не требует здесь ни строчки.
- **Догрузка бинаря** — `engine/install/install-singbox.sh` (порядок: `sing-box-tiny` → `sing-box`,
  критерий успеха = появился бинарь): кнопкой в панели (`install_full_tier`) или **автоматически**
  при выборе Full-протокола в мастере (`run.uc` запускает её первым шагом, до snapshot; провал =
  чистый abort). Не этот шаг — он ждёт готовый бинарь.
- **Замена сервера** без переустановки — `engine/install/replace_singbox.uc` (один на оба протокола).
- **Автофолбэк** AWG→Reality (runtime-детект обрыва) — будущая фаза. Ведёт только на TCP-ось:
  Hysteria2 живёт на той же UDP-оси, что AWG, и упал бы вместе с ним.
- **Замер goodput/CPU под потерями** — `make qemu-netem`; живой сервер провайдера — вне лабы.
