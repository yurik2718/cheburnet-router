# GL.iNet Beryl AX — физический переключатель и LED

Эта страница описывает **Beryl-AX-специфичное** железо и настройку. Если у вас **не** Beryl AX (например, Cudy TR3000 или другой роутер без физического слайдера) — читать необязательно. Управление режимами и индикация на вашем роутере описаны в [docs/07-modes.md](../07-modes.md).

## Содержание

1. [Физический слайдер и GPIO](#физический-слайдер-и-gpio)
2. [Hotplug-хендлер](#hotplug-хендлер)
3. [LED blue:run](#led-bluerun)
4. [Маппинг положений слайдера → режим](#маппинг-положений-слайдера--режим)
5. [Диагностика](#диагностика)

## Физический слайдер и GPIO

На корпусе GL.iNet Beryl AX (GL-MT3000) расположен **двухпозиционный слайдер**. Он подключён к GPIO-512 микроконтроллера MediaTek MT7981B, с меткой (label) `mode` в device tree. Тип входного события — `EV_SW` (switch, не кнопка): генерирует одиночное событие при смене положения, а не pair press/release.

Посмотреть состояние GPIO:

```bash
cat /sys/kernel/debug/gpio
```

Ожидаемый вывод (сокращённо):

```
gpiochip0: GPIOs 512-568, parent: platform/11d00000.pinctrl:
 gpio-512 (mode)                in  hi IRQ          ← слайдер
 gpio-513 (reset)               in  hi IRQ ACTIVE LOW
 gpio-542 (white:system)        out lo ACTIVE LOW   ← боковой белый LED
 gpio-543 (blue:run)            out hi ACTIVE LOW   ← главный синий LED
```

Device-tree информация:

```bash
cat /sys/firmware/devicetree/base/gpio-keys/mode/label
# mode

cat /sys/firmware/devicetree/base/gpio-keys/mode/linux,input-type | hexdump -C
# 00 00 00 05  ← EV_SW (5)

cat /sys/firmware/devicetree/base/gpio-keys/mode/linux,code | hexdump -C
# 00 00 01 00  ← 256 = BTN_0 в mapping'е OpenWrt
```

## Hotplug-хендлер

OpenWrt при смене состояния GPIO-кнопки/переключателя вызывает скрипты в `/etc/hotplug.d/button/`. Переменные окружения:

- `$BUTTON` — имя события (у нас `BTN_0`)
- `$ACTION` — `pressed` или `released` (для EV_SW — каждое положение)
- `$SEEN` — секунд прошло с предыдущего изменения

Наш хендлер `/etc/hotplug.d/button/10-vpn-mode`:

```sh
#!/bin/sh
[ "$BUTTON" = "BTN_0" ] || exit 0
case "$ACTION" in
    pressed)  /usr/bin/vpn-mode home   ;;
    released) /usr/bin/vpn-mode travel ;;
esac
```

Пять строчек. Ловим `BTN_0`, вызываем соответствующий режим. Всё.

## LED blue:run

Передний яркий синий LED на лицевой панели Beryl AX — это `blue:run`. Управляется через sysfs:

```bash
# Путь
ls /sys/class/leds/blue:run/
# brightness, trigger, delay_on, delay_off, max_brightness

# Включить ровное свечение
echo none > /sys/class/leds/blue:run/trigger
echo 1    > /sys/class/leds/blue:run/brightness

# Мигание 500/500 мс
echo timer > /sys/class/leds/blue:run/trigger
echo 500   > /sys/class/leds/blue:run/delay_on
echo 500   > /sys/class/leds/blue:run/delay_off

# Выключить
echo 0 > /sys/class/leds/blue:run/brightness
```

Скрипт `/usr/bin/vpn-led` (универсальный для любого OpenWrt-железа) **находит `blue:run` автоматически** как первый кандидат в своём списке — на Beryl AX работает из коробки.

### Паттерны индикации

| Что видно | Режим | Что означает |
|---|---|---|
| 🔵 **SOLID** (ровно горит) | HOME + VPN OK | Норма |
| 🔵💨 **SLOW BLINK** (1 Гц) | TRAVEL + VPN OK | Full tunnel |
| 🔵⚡ **FAST BLINK** (5 Гц) | VPN DOWN | Требует внимания |

Быстрое мигание — универсальный сигнал «что-то не так» на сетевом оборудовании. Обучать пользователей не нужно.

### Дополнительный LED `white:system`

На боковой грани Beryl AX также расположен белый `white:system`. В нашей сборке **не используется** — оставлен для дефолтного OpenWrt-поведения (индикатор активности системы). Если хочется задействовать — можно сделать, например, индикатором здоровья AWG (solid=up, blink=down) параллельно с blue:run (показывающим режим).

## Маппинг положений слайдера → режим

Калибровка проводилась эмпирически при установке:

| Физическое положение | `$ACTION` | GPIO-512 value | Режим |
|---|---|---|---|
| **LEFT** | `pressed` | `hi` (HIGH) | **HOME** |
| **RIGHT** | `released` | `lo` (LOW) | **TRAVEL** |

Этот маппинг зашит в `/usr/bin/vpn-mode` в функции `detected_mode()`:
```sh
detected_mode() {
    case "$(gpio_state)" in
        lo) echo travel ;;
        hi) echo home ;;
        *)  echo unknown ;;
    esac
}
```

На других аппаратных ревизиях Beryl AX (теоретически возможны) маппинг мог бы отличаться. Проверяется одной командой:
```bash
cat /sys/kernel/debug/gpio | grep mode
# gpio-512 (mode)  in  hi   ← слайдер сейчас в HIGH
```

Переключите слайдер и повторите — значение должно смениться на `lo`.

## Диагностика

### Установить debug-хендлер (временно)

```bash
cat > /etc/hotplug.d/button/99-debug << 'EOF'
#!/bin/sh
logger -t slider-debug "BUTTON=$BUTTON ACTION=$ACTION SEEN=$SEEN"
EOF
chmod +x /etc/hotplug.d/button/99-debug

# Подвиньте слайдер несколько раз
logread -t slider-debug
# slider-debug: BUTTON=BTN_0 ACTION=pressed SEEN=3
# slider-debug: BUTTON=BTN_0 ACTION=released SEEN=2

# После отладки удалить
rm /etc/hotplug.d/button/99-debug
```

### Ручной тест LED

```bash
# Все три паттерна по очереди, по 3 секунды каждый
echo "=== SOLID ===";     echo none > /sys/class/leds/blue:run/trigger; echo 1 > /sys/class/leds/blue:run/brightness; sleep 3
echo "=== SLOW BLINK ==="; echo timer > /sys/class/leds/blue:run/trigger; echo 1000 > /sys/class/leds/blue:run/delay_on; echo 1000 > /sys/class/leds/blue:run/delay_off; sleep 3
echo "=== FAST BLINK ==="; echo 200 > /sys/class/leds/blue:run/delay_on; echo 200 > /sys/class/leds/blue:run/delay_off; sleep 3
# Восстановить
/usr/bin/vpn-led
```

### Проверить что init.d синхронизация работает

```bash
/etc/init.d/vpn-mode enabled && echo "auto-start at boot: yes"
cat /etc/vpn-mode.state
# home  ← текущее сохранённое состояние

# Принудительно пересинхронизировать с физическим слайдером
/usr/bin/vpn-mode detect
```

## Почему именно такая реализация

### Почему EV_SW (switch), а не EV_KEY (button)

Для трёх-позиционного переключателя (как у микроволновки) оптимален EV_SW: одно событие = одно стабильное положение. Если бы использовался EV_KEY, мы получили бы сложное поведение с парными pressed/released на каждую позицию, что хуже отлаживается.

### Почему slider = bonus, а не обязательное

Чтобы одна и та же сборка работала и на Beryl AX, и на Cudy TR3000, и на любом другом OpenWrt-роутере. Физический переключатель — это про UX, не про функциональность. CLI `vpn-mode home/travel` делает то же самое, работает везде.

### Почему LED blue:run, а не white:system

`blue:run` виден с большего расстояния, расположен на лицевой панели, пользователь смотрит на него интуитивно. `white:system` — сбоку, менее заметен. Для «единственного пользовательского индикатора» выбор очевиден.

## Дополнительно

- **Автообнаружение LED** в `vpn-led` означает, что на других роутерах скрипт найдёт свой LED без изменений (blue:status у Cudy, green:status у TP-Link, etc.).
- **Hotplug-хендлер `10-vpn-mode`** установлен всегда — на роутерах без `BTN_0` он просто никогда не сработает (первая же строчка `[ "$BUTTON" = "BTN_0" ] || exit 0` останавливает).
- **Init.d `vpn-mode`** — `detect` на роутерах без GPIO `mode` возвращает `unknown`, сервис тихо завершается, сохранённое через CLI состояние остаётся активным.

Архитектура специально сделана **универсальной**: везде где возможно — автоматическое поведение, нигде нет «fail если нет такого-то LED / GPIO».
