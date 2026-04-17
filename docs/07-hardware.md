# 🎚 07. Слайдер и LED-индикация

## TL;DR

Beryl AX имеет физический слайдер на корпусе, подключенный к **GPIO-512** с меткой «mode». Тип события — **EV_SW** (switch, не кнопка), код **BTN_0**. Хендлер `/etc/hotplug.d/button/10-vpn-mode` ловит события `pressed` (слайдер влево) → HOME и `released` (слайдер вправо) → TRAVEL. LED `blue:run` на передней панели кодирует три состояния: SOLID = HOME + VPN OK, медленное мигание = TRAVEL + VPN OK, быстрое мигание = VPN down. При загрузке `/etc/init.d/vpn-mode` читает GPIO и применяет соответствующий режим.

## Железо Beryl AX с точки зрения Linux

GL-MT3000 с точки зрения ядра — это набор GPIO-линий, обрабатываемых модулем `gpio_button_hotplug`. Начиная смотреть на живое устройство:

```bash
cat /sys/kernel/debug/gpio
```

вывод:
```
gpiochip0: GPIOs 512-568, parent: platform/11d00000.pinctrl:
 gpio-512 (mode)                in  hi IRQ
 gpio-513 (reset)               in  hi IRQ ACTIVE LOW
 gpio-524 (regulator-usb-vbus)  out hi
 gpio-526 (reset)               out hi ACTIVE LOW
 gpio-540 (regulator-fan-5v)    out hi
 gpio-541 (interrupt)           in  hi IRQ
 gpio-542 (white:system)        out lo ACTIVE LOW
 gpio-543 (blue:run)            out hi ACTIVE LOW
```

Важные линии:
- **`gpio-512 mode`** — наш слайдер. Input, IRQ-driven.
- `gpio-513 reset` — кнопка reset (стандартная OpenWrt handling).
- **`gpio-542 white:system`** — LED system (боковой).
- **`gpio-543 blue:run`** — LED run (передняя панель, большой).

«ACTIVE LOW» — означает, что «логической 1» соответствует **низкий уровень** на GPIO-пине. Для LED это значит: `brightness=1` → пин спускается в low → ток течёт через LED → он светится. Для слайдера — противоположно.

## Слайдер: EV_SW vs кнопка

GPIO-512 может быть настроен как одно из двух:
- **EV_KEY** — кнопка: генерирует пары `pressed` + `released` при нажатии/отпускании. Короткий pulse.
- **EV_SW** — переключатель (switch, тумблер): генерирует **одиночное** событие при смене состояния. Стабильное.

