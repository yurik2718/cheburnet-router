# Развёртывание на чистом OpenWrt

## Требования

- **OpenWrt 25.12.x** (свежая установка, ванильная). На GL.iNet-прошивке **не работает** — перепрошейте на OpenWrt сначала.
- **Роутер с ≥256 MB RAM и ≥128 MB flash.** Тестовая платформа: GL.iNet Beryl AX (GL-MT3000), 512/256.
- **apk package manager** (в 25.12+ по умолчанию).
- **SSH-доступ** на роутер (ключ или пароль).
- **Ваш AmneziaWG .conf-файл** от Amnezia (Premium или свой self-hosted).
- **Интернет** на роутере (для скачивания пакетов).

## Порядок

```
scripts                  Что делает                               Время
────────────────────────────────────────────────────────────────────────
00-prerequisites.sh      apk update, базовые инструменты           ~1 мин
01-amneziawg.sh          ядерный модуль + tools + UCI awg0         ~2 мин
02-podkop.sh             podkop + sing-box (itdoginfo installer)   ~3 мин
03-adblock.sh            adblock-lean + Hagezi Pro                 ~2 мин
04-dns.sh                Quad9 DoH + Cloudflare fallback           ~1 мин
05-wifi.sh               SSID + WPA2/WPA3 + country code           ~1 мин
06-slider-led.sh         vpn-mode CLI, vpn-led, init.d, cron        ~1 мин
07-killswitch.sh         fw4-правила для защиты от утечек          30 сек
```

Всего ~10-12 минут. Запуск по очереди или одной командой через `full-deploy.sh`.

## Быстрый путь

С вашего ноутбука:

```bash
# 1. Положите ваш .conf-файл
cp /path/to/your-awg.conf configs/awg0.conf

# 2. Настройте Wi-Fi
cp configs/wireless.uci.example.txt configs/wireless-actual.txt
# Отредактируйте SSID, пароль, country code:
vim configs/wireless-actual.txt

# 3. Запустите полное развёртывание
./setup/full-deploy.sh root@192.168.1.1
```

Скрипт:
- Передаст необходимые файлы через scp
- Выполнит все 8 шагов по порядку
- Выведет финальный статус

## Поштучно (если хотите понимать происходящее)

```bash
export ROUTER=root@192.168.1.1

# Каждый шаг — отдельным SSH-сеансом
ssh $ROUTER "$(cat setup/00-prerequisites.sh)"
ssh $ROUTER "$(cat setup/01-amneziawg.sh)"
# Перед 01 нужно загрузить awg0.conf:
scp configs/awg0.conf $ROUTER:/etc/amnezia/amneziawg/
ssh $ROUTER "$(cat setup/01-amneziawg.sh)"

# ... и так далее
```

## Портирование на другой роутер

### Что точно портируется:

- `scripts/*` — POSIX sh, работают на любом OpenWrt 23.05+ с busybox
- `setup/*.sh` — зависят от `apk` (OpenWrt 25.12+) или `opkg` (23.05-24.10). Шаблоны в ваших скриптах поправить соответственно.
- Все настройки UCI

### Что может потребовать адаптации:

1. **Архитектура CPU.** AWG-пакеты собраны для `aarch64_cortex-a53_mediatek_filogic`. Для других — смените в `01-amneziawg.sh` (например, `x86_64` или `mipsel_24kc`). Полный список — [release-страница awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt/releases).

2. **Версия OpenWrt.** В ссылках на пакеты прописана `v25.12.2`. Если у вас `v23.05.5` — пакет будет назваться `v23.05.5_...apk`.

3. **Железо LED/GPIO.** На других роутерах имена LED отличаются:
   - TP-Link Archer — `green:status`, `red:wan`
   - Xiaomi AX3600 — `yellow:status`, `blue:status`
   - Поправьте пути в `scripts/vpn-led`: `LED=/sys/class/leds/YOUR_LED_NAME`

4. **GPIO-кнопка.** Если в вашем роутере нет физического слайдера (большинство случаев), секцию слайдера пропустите. Переключение через CLI `vpn-mode home/travel`. LED-индикация всё равно работает.

5. **Подсеть LAN.** Если у вас LAN не `192.168.1.0/24`, в `vpn-mode` и killswitch-rules нужно заменить.

6. **Firmware без `apk`.** На OpenWrt 23.05/24.10 — `opkg install` вместо `apk add`, и другие URL для kmod (openwrt.org снапшоты).

## После установки

Проверить финальный статус:

```bash
ssh $ROUTER 'awg show awg0 | grep handshake; \
  podkop check_nft_rules; \
  /etc/init.d/adblock-lean status; \
  vpn-mode status; \
  dns-provider status'
```

Ожидаемый вывод: handshake свежий, все подkop-флаги = 1, adblock running, режим = home/travel, DNS = Quad9.

## Uninstall / откат

```bash
ssh $ROUTER 'bash -s' < setup/uninstall.sh
# Предупреждение: полностью сбросит настройки в ванильный OpenWrt
```

Альтернатива — `firstboot && reboot` на роутере (прямо откат к factory).
