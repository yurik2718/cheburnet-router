# tests/qemu — VM smoke-тесты для cheburnet-router

Поднимают **релизный OpenWrt x86-64** (пин версии — в `lib.sh`) в qemu/KVM, накатывают движок и
проверяют, что он работает на **реальном** busybox-окружении (а не gawk/host-bash, на которых
гоняются T1/T2). Релиз, а не rolling snapshot: у пользователей стоит именно релиз, файл релиза
неизменен (пин не протухает), и только под релиз существует `kmod-amneziawg` из awg-openwrt.

## Запуск

| Команда | Что делает | Время | Интернет нужен? |
|---|---|---|---|
| `make qemu-smoke` | T3a — hermetic smoke движка: ubus-методы, граница доверия, rootpass→session.login, NAT-зона+nft+teardown | ~2мин | нет* |
| `make qemu-webui` | T3b — + uhttpd + HTTP/UI: раздача Svelte-бандла, ACL anon-vs-admin, session.login | ~3мин | да (apk add uhttpd-mod-ubus) |
| `make qemu-install` | T3c — установка через **apk** + data-plane против реальных сервисов (dnsmasq-full/https-dns-proxy) | ~5-8мин | да (apk) |
| `make qemu-reality` / `qemu-hysteria` | T3d/T3e — обвязка Full-тира: config.json + `sing-box check`, netifd-маршрут, проба, teardown; замер веса | ~4-6мин | да |
| `make qemu-netem` | T3f — goodput/CPU при потерях, QUIC против TCP (цифры в ADR 0004, релиз не гейтит) | ~6-10мин | да |
| `make qemu-rollback` | T3g — полная установка через ubus + откат при мёртвом сервере | ~5-8мин | да |
| `make qemu-reboot` | T3h — data-plane переживает перезагрузку | ~6-9мин | да |
| `make qemu-route-fallback` | T3i — WAN переподключился: half-routes и путь наружу целы | ~5-8мин | да |
| `make qemu-dns-fallback` | T3j — туннель умер: DNS жив резервным путём; сторож чинит инварианты | ~6-9мин | да |
| `make qemu-emergency` | T3k — аварийный режим: выключить защиту / вернуть | ~6-9мин | да |
| `make qemu-live-vps` / `qemu-live-install` | T4 — трафик насквозь через настоящий сервер; commit-ветка + ребут (нужен стенд `tests/vps/`, не CI) | ~10мин | да |

Полные описания — комментарии к целям в корневом `Makefile`.

Все запускаются из корня репо. При падении автоматически выводят последние 60 строк
serial-консоли VM и возвращают exit ≠ 0. (*первый запуск качает образ — дальше кэш.)

### T3a — `smoke.sh` (hermetic)

Деплоит движок **как пакет** (shim → `/usr/libexec/rpcd/cheburnet`, engine без `tests/` в
`/usr/share/cheburnet`, ACL из реестра) и проверяет на живом OpenWrt то, что юниты и dry-run'ы
не могут: регистрацию ubus-методов, границу доверия сквозь настоящий rpcd (required/токен-гейт/
confirm), `steps/rootpass` на реальном busybox `passwd` + **`session.login` этим паролем**
(ключевое допущение входа в панель), no-op wifi-шага без радио, NAT-зону + nft-цепочки +
`--teardown` на реальном fw4. Не покрывает: HTTP-слой
`/ubus` с ACL-инфорсментом (уровень T3b) и полный install (apk, AWG-сервер).

T3a НЕ зовёт `apk`/`wget` к github — все файлы кладутся напрямую через ssh+cat, интернет не нужен.

### T3b — `webui.sh` (требует интернета)

Путь **браузера**, а не прямых ubus-вызовов: `uhttpd` + `uhttpd-mod-ubus` раздают собранный
Svelte-бандл (`index.html` + hashed asset) и принимают JSON-RPC на `/ubus`. Проверяет:

- ACL-инфорсмент: anon-сессия может читать (`status`/`install_progress`), но получает `code=6`
  (`PERMISSION_DENIED`) на `set_mode`/`service_restart`/`factory_reset`.
- `install` гейтится install-токеном (см. [[../../docs/kb/architecture/reliability|reliability]]).
- `session.login` — отказ на неверном пароле, успех на верном (root-пароль из `steps/rootpass`).
- После входа admin-методы (`service_restart`) проходят; `factory_reset` с неверным `confirm`
  отдаёт доменную ошибку, не запускает reset.

