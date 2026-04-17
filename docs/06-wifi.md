# 📡 06. Wi-Fi

## TL;DR

Два радио (2.4 ГГц и 5 ГГц) объединены под **одним SSID** для простоты. Шифрование — **WPA2/WPA3-mixed (`sae-mixed`)**: новые устройства получают WPA3-SAE (forward secrecy + PMF), старые откатываются на WPA2-PSK. Требует пакета `wpad-mbedtls` (не базового `wpad-basic-mbedtls`). Country code — RU, PMF включён (`ieee80211w='1'`).

## Wi-Fi стандарты в одном абзаце

- **WPA** (2003) — затычка для сломанного WEP. Давно deprecated.
- **WPA2** (2004, RFC 4686) — стандарт дома на 20 лет. PSK-режим уязвим к offline-brute-force на захваченном handshake.
- **WPA3** (2018) — принципиально новый SAE-handshake (Simultaneous Authentication of Equals), устойчив к offline-атакам **даже при слабом пароле**. Плюс обязательные PMF (защита управляющих фреймов).
- **WPA3-transition (sae-mixed)** — AP заявляет оба, клиент выбирает максимум поддерживаемого.

## Зачем WPA3 именно нам

Главная киллер-фича для нашего кейса — **Forward Secrecy**.

### Сценарий: forward secrecy

Представьте, что сосед за стенкой захватывает зашифрованный Wi-Fi-трафик вашего роутера в течение месяца. Сохраняет.

