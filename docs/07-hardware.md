# 🎚 07. Управление режимами и индикация

## TL;DR

**Универсально (работает везде):** CLI `/usr/bin/vpn-mode {home|travel|toggle|status|detect}` — переключение между режимами одной командой. Работает на любом OpenWrt-роутере.

**Бонусом на Beryl AX:** физический слайдер на корпусе (GPIO-512) автоматически вызывает `vpn-mode home/travel` при переключении. LED `blue:run` показывает состояние.

**На Cudy и других роутерах без слайдера:** CLI остаётся основным способом. Индикация через LED работает автоматически, если найден подходящий — `vpn-led` умеет находить LED самостоятельно.

## Часть 1. Универсальный способ — CLI (работает везде)

### `vpn-mode` — центральная команда

```bash
vpn-mode home        # включить HOME — split-routing (большинство через VPN, RU-сервисы direct)
vpn-mode travel      # включить TRAVEL — full tunnel (всё через VPN)
vpn-mode toggle      # переключить в противоположный
vpn-mode status      # показать текущий режим
vpn-mode detect      # прочитать слайдер/GPIO (если есть) и применить
```

Без физического слайдера можно закрепить желаемый режим навсегда, просто вызвав `vpn-mode home` или `vpn-mode travel` один раз. Настройки сохраняются в UCI и применяются при каждой загрузке.

### Что конкретно делает

`apply_home()` — редактирует секцию `podkop.exclude_ru` так, что в `sing-box` появляется дополнительное route-правило: `russia_outside` + `.ru/.su/.рф/vk.com` → direct-out. Всё остальное → main-out (AWG).

`apply_travel()` — удаляет списки из `podkop.exclude_ru`, делая её неактивной. Остаётся одно правило: **всё от LAN → main-out**. Никаких исключений.

После изменения конфигурации вызывается `podkop reload`, который перечитывает UCI и перегенерирует конфиг sing-box. Процесс занимает 2-3 секунды, трафик в этот момент кратковременно прерывается.

### Автоматическое применение при загрузке

Сервис `/etc/init.d/vpn-mode` запускается с приоритетом `START=99` (после podkop). После 5-секундной задержки вызывает `vpn-mode detect`:

- Если в системе есть GPIO-based слайдер (см. Часть 2) — читает его состояние и применяет соответствующий режим.
- Если слайдера нет — использует сохранённый в `/etc/vpn-mode.state` (последний явно применённый через CLI).

Это гарантирует корректное состояние после ребута независимо от того, трогал ли кто-то слайдер за время выключения.

## Часть 2. Бонус для Beryl AX — физический слайдер + LED

На корпусе GL.iNet Beryl AX есть двухпозиционный слайдер. GPIO-512 (`label=mode`), тип события — EV_SW (switch), код `BTN_0`.

### Как ядро видит слайдер

```bash
cat /sys/kernel/debug/gpio
```

вывод (сокращённо):
```
gpio-512 (mode)                in  hi IRQ
gpio-513 (reset)               in  hi IRQ ACTIVE LOW
gpio-542 (white:system)        out lo ACTIVE LOW
gpio-543 (blue:run)            out hi ACTIVE LOW
```

### Hotplug-хендлер

`/etc/hotplug.d/button/10-vpn-mode`:
```sh
#!/bin/sh
[ "$BUTTON" = "BTN_0" ] || exit 0
case "$ACTION" in
    pressed)  /usr/bin/vpn-mode home   ;;
    released) /usr/bin/vpn-mode travel ;;
esac
```

ACTION `pressed` / `released` соответствуют двум положениям слайдера. Конкретный маппинг (какая сторона — home) определён эмпирически при калибровке:

| Физически | ACTION | GPIO | Режим |
|---|---|---|---|
| LEFT | `pressed` | `hi` | HOME |
| RIGHT | `released` | `lo` | TRAVEL |

### LED-индикация

LED `blue:run` на передней панели, управляемый `/usr/bin/vpn-led`:

| Паттерн | Режим | Означает |
|---|---|---|
| 🔵 **SOLID** | HOME + VPN OK | Всё в норме |
| 🔵💨 **SLOW BLINK** (1 Гц) | TRAVEL + VPN OK | Full tunnel |
| 🔵⚡ **FAST BLINK** (5 Гц) | VPN DOWN | Требует внимания |

Скрипт вызывается:
1. **Напрямую** из `vpn-mode home/travel` — мгновенная реакция на переключение.
2. **Cron-ом** каждые 30 секунд — перечитывает свежесть handshake AWG и корректирует LED.
3. **Init.d** — при загрузке.

### Как определяется «здоровье VPN»

```sh
hs=$(awg show awg0 latest-handshakes | awk '{print $2; exit}')
# Если hs существует, > 0, и моложе 180 секунд — здоров
[ $(( $(date +%s) - hs )) -lt 180 ]
```

180 секунд = 3 минуты. При `PersistentKeepalive=25` в штатной работе handshake обновляется каждые 25 сек — 180 сек означает 7+ пропущенных обновлений, явный сбой.

## Часть 3. На Cudy TR3000 и других роутерах без физического слайдера

### Переключение режима

Слайдера нет — используйте CLI:

```bash
# Установить режим один раз, навсегда
vpn-mode home     # или travel

# Проверить
vpn-mode status
```