Ставит `uhttpd-mod-ubus` через `apk add` — **поэтому нужен интернет в VM**.

### T3c — `install.sh` (установка через apk, нужен интернет)

Ставит DEPENDS пакета из **реального apk-feed** на живой OpenWrt и гоняет data-plane против
**настоящих** сервисов (а не подсунутых руками): проверяет, что `package/cheburnet/Makefile`
DEPENDS вообще резолвятся под arch; `dnsmasq` → `dnsmasq-full` swap; `dns`-шаг (реальный
dnsmasq-full перечитывает наш nftset); `doh`-шаг (реальный https-dns-proxy стартует с нашими
резолверами); preflight на живом `apk --simulate` даёт вердикт. **AmneziaWG ставится тем же
vendored-инсталлятором, что и на роутере**, и модуль грузится в ядро — проверка vermagic, которая
раньше жила только на железе. Реальный handshake с VPN-сервером и Wi-Fi-радио — вне охвата QEMU,
проверяются на железе (см.
[docs/kb/meta/release-checklist.md](../../docs/kb/meta/release-checklist.md)).

## Что НЕ покрывает

- **Реальный AmneziaWG/VLESS happy-path** на целевой arch: в QEMU kmod ставится и грузится, но
  handshake с живым сервером и arch-специфика (mips/arm) — ручной smoke на роутере перед релизом.
- **Браузерный рендеринг** (CSS, race conditions при кликах, JS-ошибки). T3b шлёт те же
  ubus-запросы, что и UI, но не кликает по кнопкам в реальном движке рендеринга.
- **Реальный Wi-Fi / nft kill-switch на целевой arch.** VM = x86-64; реальные роутеры — другие
  архитектуры с другим nft/hostapd.

## Артефакты

`tests/qemu/.work/` (в .gitignore) содержит:

- `openwrt-<версия>.img.gz` — кешированный образ (15 МБ); имя с версией, чтобы смена пина
  не подменяла кеш молча.
- `disk.img` — пересоздаётся из `.gz` каждый запуск (никакого state'а от прошлых прогонов).
- `id_ed25519` / `id_ed25519.pub` — переиспользуемый SSH-ключ для VM.
- `serial.log` — лог serial-консоли (полезен при падении).
- `cmd.fifo` — fifo для отправки команд в serial. Удаляется trap'ом на выходе.

Очистить кеш целиком: `rm -rf tests/qemu/.work` (только образ перекачается заново).

## Как перейти на новую версию OpenWrt

Пин живёт в `tests/qemu/lib.sh` (`OPENWRT_VERSION` + `IMG_SHA256`). Порядок — не формальность:
каждый пункт закрывает конкретный способ получить «зелёный» тест, ничего не проверивший.

1. Взять хеш из **upstream-файла** `sha256sums` рядом с образом, а не посчитать по скачанному
   (иначе пин подтверждает лишь то, что файл скачался целиком):

   ```sh
   curl -s https://downloads.openwrt.org/releases/<версия>/targets/x86/64/sha256sums \
     | grep 'generic-ext4-combined.img.gz'
   ```

2. Проверить, что у [awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt/releases)
   есть релиз `v<версия>`: `kmod-amneziawg` собирается под конкретную сборку ядра, и без него
   `make qemu-install` упадёт на установке AmneziaWG (это и есть смысл проверки).
3. Прогнать `make qemu-smoke`, `make qemu-install`, `make qemu-reality` локально.
4. Только после этого менять цифры в `lib.sh` — одним коммитом с результатом прогона.

Снапшот при этом не забыт: джоб `qemu-snapshot-canary` (`.github/workflows/test.yml`) раз в
неделю гоняет smoke на rolling snapshot с `continue-on-error` — ранний сигнал о поломках
upstream, который **не блокирует** релиз.

## Архитектура

- `lib.sh` — общая инфра: paths, deps, image-prep, qemu-launch, serial+ssh helpers, boot+setup,
  deploy, `vm_start_firewall`, `vm_inv_failed` (чек-лист инвариантов). Source-only.
- Остальные `*.sh` — по одному сценарию из таблицы выше поверх lib.sh; новые сценарии начинаются с
  копии ближайшего (`emergency.sh` — образец с отрицательным контролем).

При падении — лог serial-консоли в `.work/serial.log`. Trap EXIT гарантированно убивает qemu и
чистит fifo, даже на Ctrl+C.
