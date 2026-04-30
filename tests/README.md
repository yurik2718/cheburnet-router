# tests/

Тестовая инфраструктура `cheburnet-router`. Три уровня (см. план в `AGENTS.md`).

## Структура

```
tests/
├── lint.sh                 # T1 — единая точка статики (CI + локально)
├── unit/                   # T2 — bats-core тесты pure-функций
│   ├── test_json_escape.bats
│   ├── test_awg_conf_parser.bats
│   ├── test_awg_version_selection.bats
│   └── test_input_validation.bats
├── integration/            # T3a — реальный rpcd-cheburnet в sandbox
│   ├── helpers/sandbox.bash    # инфра: tmpdir + PATH-моки + ETC_*-overrides
│   ├── mocks/                  # PATH-shim'ы для uci, ubus, awg, jsonfilter ...
│   ├── test_get_status.bats
│   ├── test_install_start.bats
│   ├── test_mutations.bats
│   ├── test_acl_lockdown.bats
│   └── test_protocol.bats
├── fixtures/               # AWG-конфиги для unit-парсера
├── helpers/                # setup для unit-тестов
│   └── setup.bash
└── vendor/                 # git submodules: bats-core + расширения
    ├── bats-core/
    ├── bats-support/
    └── bats-assert/
```

После клона репо подтянуть submodules:

```bash
git submodule update --init --recursive
```

## T1 — статика (готово)

Один скрипт `tests/lint.sh` гоняется одинаково локально и в CI:

```bash
make lint
```

Что проверяется:

| # | Проверка | Зачем |
|---|---|---|
| 1 | `shellcheck --shell=sh --severity=warning` на 39 POSIX-скриптах | Большинство кода идёт в busybox-ash на роутер; нужен POSIX-режим |
| 2 | `shellcheck --shell=bash --severity=warning` на `setup.sh` | Хост-тулинг, использует bash-фичи |
| 3 | `sh -n` / `bash -n` на всех скриптах | Safety net поверх shellcheck |
| 4 | `python3 -m json.tool` на `web/rpcd-acl.json` + двух embedded-ACL heredoc'ах в `web/run-install.sh` и `setup/full-deploy.sh` | Кривая ACL-JSON ломает rpcd → веб-мастер мёртв |
| 5 | `sha256(bootstrap.sh)` совпадает с хэшем в `README.md` | Если рассинхронить — пользователь делает bootstrap, проверка подписи проваливается, установка не идёт |

CI: `.github/workflows/lint.yml` (push/PR → ubuntu-latest, `apt-get install shellcheck`, `make lint`).

### Локальные требования

- `bash`, `sh`, `python3` (обычно уже есть)
- `shellcheck` ≥ 0.8 — `apt-get install shellcheck` / `dnf install ShellCheck` / `brew install shellcheck`

### Если shellcheck ругается

Не глуши `# shellcheck disable=...` без объяснения. Допустимые причины:
- `SC3043` (`local`) на скриптах для роутера — busybox-ash поддерживает `local`, но POSIX — нет. Подавляй с пометкой "busybox-ash supports local".
- `SC2034` на `START`/`USE_PROCD` в `init.d/*` — переменные читает `/etc/rc.common`, который сорсит файл. Подавляй с пометкой "consumed by /etc/rc.common".

Всё остальное — чини, не глуши.

## T2 — unit-тесты (готово)

```bash
make test            # 68 тестов, ~3 секунды
```

Покрыто:

| Suite | Что тестирует | Источник истины |
|---|---|---|
| `test_json_escape.bats` | `json_escape` — экранирование для JSON-литерала. Round-trip через `python3 json.load`, попытки JSON-инъекции, unicode/emoji, CRLF | `lib/cheburnet-utils.sh` |
| `test_awg_conf_parser.bats` | `awg_get_iface`/`awg_get_peer`/`awg_endpoint_host`/`awg_endpoint_port`. v1.0 минимальный, v1.5 с CPS, отсутствующая `[Peer]`, IPv6 endpoint в скобках | то же |
| `test_awg_version_selection.bats` | `awg_pick_version` — выбор подходящего релиза awg-openwrt. wget-shim в `$PATH` мокает HEAD-запросы | то же |
| `test_input_validation.bats` | `cheburnet_valid_mode`/`tier`/`factory_confirm` — валидаторы пользовательского ввода из ubus. Все известные shell-инъекции отвергаются | то же |

