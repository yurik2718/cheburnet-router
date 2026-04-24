# 🌐 02. AmneziaWG — VPN-туннель

## TL;DR

Устанавливаем **ядерный модуль** `kmod-amneziawg` и пользовательский пакет `amneziawg-tools` из репозитория [Slava-Shchipunov/awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt). Создаём UCI-интерфейс `awg0` с `proto='amneziawg'`, заполняем AWG-параметрами (`Jc`, `Jmin`, `Jmax`, `S1`, `S2`, `H1..H4`) и peer-секцию ключами/endpoint'ом из `.conf`-файла Amnezia. Включаем `route_allowed_ips='0'` — маршрутизацией займётся podkop, не netifd.

## Зачем AmneziaWG, а не WireGuard

### Проблема: DPI в РФ детектирует стандартный WireGuard

WireGuard, несмотря на свою минималистичность, **уязвим для сигнатурного анализа**. Первый пакет handshake'а всегда начинается с байта `0x01`, имеет фиксированную длину 148 байт, и параметры `sender_index`/`receiver_index` обнуляются предсказуемо. Глубокая инспекция пакетов (DPI) у провайдеров в РФ ловит этот отпечаток и режет соединение за миллисекунды.

Фактически с осени 2022 года стандартный WireGuard в России **непригоден** для обхода цензуры — соединение либо не устанавливается, либо работает 30 секунд и рвётся.

### Решение: обфускация handshake

AmneziaWG — форк WireGuard, где сохранена криптография (это критически важно — ни грамма не теряем в безопасности), но handshake маскируется через четыре техники:

| Параметр | Что делает |
|---|---|
| **`Jc`** | Число «junk»-пакетов перед реальным handshake'ом (рандомный мусор) |
| **`Jmin` / `Jmax`** | Минимальный и максимальный размер junk-пакетов |
| **`S1` / `S2`** | Случайный padding внутри handshake init/response пакетов |
| **`H1` / `H2` / `H3` / `H4`** | Подменяют фиксированные байты протокольных заголовков на случайные числа (в пределах возможного, не ломая протокол) |

Результат: сниффер видит **неструктурированный UDP-поток**, который не совпадает ни с WG-сигнатурой, ни с какой-либо известной. DPI-движок не может классифицировать трафик.

> **💡 Занятный факт.** Amnezia появилась как некоммерческий проект от русскоязычных разработчиков после блокировки протонмейла и тор-бриджей в 2022. Идея обфускации WG возникла из наблюдения: РКН ловит именно handshake, передача данных после установления сессии не фингерпринтится. Значит, достаточно замаскировать первые 2-3 пакета.

### Почему AWG 2.0 (а не 1.0)

В 2024-25 годах Amnezia выпустила **AWG 2.0** с дополнительными параметрами `I1-I5` (Custom Protocol Signature — поддельные пакеты целых протоколов, имитирующие DNS/HTTP-заголовки перед WG-handshake). Сервер Amnezia Premium обновлён под 2.0.

