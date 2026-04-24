# cheburnet-router

> **Роутер для свободного интернета дома.**  
> `.ru` `.su` `.рф` — через ваш обычный IP. Всё остальное — через зашифрованный VPN.  
> Реклама заблокирована на всех устройствах. Настройка — одной командой.

![Platform](https://img.shields.io/badge/platform-OpenWrt%2025.12-blue)
![Hardware](https://img.shields.io/badge/hardware-Cudy%20TR3000%20%7C%20GL.iNet%20Beryl%20AX-orange)
![VPN](https://img.shields.io/badge/VPN-AmneziaWG-green)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

> **⚠️ Важно:** для работы VPN нужен либо **платный сервер Amnezia VPN**, либо **свой VPS с установленным AmneziaWG**. Бесплатного VPN здесь нет — этот проект настраивает роутер, но не предоставляет сам VPN-сервер.

---

## Быстрый старт

**Что нужно до начала:**

1. Роутер прошит на OpenWrt 25.12 → [Как прошить ↓](#шаг-2--прошить-openwrt)
2. **Платная подписка [Amnezia VPN](https://amnezia.org)** или свой VPS с AmneziaWG → [Подробнее ↓](#шаг-3--получить-amneziawg-конфиг)
3. SSH работает: `ssh root@192.168.1.1`

```bash
git clone https://github.com/yurik2718/cheburnet-router.git
cd cheburnet-router
./setup.sh
```

Мастер объяснит разницу между VPN и zapret, поможет выбрать подходящий вариант и сделает всё сам.

---

## Два варианта — какой выбрать?

### VPN (AmneziaWG) — рекомендуем

Ваш трафик идёт через зашифрованный туннель до VPN-сервера за рубежом. Провайдер видит только зашифрованный поток — не видит ни сайты, ни содержимое.

**Открывает:** всё — YouTube, Instagram, Telegram, любые заблокированные сайты.  
**Требует:** платный VPN-сервер (~300–500 руб/мес) — Amnezia VPN или свой VPS.

### zapret — бесплатно, без сервера

Роутер «ломает» TCP-пакеты так, что DPI-оборудование провайдера не распознаёт к какому сайту идёт запрос. Работает полностью локально, без внешнего сервера.

**Открывает:** сайты заблокированные через DPI — YouTube, Twitch и часть других.  
**Не открывает:** Instagram, Facebook и другие сайты с IP-блокировкой.  
**Не скрывает:** провайдер по-прежнему видит какие сайты вы открываете.

> **Совет:** если нужен Instagram или важна приватность — берите VPN. zapret — хорошее решение если VPN пока недоступен.

---

## Что происходит после установки

| Куда идёт трафик | Как маршрутизируется |
|---|---|
| yandex.ru, vk.com, gosuslugi.ru | Напрямую через ваш интернет |
| youtube.com, instagram.com, telegram.org | Через зашифрованный VPN-туннель |
| Реклама и трекеры | Заблокированы на уровне DNS |

Переключить режим можно одной командой:

```bash
ssh root@192.168.1.1

vpn-mode home    # .ru напрямую + остальное через VPN (по умолчанию)
vpn-mode travel  # весь трафик через VPN
vpn-mode status  # текущий режим
```

---

## Пошаговый гайд

### Шаг 1 — Купить роутер

**Рекомендуется: Cudy TR3000 v1** (~$40–55 на AliExpress)

- Компактный, питание от USB-C (работает от повербанка)
- Wi-Fi 6, 2.5 GbE, 512 МБ RAM
- Идентичное железо с GL.iNet Beryl AX, но в 2–3 раза дешевле

> ⚠️ **Серийники `2543...`** (ноябрь 2025+) — нужна OpenWrt 24.10.5+, иначе кирпич.  
> ❌ **Не берите** MT7621-роутеры (WR1300, M1300, X6) — мало RAM.

Другие совместимые модели: [таблица совместимости ↓](#совместимое-железо)

---

### Шаг 2 — Прошить OpenWrt

1. Зайдите на **[cudy.com/openwrt-software-download](https://www.cudy.com/en-us/blogs/faq/openwrt-software-download)**
2. Скачайте **interim firmware** для вашей модели
3. В веб-интерфейсе Cudy: **Firmware Upgrade** → загрузите interim-файл → дождитесь перезагрузки
4. Скачайте **OpenWrt 25.12.2** с [openwrt.org/toh](https://openwrt.org/toh/start) → прошейте снова
5. Роутер перезагрузится. Проверьте SSH:

```bash
ssh root@192.168.1.1
# Если пустой пароль — просто Enter
```

> Подробности и нюансы прошивки: [docs/10-upgrades.md](docs/10-upgrades.md)

---

### Шаг 3 — Получить AmneziaWG конфиг

> **⚠️ Без VPN-сервера роутер не заработает как задумано.** Нужен один из вариантов ниже.

**Вариант А — Amnezia VPN** (платная подписка, самый простой):
> Купите подписку на [amnezia.org](https://amnezia.org), скачайте приложение.  
> В приложении: Настройки → Сервер → Поделиться → Экспорт конфигурации → скачайте `.conf`

**Вариант Б — Свой VPS с AmneziaWG** (платный VPS, но сервер ваш):
> Арендуйте VPS (~$3–5/мес, например Hetzner, DigitalOcean, Timeweb).  
> Установите через приложение Amnezia: [amnezia.org](https://amnezia.org) → инструкция за ~5 минут.  
> Экспортируйте `.conf` так же как в варианте А.

> Что такое AmneziaWG и зачем: [docs/02-amneziawg.md](docs/02-amneziawg.md)

---

### Шаг 4 — Клонировать репозиторий

```bash
git clone https://github.com/yurik2718/cheburnet-router.git
cd cheburnet-router
```

---

### Шаг 5 — Запустить мастер установки

```bash
./setup.sh
```

Мастер спросит:
- IP роутера (обычно `192.168.1.1`)
- Путь к вашему `.conf` файлу
- Название и пароль Wi-Fi

Потом сделает всё остальное сам и покажет финальный статус.

---

### Шаг 6 — Проверить работу

1. Подключитесь к Wi-Fi с вашим новым SSID
2. Откройте **[speedtest.yandex.ru](https://speedtest.yandex.ru)** — российский сервис, должен работать напрямую и показывать ваш обычный IP
3. Откройте **[speedtest.net](https://speedtest.net)** — в России заблокирован, значит откроется только через VPN. Если открылся — маршрутизация работает правильно

```bash
# Или проверьте прямо из терминала:
ssh root@192.168.1.1 'travel-check'
```

---

## Что установлено и как работает

### Режим VPN

| Компонент | Что делает |
|---|---|
| **AmneziaWG** | VPN-туннель с обфускацией — обходит примитивный DPI |
| **Podkop + sing-box** | Умный split-routing: .ru/.su/.рф напрямую, всё остальное через VPN |
| **adblock-lean + Hagezi Pro** | Блокировка 200к+ рекламных и трекинговых доменов на уровне DNS |
| **Quad9 DoH** | Зашифрованный DNS, автоматически переключается на Cloudflare при сбое |
| **Kill switch** | При падении VPN трафик блокируется — ничего не утекает |
| **Watchdog** | Автоматически перезапускает VPN при зависании |
| **WPA3** | Современное шифрование Wi-Fi |

### Режим zapret

| Компонент | Что делает |
|---|---|
| **zapret / nfqws** | Перехватывает пакеты через nfqueue и модифицирует их так, что DPI не распознаёт сайт |
| **adblock-lean + Hagezi Pro** | Блокировка рекламы и трекеров |
| **Quad9 DoH** | Зашифрованный DNS |
| **WPA3** | Современное шифрование Wi-Fi |

**Как работает zapret:** роутер ловит исходящие TCP/UDP пакеты на порту 443, разбивает TLS-хэндшейк на части или инжектирует фиктивные пакеты. DPI-оборудование провайдера «видит мусор» вместо имени сайта и не блокирует. Сервер получает нормальные пакеты — соединение устанавливается. Всё это происходит за миллисекунды и прозрачно для устройств в сети.

**Если zapret не помогает:** эффективность зависит от провайдера. Можно попробовать другую стратегию — отредактируйте строку `OPTS_TCP` в `/etc/init.d/zapret`:
```bash
ssh root@192.168.1.1

# Доступные стратегии (меняйте и перезапускайте):
# --dpi-desync=fake,disorder2    ← по умолчанию
# --dpi-desync=fake,split2
# --dpi-desync=disorder2
# --dpi-desync=fake

/etc/init.d/zapret restart
```

---

## Полезные команды

```bash
ssh root@192.168.1.1

# Режимы
vpn-mode status          # текущий режим
vpn-mode home            # .ru напрямую, остальное через VPN
vpn-mode travel          # весь трафик через VPN

# Диагностика
travel-check             # полная диагностика одной командой
awg show awg0            # статус VPN-туннеля
dns-provider status      # текущий DNS-провайдер

# Логи
logread | grep -i amnezia    # логи VPN
logread | grep -i podkop     # логи маршрутизации
```

Шпаргалка всех команд: [docs/commands.md](docs/commands.md)

---

## Документация

Разложена по темам. Можно читать в любом порядке.

| # | Тема | Что внутри |
|---|---|---|
| 📐 01 | [Архитектура](docs/01-architecture.md) | Схема потока трафика, слои защиты |
| 🌐 02 | [AmneziaWG](docs/02-amneziawg.md) | Как работает туннель и обфускация |
| 🧭 03 | [Podkop и маршрутизация](docs/03-podkop-routing.md) | Split-routing, FakeIP, настройка списков |
| 🚫 04 | [Блокировка рекламы](docs/04-adblock.md) | adblock-lean, Hagezi Pro |
| 🔒 05 | [DNS](docs/05-dns.md) | Quad9 DoH, Cloudflare fallback, автофейловер |
| 📡 06 | [Wi-Fi](docs/06-wifi.md) | WPA3 SAE, PMF, country code |
| 🎚 07 | [Управление режимами](docs/07-modes.md) | HOME/TRAVEL, vpn-mode, физическая кнопка |
| 🛡 08 | [Kill switch](docs/08-killswitch.md) | Трёхслойная защита от утечек |
| 🔧 09 | [Диагностика](docs/09-troubleshooting.md) | «что-то не работает — куда смотреть» |
| 🔄 10 | [Обновления](docs/10-upgrades.md) | sysupgrade, apk upgrade, восстановление |
| 🎒 11 | [TRAVEL-режим](docs/11-travel.md) | WISP, captive portal, USB-tethering |

---

## Совместимое железо

### Рекомендованные роутеры

| Модель | Цена | Особенности |
|---|---|---|
| **Cudy TR3000 v1** ⭐ | ~$40–55 | Travel-форм-фактор, USB-C 5V (PowerBank), 2.5 GbE |
| Cudy WR3000P v1 | ~$50–65 | 4×GbE LAN + 2.5 GbE WAN, стационарный |
| Cudy AP3000 v1 | ~$60–75 | 256 MB flash, больше запаса overlay |
| GL.iNet Beryl AX | ~$110–140 | Физический слайдер HOME/TRAVEL + активное охлаждение |

**Все модели** используют MediaTek MT7981 (Filogic) — пакеты AmneziaWG совместимы без изменений.

Минимальные требования для любого роутера:
- ≥ 256 MB RAM (рекомендуется 512 MB)
- ≥ 64 MB flash
- OpenWrt 23.05+

**Важно при покупке Cudy:**
- Серийники `2543...` (ноябрь 2025+) — нужна OpenWrt 24.10.5+
- Первая прошивка требует interim firmware с сайта Cudy
- Не берите MT7621 (WR1300, M1300) — 128 MB RAM, не хватит

> Портирование на другое железо: [setup/README.md](setup/README.md)

---

## Для любопытных — как это устроено

Если хочется понимать, а не просто запустить — вот точки входа:

- **[Архитектура](docs/01-architecture.md)** — большая схема, поток каждого пакета через систему
- **[AmneziaWG изнутри](docs/02-amneziawg.md)** — разбор обфускации по байтам, decoy-пакеты
- **[Podkop + sing-box](docs/03-podkop-routing.md)** — FakeIP механика, TPROXY, почему именно так
- **[Defense-in-depth](docs/08-killswitch.md)** — все три слоя kill switch, что закрывает каждый
- **[Лаборатория сетей](docs/education.md)** — tcpdump, DNS query logging, посмотрите что ваши устройства делают в фоне

---

## Честные ограничения

- ❌ Не защищает от физического доступа к роутеру (firstboot сбрасывает всё)
- ❌ Не гарантирует невидимость для продвинутого статистического DPI
- ❌ Не блокирует 100% рекламы (YouTube доставляет видеорекламу с тех же серверов что и видео)
- ❌ Не лечит malware на устройствах в сети
- ❌ Нужен платный VPN-сервер или свой VPS — бесплатного «всё включено» нет

---

## Дисклеймер

VPN-технологии легальны в большинстве стран. Проект создан в образовательных целях.  
Автор не несёт ответственности за использование этих технологий читателями.

---

## Благодарности

- [AmneziaVPN](https://amnezia.org/) — open-source VPN с обфускацией
- [itdoginfo/podkop](https://github.com/itdoginfo/podkop) — split-routing
- [SagerNet/sing-box](https://github.com/SagerNet/sing-box) — прокси-роутер
- [Slava-Shchipunov/awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt) — kmod-amneziawg
- [lynxthecat/adblock-lean](https://github.com/lynxthecat/adblock-lean) — DNS-блокировка
- [hagezi/dns-blocklists](https://github.com/hagezi/dns-blocklists) — блок-списки
- [Quad9](https://www.quad9.net/) — DoH-резолвер
- [OpenWrt](https://openwrt.org/) — свободная ОС для роутеров

[MIT License](LICENSE) — форкайте, адаптируйте, шлите PR.
