# Техническая документация setup/

> Эта папка — **внутренности установки**. Обычным пользователям сюда заходить не нужно:
> для установки запускается `./setup.sh` из корня репозитория, всё остальное произойдёт автоматически.
> Этот README для разработчиков, которые хотят понимать или портировать установку.

## Что устанавливается

`setup.sh` проводит пользователя через 4 шага (адрес роутера → .conf → Wi-Fi → подтверждение) и затем запускает `full-deploy.sh`, который ставит на роутер AmneziaWG-стек.

| Entrypoint | Что ставит | Время |
|---|---|---|
| `full-deploy.sh` | AmneziaWG + podkop/sing-box + adblock + DoH + kill-switch + watchdog + travel-tooling | ~12 мин |

## Требования к роутеру

- **OpenWrt 25.12+** с пакетным менеджером `apk` (в 25.12+ это по умолчанию).
- **≥256 MB RAM**, **≥64 MB flash**. Тестовая платформа — Cudy TR3000 и GL.iNet Beryl AX (оба на MediaTek MT7981/Filogic, aarch64).
- **SSH-доступ** по паролю или ключу (мастер сам поставит ключ если его ещё нет).
- **Интернет на роутере** — для скачивания пакетов.
- Файл `.conf` от AmneziaWG (Amnezia Premium или свой VPS с AmneziaWG).

## Шаги установки

`full-deploy.sh` выполняет следующие скрипты по порядку (на роутере):

| Скрипт | Что делает | Время |
|---|---|---|
| `00-prerequisites.sh` | `apk update`, базовые тулзы (jq, curl, coreutils-sort) | ~1 мин |
| `01-amneziawg.sh` | kmod-amneziawg + tools + luci-proto, парсинг `.conf`, UCI-интерфейс `awg0` | ~2 мин |
| `02-podkop.sh` | podkop + sing-box, UCI для split-routing | ~3 мин |
| `03-adblock.sh` | adblock-lean + Hagezi Pro (~200k доменов) | ~2 мин |
| `04-dns.sh` | Quad9 DoH через sing-box | ~1 мин |
| `05-wifi.sh` | SSID + WPA2/WPA3-mixed + country code | ~1 мин |
| `06-vpn-mode.sh` | CLI `vpn-mode`, hotplug-обработчик кнопки, init.d-сервис | ~1 мин |
| `07-killswitch.sh` | fw4-правила DROP LAN→WAN (утечки при падении VPN) | ~30 сек |
| `08-watchdog.sh` | `awg-watchdog` + cron (перезапуск при протухшем handshake) | ~10 сек |
| `09-ssh-hardening.sh` | Отключение password-auth в dropbear, REJECT SSH с WAN | ~20 сек |
| `10-quality.sh` | Timezone MSK, persistent logs, SQM (установка), sysupgrade.conf | ~1 мин |
| `11-travel.sh` | travel-connect / travel-portal / travel-vpn-on | ~20 сек |
| `12-travel-plus.sh` | USB tethering (kmods) + travel-scan/wifi/mac/check | ~1 мин |

## Поштучный запуск (для отладки)

Если хочется понять, что делает каждый шаг — запускайте скрипты по одному:

```bash
export ROUTER=root@192.168.1.1

# Сначала подготовьте configs/wireless-actual.txt через ./setup.sh
# и положите .conf в configs/awg0.conf

scp configs/awg0.conf "$ROUTER":/etc/amnezia/amneziawg/awg0.conf
ssh "$ROUTER" 'mkdir -p /tmp/scripts /tmp/configs'
scp scripts/* "$ROUTER":/tmp/scripts/

ssh "$ROUTER" 'sh -s' < setup/00-prerequisites.sh
ssh "$ROUTER" 'sh -s' < setup/01-amneziawg.sh
# ... и т.д.
```

## Портирование на другое железо

### Что определяется автоматически

| Параметр | Источник | Файл |
|---|---|---|
| Архитектура пакетов awg-openwrt | `${DISTRIB_ARCH}_${DISTRIB_TARGET}` из `/etc/openwrt_release` | `01-amneziawg.sh`, `post-upgrade.sh` |
| Версия awg-openwrt | `v$DISTRIB_RELEASE` с fallback на последнюю стабильную (v25.12.2) | то же |
| LAN-подсеть | `network_get_subnet lan` через `/lib/functions/network.sh`, fallback на `ipcalc.sh` | `02-podkop.sh`, `07-killswitch.sh` |
| Архитектура nfqws-бинарника | `uname -m` | (zapret удалён, неактуально) |

Поэтому переустановка на любой OpenWrt 25.12+ с поддерживаемой awg-openwrt архитектурой проходит без правок.

### Что переносится без правок

- `scripts/*` — POSIX sh, работают на любом OpenWrt 23.05+ с busybox.
- UCI-конфигурация — формат стабилен между версиями.
- `07-killswitch.sh`, `05-wifi.sh`, `10-quality.sh` — не привязаны к железу.

### Что может потребовать ручной адаптации

1. **Архитектура без релиза в awg-openwrt.**
   Если для вашей архитектуры нет готового релиза в [awg-openwrt releases](https://github.com/Slava-Shchipunov/awg-openwrt/releases) — `01-amneziawg.sh` упадёт с понятной ошибкой. Решение — собрать `kmod-amneziawg` вручную по инструкции из репозитория awg-openwrt.

2. **Физическая кнопка переключения режимов.**
   Работает на любом роутере, где OpenWrt настроил `gpio_button_hotplug` (Cudy TR3000, Beryl AX, большинство современных моделей). На роутерах без кнопки — переключайте режим через CLI: `vpn-mode home` / `vpn-mode travel`.

3. **OpenWrt 23.05/24.10 (с `opkg` вместо `apk`).**
   Замените `apk add` на `opkg install` + обновите URL-ы для kmod (снапшоты openwrt.org). Тестировано на OpenWrt 25.12+.

## После установки — проверка

```bash
ssh $ROUTER 'awg show awg0 | grep handshake; \
  podkop check_nft_rules; \
  /etc/init.d/adblock-lean status; \
  vpn-mode status; \
  dns-provider status'
```

Ожидаемо: handshake свежий, все сервисы running.

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
