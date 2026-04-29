<div align="center">

# 🔐 cheburnet-router

# Образовательный OpenWrt-стенд<br>с автоматизированной настройкой

### Открыл браузер → ввёл пароль Wi-Fi → стенд работает

*AmneziaWG 2.0 · Three-layer kill switch · Split-routing · DoH · WPA3 · 200k+ доменов в блок-листе*

<br>

![Platform](https://img.shields.io/badge/platform-OpenWrt%2025.12-blue)
![Hardware](https://img.shields.io/badge/hardware-Cudy%20TR3000%20%7C%20GL.iNet%20Beryl%20AX-orange)
![VPN](https://img.shields.io/badge/VPN-AmneziaWG%202.0%20%2B%20I1%20CPS-green)
![DNS](https://img.shields.io/badge/DNS-Quad9%20DoH-9cf)
![Adblock](https://img.shields.io/badge/Adblock-Hagezi%20Pro%20200k%2B-red)
![License](https://img.shields.io/badge/license-MIT-lightgrey)
![Docs](https://img.shields.io/badge/docs-11%20глав-purple)

<br>

**[Быстрый старт ↓](#быстрый-старт--веб-мастер)** · **[Что изучаем ↓](#что-изучаем-на-стенде)** · **[Документация ↓](#документация)**

</div>

---

> ℹ️ **Образовательный проект.** Это рабочая лаборатория для изучения сетевых технологий — VPN, обфускации трафика, split-routing, DNS-шифрования, kill switch, DPI. Все компоненты — open-source и индустриально-стандартные, применяются в корпоративных сетях, банкинге и удалённой работе.

> ⚠️ Стенду нужен AmneziaWG-сервер. Подробности в [Шаге 3](#шаг-3--получить-amneziawg-конфиг).

---

## Что изучаем на стенде

Стенд показывает на одном роутере, как современные сетевые технологии работают вместе:

| Технология | Что изучаем |
|---|---|
| 🌐 **AmneziaWG 2.0 + I1 CPS** | VPN-туннель с обфускацией: decoy-пакеты, маскировка под HTTPS, custom protocol signature. По байтам разобрано в [docs/02](docs/02-amneziawg.md). |
| 🧭 **Podkop + sing-box** | Policy-based routing на FakeIP: `.ru/.su/.рф` идут одним маршрутом, остальное другим. TLD-матчинг + живые списки доменов. [docs/03](docs/03-podkop-routing.md). |
| 🛡 **Three-layer kill switch** | Defense-in-depth: sing-box bind-outbound + TPROXY + fw4 firewall. Три независимых слоя — для отказа нужно чтобы все три не сработали. [docs/08](docs/08-killswitch.md). |
| 🔒 **Quad9 DoH** | DNS-over-HTTPS как замена открытому DNS. Зашифрованные DNS-запросы, защита от подмены. [docs/05](docs/05-dns.md). |
| 🚫 **adblock-lean + Hagezi Pro** | Блокировка рекламы и трекеров на уровне DNS — 200k+ доменов на роутере. Защита всех устройств в сети. [docs/04](docs/04-adblock.md). |
| 📡 **WPA3 SAE + PMF** | Современное шифрование Wi-Fi: SAE handshake, защита фреймов управления. [docs/06](docs/06-wifi.md). |
| 🔧 **AWG watchdog** | Авто-перезапуск туннеля при зависании handshake. Образец practical reliability engineering. |

В каждой главе документации: «что», «зачем», «как работает», «какие альтернативы рассматривались», ссылки на RFC и whitepapers.

---

## Быстрый старт — веб-мастер

Не нужны git, bash, Linux — только браузер. Один раз через SSH запускаем веб-мастер:

```bash
ssh root@192.168.1.1 'wget -qO- https://raw.githubusercontent.com/yurik2718/cheburnet-router/main/bootstrap.sh | sh'
```

Открываем в браузере:

```
http://192.168.1.1/cheburnet/
```

Веб-мастер примет `.conf`-файл, настроит Wi-Fi и сделает всё остальное. Прогресс — прямо в браузере. После установки там же — управление и статус.

**Альтернатива для продвинутых** (Linux/macOS):

```bash
git clone https://github.com/yurik2718/cheburnet-router.git
cd cheburnet-router
./setup.sh
```

---

## Что происходит после установки

| Трафик | Куда идёт |
|---|---|
| yandex.ru, vk.com, gosuslugi.ru | Напрямую — без VPN, полная скорость |
| youtube.com, instagram.com, telegram.org | Через зашифрованный AmneziaWG-туннель |
| Реклама и трекеры | Заблокированы на уровне DNS |

Переключение режима — одна команда:

```bash
ssh root@192.168.1.1
vpn-mode home    # .ru напрямую + остальное через VPN (по умолчанию)
vpn-mode travel  # весь трафик через VPN
vpn-mode status  # текущий режим
```

---

## Что установлено

| Компонент | Что делает |
|---|---|
| **AmneziaWG 2.0 + I1 CPS** | VPN-туннель с обфускацией, маскируется под обычный HTTPS-трафик |
| **Podkop + sing-box** | Split-routing: `.ru/.su/.рф` напрямую, остальное через VPN |
| **adblock-lean + Hagezi Pro** | Блокировка 200k+ рекламных доменов на уровне DNS |
| **Quad9 DoH** | Зашифрованный DNS — провайдер не видит ваши запросы |
| **Kill switch (3 слоя)** | При падении VPN трафик блокируется — ничего не утекает |
| **AWG watchdog** | Авто-перезапуск туннеля при зависании handshake |
| **WPA3** | Современное шифрование Wi-Fi |

---

## Для дома — настроил один раз, работает годами

- **Kill switch всегда активен** — сбой VPN не приводит к утечкам
- **AWG watchdog** — туннель автоматически восстанавливается при зависании
- **Quad9 DoH** — зашифрованный DNS без дополнительной настройки
- **adblock-lean** защищает все устройства в сети — телефоны, Smart TV, планшеты

---

## Для путешественников — полный travel-набор

Компактный **Cudy TR3000** работает от PowerBank 5V. Подключили в отеле — все ваши устройства в защищённой сети. Отель видит одного клиента — ваш роутер.

- **`travel-connect`** — подключение в WISP-режиме (роутер как Wi-Fi клиент)
- **`travel-portal`** — обработка captive portal с авто-восстановлением через N минут
- **`travel-check`** — полная диагностика одной командой
- **`travel-vpn-on`** — ручное восстановление VPN после портала

---

## Пошаговый гайд

### Шаг 1 — Купить роутер

**Рекомендуется: Cudy TR3000 v1** (~$40–55 на AliExpress)

- Компактный, питание от USB-C (работает от повербанка)
- Wi-Fi 6, 2.5 GbE, 512 МБ RAM
- Тот же чип (MT7981B), что у GL.iNet Beryl AX — в 2–3 раза дешевле

> ⚠️ **Серийники `2543...`** (ноябрь 2025+) — нужна OpenWrt 24.10.5+, иначе кирпич.
> ❌ **Не берите** MT7621-роутеры (WR1300, M1300, X6) — 128 МБ RAM, не хватит.

→ [Таблица совместимых моделей ↓](#совместимое-железо)

---

### Шаг 2 — Прошить OpenWrt

1. Зайдите на **[cudy.com/openwrt-software-download](https://www.cudy.com/en-us/blogs/faq/openwrt-software-download)**
2. Скачайте **interim firmware** → прошейте через веб-UI Cudy (Firmware Upgrade)
3. После перезагрузки скачайте **OpenWrt 25.12.2** с [openwrt.org/toh](https://openwrt.org/toh/start) → прошейте снова
4. Проверьте SSH: `ssh root@192.168.1.1` (по умолчанию пустой пароль)

> Подробности и нюансы прошивки: [docs/10-upgrades.md](docs/10-upgrades.md)

---

### Шаг 3 — Получить AmneziaWG конфиг

Стенду нужен AmneziaWG-сервер — иначе VPN-часть не поднимется. Два варианта:

| Вариант | Сложность | Стоимость | Кому подойдёт |
|---|---|---|---|
| 🚀 **Amnezia Premium** | 5 минут, готовый `.conf` | от ~$3/мес | Хочу чтобы просто работало |
| 🛠 **Свой VPS + Amnezia** | 30 минут, настройка через приложение | от $3/мес VPS | Хочу контролировать всё сам |

#### 🚀 Вариант А — Amnezia Premium (рекомендуется)

👉 **[Купить Amnezia Premium](https://storage.googleapis.com/amnezia/amnezia.org?m-path=premium&arf=EB5KDKXCJYQYP4MG)** — готовая подписка с экспортом `.conf` в один клик.

> *Это реферальная ссылка — переход по ней поддерживает развитие проекта (с твоей стороны цена не меняется). Если не хочешь использовать реф — иди на [amnezia.org](https://amnezia.org) напрямую.*

В приложении: Настройки → Сервер → Поделиться → Экспорт конфигурации → скачайте `.conf`.

#### 🛠 Вариант Б — Свой VPS с AmneziaWG

Арендуйте VPS (~$3–5/мес — Hetzner, DigitalOcean, Timeweb).
Установите через приложение Amnezia → инструкция за ~5 минут. Экспортируйте `.conf`.

> Как устроен AmneziaWG изнутри (по байтам): [docs/02-amneziawg.md](docs/02-amneziawg.md)

---

### Шаг 4 — Запустить веб-мастер

```bash
# Один раз через SSH:
ssh root@192.168.1.1 'wget -qO- https://raw.githubusercontent.com/yurik2718/cheburnet-router/main/bootstrap.sh | sh'

# Открываем в браузере:
# http://192.168.1.1/cheburnet/
```

Веб-мастер спросит `.conf`-файл, название и пароль Wi-Fi — и сделает всё остальное сам.

---

### Шаг 5 — Проверить работу

1. Подключитесь к Wi-Fi с вашим новым SSID
2. Откройте **[speedtest.yandex.ru](https://speedtest.yandex.ru)** — российский сервис, идёт напрямую с полной скоростью
3. Откройте **[speedtest.net](https://speedtest.net)** — иностранный сервис, идёт через VPN-туннель
4. Сравните `traceroute` для обоих — увидите два разных маршрута. Это и есть split-routing в работе.

```bash
ssh root@192.168.1.1 'travel-check'   # полная диагностика одной командой
```

---

## Совместимое железо

### Рекомендованные роутеры

| Модель | Цена | Особенности |
|---|---|---|
| **Cudy TR3000 v1** ⭐ | ~$40–55 | Travel-форм-фактор, USB-C 5V (PowerBank), 2.5 GbE |
| Cudy WR3000P v1 | ~$50–65 | 4×GbE LAN + 2.5 GbE WAN, стационарный |
| Cudy AP3000 v1 | ~$60–75 | 256 МБ flash, больше запаса overlay |
| GL.iNet Beryl AX | ~$110–140 | Физический слайдер HOME/TRAVEL + активное охлаждение |

**Все модели** используют MediaTek MT7981 (Filogic) — пакеты AmneziaWG совместимы без изменений.

### Cudy TR3000 vs GL.iNet Beryl AX

Железо почти идентичное — оба на MediaTek MT7981B:

| | GL.iNet Beryl AX | Cudy TR3000 |
|---|:---:|:---:|
| SoC | MT7981B | **тот же** |
| RAM | 512 МБ | 512 МБ |
| Flash | 256 МБ | 128 МБ |
| Wi-Fi | 6 AX3000 | 6 AX3000 |
| Активное охлаждение | Есть (кулер) | Нет (пассивное) |
| Физический слайдер HOME/TRAVEL | ✅ | ❌ (CLI `vpn-mode`) |
| **Цена** | **~$110–140** | **~$40–55** |

**О flash:** наша сборка использует ~27 МБ. На Cudy (128 МБ) остаётся ~100 МБ overlay — с большим запасом.
**О кулере:** trip point термозоны — 60°C. В домашнем режиме CPU редко превышает 55–58°C. Кулер почти не включается даже на Beryl AX.

**Вывод:** если нужен физический переключатель для нетехнических пользователей в семье — Beryl AX. Если хотите тот же функционал за треть цены — Cudy TR3000.

### Минимальные требования

- ≥ 256 МБ RAM (рекомендуется 512 МБ)
- ≥ 64 МБ flash
- OpenWrt 25.12+ (с `apk`-пакетным менеджером)
- Архитектура, для которой есть [готовые пакеты awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt/releases): `aarch64_cortex-a53_mediatek_filogic`, `x86_64`, `mipsel_24kc` и др.

### Универсальность

Установка не привязана к конкретному роутеру: архитектура пакетов AmneziaWG, версия awg-openwrt и LAN-подсеть **определяются автоматически** из `/etc/openwrt_release` и `uci show network.lan` при запуске `setup.sh`. На любом совместимом OpenWrt-роутере мастер ставит сборку без правок.

> Подробности портирования и список того, что детектится автоматически: [setup/README.md](setup/README.md)

---

## Документация

| # | Тема | Что внутри |
|---|---|---|
| 📐 01 | [Архитектура](docs/01-architecture.md) | Схема потока трафика, слои защиты |
| 🌐 02 | [AmneziaWG](docs/02-amneziawg.md) | Туннель, обфускация по байтам, watchdog |
| 🧭 03 | [Podkop и маршрутизация](docs/03-podkop-routing.md) | Split-routing, FakeIP, настройка списков |
| 🚫 04 | [Блокировка рекламы](docs/04-adblock.md) | adblock-lean, Hagezi Pro |
| 🔒 05 | [DNS](docs/05-dns.md) | Quad9 DoH, как работает защита |
| 📡 06 | [Wi-Fi](docs/06-wifi.md) | WPA3 SAE, PMF, country code |
| 🎚 07 | [Управление режимами](docs/07-modes.md) | HOME/TRAVEL, vpn-mode, кнопка |
| 🛡 08 | [Kill switch](docs/08-killswitch.md) | Три независимых слоя защиты от утечек |
| 🔧 09 | [Диагностика](docs/09-troubleshooting.md) | «что-то не работает — куда смотреть» |
| 🔄 10 | [Обновления](docs/10-upgrades.md) | sysupgrade, apk upgrade, восстановление |
| 🎒 11 | [TRAVEL-режим](docs/11-travel.md) | WISP, captive portal, работа из отеля |

---

## Для любопытных — как это устроено изнутри

Если хочется понимать, а не просто запустить:

- **[AmneziaWG изнутри](docs/02-amneziawg.md)** — разбор обфускации по байтам, decoy-пакеты, hex-анализ
- **[Podkop + sing-box](docs/03-podkop-routing.md)** — FakeIP механика, TPROXY, почему именно так
- **[Defense-in-depth kill switch](docs/08-killswitch.md)** — все три слоя, что закрывает каждый
- **[Архитектура](docs/01-architecture.md)** — большая схема, поток каждого пакета
- **[Лаборатория сетей](docs/education.md)** — tcpdump, DNS query logging, посмотрите что ваши устройства делают в фоне

В каждой главе: «Почему так, а не иначе», проверочные вопросы, ссылки на RFC и whitepapers.

---

## Честные ограничения

- ❌ Не защищает от физического доступа к роутеру
- ❌ Не гарантирует невидимость при продвинутом статистическом DPI
- ❌ Не блокирует 100% рекламы (например, YouTube-реклама идёт с тех же серверов что и видео)
- ❌ Не лечит malware на устройствах в сети
- ❌ Нужен AmneziaWG-сервер — Premium-подписка или свой VPS

---

## Дисклеймер

**Этот проект — образовательная демонстрация сетевых технологий.** AmneziaWG, WireGuard, OpenVPN, DoH, split-routing — стандартные индустриальные технологии, применяются в корпоративных сетях, для удалённой работы, в банкинге и для защиты трафика в публичных Wi-Fi. Их применение **легально** в большинстве стран.

Проект **не предназначен** для нарушения законов вашей юрисдикции. Автор не несёт ответственности за то, как читатель применяет описанные технологии — ответственность за соблюдение применимого законодательства лежит на пользователе.

---

## Благодарности

- [AmneziaVPN](https://amnezia.org/) — open-source VPN с обфускацией ([Amnezia Premium](https://storage.googleapis.com/amnezia/amnezia.org?m-path=premium&arf=EB5KDKXCJYQYP4MG) — подписка через реф-ссылку)
- [itdoginfo/podkop](https://github.com/itdoginfo/podkop) — split-routing для OpenWrt
- [SagerNet/sing-box](https://github.com/SagerNet/sing-box) — прокси-роутер
- [Slava-Shchipunov/awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt) — kmod-amneziawg
- [lynxthecat/adblock-lean](https://github.com/lynxthecat/adblock-lean) — DNS-блокировка
- [hagezi/dns-blocklists](https://github.com/hagezi/dns-blocklists) — блок-списки доменов
- [Quad9](https://www.quad9.net/) — DoH-резолвер
- [OpenWrt](https://openwrt.org/) — свободная ОС для роутеров

[MIT License](LICENSE) — форкайте, адаптируйте, шлите PR.