Перезагрузка роутера режим **сохранит** (он записан в `/etc/vpn-mode.state`). Hotplug-хендлер в этом случае не срабатывает (нет событий от слайдера) — это нормально.

Если нужно быстро переключать «дома ↔ в поездке», варианты:

**A) SSH-ярлык на ноутбук/телефон:**
```bash
alias vpn-home='ssh root@192.168.1.1 vpn-mode home'
alias vpn-travel='ssh root@192.168.1.1 vpn-mode travel'
```

**B) Веб-хук + bookmark в браузере** (чуть сложнее). Можно открыть порт на роутере, принимающий запросы на переключение; bookmark-кнопка в браузере делает GET. Реализацию оставляем как домашнее задание.

**C) Автоматическое переключение по Wi-Fi SSID клиента.** Например, ноутбук детектит, что он в незнакомой сети, и через SSH дёргает `vpn-mode travel`. Требует custom-скриптов на клиенте — не включено в этот репозиторий.

### LED-индикация

`/usr/bin/vpn-led` **автоматически** ищет подходящий LED из стандартных имён:
- `blue:run`, `blue:status`, `green:status`, `white:system`, `green:wlan`, `status`, `power`

На Cudy TR3000 это обычно `green:wlan` или `blue:status` — скрипт найдёт и будет моргать как на Beryl AX.

Посмотреть, какие LED доступны на вашем железе:
```bash
ls /sys/class/leds/
```

Если нужен конкретный LED, переопределите:
```bash
# В вашем crontab:
* * * * * LED_PATH=/sys/class/leds/my-led /usr/bin/vpn-led
```

Если ни одного пользовательского LED не найдено — скрипт **молча выходит**. Cron не спамит ошибками. Индикация просто отсутствует, но всё остальное работает.

### Как проверить, что всё работает

```bash
# Применили режим
vpn-mode travel
vpn-mode status
# >>> Saved state: travel ...

# Провоцируем LED-проверку (если LED есть)
/usr/bin/vpn-led
# Смотрим, моргает ли

# Определить текущий LED
for L in /sys/class/leds/*; do
    name=$(basename "$L")
    case "$name" in
        mt76-*|wwan|mmc|mtk*) continue ;;   # пропускаем системные
    esac
    echo "available: $name"
done
```

## Почему такая архитектура

### Почему CLI универсален, а слайдер — «бонус»

Philosophy: работоспособность **не должна** зависеть от физического железа, доступного только на одной модели. Слайдер добавляет UX на Beryl AX, но система работает и без него. Это позволяет одному репозиторию обслуживать десяток разных роутеров без форков.

### Почему один LED, а не два (как в Beryl AX)

На Beryl AX есть и `blue:run`, и `white:system`. Изначально рассматривался двухцветный сетап (blue=mode, white=health). Отвергнуто:
- На Cudy/WiFi-точках доступа обычно один пользовательский LED → сценарий «два LED» не переносится.
- Проще объяснить: «ровно горит = норма, мигает = смотри сюда».

### Почему не использовать несколько LED для большей ясности

Любое добавление — сложность. Один LED с тремя паттернами даёт достаточно информации для not-техников. Два LED → приходится объяснять кодирование состояний. Простота > Информативность для целевой аудитории.

## Проверь себя

1. **Я на Cudy TR3000, слайдера нет. Как мне переключаться между режимами в поездке?**
   <details><summary>Ответ</summary>
   CLI через SSH: `ssh root@192.168.1.1 vpn-mode travel`. Или делайте alias в shell-конфиге вашего ноутбука. Если переключать часто не надо — один раз `vpn-mode home` дома, `vpn-mode travel` перед поездкой.
   </details>

2. **У меня роутер вообще без слайдера и без яркого LED. Что я теряю?**
   <details><summary>Ответ</summary>
   Только UX-удобство. Вся функциональность (split-routing, AWG, DNS, adblock, killswitch, SSH hardening) работает независимо от физического железа. Вы управляете через CLI, проверяете состояние через `vpn-mode status`, `awg show awg0`, `logread`. Это стандартный Linux-way.
   </details>

3. **Как сделать чтобы при `vpn-mode detect` система правильно угадала режим на моей Cudy без GPIO?**
   <details><summary>Ответ</summary>
   На Cudy `vpn-mode detect` не найдёт GPIO `mode`, функция `gpio_state()` вернёт пусто, `detected_mode()` вернёт `unknown`, скрипт просто выйдет без изменений (оставит текущее сохранённое в `/etc/vpn-mode.state`). Это правильное поведение: **ничего не ломать, если нет информации**. Режим остаётся тем, который вы выставили через `vpn-mode home/travel` в последний раз.
   </details>

## 📚 Глубже изучить

- [OpenWrt: LEDs configuration](https://openwrt.org/docs/guide-user/base-system/led_configuration) — как устроен LED-subsystem
- [OpenWrt: Hotplug](https://openwrt.org/docs/guide-user/base-system/hotplug) — как ядро шлёт события скриптам
- [Linux GPIO sysfs interface](https://docs.kernel.org/admin-guide/gpio/sysfs.html) — работа с GPIO через файловую систему
- [Linux input-event-codes.h](https://github.com/torvalds/linux/blob/master/include/uapi/linux/input-event-codes.h) — список кодов кнопок и переключателей
