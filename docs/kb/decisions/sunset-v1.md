---
title: "Sunset v1 — чек-лист удаления старой версии"
tags: [decision, meta, historical]
aliases: [sunset-v1, снятие-v1]
status: done
date: 2026-07-10
updated: 2026-07-10
---

# Sunset v1 — чек-лист удаления старой версии

> **Статус: выполнено (2026-07-10).** v1 удалён из репозитория одним заходом правок вслед за
> релизом v2.0.1. Документ оставлен как исторический след решения — гейты ниже отмечены по
> факту на момент удаления, включая два принятых мейнтейнером компромисса (см. пометки).

Этот документ отвечает на вопрос «когда и как безопасно удалить v1, ничего не сломав».
Принцип: **сначала зелёный и зарелиженный v2, потом удаление** — не наоборот.

---

## Гейты: удалять v1 нельзя, пока не выполнено ВСЁ

- [x] **Паритет фич v2 ≥ v1.** Всё, что обещано пользователю, работает в v2:
  - [x] AmneziaWG (Light-тир) — покрыто `make qemu-smoke` + живым роутером.
  - [x] Кастомный DNS-фильтр (реклама / 18+) — `steps/doh`, 5 провайдеров.
  - [x] **VLESS+Reality (Full-тир) — НЕ блокер релиза** (решение мейнтейнера 2026-07-03:
        де-скоуп первого релиза, возврат в v2.1). v1 его тоже не имел, так что паритет
        не страдает; код Full-тира в дереве, но мастер его не предлагает и пакет
        cheburnet-full не собирается.
        См. [0004-multi-protocol-tiers](../decisions/0004-multi-protocol-tiers.md).
- [x] **v2 проверен «живьём».**
  - [x] `make qemu-smoke` (hermetic smoke движка).
  - [x] `make qemu-install` (DEPENDS + data-plane на реальных сервисах).
  - [x] Прогон на **реальном роутере** (GL-MT3000): bootstrap → install через веб-мастер →
        живой AWG-трафик и kill-switch → DNS-фильтр.
  - [ ] **Принято как компромисс:** QEMU-матрица arch (mipsel / aarch64) не прогонялась —
        только x86_64. Пункт был помечен «желательно», не блокирующим; риск на будущее —
        первый релиз под слабую arch может вскрыть то, что x86_64-QEMU не ловит.
- [x] **Дистрибуция настоящая, не плейсхолдер.** Своего feed'а нет осознанно (MVP-выбор, см.
      [docs/kb/architecture/bootstrap.md](../architecture/bootstrap.md)) — вместо него
      arch-независимый `.apk` (`PKGARCH:=all`) как ассет GitHub Release,
      `apk add --allow-untrusted`. Публикация по git-тегу в CI (`release.yml`) подтверждена
      живьём: v2.0.1 собран и опубликован, реальный однострочник поставил и обновил пакет
      на роутере.
- [x] **Релиз v2 выпущен** (тег `v2.0.1` + GitHub Release).
  - [ ] **Принято как компромисс:** обкаточный период — около 2 дней между релизом и
        удалением v1, короче, чем «разумный» подразумевал этот чек-лист изначально. Решение
        мейнтейнера — не блокирующий гейт задним числом.
- [x] **Документация v2 самодостаточна** — `docs/kb/` покрывает flash OpenWrt, AmneziaWG,
      split-routing, DNS, kill-switch, режимы, troubleshooting, upgrade, LAN-конфликт.

---

## Что удалено

**Корень:** `install.sh`, `setup.sh`, `AGENTS.md` (уроки перенесены в `CLAUDE.md`, раздел
«Уроки предыдущей архитектуры»).

**Каталоги v1:** `setup/`, `lib/`, `scripts/`, `configs/`, `backup/`, `web/`,
`vendor/podkop-install.sh` + `vendor/abl-install.sh` (`vendor/amneziawg-install.sh` остался —
используется bootstrap'ом v2). `assets/` — проверено, используется актуальным README, оставлен.

**Тесты v1:** `tests/unit/*.bats`, `tests/integration/` (+ `helpers/`, `mocks/`),
`tests/hardware/`, `tests/manual-release-checklist.md`, `tests/fixtures/` (были нужны только
удалённым unit-тестам), bats-submodules (`tests/vendor/`, `.gitmodules`),
`tests/qemu/{smoke,smoke-http,install,audit-setup}.sh`. Остались `smoke.sh`,
`webui.sh`, `install.sh`, `lib.sh`.

**Документация v1:** `docs/01-architecture.md` … `docs/10-upgrades.md`, `docs/commands.md`,
`docs/RELEASE-CHECKLIST.md` (заменён на [release-checklist.md](../meta/release-checklist.md)),
`docs/test-lan-conflict.md` (контент перенесён в
[reference/troubleshooting.md](../reference/troubleshooting.md)), `docs/router-too-small.md`
(решаемая им проблема — v1-specific, в v2 не воспроизводится), `docs/images/luci-podkop-*.png`.
`docs/00-flash-openwrt.md` **не удалён** — контент не зависит от v1/v2 (прошивка стокового
OpenWrt), переклассифицирован как общий шаг.

**CI/Makefile:** job'ы `test`/`qemu-smoke`/`qemu-install` из `test.yml`, targets
`qemu`/`qemu-http`/`qemu-install`/`test-unit`/`test-integration`/`hardware` из `Makefile`,
ветка `feat/v2` из триггеров `engine.yml` (сама ветка удалена ранее после merge).

---

## После удаления

- [x] `grep -ri "podkop\|sing-box\|setup/\|install.sh\|AGENTS.md"` по `docs/` и корню — не
      осталось висячих ссылок на удалённое (за вычетом этого исторического документа).
- [x] `README.md` описывает только путь установки через `bootstrap.sh`.
- [x] `CLAUDE.md` обновлён: раздел «миграция v1→v2» переписан в прошедшем времени, упоминания
      `AGENTS.md` убраны, раздел hard-won-уроков переформулирован (уже внутри v2, не «переносим»).
- [ ] `make lint && make test-engine` — прогнать после этого коммита (QEMU — руки мейнтейнера,
      нужен KVM/интернет, недоступны в среде правки).

---

## Порядок (кратко)

```
qemu-smoke + qemu-install зелёные в CI
  → проверка на реальном роутере
    → настоящий feed + подпись + публикация по тегу
      → РЕЛИЗ v2 (тег + Release, только Light-тир — Full отложен на v2.1)
        → обкатка без критичных регрессий
          → chore: sunset v1 (этот чек-лист)
```