### Зависимости

- `bash` ≥ 4 (для bats-core)
- `python3` (для round-trip-проверки JSON в `json_escape`)
- bats-core / bats-support / bats-assert — git submodules в `tests/vendor/`

### Добавление нового теста

1. Если функция новая — добавь в `lib/cheburnet-utils.sh` (только pure-функции, без side-effects).
2. Создай `tests/unit/test_<feature>.bats`:
   ```bash
   #!/usr/bin/env bats
   load '../helpers/setup'

   @test "функция: что проверяем" {
       run my_function "input"
       assert_success
       assert_output "expected"
   }
   ```
3. `make test` — должно стать N+1 тестов.

### Что НЕ тестируется юнитами (намеренно)

- Императивные `uci set` / `apk add` / `nft` — это тест busybox-uci, не нашего кода
- Поведение `rpcd-cheburnet` end-to-end (реальный ubus, реальный jsonfilter) — это T3
- AWG handshake, podkop split-routing — T3 / Уровень 4 (manual)

## T3a — integration через mock-окружение (готово)

```bash
make test-integration       # 64 теста, ~6 секунд
make test                   # unit + integration вместе, ~10 секунд
```

Стенд: реальный `web/rpcd-cheburnet` (без модификаций) запускается в каждом
тесте с переопределёнными системными путями (`STATE_DIR`, `INSTALL_DIR`,
`ETC_CHEBURNET`, `ETC_INIT_D` и т.д.) и `PATH`-prepend каталогом моков. Никакого
QEMU, никакого реального ubus.

| Suite | Тестов | Что покрывает |
|---|---|---|
| `test_get_status.bats` | 6 | pre/post-install statе, dns_up probe, валидность JSON |
| `test_install_start.bats` | 10 | защита токеном (нет файла / нет в payload / неверный / префикс), валидация ssid/wifi_key/root_pass/awg_conf |
| `test_mutations.bats` | 18 | factory_reset / mode_switch / set_blocklist_tier / service_restart / install_cancel + защита от shell-инъекций |
| `test_acl_lockdown.bats` | 17 | контракт `web/rpcd-acl.json` (pre-install) + heredoc-ACL в `run-install.sh` и `full-deploy.sh` (post-install) — bit-for-bit одинаковы, никаких лишних методов в unauth.write |
| `test_protocol.bats` | 13 | `list` возвращает все 8 методов, `install_progress` (idle / step / done / crashed), unknown method → JSON-error |

### Что НЕ покрывает T3a (намеренно)

- Реальный ACL-enforcement (это делает rpcd-демон по `acl.d/*.json`, не сам
  скрипт). Здесь проверяется только структура файлов; реальный enforce —
  ручной чек в `docs/RELEASE-CHECKLIST.md`.
- Полный путь bootstrap → install → ACL-lock через сеть (uhttpd, реальный
  ubus). Это T3b (QEMU-стенд, не реализован — нужен либо self-hosted runner с
  KVM, либо `libguestfs-tools`. См. `AGENTS.md`).
- Поведение setup-скриптов на роутере (apk add, modprobe, uci commit network).
  Это покрывается ручным smoke в чек-листе.

### Refactor в `web/rpcd-cheburnet` для тестируемости

В рамках T3a добавлены env-overrides системных путей (`ETC_CHEBURNET`,
`ETC_AWG_DIR`, `ETC_ADBLOCK_CFG`, `ETC_INIT_D`, `ETC_VPN_MODE_STATE`,
`USR_BIN_VPN_MODE`). Значения по умолчанию = жёсткие `/etc/cheburnet`,
`/etc/init.d` и т.п. — поведение в проде идентично. Тесты переопределяют их
через export.

## T3b — реальный QEMU+OpenWrt (не реализовано)

См. `docs/RELEASE-CHECKLIST.md`. Будет nightly или manual-trigger; через
self-hosted runner с KVM либо `libguestfs-tools`. Покрывает 3-4 жирных
сценария, которые принципиально нельзя замокать (ACL-enforcement через
реальный rpcd, POST через uhttpd с реальной сессией).

## T3c — RELEASE-CHECKLIST (готово)

`docs/RELEASE-CHECKLIST.md` — пункты, которые **нельзя** автоматизировать
(физическая кнопка, WPA3-handshake, реальный AWG, 24-часовой uptime). Гоняется
руками перед каждым тегом.
