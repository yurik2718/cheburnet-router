# 🧭 07. Управление режимами (HOME / TRAVEL)

## TL;DR

Два режима: **HOME** (split-routing — основной трафик через VPN, RU-сервисы напрямую) и **TRAVEL** (full-tunnel — всё через VPN без исключений). Переключение через CLI: `vpn-mode home/travel/toggle/status`. Настройки сохраняются в UCI и в `/etc/vpn-mode.state`, применяются при каждой загрузке автоматически.

На роутерах Cudy переключение выполняется через CLI: `vpn-mode home` / `vpn-mode travel`.

## Два режима — что они делают

### HOME (основной)

Трафик разделяется:
- **Через VPN (AWG → Switzerland):** всё по умолчанию — google.com, github.com, youtube.com, etc.
- **Напрямую (WAN):** домены в `russia_outside` community-list, `.ru/.su/.рф` TLD, `vk.com`. Эти сервисы лучше работают с реального IP.

Подходит для **повседневного использования**: быстрый доступ к .ru-сайтам без VPN-оверхеда, всё остальное — защищённо через туннель.

### TRAVEL (full tunnel)

**Абсолютно весь** трафик LAN-клиентов идёт через AWG → Switzerland. Никаких исключений.

Подходит для:
- **Поездок в недоверенные сети** (отельный/кафешный Wi-Fi, аэропорт, коворкинг)
- **Максимальной приватности** когда неважны скорости .ru-ресурсов
- **Отладки** (упростить routing для диагностики)

### Техническая разница

Режимы отличаются содержимым UCI-секции `podkop.exclude_ru`:

| Параметр | HOME | TRAVEL |
|---|---|---|
| `connection_type` | `exclusion` | `exclusion` |
| `community_lists` | `russia_outside` | *(пусто)* |
| `user_domains` | `.ru .su .xn--p1ai vk.com` | *(пусто)* |

В TRAVEL списки просто пустые — podkop видит «секция без активных списков» и пропускает её. В sing-box'е остаётся **одно** route-правило: `source_ip_cidr=192.168.1.0/24 → main-out (awg0)`.

## Команда `vpn-mode`

```bash
vpn-mode home        # включить HOME
vpn-mode travel      # включить TRAVEL
vpn-mode toggle      # переключить в противоположный
vpn-mode status      # показать текущее состояние
vpn-mode detect      # прочитать GPIO (если есть) и применить
```

### Пример использования

Домашний сценарий (one-time):
```bash
ssh root@192.168.1.1 vpn-mode home
```
Роутер помнит этот режим навсегда, в том числе после перезагрузки.

Перед поездкой:
```bash
ssh root@192.168.1.1 vpn-mode travel
```

На ноутбуке удобно сделать aliases:
```bash
# в ~/.bashrc или ~/.zshrc
alias vpn-home='ssh root@192.168.1.1 vpn-mode home'
alias vpn-travel='ssh root@192.168.1.1 vpn-mode travel'
alias vpn-status='ssh root@192.168.1.1 vpn-mode status'
```

### Что делает под капотом

`apply_home()` — UCI-манипуляция:
```sh
uci set podkop.exclude_ru.connection_type='exclusion'
uci add_list podkop.exclude_ru.community_lists='russia_outside'
uci add_list podkop.exclude_ru.user_domains='.ru'
uci add_list podkop.exclude_ru.user_domains='.su'
uci add_list podkop.exclude_ru.user_domains='.xn--p1ai'
uci add_list podkop.exclude_ru.user_domains='vk.com'
uci commit podkop
echo home > /etc/vpn-mode.state
/etc/init.d/podkop reload
```

`apply_travel()` — удаляет списки, делая секцию неактивной:
```sh
uci -q delete podkop.exclude_ru.community_lists
uci -q delete podkop.exclude_ru.user_domains
uci commit podkop
echo travel > /etc/vpn-mode.state
/etc/init.d/podkop reload
```

Плюс в обоих случаях — вызов `vpn-led` для обновления индикации (если LED доступен).

