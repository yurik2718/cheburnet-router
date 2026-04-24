# AGENTS — контекст для AI-ассистентов и maintainer'ов

Этот файл — краткий ориентир для AI-моделей (Claude, GPT, Cursor, любые coding-agents), которые будут помогать дорабатывать конфигурацию в будущем. Также полезен людям-инженерам при возвращении к проекту после паузы. Обычным пользователям — читайте [README.md](./README.md).

Формат `AGENTS.md` — эмерджентная конвенция для AI-контекста в репозиториях, поддерживается Claude Code, OpenAI Codex и др.

## Что это за проект

Полная настройка роутера **GL.iNet Beryl AX (GL-MT3000)** или **Cudy TR3000** (и др. на MediaTek MT7981) на ванильной **OpenWrt 25.12.2** для приватной маршрутизации, обхода сетевых ограничений через VPN-обфускацию и полноценной домашней/travel-эксплуатации. Акценты:

- Надёжность (работает годами без обслуживания, в т.ч. у нетехнических пользователей)
- Приватность (минимум утечек, доверенные провайдеры, defence-in-depth)
- Кросс-платформенность (один репо → несколько моделей железа)

## Стек технологий

| Компонент | Роль | Ссылка на доку |
|---|---|---|
| **OpenWrt 25.12.2** | Базовая ОС, пакетный менеджер **apk** (не opkg) | https://openwrt.org/docs/ |
| **AmneziaWG 2.0** | VPN-туннель с обфускацией (форк WireGuard) | [docs/02-amneziawg.md](docs/02-amneziawg.md) |
| **Podkop 0.7.14** | Policy-based routing через sing-box | [docs/03-podkop-routing.md](docs/03-podkop-routing.md) |
| **sing-box 1.12.17** | TProxy + FakeIP + DNS-маршрутизация | (то же) |
| **adblock-lean 0.8.1** | Блокировка рекламы через dnsmasq (198k доменов, Hagezi Pro) | [docs/04-adblock.md](docs/04-adblock.md) |
| **dnsmasq + Quad9 DoH** | Локальный DNS с форвардом в зашифрованный upstream | [docs/05-dns.md](docs/05-dns.md) |
| **hostapd / wpad-mbedtls** | Wi-Fi AP, WPA2/WPA3-mixed (sae-mixed) | [docs/06-wifi.md](docs/06-wifi.md) |
| **nftables (fw4)** | Kill switch и общий firewall | [docs/08-killswitch.md](docs/08-killswitch.md) |
| **Управление режимами** | CLI `vpn-mode` (универсально для всех роутеров) | [docs/07-modes.md](docs/07-modes.md) |

## Ключевые файлы на роутере

```
/usr/bin/vpn-mode              # CLI переключения HOME/TRAVEL
/usr/bin/dns-provider          # Ручной свитч DNS (Quad9 <-> Cloudflare)
/usr/bin/dns-healthcheck       # Автофейловер DNS (крон каждые 30с)
/etc/hotplug.d/button/10-vpn-mode  # Хендлер слайдера
/etc/init.d/vpn-mode           # Сервис синхронизации при загрузке
/etc/amnezia/amneziawg/awg0.conf  # AWG конфиг (СЕКРЕТ, не коммитится)
/etc/config/podkop             # UCI podkop
/etc/config/wireless           # UCI Wi-Fi
/etc/config/firewall           # UCI firewall (с KillSwitch-правилами)
```

Исходники этих файлов — в папке [scripts/](scripts/).

## Как вносить изменения (workflow для ИИ)

1. **Читай по порядку**: `README.md` → `docs/01-architecture.md` → конкретную главу.
2. **Не ломай защитные слои.** Три независимых механизма защиты от утечек (см. `docs/08-killswitch.md`). Если кажется «вот этот слой лишний» — перечитай threat model.
3. **Podkop перегенерирует sing-box конфиг.** Не редактируй `/etc/sing-box/config.json` напрямую — изменения потеряются. Правь UCI podkop'а.
4. **UCI-опции подkop'а per-section.** Секции `main`, `exclude_ru` имеют **разный** `connection_type` (`vpn` vs `exclusion`). Правила роутинга подставляются в sing-box в определённом порядке (exclusion раньше main).
5. **Сохраняй стиль кода.** POSIX sh, busybox-совместимо (нет bash-ostrichisms), shellcheck-clean.
6. **Логируй через `logger -t`.** Пользователь смотрит `logread -t vpn-mode`, `logread -t dns-provider` и т.п.
7. **После правки скриптов** — обнови их копии в `scripts/` этого репо **и** файл на роутере. Держи синхронным.

## Важные инварианты (не нарушать)

- `route_allowed_ips=0` на AWG-пире → **intentional**. Routing делает podkop, не AWG-интерфейс сам.
- `fully_routed_ips=192.168.1.0/24` в секции `main` → source-based routing для всего LAN.
- `sae-mixed` требует `wpad-mbedtls`, а не `wpad-basic-mbedtls` (в ванильном OpenWrt basic).
- `community_lists='russia_outside'` в секции `exclude_ru` — **НЕ путать** с `russia_inside`. Названия контринтуитивные, см. docs/03.
- Physical slider: `gpio-512`, `EV_SW`, код `BTN_0`. Mapping: `pressed=LEFT=HOME`, `released=RIGHT=TRAVEL`. GPIO `hi=HOME`, `lo=TRAVEL` (после корректировки).

## Стиль документации

- **Русский** (это главное требование).
- Инженерная тональность: факты, чертежи, threat model. Без «волшебства» и инфантилизма.
- **Каждая глава**: «что», «зачем», «как работает», «какие альтернативы рассматривались», «что почитать дальше», «проверь себя» (Q&A).
- **Схемы** — mermaid (GitHub renders это нативно).
- **Эмодзи** — экономно, только как визуальные якоря для разделов (📘 📐 🔒 🧠 и т.п.), не в прозе.

## Контакты / источники

- Оригинальная сессия сборки: ChatGPT/Claude chat от апреля 2026
- Amnezia Premium (источник AWG-конфигов): https://amnezia.org/
- Podkop: https://github.com/itdoginfo/podkop
- OpenWrt: https://openwrt.org/

## История изменений

- **2026-04-17** — первая публикация, сборка на Beryl AX + OpenWrt 25.12.2 + AmneziaWG 2.0 + Podkop 0.7.14.