**WPA2-PSK:** трафик шифруется ключом PTK, который генерируется из PSK (пароля) + nonce'ов из handshake'а. Если через год сосед получит ваш пароль (утечка, социальный инжиниринг, продажа роутера без reset'а), он **расшифрует весь записанный месяц трафика** из архива. Forward secrecy отсутствует.

**WPA3-SAE:** каждая сессия использует **уникальный session key**, не выводимый из пароля напрямую (Dragonfly handshake). Даже при знании пароля прошлые сессии **невозможно расшифровать**.

Для пользователя в РФ, где ISP может вести архивы — это принципиально.

### Сценарий: защита управляющих фреймов (PMF)

Без PMF любой может послать «deauth»-фрейм (незашифрованный фрейм управления), выкинув клиента с сети. Распространённая атака:
1. Атакующий выкидывает жертву с AP
2. Жертва переподключается → handshake
3. Handshake захватывается → brute-force оффлайн

**PMF (IEEE 802.11w)** шифрует management-фреймы, deauth-атака невозможна.

В WPA2 PMF **опционален и часто выключен по умолчанию**. В WPA3 **обязателен**.

## Конфигурация

### Пакет wpad

Важно: OpenWrt из коробки ставит `wpad-basic-mbedtls` — **поддерживает только WPA2**. Для WPA3/SAE нужна полная версия.

```bash
apk del wpad-basic-mbedtls
apk add wpad-mbedtls
```

Опции:
- `wpad-mbedtls` — полная версия, mbedTLS (легче на ресурсы)
- `wpad-openssl` — альтернатива на OpenSSL (больше совместимость, больше размер)
- `wpad-wolfssl` — на wolfSSL

Для Beryl AX разницы в производительности между mbedtls и openssl **нет** — оба справляются с 1.2 Гбит/с Wi-Fi 6.

### UCI-конфигурация

```ini
# /etc/config/wireless

config wifi-device 'radio0'
    option type 'mac80211'
    option path 'platform/soc/18000000.wifi'
    option band '2g'
    option channel '1'
    option htmode 'HE20'
    option country 'RU'

config wifi-iface 'default_radio0'
    option device 'radio0'
    option network 'lan'
    option mode 'ap'
    option ssid 'CheburNet_Beta_Tester'
    option encryption 'sae-mixed'
    option key 'ВАШ_СТОЙКИЙ_ПАРОЛЬ'
    option ieee80211w '1'
    option disabled '0'

config wifi-device 'radio1'
    option type 'mac80211'
    option path 'platform/soc/18000000.wifi+1'
    option band '5g'
    option channel '36'
    option htmode 'HE80'
    option country 'RU'

config wifi-iface 'default_radio1'
    option device 'radio1'
    option network 'lan'
    option mode 'ap'
    option ssid 'CheburNet_Beta_Tester'
    option encryption 'sae-mixed'
    option key 'ВАШ_СТОЙКИЙ_ПАРОЛЬ'
    option ieee80211w '1'
    option disabled '0'
```

**Ключевые параметры:**
- `encryption 'sae-mixed'` — WPA2/WPA3 transition
- `ieee80211w '1'` — PMF capable (не required). Ставить `'2'` (required) только если уверены, что все клиенты поддерживают PMF
- `country 'RU'` — разблокирует корректные каналы/мощность для российского регулирования
- Один и тот же SSID на обеих радио → band steering (клиент сам выбирает)

### Почему один SSID на оба диапазона

**Альтернатива:** `CheburNet_2G` и `CheburNet_5G`. Клиент вручную выбирает.

**Проблемы:**
- Родственникам придётся объяснять, что выбрать
- Старые устройства (2.4 ГГц-only) подключатся неправильно, если случайно выбрать _5G
- Ноутбук, переходящий из зоны 5G в зону 2.4 — не переключится автоматически

**Одно имя:** драйвер 802.11k/v/r помогает клиентам выбрать лучшее радио + roaming между ними при движении в квартире.

> 💡 **«Band steering»** — AP может отказаться принять клиента на 2.4 ГГц, если он поддерживает 5 ГГц (это сигнал клиенту попробовать другое радио). OpenWrt hostapd поддерживает через опцию `option band_steering '1'` в wifi-iface, но по умолчанию не включено.

### Country code и каналы

**2.4 ГГц** — везде одинаково (13 каналов в Европе/Азии, 11 в США). Канал 1 — чаще всего свободен в густозаселённых городах.

**5 ГГц в РФ** — более ограничен, чем в EU/US:
- **36, 40, 44, 48** — без ограничений (UNII-1)
- **52, 56, 60, 64, 100, 104, 108, 112, 116, 132, 136, 140** — DFS (Dynamic Frequency Selection): AP должна слушать радары и перестроиться, если обнаружит. Разрешены.
- **120, 124, 128, 149+** — ограничены или запрещены.

Мы поставили канал 36 — без DFS, гарантированно стабильный.

> ⚠️ **Если поставить неправильный country code** — например, US — AP будет работать на каналах, запрещённых в РФ. Это нелегально, и может создавать помехи радарам авиации (DFS). Ставьте `RU` честно.

## Безопасность пароля

**Длинный пароль ≠ устойчивость к атаке.** Длина защищает от brute-force, но WPA3-SAE **делает brute-force практически невозможным** независимо от длины.

**Все равно** рекомендую 16+ символов или passphrase-стиль:
- ❌ `admin123` — brute в секунды
- ⚠️ `Th1sIsAP@ss` — современная GPU сломает за часы
- ✅ `global-freedom-connections-2026!` — astronomy
- ✅ `correct-horse-battery-staple` — classic XKCD, 27^4 entropy ≈ 44 bits

Избегайте:
- Словарных слов подряд (без разделителей)
- Даты рождения, адресов, имён
- Stock-phrases из популярных фильмов/песен

**Изменение пароля** на активном AP:
```bash
uci set wireless.default_radio0.key='НОВЫЙ_ПАРОЛЬ'
uci set wireless.default_radio1.key='НОВЫЙ_ПАРОЛЬ'
uci commit wireless
wifi reload
```

Все клиенты будут отключены, должны переподключиться с новым паролем.

## Гостевой Wi-Fi (guest network)

Хорошая практика — отдельный SSID для гостей, изолированный от LAN.

**Добавление гостевой сети:**
```bash
# Новый network для guest
uci set network.guest=interface
uci set network.guest.proto='static'
uci set network.guest.ipaddr='192.168.10.1'
uci set network.guest.netmask='255.255.255.0'

# DHCP для guest
uci set dhcp.guest=dhcp
uci set dhcp.guest.interface='guest'
uci set dhcp.guest.start='100'
uci set dhcp.guest.limit='150'
uci set dhcp.guest.leasetime='6h'

# Firewall zone
uci add firewall zone
uci set firewall.@zone[-1].name='guest'
uci set firewall.@zone[-1].network='guest'
uci set firewall.@zone[-1].input='REJECT'      # гости не могут войти в админку
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'    # гости не видят LAN

# Guest → VPN (можно настроить как LAN, или отдельно direct)
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='guest'
uci set firewall.@forwarding[-1].dest='vpn'    # через AWG тоже?
# или
# uci set firewall.@forwarding[-1].dest='wan'  # напрямую, без VPN

# Wi-Fi iface
uci set wireless.guest=wifi-iface
uci set wireless.guest.device='radio1'
uci set wireless.guest.network='guest'
uci set wireless.guest.mode='ap'
uci set wireless.guest.ssid='CheburNet_Guest'
uci set wireless.guest.encryption='sae-mixed'
uci set wireless.guest.key='guest-password-123'
uci set wireless.guest.isolate='1'              # клиенты не видят друг друга

uci commit
/etc/init.d/network restart
wifi reload
```

Плюсы гостевой сети:
- Ваши LAN-устройства (NAS, принтер, smart home) **невидимы** гостям
- Админка роутера **недоступна** гостям
- Можно не пускать в VPN (гость идёт прямо через WAN без оверхеда) или наоборот, не выпускать без VPN (защита гостевых устройств)

## Мощность передатчика

По умолчанию hostapd использует максимум, разрешённый country code. В РФ для 5 ГГц UNII-1 это обычно **20 dBm** (100 мВт). Чаще всего **оставляем как есть**.

Снижение может быть полезно:
- В маленькой квартире (соседи не ловят ваш SSID)
- В офисе рядом с другими AP (меньше interference)
- Для экономии батареи роутера (но Beryl AX не батарейный, мимо)

```bash
uci set wireless.radio1.txpower='15'         # 15 dBm = 32 мВт
uci commit wireless; wifi reload
```

## Диагностика

```bash
# Подключённые клиенты
iw dev phy1-ap0 station dump

# Качество сигнала каждого
iw dev phy1-ap0 station dump | grep -E "Station|signal|tx bitrate"
# >>> signal: -45 dBm      <- хорошо (> -60)
# >>> signal: -75 dBm      <- слабый, на грани
# >>> signal: < -80 dBm    <- плохо, может теряться

# Какое шифрование использует клиент
hostapd_cli -i phy1-ap0 all_sta | grep -E 'Station|key_mgmt|sae'

# Hostapd статус
logread | grep hostapd | tail

# Сканирование эфира (увидеть соседей)
iw dev phy1-ap0 survey dump
```

## Типичные проблемы

### Устройство не подключается к sae-mixed

**Симптом:** «не может подключиться», «неправильный пароль» (но пароль точно правильный).

**Причины:**
1. **Очень старый клиент** (Android <10, iOS <13, Windows <10 1903) — не умеет SAE. Должен откатиться на WPA2, но иногда hostapd/клиент путаются. Решение: переключить на `psk2+ccmp` (чистый WPA2) или обновить клиента.
2. **Проблемы с PMF** на клиенте. Проверьте `ieee80211w='1'` (capable, не required) — некоторые старые устройства не умеют даже optional PMF.

### Странно низкая скорость Wi-Fi

Чек-лист:
- `iw dev phy1-ap0 station dump` — смотрим на **HE-MCS** (должно быть >= 7 для скорости)
- Клиент на 2.4 ГГц, а не 5 ГГц? — на 2.4 физика медленнее в разы
- Канал забит? — `iw dev phy1-ap0 survey dump` покажет активность соседей, поменяйте канал
- htmode стоит правильно? `HE80` для 5 ГГц даёт до 1.2 Гбит/с

### Клиент постоянно переключается между 2.4 и 5 ГГц

Это band steering не работает как надо. Можно попробовать:
- `option band_steering '1'` в 2.4 wifi-iface
- Или развести на разные SSID как workaround

## Проверь себя

1. **Почему для нашего сетапа WPA2/WPA3-mixed лучше, чем только WPA3?**
   <details><summary>Ответ</summary>Совместимость. В доме у родственников могут быть старые устройства: смарт-розетка 2018, старый IP-камера, гость с древним Android. Они не подключатся к чистому WPA3. Mixed — новые получают WPA3, старые — WPA2, все счастливы.</details>

2. **Что произойдёт, если изменить country code с RU на US?**
   <details><summary>Ответ</summary>AP начнёт использовать каналы и мощности, разрешённые в US. Каналы 36-48 совпадают, так что функционально будет работать. Но юридически — создаёт помехи для радиосистем, работающих на «специфически-RU» частотах (радары). Регулятор РФ может наказать. Плюс, если роутер попадёт в Европу — там свои ограничения отличаются от US. Честно ставьте корректную страну.</details>

3. **Если кто-то заспуфит нашу MAC-адрес и попытается подключиться — что его остановит?**
   <details><summary>Ответ</summary>WPA2/3 handshake требует знать **пароль**. MAC-спуфинг не даёт знания пароля. Клиент со спуфленым MAC'ом без пароля не пройдёт handshake. Если у атакующего **есть пароль** — он и без спуфинга подключится. MAC-фильтрация (`option macfilter`) — security theater, обходится за 30 секунд (wireless-фреймы содержат MAC и атакующий их может увидеть).</details>

## 📚 Глубже изучить

### Обязательно
- [OpenWrt Wiki: Wireless configuration](https://openwrt.org/docs/guide-user/network/wifi/basic) — параметры и примеры
- [Wi-Fi Alliance: WPA3 Specification](https://www.wi-fi.org/discover-wi-fi/security) — что такое WPA3 от source-of-truth

### Желательно
- [Dragonfly Key Exchange (RFC 7664)](https://datatracker.ietf.org/doc/html/rfc7664) — математика SAE
- [802.11w (PMF) explained](https://www.arubanetworks.com/techdocs/ArubaOS_83_Web_Help/Content/arubaos-solutions/802.11w/wifi-pmf.htm) — защита management-фреймов
- [KRACK Attacks (wpa2 vulnerability disclosed 2017)](https://www.krackattacks.com/) — почему нельзя использовать dumb WPA2

### Для любопытных
- 📺 [Mathy Vanhoef: Defeating Dragonfly with Side-Channels (BlackHat 2019)](https://www.youtube.com/watch?v=H55tdd26q5w) — атаки на раннюю реализацию WPA3
- 📺 [NetworkChuck: WPA3 explained](https://www.youtube.com/watch?v=zVMd6EuLPzM) — 15 минут понятно
- [802.11 Wireless Networks: Definitive Guide (Matthew Gast)](https://www.oreilly.com/library/view/80211-wireless-networks/0596100523/) — книга для глубокого погружения
