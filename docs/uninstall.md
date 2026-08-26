# Удаление cheburnet

Как убрать cheburnet с роутера — полностью или частично. Wi-Fi, пароль root и сам OpenWrt при
этом не страдают.

> **Порядок важен: сначала снять настройку, потом удалять пакет.** Правила nftables, policy
> routing, зону NAT, секции туннеля и привязки dnsmasq снимает сам движок. Если начать с `apk
> del`, движок исчезнет вместе с этой возможностью — роутер останется с маршрутами через
> несуществующий туннель, и чистить придётся руками.

Часто нужно не удаление, а **сброс настройки**: роутер возвращается к обычной маршрутизации, но
панель остаётся и настроить заново можно в два клика. Это шаг 1 ниже — на нём можно и
остановиться.

## 1. Снять конфигурацию

В панели `http://192.168.1.1/cheburnet/` → **«Опасная зона»** → **«Сбросить настройку
cheburnet»**. То же самое по SSH:

```sh
ucode -R /usr/share/cheburnet/engine/install/reset.uc
```

Роутер вернётся к обычной маршрутизации, сеть на несколько секунд перезапустится — это нормально,
`reset` делает именно `network restart` (после удаления интерфейса туннеля `reload` не возвращает
маршрут по умолчанию через WAN, и роутер остался бы без интернета).

Что именно снимается, а что остаётся — [Troubleshooting → Сброс
настройки](kb/reference/troubleshooting.md#сброс-настройки-что-снимается-а-что-остаётся).

## 2. Удалить пакет

```sh
apk del cheburnet
apk del sing-box-tiny    # только если ставились запасные туннели (VLESS+Reality / Hysteria2)
```

## 3. Зависимости — по желанию

Автоматически они не уйдут: часть ставил не apk (модуль ядра приезжает от
[awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt)). Безопасно удалить то, что нужно
только cheburnet:

```sh
apk del https-dns-proxy amneziawg-tools kmod-amneziawg
apk info | grep sing-box     # если ставился Full-тир — увидите sing-box-tiny или sing-box
apk del sing-box-tiny        # имя подставьте из вывода выше
```

> [!warning] Что удалять НЕ надо
> `dnsmasq-full`, `nftables`, `uhttpd`, `rpcd`, `ucode` и модули `ucode-mod-*` — это базовые
> компоненты OpenWrt и LuCI, cheburnet их только использует. Без `dnsmasq-full` роутер останется
> без DHCP и DNS, без `uhttpd`/`rpcd` — без веб-интерфейса. Места они занимают немного.
>
> `dnsmasq-full` — полная замена обычного `dnsmasq` (нужна ради nftset, см.
> [dnsmasq-nftset](kb/concepts/dnsmasq-nftset.md)); после удаления cheburnet он продолжает
> работать как штатный, менять его обратно не требуется.

## Проверить, что чисто

```sh
apk list --installed 2>/dev/null | grep '^cheburnet-'   # пусто = пакета нет
ls /etc/cheburnet                       # «No such file» = конфигурация снята
ls /etc/nftables.d/10-cheburnet.nft     # «No such file» = правила фаервола сняты
ip rule show                            # правил с fwmark от cheburnet быть не должно
nft list ruleset | grep -c cheburnet    # 0 (цепочки cheburnet_mark / cheburnet_ks)
grep -c cheburnet /etc/crontabs/root    # 0 = cron-запись сторожа снята
ls /etc/hotplug.d/iface/99-cheburnet    # «No such file» = хук восстановления снят
```

## Если пакет уже удалён, а настройка осталась

Симптомы: нет интернета, `ip route` показывает маршрут через отсутствующий `awg0`/`singtun0`.
Проще всего вернуть пакет, выполнить шаг 1 и удалить снова:

```sh
wget -O /tmp/cheburnet.sh https://raw.githubusercontent.com/andreiyurik/cheburnet-router/master/bootstrap/bootstrap.sh
sh /tmp/cheburnet.sh
ucode -R /usr/share/cheburnet/engine/install/reset.uc
apk del cheburnet
```

Совсем без сети на роутере остаётся ручной путь — снять секции туннеля в `/etc/config/network`,
секции `https-dns-proxy`, наши `ipset`-секции, `server 127.0.0.1#…`, `noresolv` и `strictorder` в
`/etc/config/dhcp`, `sing-box.main` в `/etc/config/sing-box` (если был), строку `watchdog/tick.uc`
из `/etc/crontabs/root`, файлы `/etc/nftables.d/10-cheburnet.nft` и
`/etc/hotplug.d/iface/99-cheburnet`, затем `/etc/init.d/network restart; fw4 reload`. Что именно принадлежит cheburnet — перечислено в
[Troubleshooting](kb/reference/troubleshooting.md#сброс-настройки-что-снимается-а-что-остаётся).

---

Не получается — [issue на GitHub](https://github.com/andreiyurik/cheburnet-router/issues/new/choose)
или [Telegram @industrialprofi](https://t.me/industrialprofi).
