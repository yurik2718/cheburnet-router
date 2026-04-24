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

## Автоматическое применение при загрузке

`/etc/init.d/vpn-mode` стартует с приоритетом `START=99` (после podkop), ждёт 5 секунд и вызывает `vpn-mode detect`:

- **Beryl AX** — читает GPIO-слайдер и применяет соответствующий режим.
- **Cudy TR3000 и другие** — `detect` возвращает `unknown`, используется последний сохранённый режим из `/etc/vpn-mode.state`.

Это гарантирует корректное состояние после каждой перезагрузки.

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

## Проверь себя

1. **У меня нет физической кнопки или слайдера. Потеряю ли я функциональность?**
   <details><summary>Ответ</summary>
   Нет. Всё работает через CLI: `vpn-mode home/travel/status`. Режим сохраняется в `/etc/vpn-mode.state` и восстанавливается при каждой загрузке. Физическая кнопка — удобство, не требование.
   </details>

2. **Можно ли добавить третий режим (например, «VPN выключен»)?**
   <details><summary>Ответ</summary>
   Технически да — добавить в `vpn-mode` ещё одну функцию `apply_off()`, которая удаляет `fully_routed_ips` из секции `main`. Но это меняет смысл архитектуры: вы получаете роутер без VPN, что противоречит цели проекта (если VPN не нужен — проще отдельный роутер). Рекомендую не добавлять.
   </details>

## 📚 Глубже изучить

- [docs/03-podkop-routing.md](03-podkop-routing.md) — как устроен split-routing на уровне sing-box
- [OpenWrt: hotplug](https://openwrt.org/docs/guide-user/base-system/hotplug) — как работают системные события для кнопок и интерфейсов
