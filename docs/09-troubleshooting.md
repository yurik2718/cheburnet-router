# 🔧 09. Диагностика и troubleshooting

Быстрый справочник «что-то не работает — куда смотреть».

## Первая помощь: универсальная проверка

Выполнить в указанном порядке. Первое что покажет аномалию — там и ищи.

```bash
# 1. AWG жив?
awg show awg0 | grep -E 'handshake|transfer'
# Ожидается: handshake < 3 минут, transfer увеличивается

# 2. Sing-box работает?
/etc/init.d/sing-box status
# Ожидается: running

# 3. Podkop настроил nft правильно?
podkop check_nft_rules
# Ожидается: все флаги = 1

# 4. DNS резолвится?
nslookup cloudflare.com 192.168.1.1
# Ожидается: какой-то ответ

# 5. Какой режим активен?
/usr/bin/vpn-mode status

# 6. Trace маршрута (с LAN-клиента): какой IP видит внешний сервис?
curl -s https://ifconfig.co/json | jq '.ip, .country'
# В HOME: должен быть Swiss IP для иностранных сайтов
# В TRAVEL: Swiss IP для всех сайтов включая ru
```

## Симптомы и решения

### «VPN скорость упала в 10–100 раз, перезагрузка помогает»

Классический симптом переполнения таблицы conntrack. VPN работает, handshake свежий, но скорость
падает с ~60 Мбит/с до 0.5–1 Мбит/с. После ребута — всё снова быстро. Через 1–2 недели повторяется.

**Что происходит:** ядро Linux отслеживает каждое соединение (TCP, UDP) в таблице `nf_conntrack`.
По умолчанию TCP-соединения живут в таблице ~2 часа после закрытия. За 2 недели таблица
забивается «мёртвыми» записями, новые пакеты дропаются, скорость рушится.

**Диагностика (не дожидаясь следующего инцидента):**
```bash
# Текущее заполнение таблицы
cur=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
max=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
echo "${cur}/${max} ($(( cur * 100 / max ))%)"
# >80% — опасная зона; 100% — причина тормозов

# Логи conntrack-monitor (раз в 15 мин)
logread -e conntrack-monitor | tail -10

# Топ состояний соединений
cat /proc/net/nf_conntrack | awk '{print $4}' | sort | uniq -c | sort -rn
```

**Немедленное лечение (без ребута):**
```bash
conntrack -F   # сброс таблицы, скорость восстановится за секунды
```
Скорость вернётся немедленно. Активные соединения переустановятся автоматически.

**Постоянное решение** — уже применено через `setup/10-quality.sh`:
- TCP established timeout: 7440 s → **3600 s** (1 час вместо 2)
- UDP stream timeout: 180 s → **60 s**
- `conntrack-monitor` запускается каждые 15 мин, при >95% делает автоматический сброс
- `@reboot` cron применяет настройки после каждой загрузки

Проверить что настройки активны:
```bash
sysctl net.netfilter.nf_conntrack_tcp_timeout_established
# Ожидается: 3600
crontab -l | grep conntrack
# Ожидается: строки @reboot и */15
```

### «Весь интернет не работает»

Начните с **pinga**:
```bash
# С LAN-клиента
ping -c 3 192.168.1.1          # роутер жив?
ping -c 3 8.8.8.8              # WAN есть? (NB: у нас kill switch блокирует ICMP от LAN к WAN → не работает и это ожидаемо)
nslookup google.com 192.168.1.1 # DNS?
```

Если роутер **не пингуется** — проблема в Wi-Fi/LAN. Смотрите [docs/06-wifi.md](06-wifi.md).

Если DNS не резолвится — смотрите дальше.

### «Некоторые сайты не работают, другие работают»

Самый распространённый случай. Полный процесс диагностики:

```bash
# Шаг 1: что отдаёт DNS?
nslookup site-that-broken.com 192.168.1.1

# Если вернул 198.18.0.X — FakeIP → пойдёт в VPN. Значит AWG должен работать.
# Если вернул реальный IP → пойдёт direct через WAN (или через source-based VPN).

# Шаг 2: проверить AWG
awg show awg0 | grep handshake
# Handshake > 3 минут назад → VPN мёртв

# Шаг 3: тест curl
curl -v --max-time 10 https://site-that-broken.com
# Часто `Resolving timed out` → DNS-tier; `connection refused` → routing-tier
```

