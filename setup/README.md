# Техническая документация setup/

> Эта папка — **внутренности установки**. Обычным пользователям сюда заходить не нужно:  
> для установки запускается `./setup.sh` из корня репозитория, всё остальное произойдёт автоматически.  
> Этот README для разработчиков, которые хотят понимать или портировать установку.

## Два режима

Репозиторий поддерживает два варианта обхода блокировок — оба настраиваются одним интерактивным мастером `setup.sh`:

| Режим | Entrypoint | Что ставит | Время |
|---|---|---|---|
| **VPN (AmneziaWG)** | `full-deploy.sh` | AmneziaWG + podkop/sing-box + adblock + DoH + kill-switch + watchdog + travel-tooling | ~12 мин |
| **zapret (DPI-обход без VPN)** | `full-deploy-zapret.sh` | zapret/nfqws + adblock + DoH (https-dns-proxy) | ~8 мин |

Пользователю выбор предлагается на первом экране `setup.sh`. Дальше мастер спрашивает настройки Wi-Fi и (для VPN) путь к `.conf`-файлу, запускает соответствующий `full-deploy-*.sh` и показывает финальный статус.

## Требования к роутеру

- **OpenWrt 25.12+** с пакетным менеджером `apk` (в 25.12+ это по умолчанию).
- **≥256 MB RAM**, **≥64 MB flash**. Тестовая платформа — Cudy TR3000 и GL.iNet Beryl AX (оба на MediaTek MT7981/Filogic, aarch64).
- **SSH-доступ** по паролю или ключу (мастер сам поставит ключ если его ещё нет).
- **Интернет на роутере** — для скачивания пакетов.
- **Для VPN-режима**: файл `.conf` от Amnezia (Premium или свой VPS с AmneziaWG).

## Точки входа

### VPN: `full-deploy.sh`

Выполняет следующие шаги по порядку (на роутере):

| Скрипт | Что делает | Время |
|---|---|---|
| `00-prerequisites.sh` | `apk update`, базовые тулзы (jq, curl, coreutils-sort) | ~1 мин |
| `01-amneziawg.sh` | kmod-amneziawg + tools + luci-proto, парсинг `.conf`, UCI-интерфейс `awg0` | ~2 мин |
| `02-podkop.sh` | podkop + sing-box, UCI для split-routing | ~3 мин |
| `03-adblock.sh` | adblock-lean + Hagezi Pro (~200k доменов) | ~2 мин |
| `04-dns.sh` | Quad9 DoH через sing-box + Cloudflare fallback + auto-failover | ~1 мин |
| `05-wifi.sh` | SSID + WPA2/WPA3-mixed + country code | ~1 мин |
| `06-vpn-mode.sh` | CLI `vpn-mode`, hotplug-обработчик кнопки, init.d-сервис | ~1 мин |
| `07-killswitch.sh` | fw4-правила DROP LAN→WAN (утечки при падении VPN) | ~30 сек |
| `08-watchdog.sh` | `awg-watchdog` + cron (перезапуск при протухшем handshake) | ~10 сек |
| `09-ssh-hardening.sh` | Отключение password-auth в dropbear, REJECT SSH с WAN | ~20 сек |
| `10-quality.sh` | Timezone MSK, persistent logs, SQM (установка), sysupgrade.conf | ~1 мин |
| `11-travel.sh` | travel-connect / travel-portal / travel-vpn-on | ~20 сек |
| `12-travel-plus.sh` | USB tethering (kmods) + travel-scan/wifi/mac/check | ~1 мин |

### zapret: `full-deploy-zapret.sh`

Выполняет только нужные для zapret-режима шаги:

| Скрипт | Что делает |
|---|---|
| `00-prerequisites.sh` | `apk update`, базовые тулзы |
| `03-adblock.sh` | adblock-lean + Hagezi Pro |
| `04-dns-zapret.sh` | **https-dns-proxy** (Quad9 primary + Cloudflare fallback), noresolv в dnsmasq |
| `05-wifi.sh` | Wi-Fi настройка |
| `09-ssh-hardening.sh` | Dropbear hardening |
| `13-zapret.sh` | nfqws + nftables правило на FORWARD + init.d автозапуск |

В zapret-режиме podkop/sing-box/AmneziaWG **не устанавливаются**. DoH обеспечивает лёгкий `https-dns-proxy`, который сам интегрируется с dnsmasq.