В device tree Beryl AX: `gpio-keys/mode` с `linux,input-type = <0x05>` — это **EV_SW** (значение 5 = EV_SW по [include/uapi/linux/input-event-codes.h](https://github.com/torvalds/linux/blob/master/include/uapi/linux/input-event-codes.h)).

Код события — `linux,code = <0x100>` = **256**. Для EV_SW код 256 в OpenWrt-модуле `gpio_button_hotplug` маппится на имя `BTN_0` в переменной `$BUTTON`.

## Хендлер событий

OpenWrt имеет механизм [hotplug.d](https://openwrt.org/docs/guide-user/base-system/hotplug) — скрипты, которые автоматически вызываются при событиях ядра. Для кнопок/переключателей — каталог `/etc/hotplug.d/button/`.

Скрипт `/etc/hotplug.d/button/10-vpn-mode`:
```sh
#!/bin/sh
[ "$BUTTON" = "BTN_0" ] || exit 0
case "$ACTION" in
    pressed)  /usr/bin/vpn-mode home   ;;
    released) /usr/bin/vpn-mode travel ;;
esac
```

Переменные окружения, которые прокидывает ядро/хотплаг-демон:
- `$BUTTON` — имя кнопки (`BTN_0`, `reset`, `wps` и т.п.)
- `$ACTION` — `pressed`, `released`, или `held`
- `$SEEN` — сколько секунд прошло с последнего изменения (полезно для загрузочного события)

Для EV_SW: `pressed` и `released` соответствуют двум физическим положениям. Какое из них «влево», а какое «вправо» — определяется опытным путём при первой калибровке.

**Наша калибровка (Beryl AX GL-MT3000):**
| Физическое положение слайдера | `$ACTION` | GPIO-512 value | Режим |
|---|---|---|---|
| **LEFT** | `pressed` | `hi` (HIGH) | **HOME** |
| **RIGHT** | `released` | `lo` (LOW) | **TRAVEL** |

## CLI `vpn-mode`

Центральная утилита `/usr/bin/vpn-mode` — управляет переключением:

```bash
vpn-mode home        # применить HOME
vpn-mode travel      # применить TRAVEL
vpn-mode detect      # прочитать GPIO, применить соответствующий режим
vpn-mode toggle      # инвертировать текущий
vpn-mode status      # показать текущее состояние
```

Что делает `apply_home()`:
```sh
uci set podkop.exclude_ru=section
uci set podkop.exclude_ru.connection_type='exclusion'
uci set podkop.exclude_ru.user_domain_list_type='dynamic'
uci -q delete podkop.exclude_ru.community_lists
uci add_list podkop.exclude_ru.community_lists='russia_outside'
uci -q delete podkop.exclude_ru.user_domains
uci add_list podkop.exclude_ru.user_domains='.ru'
uci add_list podkop.exclude_ru.user_domains='.su'
uci add_list podkop.exclude_ru.user_domains='.xn--p1ai'
uci add_list podkop.exclude_ru.user_domains='vk.com'
uci commit podkop
echo home > /etc/vpn-mode.state
/usr/bin/vpn-led          # обновить индикацию
# reload_podkop (фоном)
```

Что делает `apply_travel()`:
```sh
uci -q delete podkop.exclude_ru.community_lists
uci -q delete podkop.exclude_ru.user_domains
uci -q delete podkop.exclude_ru.user_domain_list_type
uci commit podkop
echo travel > /etc/vpn-mode.state
/usr/bin/vpn-led
# reload_podkop
```

После любого apply — `/etc/init.d/podkop reload` перегенерирует sing-box конфиг и перезапускает sing-box. Это занимает ~2-3 секунды; в это время соединения LAN-клиентов прерываются (они переподключаются автоматически).

## Автосинхронизация при загрузке

При включении роутера, UCI-состояние podkop помнит «последний применённый режим». Но физический слайдер мог быть **переключён за время, пока роутер был выключен** — UCI об этом ничего не знает.

`/etc/init.d/vpn-mode` решает это:
```sh
#!/bin/sh /etc/rc.common
START=99                # запускается последним, после podkop
USE_PROCD=1

boot() { start; }

start_service() {
    # Подождать пока podkop поднимется, потом выровнять режим
    ( sleep 5; /usr/bin/vpn-mode detect; /usr/bin/vpn-led ) &
}
```

`vpn-mode detect` читает `/sys/kernel/debug/gpio` (парсит строку с `mode`), определяет `hi` или `lo`, вызывает `apply_home` или `apply_travel`. Если текущее состояние в `/etc/vpn-mode.state` уже совпадает — no-op (не триггерит лишний reload).

## LED-индикация

### Три состояния

LED `blue:run` на передней панели Beryl AX — единственный визуальный канал для пользователя.

| Паттерн | Режим | Что означает |
|---|---|---|
| 🔵 **SOLID** | HOME + VPN OK | Всё хорошо, повседневный режим |
| 🔵💨 **SLOW BLINK** (1 Гц) | TRAVEL + VPN OK | Полный туннель активен |
| 🔵⚡ **FAST BLINK** (5 Гц) | VPN DOWN | Требует внимания |

Паттерн **быстрого мигания** — это универсальный язык «что-то пошло не так» на сетевом оборудовании (Cisco, Mikrotik, большинство ISP-роутеров). Пользователю не нужно учиться — интуитивно понятно.

### Как это работает

Linux LED subsystem даёт два способа управления:
- **Direct brightness**: `echo 1 > /sys/class/leds/<name>/brightness` (solid on), `echo 0 > ...` (off)
- **Trigger**: `echo timer > /sys/class/leds/<name>/trigger` + `delay_on`/`delay_off` в миллисекундах

Наш скрипт `/usr/bin/vpn-led` в трёх ветках:
```sh
LED=/sys/class/leds/blue:run

set_solid() {
    echo none > "$LED/trigger"
    echo 1    > "$LED/brightness"
}

set_blink() {      # $1 = ms on, $2 = ms off
    echo timer > "$LED/trigger"
    echo "$1"  > "$LED/delay_on"
    echo "$2"  > "$LED/delay_off"
}

if ! awg_healthy; then
    set_blink 200 200       # fast
elif [ "$(mode)" = "travel" ]; then
    set_blink 1000 1000     # slow
else
    set_solid               # HOME
fi
```

### Когда обновляется

`vpn-led` вызывается в трёх случаях:

1. **При переключении режима** — из `apply_home()` / `apply_travel()`. Мгновенная реакция на слайдер.
2. **При загрузке** — из `/etc/init.d/vpn-mode` после `detect`.
3. **В cron каждые 30 секунд** (`* * * * *` + `* * * * * sleep 30 && ...`) — чтобы отслеживать изменение здоровья AWG и перестраивать LED.

### Как измеряется «здоровье AWG»

```sh
awg_healthy() {
    local hs
    hs=$(awg show awg0 latest-handshakes 2>/dev/null | awk '{print $2; exit}')
    [ -n "$hs" ] && [ "$hs" -gt 0 ] && [ $(( $(date +%s) - hs )) -lt 180 ]
}
```

`awg show awg0 latest-handshakes` возвращает UNIX-timestamp последнего handshake'а. Если:
- Значение есть (peer в принципе существует),
- Больше 0 (не «никогда»),
- Moloже 180 секунд (3 минуты с учётом что `PersistentKeepalive=25` даёт handshake ~каждые 25с, — 3 мин это 7+ пропусков, гарантированная проблема)

→ здоров. Иначе — fast blink.

## Почему так, а не иначе

### Почему один LED, а не два

Альтернатива: `blue:run` = mode indicator, `white:system` = VPN health. Два независимых канала.

Проблемы:
1. **Белый LED на Beryl AX плохо виден издалека** — сбоку, маленький. Пользователь привык смотреть на «главный» синий.
2. **Два мигающих LED** раздражают глаз больше, чем один.
3. **Сложнее объяснить родственникам:** «если синий светится ровно, но белый мигает — это X, а если ...» → комбинаторный взрыв.

Один LED с тремя паттернами — **проще для пользователя**, достаточно для диагностики.

### Почему SOLID для HOME

**Default happy state = solid light**. 99% времени у пользователей это главный режим. Ровно горит = норма, всё хорошо, игнорировать.

**Любое отклонение** (blink) = сигнал «что-то не как обычно». Пользователь не-айтишник сразу замечает разницу, даже не зная деталей.

### Почему fast-blink для алерта

Быстрое мигание «раздражает» глаз — это эволюционно закреплённое «attention!». Моргающий красный треугольник на приборной панели, моргающая лампочка духовки «пора доставать», моргающий индикатор низкой батареи. Универсальный язык.

Можно было бы: «если VPN упал, выключить LED совсем». Но это двусмысленно: «выключен LED = роутер выключен ИЛИ VPN упал ИЛИ свет перегорел». Мигание — однозначно «что-то сломалось, но роутер жив».

## Расширения

Хотя в базе используется только `blue:run`, есть идеи на будущее:

### WiFi-индикаторы

`mt76-phy0/1` — активность радио. Не трогаем (системное использование).

### USB-LED

Если подключён USB-накопитель — `blue:run` уже занят. Можно задействовать `white:system` как USB-indicator:
- `white:system` SOLID = USB подключён, готов
- SLOW BLINK = запись/бэкап в процессе

### Исходящий трафик

Можно через `trigger=netdev` показать активность awg0:
- Моргает при TX/RX через туннель
- Не моргает когда пусто

Убирает «статичность» LED, даёт живое ощущение «роутер работает».

## Диагностика

```bash
# Посмотреть текущее состояние LED
cat /sys/class/leds/blue:run/trigger
cat /sys/class/leds/blue:run/brightness
cat /sys/class/leds/blue:run/delay_on /sys/class/leds/blue:run/delay_off 2>/dev/null

# Вручную потестить паттерны
/usr/bin/vpn-led               # применить правильный по текущему state

# Принудительно solid
echo none > /sys/class/leds/blue:run/trigger
echo 1 > /sys/class/leds/blue:run/brightness

# Принудительно blink
echo timer > /sys/class/leds/blue:run/trigger
echo 500 > /sys/class/leds/blue:run/delay_on
echo 500 > /sys/class/leds/blue:run/delay_off

# Посмотреть что приходит от слайдера
# (нужно временно повесить debug-хендлер)
cat > /etc/hotplug.d/button/99-debug << 'EOF'
logger -t slider-debug "BUTTON=$BUTTON ACTION=$ACTION SEEN=$SEEN"
EOF
chmod +x /etc/hotplug.d/button/99-debug
# подвигать слайдер
logread -t slider-debug
# убрать после отладки:
rm /etc/hotplug.d/button/99-debug
```

## Проверь себя

1. **Почему при загрузке роутера 5 секунд задержка перед `vpn-mode detect`?**
   <details><summary>Ответ</summary>Podkop имеет START=99 (одинаковый с нашим vpn-mode). Если их запускать параллельно, vpn-mode может вызвать `podkop reload` до того, как подkop ещё не закончил начальный старт — race condition, странное состояние. 5 секунд — эмпирическая задержка, чтобы podkop гарантированно «устаканился». Cleaner-решение — зависимость в init.d, но START=99 sleep 5 работает проще.</details>

2. **Что будет, если физически убрать слайдер-механизм (заменить, сломать)?**
   <details><summary>Ответ</summary>GPIO-512 останется в каком-то положении (вероятно, «hi» по умолчанию). Система будет считать что всегда HOME. CLI `vpn-mode travel` всё равно работает вручную. Но физическое переключение станет невозможным. Можно заменить слайдер на подключение к другому источнику (например, внешняя кнопка через GPIO pin).</details>

3. **Почему cron каждые 30 секунд, а не 5 или 10?**
   <details><summary>Ответ</summary>30 секунд — компромисс. Реагировать на сбой VPN быстрее 30 сек излишне (handshake «протухает» только через 180 сек по нашим критериям). Реже чем раз в минуту — медленная диагностика (пользователь уже жалуется, LED ещё не моргает). 30 сек = разумная середина. Плюс `PersistentKeepalive=25` обеспечивает handshake чаще 30 сек в штатной работе — т.е. здоровый counter всегда фреш.</details>

## 📚 Глубже изучить

### Обязательно
- [OpenWrt: Hotplug subsystem](https://openwrt.org/docs/guide-user/base-system/hotplug) — как работают хендлеры
- [OpenWrt: LEDs configuration](https://openwrt.org/docs/guide-user/base-system/led_configuration) — про LED-subsystem
- [Linux input-event-codes.h](https://github.com/torvalds/linux/blob/master/include/uapi/linux/input-event-codes.h) — все коды кнопок/переключателей

### Желательно
- [GPIO interface in sysfs (deprecated, but still present)](https://docs.kernel.org/admin-guide/gpio/sysfs.html) — как работать с GPIO через sysfs
- [gpio_button_hotplug source (OpenWrt package)](https://github.com/openwrt/openwrt/blob/main/package/kernel/gpio-button-hotplug/src/gpio-button-hotplug.c) — код модуля
- [Device Tree Spec](https://www.devicetree.org/) — как описывается железо в современном Linux

### Для любопытных
- 📺 [LED indicators on network equipment: universal design](https://www.youtube.com/results?search_query=network+equipment+LED+design) — поиск по темам UI-дизайна
- [Nielsen Norman Group: Error message design](https://www.nngroup.com/articles/error-message-guidelines/) — как правильно сигнализировать о проблеме (принципы применимы и к железу)