**Типовые причины:**
- VPN-сервер упал → `logread | grep sing-box` покажет ошибки handshake; пере-экспортировать `.conf` из Amnezia-клиента.
- FakeIP выдаётся но sing-box не может подключиться → проверить awg handshake и `bind_interface: awg0`.
- Конкретный сайт заблокирован **в Швейцарии** (если вы в TRAVEL) — нужно попробовать другой exit-узел.

### «DNS не работает совсем»

```bash
# Что говорит dnsmasq?
ps | grep dnsmasq
# Должно быть два процесса: ujail + сам dnsmasq

# Что говорит sing-box по DNS-поводу?
logread | grep sing-box | grep dns | tail -20

# Проверить бэкэнд напрямую
nslookup google.com 127.0.0.42
# Если не работает — sing-box DNS внутренне сломан

# Попробовать форсить свитч DNS
dns-provider cloudflare
sleep 3
nslookup google.com 192.168.1.1

# Если всё равно не работает — полный рестарт стека:
/etc/init.d/podkop restart
/etc/init.d/dnsmasq restart
sleep 5
nslookup google.com 192.168.1.1
```

### «IP-адрес показывается российский, хотя я в HOME режиме»

С LAN-клиента:
```bash
curl -s https://ifconfig.co/json | jq
```

Если `"country_iso": "RU"` для обычного сайта (не `.ru`):
1. Проверить режим: `vpn-mode status` — `home`?
2. Проверить что подkop активен: `podkop check_nft_rules` — все флаги 1?
3. Проверить AWG: `awg show awg0` — handshake свежий?
4. Sing-box sniff работает? `logread | grep sing-box | grep -E 'sniff|route' | tail`
5. **Клиент делает DoH сам, минуя наш DNS?** — в этом случае для TCP-connect пойдёт через source-based routing `192.168.1.0/24 → main-out`, всё равно через VPN. Если видите RU IP — возможно, пакет **вообще не идёт в sing-box**. Проверьте tproxy-счётчики:
   ```
   nft list chain inet PodkopTable proxy | grep counter
   ```
   Если packets = 0 — пакеты не идут в tproxy, значит mangle chain не маркирует. Debug:
   ```
   nft list chain inet PodkopTable mangle
   ```

### «Неожиданно много рекламы в браузере»

```bash
# Adblock работает?
/etc/init.d/adblock-lean status

# Список загружен?
wc -l < <(zcat /var/run/adblock-lean/abl-blocklist.gz | tr '/' '\n')
# Ожидается: ~200000

# Dnsmasq читает список?
grep -c "local=" <(sh /tmp/dnsmasq.cfg01411c.d/.abl-extract_blocklist)

# Тест
nslookup pagead2.googlesyndication.com 192.168.1.1
# Должен быть пустой ответ (BLOCKED)

# Если нет — перезагрузка dnsmasq
/etc/init.d/dnsmasq restart
```

### «Роутер перезагрузился и режим не совпадает со слайдером» (Beryl AX)

```bash
# Debug initial state
vpn-mode status
# Saved state: travel
# Slider GPIO: hi -> home    ← ага, slider в HOME но state=travel

# Принудительный detect
vpn-mode detect

# Проверить что детектор работал при загрузке
logread -t vpn-mode | head
# Должно быть: mode=HOME applied или mode=TRAVEL applied в первые секунды после boot
```

Если `/etc/init.d/vpn-mode` не отработал — проверьте что включён:
```bash
/etc/init.d/vpn-mode enabled && echo OK
```

### «Wi-Fi не видит родственников устройства»

```bash
# Radio активны?
iw dev
# Должны быть phy0-ap0 и phy1-ap0

# Если пусто — hostapd не стартовал
logread | grep hostapd | tail -20

# Частая причина: не тот wpad-пакет (wpad-basic не умеет sae)
apk list --installed 2>/dev/null | grep wpad
# Ожидается: wpad-mbedtls или wpad-openssl
```

