# 🎒 11. TRAVEL-режим: WISP и captive portal

## TL;DR

Три скрипта делают роутер пригодным для путешествий:

- **`travel-connect <SSID> [password]`** — подключить роутер к upstream Wi-Fi (отельному, кофейному) как WISP-клиент. Работает через radio0 (2.4 ГГц), 5 ГГц остаётся для вашей LAN.
- **`travel-portal [минут]`** — временно приостановить VPN + kill switch, чтобы принять captive portal в отеле. Auto-restore по таймеру (default 15 мин).
- **`travel-vpn-on`** — вручную вернуть VPN-защиту досрочно.

Типичный workflow в отеле: `travel-connect "HotelWiFi" "password"` → `travel-portal` → принять terms в браузере → `travel-vpn-on` (или ждать таймера) → `vpn-mode travel` (full tunnel если не включён).

## Почему эти скрипты нужны

Без них «TRAVEL-режим» работает только если ваш роутер физически подключён Ethernet-кабелем к интернет-источнику без captive portal. В реальной поездке (отель, кофейня, коворкинг) это редкий случай.

**Типичные проблемы:**

1. **Нет Ethernet** — все интернет-источники в отеле через Wi-Fi.
2. **Captive portal** — страница «Accept terms & conditions», которая должна быть открыта в браузере перед тем как получите интернет.
3. **VPN мешает captive portal** — AmneziaWG пытается поднять туннель сразу, пакеты идут на VPN-сервер, сервер недоступен (портал блокирует всё), туннель не поднимается, пользователь не видит страницу портала.

Три скрипта решают все три проблемы.

## 1. WISP-mode: `travel-connect`

### Что это делает

Создаёт UCI-интерфейс `wwan` с `proto=dhcp` и привязанный к нему `wifi-iface` в режиме `sta` (станция/клиент) на radio0 (2.4 ГГц). Wwan добавляется в firewall-зону `wan`, masquerading работает как на обычном Ethernet WAN.

Ваша LAN (SSID `CheburNet_*`) продолжает работать независимо — и на 2.4 (одним каналом с upstream), и на 5 ГГц (на своём канале).

### Использование

```bash
# Подключиться к открытой сети
travel-connect "FreeAirportWiFi"

# К сети с паролем (WPA/WPA2/WPA3)
travel-connect "HotelGuest_502" "myroomkey2024"

# Проверить состояние
travel-connect --status

# Отключиться (и вернуть Ethernet WAN если подключён кабель)
travel-connect --off
```

### Почему radio0 (2.4 ГГц)

- **Максимальная совместимость.** Любой upstream-AP работает на 2.4. На 5 ГГц не все роутеры поддерживают, плюс DFS-каналы и регуляторные ограничения могут мешать.
- **5 ГГц остаётся чистым** для нашей LAN — быстрый Wi-Fi 6 для ваших устройств.
- **MediaTek Filogic (MT7981)** поддерживает **AP+STA на одном радио** — наша 2.4 ГГц LAN и STA для upstream работают параллельно на том же канале, что и upstream AP.

### Возможные проблемы

- **STA-режим ломает 2.4 ГГц LAN AP на время переконфига** — ваши 2.4-клиенты (старые IoT) могут на 3-5 секунд потерять связь при `travel-connect`, потом переподключатся к новому каналу.
- **Хотел WiFi только на 5 ГГц** — перенесите STA на radio1 вручную: `uci set wireless.wwan.device='radio1'`. Но тогда придётся выбрать: либо LAN AP на 5 ГГц, либо STA.
- **Hidden SSID в upstream** — поддерживается, но добавьте `uci set wireless.wwan.hidden='1'` после `travel-connect`.

## 2. Captive portal: `travel-portal`

### Как работает captive portal в отелях

1. Клиент (ваш ноутбук через роутер) получает IP от DHCP отельной сети.
2. Первые попытки HTTP-запросов — отель перехватывает и редиректит на `http://portal.hotel.com/accept`.
3. Пока вы не нажмёте «Agree» на этой странице — **весь** трафик режется.
4. После принятия — ваш MAC или IP добавляется в whitelist на отельной стороне, начинает работать нормальный интернет.

### Проблема с VPN