## Автоматическое применение при загрузке

`/etc/init.d/vpn-mode` стартует с приоритетом `START=99` (после podkop), ждёт 5 секунд (чтобы podkop поднялся), и делает `vpn-mode detect`:

- На роутерах с **физическим переключателем** (например, Beryl AX) — читает GPIO и применяет соответствующий режим.
- На остальных — `detect` возвращает `unknown`, сохранённое в `/etc/vpn-mode.state` состояние остаётся активным (то, которое последним было применено через CLI).

Это гарантирует корректное состояние после каждой загрузки.

## Переключение по домашней автоматизации

Для продвинутых сценариев — автоматическое переключение на TRAVEL когда ноутбук покидает домашнюю сеть:

**На macOS / Linux ноутбук** — hook на смену Wi-Fi SSID:
```bash
# Пример: в /etc/NetworkManager/dispatcher.d/90-vpn-mode
#!/bin/sh
if [ "$CONNECTION_ID" = "HomeNetwork" ]; then
    ssh -o BatchMode=yes root@192.168.1.1 vpn-mode home
else
    ssh -o BatchMode=yes root@192.168.1.1 vpn-mode travel
fi
```

**Готовые интеграции:** Home Assistant с SSH-shell-команду, Tailscale-based triggers, etc. В этом репозитории не реализованы, но несложно добавить для своих нужд.

## Индикация состояния

Скрипт `/usr/bin/vpn-led` умеет управлять LED, если в системе есть подходящий индикатор:

| Паттерн | Режим | Смысл |
|---|---|---|
| 🟢 SOLID | HOME + VPN OK | Всё хорошо |
| 🟢💨 Медленное мигание (1 Гц) | TRAVEL + VPN OK | Full tunnel |
| 🟢⚡ Быстрое мигание (5 Гц) | VPN DOWN | Нужно внимание |

Скрипт автоматически находит LED из стандартного списка (`blue:run`, `green:wlan`, `status`, `power`, etc.). Если ни одного подходящего LED не найдено — скрипт тихо выходит, никаких ошибок.

Для **явного переопределения** (ваш LED с нестандартным именем):
```bash
# В crontab:
* * * * * LED_PATH=/sys/class/leds/my-custom-led /usr/bin/vpn-led
```

Посмотреть доступные LED:
```bash
ls /sys/class/leds/
```

Запускается cron'ом **каждые 30 секунд** + при каждом `vpn-mode apply_*`. Мониторит свежесть AWG handshake (>3 минут без handshake → fast blink).

## Проверь себя

1. **У меня нет физического переключателя. Потеряю ли я функциональность?**
   <details><summary>Ответ</summary>
   Нет, только UX-удобство. Всё работает через CLI `vpn-mode home/travel`. Режим сохраняется между перезагрузками в `/etc/vpn-mode.state`. Это нормальный Linux-way.
   </details>

2. **Как узнать, есть ли у моего роутера подходящий LED для `vpn-led`?**
   <details><summary>Ответ</summary>
   `ls /sys/class/leds/` покажет все. Скрипт `vpn-led` пробует (в порядке): `blue:run`, `blue:status`, `green:status`, `white:system`, `green:wlan`, `status`, `power`. Если ни одного — exit 0 без ошибок, просто индикации не будет. Остальная функциональность работает.
   </details>

3. **Можно ли добавить третий режим (например, «VPN выключен»)?**
   <details><summary>Ответ</summary>
   Технически да — добавить в `vpn-mode` ещё одну функцию `apply_off()`, которая удаляет `fully_routed_ips` из секции `main`. Но это меняет смысл архитектуры: вы получаете роутер без VPN, что противоречит цели проекта (если VPN не нужен — проще отдельный роутер). Рекомендую не добавлять.
   </details>

## 📚 Глубже изучить

- [docs/03-podkop-routing.md](03-podkop-routing.md) — как устроен split-routing на уровне sing-box
- [OpenWrt: hotplug](https://openwrt.org/docs/guide-user/base-system/hotplug) — как работают системные события для кнопок и интерфейсов
