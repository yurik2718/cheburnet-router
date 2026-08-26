# engine/steps/vpn — AmneziaWG-туннель (awg0)

Пользователь приносит `.conf` от VPN-провайдера; шаг парсит его и приводит UCI-интерфейс
`awg0` + peer-секцию к желаемому состоянию ([amneziawg](../../../docs/kb/concepts/amneziawg.md)).
`awg0` — дефолт-маршрут для всего, что не помечено `direct` (его держат **half-routes**, см. ниже).

## Маршрутизация: туннель = дефолт, но WAN-дефолт остаётся

> **half-routes `0.0.0.0/1` + `128.0.0.0/1`** (и `::/1` + `8000::/1`) — уже существующие
> `config route`-секции на `awg0`. Они специфичнее WAN-дефолта `0.0.0.0/0`, поэтому побеждают его
> в main **без удаления WAN** (приём `redirect-gateway def1` у OpenVPN). Тот же механизм у
> [Full-тира](../singbox/README.md) — один на оба тира. `route_allowed_ips='0'`: proto-handler свой
> маршрут не ставит. Direct-исключения вытягивает
> [policy-routing](../../../docs/kb/concepts/policy-routing.md) (`mark→table-100→WAN`) — другая
> таблица, конфликта нет. **fail-safe:** промах direct-списка = трафик уходит в туннель, а не
> дропается kill-switch'ем. Зафиксировано тестами (юниты + `make qemu-route-fallback`).
>
> Почему не `route_allowed_ips='1'` (так было раньше) — шрам «у пути наружу должен быть фолбэк»,
> см. [reliability](../../../docs/kb/architecture/reliability.md) и `make qemu-route-fallback`.

`allowed_ips` навязываем full (`0.0.0.0/0`, `::/0`): туннель принимает весь трафик, а *направление*
(что вынуть в WAN) решает policy routing. Поле `AllowedIPs` из `.conf` намеренно игнорируем.

## Чистое ядро vs импурный apply

- **`vpn.uc`** — `parse_awg_conf` (INI → объект), `split_endpoint` (`host:port` / `[ipv6]:port`),
  `build_vpn_plan` (→ uci teardown/setup). **Чистые функции**, тесты — [tests/](tests/).
- **`apply.uc`** — **router-side**: teardown (`uci -q delete`, отсутствие — норма) → setup
  (`uci batch`) → `commit network` → `network reload` → проверка `ip link` → при отсутствии
  устройства эскалация в `network restart` (на свежей установке proto-handler только что
  доставлен пакетом, и `reload` его не подхватывает — `proto:none/NO_DEVICE`). QEMU/железо.
- **`plan.uc`** — CLI чистого ядра (`.conf` → uci-план, без применения); им rpcd валидирует конфиг синхронно.

## Граница доверия и валидация

`.conf` — **вход пользователя** → валидируем (CLAUDE.md). Нет обязательных полей
(`PrivateKey`/`Address`/`PublicKey`/`Endpoint`) или битый `Endpoint` → `plan.ok=false`,
ошибки, шаг **не трогает сеть**. Обфускация (`Jc`,`Jmin`,`Jmax`,`S1..S4`,`H1..H4`,`I1..I5`)
— опциональна: пишем `awg_<lc>` только для присутствующих полей (иначе netifd не поднимет
интерфейс — урок v1). Base64-ключи с `=` не ломают парсер (split по первому `=`).

## Идемпотентность

`delete`-before-`set`: teardown удаляет интерфейс и peer-секцию, setup создаёт заново →
повторный запуск сходится к тому же состоянию (нет дублей `add_list`). Peer — **именованная**
секция (`<iface>_peer` типа `amneziawg_<iface>`) → дружелюбна к `uci batch` (не нужен
сгенерированный id анонимной секции, как в v1).

## Использование

```sh
cat awg0.conf | ucode -R engine/steps/vpn/plan.uc           # показать uci-план
cat awg0.conf | ucode -R engine/steps/vpn/apply.uc --dry-run
```

## Тесты

`make test-engine`. Покрыто: split_endpoint (v4/v6/мусор), парсер (секции, inline-комментарии,
base64-`=`), обфускация только присутствующая, **half-routes (туннель=дефолт, WAN цел)**, peer
(endpoint/PSK/forced allowed_ips/keepalive), dual-stack Address, teardown, валидация входа,
кастомное имя интерфейса.
