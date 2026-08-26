# engine/ — движок управления (ucode)

Control-plane на [ucode](https://ucode.mediatek.org/): настраивает систему и завершается —
**в пути трафика его нет** (трафик идёт только через ядро, см.
[data-plane](../docs/kb/architecture/data-plane.md)). Поэтому логика движка — **чистые
функции**, юнит-тестируемые без роутера за секунды.

Целевая раскладка по модулям — [architecture.md](../docs/architecture.md#-структура-репозитория-v2).

| Модуль | Роль | Статус |
|---|---|---|
| `routing/` | генерация конфигов split-routing (dnsmasq-nftset + nft + ip rule) | ✅ есть |
| `preflight/` | гейткипер железа/версии/зависимостей (чистая оценка + парсеры + router-side gather) | ✅ есть |
| `invariants/` | что должно быть истинно на настроенном роутере: один список на диагностику, тесты, watchdog и панель | ✅ есть |
| `watchdog/` | cron-тик раз в 5 минут: сверяет инварианты, чинит починимое, логирует только аномалии | ✅ есть |
| `rollback/` | snapshot/restore UCI там, где откат чистый (политика clean/dirty + router-side snapshot) | ✅ есть |
| `lib/` | общие хелперы (`assert.uc`, `uci.uc` list-reconcile, `proc.uc` shell/процессы, `route.uc` разбор `ip route`, `redact.uc` вырезание секретов) | ✅ есть |
| `steps/` | идемпотентные шаги по компонентам | 🟢 `vpn/`, `dns/`, `doh/`, `wifi/`, `firewall/`, `rootpass/` есть; `singbox/` (Full-тир, не в мастере) |
| `list/` | импорт и обновление community-списка доменов (чистая сборка + router-side fetch) | ✅ есть |
| `install/` | оркестратор: preflight→snapshot→шаги→health→commit/rollback (политика + router-side run) | ✅ есть |
| `ubus/` | RPC-фасад для web-мастера (чистая валидация/роутинг + rpcd-обработчик + ACL из реестра) | ✅ есть |

## Запуск тестов

```sh
make test-engine     # юнит-тесты движка (ucode), без роутера
make poc-split       # Фаза 0: split через network namespace (примитивы + вывод генератора)
```

Нужен интерпретатор `ucode`. Его установка локально и план для CI — в
[routing/tests/README.md](routing/tests/README.md).