## Поштучный запуск (для отладки)

Если хочется понять, что делает каждый шаг — запускайте скрипты по одному:

```bash
export ROUTER=root@192.168.1.1

# Сначала подготовьте configs/wireless-actual.txt через ./setup.sh
# и (для VPN) положите .conf в configs/awg0.conf

# Для VPN:
scp configs/awg0.conf "$ROUTER":/etc/amnezia/amneziawg/awg0.conf
ssh "$ROUTER" 'mkdir -p /tmp/scripts /tmp/configs'
scp scripts/* "$ROUTER":/tmp/scripts/

ssh "$ROUTER" 'sh -s' < setup/00-prerequisites.sh
ssh "$ROUTER" 'sh -s' < setup/01-amneziawg.sh
# ... и т.д.
```

## Портирование на другое железо

### Что переносится без правок

- `scripts/*` — POSIX sh, работают на любом OpenWrt 23.05+ с busybox.
- UCI-конфигурация — формат стабилен между версиями.
- `07-killswitch.sh`, `05-wifi.sh`, `10-quality.sh` — не привязаны к железу.

### Что нужно адаптировать

1. **Архитектура CPU (для AmneziaWG).**  
   `setup/01-amneziawg.sh` и `setup/post-upgrade.sh` пинят `ARCH=aarch64_cortex-a53_mediatek_filogic`. Для другой платформы замените на соответствующую — полный список тегов в [awg-openwrt releases](https://github.com/Slava-Shchipunov/awg-openwrt/releases) (например, `x86_64`, `mipsel_24kc`, `aarch64_generic`).

2. **Архитектура CPU (для zapret).**  
   `setup/13-zapret.sh` определяет архитектуру через `uname -m` автоматически. Поддерживаются aarch64, mips, mipsel, x86_64. На экзотических платформах, где бинарника `nfqws` нет в zapret-релизах, скрипт упадёт с ошибкой.

3. **Версия OpenWrt.**  
   `BASE=.../v25.12.2` в `01-amneziawg.sh` и `post-upgrade.sh` — фиксированная ссылка на релиз awg-openwrt. При обновлении OpenWrt обновляйте и эту переменную.

4. **Подсеть LAN.**  
   `192.168.1.0/24` прошито в `02-podkop.sh` (`fully_routed_ips`) и `07-killswitch.sh` (`src_ip`). Если у вас другая подсеть — замените.

5. **Физическая кнопка переключения режимов.**  
   Работает на любом роутере, где OpenWrt настроил `gpio_button_hotplug` (Cudy TR3000, Beryl AX, большинство современных моделей). На роутерах без кнопки — переключайте режим через CLI: `vpn-mode home` / `vpn-mode travel`.

6. **OpenWrt 23.05/24.10 (с `opkg` вместо `apk`).**  
   Замените `apk add` на `opkg install` + обновите URL-ы для kmod (снапшоты openwrt.org).

## После установки — проверка

```bash
# Для VPN-режима:
ssh $ROUTER 'awg show awg0 | grep handshake; \
  podkop check_nft_rules; \
  /etc/init.d/adblock-lean status; \
  vpn-mode status; \
  dns-provider status'

# Для zapret-режима:
ssh $ROUTER '/etc/init.d/zapret status; \
  /etc/init.d/adblock-lean status; \
  /etc/init.d/https-dns-proxy status'
```

Ожидаемо: handshake свежий (для VPN), все сервисы running.

## Откат / переустановка

Чистый откат к ванильному OpenWrt — через `firstboot && reboot` на роутере. После этого:

```bash
# С вашего ноутбука:
./setup.sh
# Мастер пройдёт заново
```

Если хочется сохранить конфиги перед сбросом — делайте backup (в репозитории есть `backup/backup.sh`, если вы его подготовили).

## Post-upgrade после sysupgrade OpenWrt

Когда обновляетесь между версиями OpenWrt (например, 25.12.2 → 25.12.3):

```bash
ssh $ROUTER 'sh -s' < setup/post-upgrade.sh
```

Скрипт переустановит out-of-tree пакеты (AmneziaWG, podkop, adblock-lean, sqm-scripts, wpad-mbedtls), которые sysupgrade не сохраняет. UCI-конфигурация и кастомные скрипты при этом переживают апгрейд — за это отвечает `configs/sysupgrade.conf`, установленный через `10-quality.sh`.