**Важно:** новые параметры в [Interface] секции **опциональны**. Сервер AWG 2.0 совместим с клиентами, использующими только «старые» параметры (Jc/S/H), если эти параметры **точно совпадают** между клиентом и сервером. Источник: [Amnezia docs](https://docs.amnezia.org/documentation/amnezia-wg/).

В нашей конфигурации используются только v1-параметры — этого достаточно, так как сервер сгенерирован под этот профиль.

## Установка

### 1. Пакеты (делается через скрипт `setup/01-amneziawg.sh`)

```bash
# Репозиторий Slava-Shchipunov/awg-openwrt собирает kmod под каждую версию OpenWrt
BASE=https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v25.12.2
ARCH=aarch64_cortex-a53_mediatek_filogic   # для Beryl AX; проверить свой

cd /tmp
for PKG in kmod-amneziawg_v25.12.2 amneziawg-tools_v25.12.2 luci-proto-amneziawg_v25.12.2; do
    wget -O "${PKG}_${ARCH}.apk" "$BASE/${PKG}_${ARCH}.apk"
done
apk add --allow-untrusted *amneziawg*.apk
```

После установки `modprobe amneziawg` загружает модуль, `awg --version` показывает версию userspace-тулзы.

### 2. Конфигурационный файл

Положите `.conf` от Amnezia (из клиента, `Configuration Files`) в `/etc/amnezia/amneziawg/awg0.conf`:

```ini
[Interface]
Address = 100.84.227.66/32
DNS = 100.64.0.1, 8.8.4.4
PrivateKey = <SECRET>
Jc = 4
Jmin = 10
Jmax = 50
S1 = 82
S2 = 44
H1 = 1754556670
H2 = 323984459
H3 = 1156386384
H4 = 1526318555

[Peer]
PublicKey = <SERVER_KEY>
PresharedKey = <SERVER_PSK>
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 179.43.168.10:8630
PersistentKeepalive = 25
```

Файл нужен как **референс** и для утилиты `awg-quick`, но **основная конфигурация идёт через UCI** (netifd-managed интерфейс).

### 3. UCI-интерфейс

```
uci set network.awg0=interface
uci set network.awg0.proto='amneziawg'
uci set network.awg0.private_key='<Interface.PrivateKey>'
uci add_list network.awg0.addresses='<Interface.Address>'
uci set network.awg0.mtu='1420'
uci set network.awg0.awg_jc='<Interface.Jc>'
uci set network.awg0.awg_jmin='<Interface.Jmin>'
# ... все AWG-параметры ...

uci add network amneziawg_awg0   # peer-секция
uci set network.@amneziawg_awg0[0].public_key='<Peer.PublicKey>'
uci set network.@amneziawg_awg0[0].preshared_key='<Peer.PresharedKey>'
uci add_list network.@amneziawg_awg0[0].allowed_ips='0.0.0.0/0'
uci add_list network.@amneziawg_awg0[0].allowed_ips='::/0'
uci set network.@amneziawg_awg0[0].endpoint_host='<Peer.Endpoint host>'
uci set network.@amneziawg_awg0[0].endpoint_port='<Peer.Endpoint port>'
uci set network.@amneziawg_awg0[0].persistent_keepalive='25'
uci set network.@amneziawg_awg0[0].route_allowed_ips='0'   # КРИТИЧНО

uci commit network
/etc/init.d/network restart
```

### 4. Firewall-зона

AWG-интерфейс должен попасть в отдельную firewall-зону с masq + MSS clamping:

```
uci add firewall zone
uci set firewall.@zone[-1].name='vpn'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='ACCEPT'
uci set firewall.@zone[-1].masq='1'
uci set firewall.@zone[-1].mtu_fix='1'
uci add_list firewall.@zone[-1].network='awg0'

uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='vpn'
uci commit firewall
/etc/init.d/firewall reload
```

## Важные тонкости

### `route_allowed_ips='0'` — почему

По умолчанию, когда интерфейс WG/AWG поднимается с `AllowedIPs=0.0.0.0/0`, ядро автоматически создаёт **default route** через этот интерфейс. Это означает, что **весь трафик роутера и LAN** немедленно уйдёт в туннель — включая DNS-резолвинг, обновление списков, NTP. Deadlock при первом запуске: туннель ещё не установлен, а роутер уже не может выйти в интернет для DNS.

Отключая `route_allowed_ips`, мы говорим: «не добавляй default route; маршрутизацию я делаю сам». Этим займётся podkop (sing-box) на уровне tproxy и per-outbound `bind_interface=awg0`.

> ⚠️ **Подводный камень.** Если перенести эту конфигурацию на роутер, где **нет podkop** (т.е. AWG используется «в лоб»), забыть включить `route_allowed_ips='1'` — туннель установится, но никакой трафик через него не пойдёт.

### `PersistentKeepalive=25`

WireGuard/AWG **пассивны** — они не посылают пакетов, если приложение не шлёт данных. Это означает, что NAT-запись у провайдера или на home-router'е **протухает** (обычно через 60-300 секунд неактивности), и сервер не сможет инициировать новое соединение в ответ.

`PersistentKeepalive=25` заставляет клиент отправлять пустой encrypted-пакет каждые 25 секунд — NAT-таблица остаётся живой.

> **💡 История.** 25 секунд — не случайное число. Jason Donenfeld (автор WG) пишет в документации: «Самый агрессивный NAT-таймаут, встречавшийся в реальном мире — 30 секунд (некоторые домашние роутеры Cisco). 25 секунд оставляет запас».

### MTU 1420

Внутри туннеля каждый пакет получает дополнительные заголовки:
- WireGuard/AmneziaWG: 32 байта (версия 4) или 48 байт (IPv6)
- UDP: 8 байт
- IP: 20 байт (v4) или 40 байт (v6)

`1500 (Ethernet) - 20 (IP) - 8 (UDP) - 32 (WG) = 1440`, в AWG слегка больше из-за junk — безопасно ставить **1420**. Если выше — packets будут фрагментироваться → потери производительности.

## Диагностика

Команды для проверки состояния.

```bash
# Интерфейс поднят?
ip -4 a show awg0

# Handshake свежий?
awg show awg0 | grep 'latest handshake'
# >>> latest handshake: 15 seconds ago

# Сколько данных проходит?
awg show awg0 | grep transfer
# >>> transfer: 12.43 MiB received, 5.74 MiB sent

# UCI-конфиг корректен?
uci show network | grep -E 'awg0|amneziawg'
```

**Тест реального выхода:**
```bash
# Временный route, чтобы "прогнать" пакеты через awg0
ip route add 1.1.1.1/32 dev awg0
curl -s --max-time 5 https://1.1.1.1/cdn-cgi/trace | grep -E '^(ip|loc)='
# Ожидаем: ip=<ваш_AWG_exit_IP>, loc=CH
ip route del 1.1.1.1/32
```

## Типичные проблемы

### Handshake не устанавливается (0 байт received)

**Причины в порядке вероятности:**

1. **Серверный пир отозван/деактивирован.** Ключи/endpoint валидные, но сервер не признаёт наш publickey. Решение: перевыпустить конфиг в Amnezia-клиенте.
2. **Обфускация-параметры не совпадают** с сервером (Jc/S1/S2/H1-H4). Проверить буквально каждую цифру. Если вам выдали обновлённый `.conf` — обновить все параметры, не только ключи.
3. **UDP:port блокируется** у провайдера. Редко, но бывает на корпоративных/hotel-Wi-Fi. Протестировать `nc -u server.ip port` для проверки проходимости UDP.
4. **Сам AWG-сервер недоступен.** Проверить `traceroute` до endpoint'а.

### Handshake есть, но пинг через awg0 не проходит

Обычное поведение — сервер может фильтровать ICMP. Не признак поломки. Проверка делается через реальный запрос (curl/wget), не через ping.

### Handshake периодически прерывается

- Проверить `PersistentKeepalive` — должен быть ≤30 сек
- Возможно, NAT у провайдера агрессивный — попробовать 15 сек
- ISP может throttle'ить UDP — перепроверить endpoint

## AmneziaWG 1.5 — дополнительный слой обфускации (I1-I5)

После v1.0 Amnezia добавила в протокол **Custom Protocol Signature (CPS)** — параметры `I1`-`I5`. Это «поддельные пакеты», которые клиент отправляет **перед реальным handshake'ом** — они имитируют другие популярные протоколы (DNS, HTTP и т.п.), создавая дополнительный уровень маскировки.

### Как это работает

Без `I1`:
```
Client → [AWG handshake init]    → Server
         (junk-пакеты, S/H обфускация)
```

С `I1`:
```
Client → [decoy packet 1 — похож на DNS]  → Server  (может игнорировать)
Client → [decoy packet 2 — ...]           → Server
Client → [AWG handshake init]             → Server  (реальный handshake)
```

Для DPI: серия из 5 «разнородных» пакетов разных форматов подряд выглядит как обычный интернет-шум, а не как VPN-handshake. Эффективность против современных AI/ML-основанных DPI системм возрастает.

### Наш I1

В `/etc/amnezia/amneziawg/awg0.conf` прописан документированный пример от Amnezia:

```
I1 = <r 2><b 0x8580000100010000000004796162730679616e6465780272750000010001c00c000100010001c00c000100010000026d000457fa27d1>
```

Что означают эти теги:
- `<r 2>` — 2 случайных байта в начале (transaction ID для DNS)
- `<b 0x...>` — фиксированная hex-последовательность

Разбор hex-строки:
- `85 80` — DNS flags (response, no error)
- `00 01 00 01 00 00 00 00` — QDCOUNT/ANCOUNT/NSCOUNT/ARCOUNT
- `04 79 61 62 73 06 79 61 6e 64 65 78 02 72 75 00` — имя `yabs.yandex.ru`
- `00 01 00 01` — query A/IN
- `c0 0c` — DNS compression pointer
- `00 00 02 6d` — TTL 621
- `00 04 57 fa 27 d1` — RDATA: IP 87.250.39.209

То есть **decoy-пакет = полноценный DNS-ответ** на запрос `yabs.yandex.ru`. Провайдерский DPI видит такой пакет сотни раз в секунду (это реальный Яндекс-трекер) — и пропускает, не углубляясь. Маскировка идеальная.

### Ограничения и замечания

- **Нет гарантий от Amnezia**, что конкретный сервер признаёт именно это `I1`-значение. Документация явно не описывает клиент-сервер контракт.
- **По факту работает** (проверено): добавление этого I1 с текущим сервером Amnezia Premium Switzerland не ломает handshake, сервер продолжает принимать соединения.
- **Если ваш сервер обновит свой I1** (станет AWG 2.0 full): нужно будет пере-экспортировать конфиг из клиента Amnezia, чтобы получить согласованное значение. Но пока можно пользоваться публичным example-значением.
- **Синтаксические теги** можно комбинировать: `<b 0x...>` (static bytes), `<r N>` (random N bytes), `<rc N>` (random alphanum), `<rd N>` (random digits), `<t>` (4-byte timestamp), `<c>` (4-byte counter).

### Как добавить

Вариант A — отредактировать `.conf` и пере-deploy'ить:
```
# Добавьте строку в [Interface] после H4:
I1 = <r 2><b 0x8580000100010000000004796162730679616e6465780272750000010001c00c000100010001c00c000100010000026d000457fa27d1>
```

Вариант B — прямо UCI:
```sh
uci set network.awg0.awg_i1='<r 2><b 0x8580000100010000000004796162730679616e6465780272750000010001c00c000100010001c00c000100010000026d000457fa27d1>'
uci commit network
ifdown awg0 && ifup awg0
```

Проверка что применилось:
```
awg show awg0 | grep i1
```

### Откат

Если после добавления I1 handshake сломался (редко, но может на уникальных server-config):
```sh
uci -q delete network.awg0.awg_i1
uci commit network
ifdown awg0 && ifup awg0
```

Официальный источник — [docs.amnezia.org/documentation/instructions/upgrade-awg-config](https://docs.amnezia.org/documentation/instructions/upgrade-awg-config/).

## Watchdog — автоматическое восстановление

Для удалённого роутера (у родственников), где вы не можете зайти и вручную перезапустить интерфейс при сбое, стоит поставить **watchdog**.

Скрипт `/usr/bin/awg-watchdog` запускается cron'ом каждую минуту и делает:

```
1. Проверяет что awg0 поднят (ip addr).
2. Читает возраст последнего handshake'а (awg show awg0 latest-handshakes).
3. Если handshake старше 180 секунд (3 минуты) → рестартит интерфейс:
      ifdown awg0 && sleep 2 && ifup awg0
4. Между перезапусками минимум 120 секунд (не штормить).
5. Считает счётчик подряд-рестартов (для диагностики).
```

**Почему 3 минуты?** `PersistentKeepalive=25` → handshake обновляется ~каждые 25 сек. За 3 минуты должно быть 7 успешных handshake'ов. Если их 0 — явно что-то не так, не просто пакет потерялся.

**Почему 2 минуты между рестартами?** Реальный ifdown/ifup занимает 3-5 секунд, handshake после — ещё 2-5. Если сервер на другой стороне действительно сейчас упал, ждать 2 минуты — разумно (а не штурмовать каждую секунду).

**Сценарии, которые решает:**

| Сценарий | Детект через | Что делает watchdog |
|---|---|---|
| Сервер AWG перезагружался (5 мин downtime) | handshake age > 180s | ifdown/ifup после 2 мин → новый handshake при живом сервере |
| ISP глитч (UDP-дропы на 10 мин) | handshake age растёт | пара-тройка безуспешных рестартов, потом handshake восстанавливается сам |
| Клиентский endpoint-IP сменился (NAT-rotation) | handshake age > 180s | ifdown/ifup инициирует handshake от нового source-IP |
| Сервер заблокирован РКН навсегда | handshake age растёт бесконечно | watchdog перезапускает каждые 2 мин. Бесконечный цикл — но стабильный (не падает, не жрёт CPU). |

Watchdog (cron 1 мин) пытается автоматически исправить протухший handshake. Диагностика: `logread -t awg-watchdog`.

**Установка:**
```bash
# (уже в репо: scripts/awg-watchdog)
scp scripts/awg-watchdog root@router:/usr/bin/awg-watchdog
ssh root@router 'chmod +x /usr/bin/awg-watchdog'

# cron entry
ssh root@router 'crontab -l | grep -v awg-watchdog > /tmp/c; \
  echo "* * * * * /usr/bin/awg-watchdog" >> /tmp/c; \
  crontab /tmp/c; /etc/init.d/cron restart'
```

**Диагностика:**
```bash
# История восстановлений
logread -t awg-watchdog

# Счётчик подряд-неудач (обнуляется при успехе)
cat /tmp/awg-watchdog/fails

# Когда в последний раз рестартили
cat /tmp/awg-watchdog/last-restart
date -d @$(cat /tmp/awg-watchdog/last-restart)
```

## Проверь себя

1. **Зачем нужны параметры H1-H4?**
   <details><summary>Ответ</summary>Они замещают фиксированные байты протокольных заголовков WireGuard на случайные числа. Без этого DPI-движок видел бы знакомый отпечаток («это WireGuard handshake») и резал соединение. H-параметры делают заголовок неотличимым от случайного мусора.</details>

2. **Что произойдёт, если установить `route_allowed_ips='1'` в нашей конфигурации?**
   <details><summary>Ответ</summary>Default route уйдёт через awg0. Podkop ещё не успеет применить свои правила — все router-originated запросы (DNS-bootstrap, update-lists, NTP) пойдут в туннель. Но туннель ещё может быть не поднят → deadlock при старте. Плюс, логика split-routing сломается: exclusion для RU тоже пойдёт через awg0.</details>

3. **Почему `AllowedIPs=0.0.0.0/0, ::/0`, а не только `0.0.0.0/0`?**
   <details><summary>Ответ</summary>`::/0` включает весь IPv6. Даже если мы не используем IPv6 активно (`strategy: ipv4_only` в sing-box), лучше сообщить туннелю, что IPv6-трафик тоже должен идти через него — защита от случайной IPv6-утечки, если клиент каким-то образом обошёл DNS.</details>

## 📚 Глубже изучить

### Обязательно
- [AmneziaWG documentation](https://docs.amnezia.org/documentation/amnezia-wg/) — авторский источник, описание всех параметров
- [WireGuard whitepaper](https://www.wireguard.com/papers/wireguard.pdf) (Jason Donenfeld, 2017, 12 страниц) — как устроен WG под капотом

### Желательно
- [GitHub: amnezia-vpn/amneziawg-linux-kernel-module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module) — исходники ядерного модуля
- [GitHub: Slava-Shchipunov/awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt) — репо OpenWrt-сборок
- [Tailscale Blog: Why WireGuard?](https://tailscale.com/blog/netfilter-kernel-version/) — почему WG выбрали за основу Tailscale и другие

### Для любопытных
- 📺 [WireGuard: fast, modern, secure VPN tunnel (talk by Jason Donenfeld, FOSDEM 2017)](https://www.youtube.com/watch?v=88cXH5JO8Bw) — 45 минут с автором
- [RFC 7539: ChaCha20 and Poly1305](https://datatracker.ietf.org/doc/html/rfc7539) — криптопримитивы WG
- [Curve25519: new Diffie-Hellman speed records](https://cr.yp.to/ecdh/curve25519-20060209.pdf) (Daniel J. Bernstein, 2006) — математика key exchange'а
