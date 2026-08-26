# engine/steps/doh — шифрованный DNS (DoH) + выбор провайдера/фильтрации

Шифрует upstream-резолв лёгким `https-dns-proxy` перед dnsmasq — замена DoH, который в v1
нёс sing-box ([encrypted-dns](../../../docs/kb/concepts/encrypted-dns.md)).

**Резолвер = уровень фильтрации.** В v2 блокировка рекламы/взрослого контента делается не
локальным списком, а **выбором фильтрующего DoH-провайдера** ([providers.uc](providers.uc),
[ADR 0005](../../../docs/kb/decisions/0005-dns-filtering-not-local-adblock.md)). Дефолт —
**AdGuard** (реклама+трекеры); «семейный режим» = выбрать семейного провайдера. Одна секция
`cheburnet_doh` + `cheburnet_doh_wan` (фикс. имена) → смена провайдера = чистая идемпотентная замена обеих.

## Почему DoH на роутере, а не на клиенте

Централизованный DNS на роутере сохраняет [пометку адресов](../../../docs/kb/concepts/dnsmasq-nftset.md)
для split-routing. Клиентский DoH (Chrome, смарт-ТВ) её ломает — роутер не видит резолв.
Цепочка: dnsmasq (nftset, `strictorder`) → https-dns-proxy :5053 (основной, через туннель) → при его
молчании :5054 (резервный, тот же провайдер, владелец `network` → мимо туннеля по `ip rule uidrange`)
→ зашифрованно к фильтрующему провайдеру. Подробно: [encrypted-dns](../../../docs/kb/concepts/encrypted-dns.md).

## dnsmasq-привязку держим САМИ (не магия пакета)

Пакет умеет авто-править dnsmasq (`update_dnsmasq_config='*'`) — мы это **отключаем** (`-`) и
прописываем upstream `server` сами. Так один владелец конфига dnsmasq и виден каждый шаг
(учебная цель). `noresolv='1'` ставит [DNS-шаг](../dns/) — без него dnsmasq утёк бы в
ISP-`resolv.conf`; вместе эти два шага = «весь DNS только через наш DoH».

## Чистое ядро vs импурный apply

- **`doh.uc`** — `build_doh_plan(current, opts)` → uci-операции для https-dns-proxy + dnsmasq.
  **Чистая функция**, тесты — [tests/](tests/).
- **`apply.uc`** — **router-side**: читает текущие секции/server из uci, применяет (delete
  `|| true` → `uci batch` → commit → restart https-dns-proxy + reload dnsmasq). QEMU.

## Идемпотентность

- **https-dns-proxy секции** — пересоздаём (delete-before-set). Сносим **все** существующие
  (включая дефолтную секцию пакета на :5053) — иначе она конфликтует с нашей по порту; анонимные
  секции сносятся в обратном порядке индексов (удаление сдвигает индексы). Наши секции именованные
  (`cheburnet_doh`, `cheburnet_doh_wan`) → дружелюбны к `uci batch`.
- **dnsmasq `server`** — минимальный diff по **нашим** записям (`127.0.0.1#<порт>`): чужие
  upstream-серверы пользователя не трогаем. Повтор при настроенном состоянии → no-op.

## Использование

```sh
ucode -R engine/steps/doh/apply.uc --dry-run   # на роутере: читает uci сам
```

## Граница и честность

Схема uci `https-dns-proxy` (опции `listen_addr/listen_port/resolver_url/bootstrap_dns` и
секция `config` типа `main` с `update_dnsmasq_config`) — по стабильному пакету OpenWrt; точную
привязку проверяем в QEMU. Выбор резолверов — настройка (`opts.resolvers`), не зашитый выбор.

## Тесты

`make test-engine`. Покрыто: дефолтные резолверы, `update_dnsmasq_config='-'`, dnsmasq server
(чистая система / идемпотентный no-op / чужой upstream сохраняется), замена дефолтной секции
пакета, кастомные резолверы, валидация (пустой список / дубль порта).