В нашей схеме: как только `wwan` получает IP, AWG-туннель пытается установить handshake к `179.43.168.10:8630` (швейцарский endpoint). Портал блокирует этот трафик — handshake не проходит. Трафик через туннель не ходит. Пользователь **не может** даже открыть портал, потому что:
- DNS-запросы идут через наш sing-box → DoH к Quad9 через VPN → тупик
- HTTP на `http://portal.hotel.com` → kill switch блокирует direct-WAN от LAN

### Что делает `travel-portal`

1. **Отключает kill switch** (`uci set firewall.@rule[KillSwitch-*].enabled='0'` → fw4 reload). Теперь LAN→WAN direct разрешён.
2. **Останавливает podkop** (тем самым убирает tproxy-правила). LAN-пакеты идут напрямую через WAN без перехвата.
3. **Запускает таймер** на N минут (default 15) — по истечении автоматически восстановит VPN.
4. **Переключает LED на heartbeat-паттерн** (короткая вспышка раз в секунду) — distinctive от всех других состояний, сигнализирует «VPN сознательно выключен».

Пока скрипт активен, лок-файл `/tmp/travel-portal.active` существует.

### Рабочий процесс

```bash
# 1. Подключились к отельному Wi-Fi
travel-connect "MarriottGuest" "welcome2024"

# 2. Активируем portal-режим (15 мин)
travel-portal

# 3. Открываем браузер на ноуте, заходим на http://neverssl.com
#    → отельный портал перехватил, показывает страницу terms
#    → нажимаем Accept
#    → получаем доступ к интернету от отеля

# 4. Возобновляем VPN досрочно (или ждём 15 мин)
travel-vpn-on

# 5. Теперь всё идёт через VPN. Переключаемся в TRAVEL-mode если не были
vpn-mode travel
```

### Безопасность во время portal-режима

⚠️ **Пока активен portal-mode, ваш трафик идёт напрямую через отельную сеть**. Это:

- ✅ Нормально для HTTP-запроса на сам портал (terms acceptance)
- ❌ **НЕ вводите пароли** на банки/почту/соцсети в это время
- ❌ **НЕ работайте с важными документами** в облаке

Auto-restore после 15 минут — именно поэтому. Даже если вы забыли вручную вернуть VPN, через 15 минут система сама.

### Настройка таймера

```bash
travel-portal 5     # 5 минут вместо default 15
travel-portal 30    # максимум 60, больше cap'ится
travel-portal --off # выключить сейчас (= travel-vpn-on)
```

## 3. LED-паттерны в TRAVEL-сценарии

| Состояние | Паттерн | Что означает |
|---|---|---|
| Портал-режим | 💗 Heartbeat (короткая вспышка раз в 1 сек) | VPN выключен **намеренно**, ждём принятия portal |
| TRAVEL + VPN OK | 💨 Slow blink (1 Гц) | Full tunnel, всё через VPN |
| HOME + VPN OK | 🟢 Solid | Норма |
| VPN DOWN | ⚡ Fast blink (5 Гц) | **Ошибка**, VPN не работает |

Portal-режим отличается от VPN DOWN паттерном: heartbeat вместо частого мигания. Сигнал «намеренное выключение» vs «непредвиденная ошибка». Это важно для пользователя — не надо паниковать.

## USB tethering — телефон / 4G-модем как WAN

Когда Wi-Fi в отеле плохой или вообще отсутствует, можно использовать **телефон как USB-модем** или **4G/LTE USB-dongle с SIM-картой**. После установки `12-travel-plus.sh`:

### Поддерживаемые устройства

| Тип | Протокол | Что надо на стороне устройства |
|---|---|---|
| **Android** | RNDIS / cdc_ether | Settings → Tethering → **USB tethering ON** |
| **iPhone** | ipheth | Settings → Personal Hotspot → **Allow Others to Join**. При первом подключении на iPhone: **Trust This Computer**. |
| **4G-dongle QMI** | qmi-wwan | Huawei E3372, ZTE MF79, Quectel EC25 и др. |
| **4G-dongle MBIM** | cdc-mbim | Новейшие LTE (некоторые Quectel, Sierra) |
| **3G-dongle PPP/AT** | usb-serial-option | Старые Huawei, ZTE (ограниченная поддержка) |

### Использование

