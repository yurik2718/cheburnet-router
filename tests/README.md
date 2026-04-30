# tests/

Тестовая инфраструктура `cheburnet-router`. Три уровня (см. план в `AGENTS.md`).

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

## T2 — unit-тесты (не реализовано)

`make test` — заглушка. Будет bats-core по pure-функциям (`json_escape`, парсер AWG-конфига, валидаторы).

## T3 — QEMU integration (не реализовано)

`make qemu` — заглушка. Будет OpenWrt в виртуалке + сценарии bootstrap → install → ACL-lock.

См. `AGENTS.md` для полного плана.
