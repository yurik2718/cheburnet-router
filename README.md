# cheburnet-router

> Полная настройка роутера на OpenWrt для обхода цензуры, с физическим переключателем режимов, индикацией состояния и защитой от утечек. Рабочая, протестированная, задокументированная.

![Platform](https://img.shields.io/badge/platform-OpenWrt%2025.12-blue)
![Hardware](https://img.shields.io/badge/hardware-GL.iNet%20Beryl%20AX-orange)
![VPN](https://img.shields.io/badge/VPN-AmneziaWG%202.0-green)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

## Зачем это

В 2022+ годах РКН продолжает расширять список заблокированных ресурсов и активно блокирует стандартные VPN-протоколы (в т.ч. WireGuard) через DPI. Одновременно, бытовые роутеры GL.iNet работают на прошивке с встроенным VPN-клиентом, но её функциональность ограничена и проприетарна.

Этот проект решает **конкретный сценарий**: подарить неайтишным родственникам в РФ роутер, который «просто работает», годами, без обслуживания. Включается в розетку, Wi-Fi ловится, YouTube/Google/что-угодно открываются, .ru-сервисы быстрые, реклама не грузится, при сбоях не течёт. Физический переключатель переключает между «домом» и «в поездке». LED светится — значит всё хорошо, моргает — значит надо позвонить админу.

## Что умеет

- 🌐 **Обход блокировок** через AmneziaWG 2.0 (форк WireGuard с обфускацией против DPI)
- 🧭 **Умная маршрутизация**: иностранные сайты через VPN в Швейцарии, `.ru/.рф/.su/vk.com` напрямую с российского IP
- 🔒 **DoH-шифрование DNS** (Quad9 основной, Cloudflare резерв с автофейловером)
- 🚫 **Блокировка рекламы и трекеров** (Hagezi Pro, ~200k доменов)
- 🎚 **Физический переключатель** HOME/TRAVEL на корпусе
- 💡 **LED-индикация** состояния VPN + текущего режима
- 🛡 **Kill switch**: если VPN упал — трафик блокируется, а не течёт напрямую
- 📡 **Wi-Fi WPA2/WPA3-mixed** с PMF (Protected Management Frames)
- ⚙️ **Авто-восстановление**: health-check DNS, watchdog handshake AWG (перезапуск интерфейса при протухании рукопожатия)

## Железо, на котором проверено

- **GL.iNet Beryl AX (GL-MT3000)** — MediaTek Filogic 880, 2×A53 @ 1.3 ГГц, 512 МБ RAM, 256 МБ flash
- **OpenWrt 25.12.2** (ванильный, **не** заводская прошивка GL.iNet)
- **pkgmgr**: `apk` (не opkg)

Скорее всего работает и на других OpenWrt-устройствах ≥ 256 МБ RAM с поддержкой kmod-tproxy и Wi-Fi 6 (см. [setup/README.md](setup/README.md) для портирования).

## Нагрузка и потребление

- **CPU**: 100% idle в штатном режиме, load avg ~0.1
- **RAM**: ~100 MB used / 496 MB total (20%)
- **Flash**: 25 MB / 205 MB overlay (13%)
- **Пропускная способность**: Wi-Fi 6 5 ГГц до 1.2 Гбит/с локально, VPN-трафик до ~300-400 Мбит/с (ограничен кодом sing-box в userspace)

## Быстрый старт

```
git clone https://github.com/YOUR_USERNAME/cheburnet-router.git
cd cheburnet-router

# Положите свой AmneziaWG-конфиг сюда (получается из клиента Amnezia):
cp /path/to/your-awg.conf configs/awg0.conf

# Отредактируйте Wi-Fi настройки:
cp configs/wireless.uci.example.txt configs/wireless.uci.txt
vim configs/wireless.uci.txt

# Разверните на чистом OpenWrt-роутере:
./setup/full-deploy.sh root@192.168.1.1
```

Подробные инструкции — [setup/README.md](setup/README.md).

## Документация

Разложена тематически, можно читать в любом порядке, но первые две главы задают контекст.

| # | Тема | Что внутри |
|---|---|---|
| 📐 01 | [Архитектура](docs/01-architecture.md) | Большая схема, поток трафика, слои защиты |
| 🌐 02 | [AmneziaWG](docs/02-amneziawg.md) | Туннель, обфускация, почему не чистый WireGuard |
| 🧭 03 | [Podkop и маршрутизация](docs/03-podkop-routing.md) | HOME/TRAVEL, FakeIP, `russia_inside` vs `russia_outside` |
| 🚫 04 | [Блокировка рекламы](docs/04-adblock.md) | adblock-lean, Hagezi, интеграция с dnsmasq |
| 🔒 05 | [DNS](docs/05-dns.md) | Quad9 DoH, fallback, автофейловер |
| 📡 06 | [Wi-Fi](docs/06-wifi.md) | WPA3 SAE, PMF, country code, sae-mixed |
| 🎚 07 | [Слайдер и LED](docs/07-hardware.md) | gpio_button_hotplug, паттерны индикации |
| 🛡 08 | [Kill switch](docs/08-killswitch.md) | Defense-in-depth против утечек |
| 🔧 09 | [Диагностика](docs/09-troubleshooting.md) | «что-то не работает — куда смотреть» |

## Структура репозитория

```
cheburnet-router/
├── README.md                    ← вы здесь
├── CLAUDE.md                    ← контекст для AI-ассистентов
├── docs/                        ← 9 глав, ~1000 слов каждая
├── scripts/                     ← скрипты, которые ставятся на роутер
│   ├── vpn-mode                     CLI переключения HOME/TRAVEL
│   ├── vpn-led                      Управление индикатором
│   ├── dns-provider                 Свитч DNS-провайдера
│   ├── dns-healthcheck              Автофейловер DoH
│   ├── awg-watchdog                 Авто-рестарт AWG при протухшем handshake
│   ├── hotplug/button/10-vpn-mode   Хендлер слайдера
│   └── init.d/vpn-mode              Синхронизация режима при загрузке
├── configs/                     ← шаблоны UCI (без секретов)
├── setup/                       ← пошаговые install-скрипты
├── backup/                      ← снимок конфигурации / восстановление
└── LICENSE                      ← MIT
```

## Что НЕ решает этот проект

Честно о границах:

- ❌ **Не защищает от атакующего с физическим доступом** к роутеру. Если у вашего соседа есть 5 минут с роутером в руках — он может сбросить пароль через recovery mode.
- ❌ **Не скрывает факт использования VPN** на 100%. DPI может заподозрить AmneziaWG-трафик по таймингу пакетов и объёму даже при обфускации. Но распознать его как «конкретно AmneziaWG» — сложно.
- ❌ **Не решает проблему скомпрометированных клиентских устройств.** Если на ноутбуке есть malware, никакой роутер не поможет.
- ❌ **Не блокирует 100% рекламы.** Hagezi Pro — консервативный список; YouTube-реклама частично обходится (их инфраструктура хитрая). Для максимума используйте `hagezi:ultimate` (но готовьтесь к поломкам легитимных сервисов).
- ❌ **Не обеспечивает аутентификацию пользователей** (WPA2-PSK общий пароль, нет RADIUS). Для гостевой сети — см. [docs/06](docs/06-wifi.md).

## Благодарности и источники

- [AmneziaVPN](https://amnezia.org/) — протокол и инфраструктура
- [itdoginfo/podkop](https://github.com/itdoginfo/podkop) — policy routing с великолепным UX
- [itdoginfo/allow-domains](https://github.com/itdoginfo/allow-domains) — списки `russia_inside` / `russia_outside`
- [SagerNet/sing-box](https://github.com/SagerNet/sing-box) — универсальный прокси-роутер
- [Slava-Shchipunov/awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt) — kmod-amneziawg для OpenWrt
- [lynxthecat/adblock-lean](https://github.com/lynxthecat/adblock-lean) — блокировка рекламы
- [hagezi/dns-blocklists](https://github.com/hagezi/dns-blocklists) — блок-списки доменов

## Лицензия

[MIT](LICENSE). Форкайте, адаптируйте, шлите PR'ы.