```bash
# 1. Воткните телефон/dongle в USB-порт роутера
# 2. Проверьте что устройство видно
ssh root@192.168.1.1 lsusb
# Bus 001 Device 003: ID 05ac:12ab Apple, Inc. iPhone

# 3. Поднять tethering
ssh root@192.168.1.1 travel-tether on
# → обнаружен USB-network интерфейс: usb0
# → USB-tether поднят, IP: 172.20.10.5

# 4. Проверить что интернет работает
ssh root@192.168.1.1 curl -s https://ifconfig.co

# 5. Отключить (когда не нужен)
ssh root@192.168.1.1 travel-tether off
```

### Для 4G-dongle с SIM — настройка APN

По умолчанию скрипт использует APN `internet` (подходит для большинства EU/RU операторов). Если ваш оператор требует другой APN:

```bash
# После первого `travel-tether on` (с QMI-dongle):
uci set network.wwan_usb.apn='<your-operator-apn>'
uci commit network
ifup wwan_usb
```

Типичные APN:
- МТС: `internet.mts.ru`
- МегаФон: `internet`
- Билайн: `internet.beeline.ru`
- Tele2: `internet.tele2.ru`
- EE UK: `everywhere`
- Vodafone UK: `wap.vodafone.co.uk`
- T-Mobile US: `fast.t-mobile.com`

## Wi-Fi сканирование — `travel-scan`

Перед `travel-connect` полезно увидеть доступные сети:

```bash
travel-scan              # 2.4 GHz (default)
travel-scan 5            # 5 GHz
travel-scan both         # оба диапазона
```

Вывод:
```
=== Wi-Fi сканирование ==
  SSID                            Signal     Encryption
  ----                            ------     ----------
  MarriottGuest                   -45 dBm    none
  MarriottMeeting                 -58 dBm    WPA2 PSK (CCMP)
  LaptopHotspot                   -72 dBm    WPA2 PSK (CCMP)
  ...
```

Сортировка по уровню сигнала — первая сеть с самым сильным сигналом.

## Сохранённые Wi-Fi профили — `travel-wifi`

Когда вы часто бываете в одних и тех же местах (отель сетевой, рабочий офис, дом друзей), удобно сохранять подключения:

```bash
# Первый раз — как обычно
travel-connect "MarriottGuest" "welcome2024"

# Сохранить профиль
travel-wifi save mariott-lv "MarriottGuest" "welcome2024"

# В следующий приезд — одна команда
travel-wifi connect mariott-lv

# Список
travel-wifi list
#   mariott-lv             → MarriottGuest          (WPA)
#   office-dad             → HomeOffice5G           (WPA)
#   cafe-regular           → CafeWiFi               (открытая)

# Удалить
travel-wifi delete office-dad
```

Профили хранятся в `/etc/travel-wifi/<name>.conf`, переживают sysupgrade.

## MAC-рандомизация — `travel-mac`

Некоторые отельные Wi-Fi ограничивают «1 устройство на комнату» по MAC. Плюс привычный MAC = privacy-утечка (можно отследить, что вы были в 3 разных отелях одной сети).

```bash
travel-mac random        # новый случайный MAC на WAN, сохраняется
travel-mac fixed 02:AA:BB:CC:DD:EE   # конкретный MAC
travel-mac reset         # вернуть заводской
travel-mac status        # показать текущий
```

После рандомизации WAN-интерфейс на 3-5 секунд прерывается (ifdown/ifup), потом переподключается с новым MAC.

**Когда делать:**
- Новый отель → `travel-mac random` перед `travel-connect` (чтобы отель счёл «новое устройство»)
- Раз в месяц на постоянной сети для общей приватности

## Полная диагностика — `travel-check`

Одна команда показывает всё состояние роутера:

```bash
travel-check
```

