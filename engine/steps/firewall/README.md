# engine/steps/firewall — data-plane: пометка, policy routing, kill-switch

Production-применение split-routing для форвард-трафика LAN-клиентов:

1. **NAT-зона туннеля** — uci firewall: зона `vpn` (awg0, masq + mtu_fix) и forwarding
   `lan→vpn`. Без неё трафик LAN-клиентов уходит в туннель без SNAT/forwarding и не
   возвращается — роутер «зелёный, но не везёт».
2. **Пометка** — наша prerouting-цепочка метит пакеты с `daddr ∈ direct`
   ([policy-routing](../../../docs/kb/concepts/policy-routing.md)).
3. **Policy routing** — `ip rule`/`ip route` разводят помеченное в WAN, остальное в туннель.
4. **Kill-switch** — роняет непрямой трафик, утекающий в WAN мимо туннеля
   ([kill-switch](../../../docs/kb/concepts/kill-switch.md)).
5. **Hotplug-хук восстановления** — `/etc/hotplug.d/iface/99-cheburnet`: на `ifup` любого
   интерфейса сверяет ip-часть с текущим WAN (в travel — kill-switch в ядре) и, если не сходится,
   зовёт `install/reapply.uc`. Молчит, пока идёт установка/замена сервера.

## Что переживает перезагрузку, а что нет (несимметрично!)

| Часть | Где живёт | Переживает ребут |
|---|---|---|
| цепочки, наборы, kill-switch | файл `/etc/nftables.d/10-cheburnet.nft` (грузит fw4) | да |
| NAT-зона туннеля | uci firewall | да |
| `ip rule fwmark → table`, default таблицы direct | **только ядро** | **нет** |

Из этой асимметрии вырос реальный баг (живой прогон 2026-08-01): после перезагрузки метка
ставилась, адреса в наборе были, панель зелёная — а направлять помеченный трафик стало нечем, и
direct-домены уходили в туннель. Утечки нет (fail-safe), поэтому отказ тихий. Поэтому шаг кладёт
hotplug-хук: он возвращает ip-часть при подъёме WAN — и после загрузки, и после смены шлюза у
провайдера. Логика в хуке не дублируется: он зовёт `install/reapply.uc`, то же самое, что
применяется при откате поверх рабочей системы.

## Kill-switch — ключевые решения (threat model)

> Инвариант v1: kill-switch — **осознанная защита**, не лишний слой. Дырявый kill-switch
> молча обнуляет приватность (всё «работает», но утекает).

- **Ключуемся по `oifname <wan>`, а не по LAN-CIDR.** Это убирает баг v1 (хардкод
  `192.168.1.0/24` → тихо-дырявый kill-switch на нестандартной подсети): правило вообще не
  зависит от подсети LAN.
- **`wan_if` обязателен и динамический** (из gather/preflight). Нет WAN-интерфейса →
  `plan.ok=false`, kill-switch **не строится**, шаг отказывает без изменений. Лучше честный
  отказ, чем хардкод-дыра.
- **`ct state new`** — рубим только новые исходящие соединения мимо туннеля; established
  (обратный трафик уже разрешённого) проходит.
- **AWG-handshake не задет:** он — `output` роутера, а kill-switch на `forward`.
- **TRAVEL строже:** direct-исключений нет → `oifname <wan> ct state new drop` без mark.

## Чистое ядро vs импурный apply

- **`firewall.uc`** — `build_firewall_plan(routing_plan, opts)` → `{uci_teardown, uci_setup,
  nft_path, nft_file, hotplug_path, hotplug_file, nft_teardown, ip_teardown, ip_setup, killswitch,
  ok, errors}` + `build_nat_ops(opts)`. **Чистые функции**; `ip_setup` — `render_iprules` из
  routing (единый источник). Тесты — [tests/](tests/).
- **`apply.uc`** — **router-side, импурно**, в этом порядке: файл `/etc/nftables.d/10-cheburnet.nft`
  и hotplug-хук → NAT-зона (`uci batch` + commit) → один `fw4 reload` (подхватывает и зону, и
  файл — окна без kill-switch нет) → `ip rule/route` teardown + setup. Проверяется в QEMU.
  `--dry-run` печатает всё, что будет применено.

## Идемпотентность и откат — честно

Шаг **гибридный**. NAT-зона — uci firewall (именованные секции `cheburnet_vpn`/`cheburnet_lan_vpn`,
delete-before-set): откатывается **чисто** snapshot'ом установки (`firewall ∈ CLEAN_CONFIGS`).
Состояние ядра (nft/ip) **не откатывается чисто, как UCI** — сходимся **пере-применением**: файл
перезаписывается, `fw4 reload` пересобирает цепочки, `ip rule` снимается перед добавлением (он не
идемпотентен). Это «грязный откат не маскируем под транзакцию»
([reliability](../../../docs/kb/architecture/reliability.md)). `--teardown` (откат оркестратором,
аварийный режим, reset) снимает файл, хук, ip-правила, NAT-зону и — явно — цепочки и наборы:
`fw4 reload` чужие объекты из `inet fw4` не удаляет.

**Forwarding по имени зоны (`lan→vpn`), не по CIDR** — LAN-подсеть в правилах не фигурирует
(урок v1: хардкод подсети = тихая дыра на нестандартных конфигурациях).

## Использование

```sh
echo '{"domains":["example.com"],"routing_opts":{"wan_if":"eth0"},"fw_opts":{"tunnel_if":"awg0"}}' \
  | ucode -R engine/steps/firewall/apply.uc --dry-run   # показать план, не применять
```

`fw_opts.tunnel_if` обязателен для Full-тира (`singtun0`): без него NAT-зона строится под `awg0`.
Все вызывающие (`run.uc`, `install/reapply.uc`) передают его; своих копий «переприменить firewall» в
других слоях быть не должно.

## Проверка

`make test-engine` (юнит: содержимое kill-switch HOME/TRAVEL, обязательность `wan_if`,
неприкосновенность чужих объектов, ipv6, гейты hotplug-хука). `make test-netns` грузит
сгенерированный `nft_file` в **реальное ядро** (network namespace) и проверяет антиутечку.
Живой fw4, ребут и подъём WAN — `make qemu-reboot`, `make qemu-route-fallback`.