Для **старого устройства, которое не видит sae-mixed**:
```bash
# Временно переключить на чистый WPA2
uci set wireless.default_radio0.encryption='psk2+ccmp'
uci set wireless.default_radio1.encryption='psk2+ccmp'
uci set wireless.default_radio0.ieee80211w='0'
uci set wireless.default_radio1.ieee80211w='0'
uci commit wireless
wifi reload
```


## Логи — куда смотреть

OpenWrt использует **logd** (in-memory ring buffer, 128 KB) с доступом через `logread`. После ребута логи теряются. Текущие:

```bash
logread                               # всё подряд
logread -f                            # follow (tail -f)
logread -e <tag>                      # только один tag

# Полезные теги:
logread -e vpn-mode
logread -e dns-provider
logread -e dns-health
logread -e adblock-lean
logread -e sing-box
logread -e podkop
logread -e hostapd
logread -e dnsmasq
```

Персистентные логи:
- `/var/log/apk.log` — установки/удаления пакетов
- `/tmp/log/*` — временные (теряются)

## Перезапуск «всего и сразу»

Когда всё сломалось и непонятно почему:

```bash
# Аккуратный перезапуск стека
/etc/init.d/sing-box stop
/etc/init.d/podkop stop
sleep 2
/etc/init.d/podkop start               # подkop автоматически стартует sing-box
sleep 5
/etc/init.d/dnsmasq restart
/etc/init.d/firewall reload
ifup awg0
sleep 3

# Верификация
awg show awg0 | grep handshake
podkop check_nft_rules
```

## Nuclear option

Если совсем ничего не помогает — **reboot**:

```bash
reboot
```

Или от SSH-питания: reboot роутера из розетки (если SSH не отвечает). После — даём 1-2 минуты boot'а и проверяем по чек-листу первой помощи выше.

## Откат к ванильному OpenWrt

Если всё пошло совсем не туда — сбросить настройки к factory-OpenWrt (НЕ до GL.iNet firmware):

```bash
# Backup текущих настроек сначала!
./backup/backup.sh

# Сброс к ванильному OpenWrt
firstboot
reboot

# После ребута — зайти по 192.168.1.1, установить пакеты заново
# (начать с setup/full-deploy.sh)
```

## Полезные диагностические команды

```bash
# Что в памяти
free -m
top

# Что на диске
df -h
du -sh /overlay/upper/

# CPU load
uptime

# Кто какие порты держит
netstat -tlnp | head
netstat -unlp | head

# Соединения LAN-клиентов
conntrack -L 2>/dev/null | head
# или
cat /proc/net/nf_conntrack | head

# Кто подключён к Wi-Fi
iw dev phy0-ap0 station dump
iw dev phy1-ap0 station dump

# DHCP leases
cat /tmp/dhcp.leases

# Маршруты
ip route
ip rule

# Firewall state
nft list ruleset | less

# Sing-box live config (даже если реже меняется)
jq . /etc/sing-box/config.json
```

## Где задать вопрос

Если документация не помогла:

- **Telegram** канал [@itdogchat](https://t.me/itdogchat) — автор podkop, активное сообщество
- **OpenWrt Forum**: https://forum.openwrt.org/
- **Telegram** Amnezia: https://t.me/amnezia_vpn_chat
- **GitHub Issues**: соответствующий проект (Slava-Shchipunov/awg-openwrt, itdoginfo/podkop, lynxthecat/adblock-lean)

Формат хорошего issue-репорта:
1. Что делал
2. Что ожидал
3. Что произошло на самом деле
4. Вывод `ubus call system board` (модель + версия OpenWrt)
5. Релевантный `logread` output

## 📚 Глубже изучить

- [OpenWrt wiki: Troubleshooting](https://openwrt.org/docs/guide-user/troubleshooting/start)
- [sing-box debug documentation](https://sing-box.sagernet.org/configuration/experimental/)
- [Network troubleshooting from the command line (Red Hat)](https://www.redhat.com/sysadmin/network-troubleshooting-commands) — общие sysadmin-навыки
- 📺 [Wireshark: Essentials (LinkedIn Learning)](https://www.linkedin.com/learning/wireshark-essentials) — если нужно смотреть пакеты вручную