Вывод:
```
  🛰  CHEBURNET-ROUTER TRAVEL DIAGNOSTIC
────────────────────────────────────────────────────────────
WAN источники:
  Ethernet (eth0/wan)    UP       → 192.168.31.111
  Wi-Fi WISP (wwan)      OFF      (travel-connect)
  USB tether             EMPTY    (нет USB-устройства)
  Default route:         via 192.168.31.1 dev eth0 src 192.168.31.111
────────────────────────────────────────────────────────────
VPN (AmneziaWG):
  awg0                   handshake 70s ago
  transfer:              402.18 MiB in / 104.06 MiB out
  exit endpoint:         179.43.168.10:8630
  Mode:                  home
  Portal bypass:         off
  Kill switch:           active
────────────────────────────────────────────────────────────
DNS:
  Provider:              dns.quad9.net/dns-query (doh)
  Live resolve:          OK (cloudflare.com → 104.16.133.229)
────────────────────────────────────────────────────────────
Adblock:
  Hagezi Pro:            loaded, ~198560 domains (1498 KB gz)
────────────────────────────────────────────────────────────
Система:
  Uptime:                2h 52m
  Load avg:              0.26, 0.17, 0.10
  Memory:                106 MB used / 485 MB total (21%, 313 MB free)
  Overlay flash:         27.3M used / 205.0M total (14%)
  WAN MAC:               94:83:c4:89:16:0c (factory)
```

Всё что надо для понимания состояния в одном экране.

## Продвинутые сценарии

### Автоматизация на ноутбуке

Shell-функция в `~/.bashrc` или `~/.zshrc`:

```bash
hotel() {
    local ssid="$1"
    local psk="$2"
    ssh root@192.168.1.1 "travel-connect '$ssid' '$psk' && \
                          travel-portal && \
                          echo 'Откройте http://neverssl.com в браузере, примите terms, затем:'"
    echo "После: run 'vpn-on'"
}

vpn-on() {
    ssh root@192.168.1.1 "travel-vpn-on && vpn-mode travel"
}
```

Типичный поток сокращается до двух команд: `hotel "SSID" "pass"` → accept terms → `vpn-on`.

### Сохранение часто используемых Wi-Fi

Для точек, к которым подключаетесь регулярно (дом друзей, свой офис, частая кофейня), можно сохранить и переключаться:

```bash
# Создать preset
ssh root@192.168.1.1 "cat > /root/wifi-presets/cafe.conf <<EOF
SSID=\"CafeGuest\"
PSK=\"welcome2024\"
EOF"

# Подключиться одной командой
ssh root@192.168.1.1 ". /root/wifi-presets/cafe.conf && travel-connect \"\$SSID\" \"\$PSK\""
```

### Fallback VPN-endpoint

Если отель блокирует UDP:8630 (редко, но у крупных сетей бывает), можно добавить второй AWG-endpoint (например, Netherlands:443) и скрипт свитча. Не входит в Tier 1 — задокументируем позже когда потребуется.

## Проверь себя

1. **Я подключился через `travel-connect` к отелю, но не знаю — есть ли captive portal?**
   <details><summary>Ответ</summary>
   Простой тест: после `travel-connect` (и до `travel-portal`) попробуйте `ssh root@192.168.1.1 curl -sIv http://neverssl.com 2>&1 | head`. Если видите HTTP 200 от neverssl — портала нет, можно сразу `vpn-mode travel`. Если видите HTTP 302 с редиректом на `*.hotel.com` или аналог — нужен `travel-portal`.
   </details>

2. **Что если я забыл вызвать `travel-vpn-on` и ушёл спать?**
   <details><summary>Ответ</summary>
   Через 15 минут после `travel-portal` фоновый таймер автоматически восстановит VPN. Это гарантия «максимум 15 минут без защиты». Если нужно дольше (например, заполняете большую анкету на отельном портале) — можно `travel-portal 30`.
   </details>

3. **Как переключить SSID своей домашней сети в TRAVEL-режим (чтобы видеть «CheburNet_Travel» вместо обычного), например, для отличия?**
   <details><summary>Ответ</summary>
   Не предусмотрено в Tier 1, но легко добавить. `uci set wireless.default_radio1.ssid='CheburNet_Travel'` когда входите в travel-mode, обратно — при home-mode. Подумайте, нужно ли это на самом деле — обычно родственники подключаются к вашему SSID один раз и больше не думают.
   </details>

## 📚 Глубже изучить

- [OpenWrt: WLAN client/WISP](https://openwrt.org/docs/guide-user/network/wifi/connect_client_wifi) — как сделать WISP вручную без скрипта
- [Captive portal (wikipedia)](https://en.wikipedia.org/wiki/Captive_portal) — что это такое в общем
- [WISP мOPS in MediaTek](https://openwrt.org/docs/techref/hardware/port.switch.vlan) — нюансы концурентного AP+STA
- [NeverSSL](http://neverssl.com/) — специальный сайт который никогда не редиректит на HTTPS, идеален для тестирования captive portals
