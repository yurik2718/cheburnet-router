# 📋 Справочник команд — шпаргалка на одной странице

Все CLI-команды в одном месте. Для деталей — ссылки на соответствующие главы.

**Все команды запускаются с вашего ноутбука через SSH:**
```bash
ssh root@192.168.1.1 <команда>
```

Или сначала залогиньтесь, потом команды без `ssh`:
```bash
ssh root@192.168.1.1
# теперь вы на роутере
vpn-mode status
```

---

## 🎯 Самое частое

```bash
# Статус VPN + DNS + режим
vpn-mode status
dns-provider status
awg show awg0 | grep handshake

# Полная диагностика одной командой
travel-check

# Нашли проблему — универсальный перезапуск
/etc/init.d/podkop restart
```

---

## 🧭 Переключение режимов HOME / TRAVEL

См. [docs/07-modes.md](07-modes.md)

```bash
vpn-mode home          # HOME: split-routing (VPN для всего кроме .ru/vk/etc)
vpn-mode travel        # TRAVEL: full tunnel, всё через VPN
vpn-mode toggle        # Переключить на противоположный
vpn-mode status        # Показать текущее
vpn-mode detect        # Синхронизировать по GPIO-слайдеру (только Beryl AX)
```

**Физическая кнопка** (Cudy TR3000, Beryl AX) — переключает режим нажатием автоматически.  
На других роутерах — только CLI.

---

## 🔒 DNS (Quad9 / Cloudflare)

См. [docs/05-dns.md](05-dns.md)

```bash
dns-provider status        # Какой DNS сейчас активен
dns-provider quad9         # Переключить на Quad9 (default)
dns-provider cloudflare    # Переключить на Cloudflare

# Автофейловер крутится в cron, вручную не трогаем
logread -t dns-health      # История автофейловера
```

---

## ✈️ TRAVEL-режим (в дороге)

См. [docs/11-travel.md](11-travel.md)

### Wi-Fi WISP (подключение к отельному Wi-Fi)

```bash
travel-scan                    # Просканировать доступные Wi-Fi
travel-scan 5                  # Только 5 ГГц
travel-scan both               # Оба диапазона

travel-connect "SSID" "pass"   # Подключиться как WISP-client
travel-connect --off           # Отключиться (вернуть Ethernet WAN)
travel-connect --status        # Статус подключения
```

### Сохранённые Wi-Fi профили

```bash
travel-wifi save marriott "MarriottGuest" "pass2024"   # Запомнить
travel-wifi list                                       # Список сохранённых
travel-wifi connect marriott                           # Быстрый reconnect
travel-wifi delete marriott                            # Удалить профиль
travel-wifi show marriott                              # Показать (пароль в открытом виде!)
```

### Captive portal (отельная «Accept terms» страница)

```bash
travel-portal                  # Выключить VPN на 15 мин (default) для portal'a
travel-portal 5                # На 5 мин
travel-portal --off            # Выключить сейчас (= travel-vpn-on)

travel-vpn-on                  # Вернуть VPN принудительно
```

### USB tethering (телефон / 4G-модем)

```bash
travel-tether on               # Автодетект USB-устройства, поднять как WAN
travel-tether off              # Отключить
travel-tether status           # Статус

# Для 4G-dongle с SIM:
uci set network.wwan_usb.apn='your-apn'
uci commit network
ifup wwan_usb
```

### MAC-рандомизация (обход отельных лимитов)

```bash
travel-mac status              # Текущий MAC
travel-mac random              # Сменить на случайный
travel-mac fixed AA:BB:CC:DD:EE:FF   # Конкретный MAC
travel-mac reset               # Вернуть заводской
```

### Полная диагностика в дороге

```bash
travel-check                   # Всё состояние за один экран:
                               #   WAN-источники (Ethernet/WiFi/USB)
                               #   VPN (handshake, endpoint, mode)
                               #   DNS, adblock, system
```

---

## 📊 Замеры скорости и качества сети

См. [scripts/net-benchmark](../scripts/net-benchmark)

```bash
net-benchmark                  # Полный тест (~60 сек):
                               #   download + bufferbloat grade A+...F
                               #   рекомендация SQM

net-benchmark quick            # Только скорость (~20 сек, без bufferbloat)

# После теста — применить рекомендованный SQM:
sqm-tune 76 76                 # 76 download Mbps, 76 upload Mbps (95% margin)
```

Подробно про SQM — [docs/10-upgrades.md](10-upgrades.md).

---

## 💾 NAS (Samba-шара через USB-диск)

```bash
# Смонтирован ли USB-диск
df -h /mnt/storage
ls /mnt/storage

# Безопасно извлечь диск (перед unplug)
umount /mnt/storage

# SMB-credentials (user/pass)
cat /root/family-smb.txt

# Статус ksmbd
/etc/init.d/ksmbd status
ps | grep ksmbd
```

Подключение с клиентов:
- **Windows:** `\\192.168.1.1\storage` в Проводнике
- **macOS:** Finder → Go → Connect → `smb://192.168.1.1/storage`
- **Linux:** `smbclient //192.168.1.1/storage -U family`

---

## 🛡 AmneziaWG (VPN)

См. [docs/02-amneziawg.md](02-amneziawg.md)

```bash
# Состояние туннеля
awg show awg0                          # Полный статус
awg show awg0 | grep handshake         # Когда последний handshake
awg show awg0 | grep transfer          # Сколько передано

# Ручной перезапуск (watchdog делает это автоматом при протухшем handshake)
ifdown awg0 && ifup awg0

# Логи watchdog'а
logread -t awg-watchdog
cat /tmp/awg-watchdog/fails            # Счётчик подряд-неудач
```

---

## 🚫 Adblock

См. [docs/04-adblock.md](04-adblock.md)

```bash
# Статус adblock-lean
/etc/init.d/adblock-lean status

# Сколько доменов в блок-листе
zcat /var/run/adblock-lean/abl-blocklist.gz | tr '/' '\n' | grep -c '\.'

# Тест: блокируется ли конкретный домен?
nslookup doubleclick.net 192.168.1.1   # пустой ответ = BLOCKED

# Обновить блок-лист сейчас (cron делает раз в сутки)
/etc/init.d/adblock-lean start

# Добавить/убрать свои домены
vim /etc/adblock-lean/allowlist        # разблокировать
vim /etc/adblock-lean/blocklist        # заблокировать дополнительно
/etc/init.d/adblock-lean start         # применить
```

---

## 🚦 SQM (CAKE — борьба с bufferbloat)

```bash
# Статус
tc -s qdisc show dev eth0 | head

# Применить новые значения (Mbps → автоматически 95%)
sqm-tune 76 76                         # 76/76 Mbps

# Отключить
uci set sqm.eth0.enabled='0'
uci commit sqm
/etc/init.d/sqm stop
```

---

## 📡 Wi-Fi

См. [docs/06-wifi.md](06-wifi.md)

```bash
# Подключённые клиенты (их сила сигнала, скорость, MAC)
iw dev phy1-ap0 station dump           # 5 ГГц
iw dev phy0-ap0 station dump           # 2.4 ГГц

# Сменить SSID/пароль
uci set wireless.default_radio0.ssid='NewName'
uci set wireless.default_radio0.key='newpassword'
# то же для default_radio1
uci commit wireless
wifi reload
```

---

## 📋 Логи (что где смотреть)

```bash
# Всё в real-time
logread -f

# По конкретным компонентам
logread -t vpn-mode                    # Переключения режимов
logread -t dns-health                  # Автофейловер DNS
logread -t dns-provider                # Ручные свитчи DNS
logread -t awg-watchdog                # Перезапуски AWG
logread -t travel-portal               # Captive portal bypass
logread -t travel-tether               # USB tethering
logread -t travel-connect              # WISP подключения
logread -t travel-mac                  # Смена MAC
logread -t usb-mount                   # Монтирование USB
logread -t podkop                      # Podkop events
logread | grep sing-box                # Sing-box (большой объём)

# Персистентные логи (14 дней на flash)
ls /root/logs/
cat /root/logs/system-2026-04-17.log

# Ручной снапшот текущих логов
/usr/bin/log-snapshot
```

---

## ⚙️ Системное администрирование

```bash
# Общее состояние
uptime                                 # Загрузка CPU + uptime
free -m                                # RAM
df -h /overlay                         # Flash usage

# Все активные сервисы
for S in podkop sing-box dnsmasq adblock-lean ksmbd cron dropbear sqm; do
    echo "$S: $(/etc/init.d/$S status 2>&1 | head -1)"
done

# Подключённые DHCP-клиенты
cat /tmp/dhcp.leases

# Firewall — текущие nft-правила
nft list ruleset | less

# Процессы
ps
top -d 5
```

---

## 🔄 Backup / Restore / Upgrade

См. [docs/10-upgrades.md](10-upgrades.md)

```bash
# На ВАШЕМ ноутбуке (не на роутере):
./backup/backup.sh root@192.168.1.1               # Полный снапшот в backup/snapshots/
./backup/restore.sh backup/snapshots/20260417-120000 root@192.168.1.1

# После sysupgrade (новая прошивка OpenWrt):
ssh root@192.168.1.1 'sh -s' < setup/post-upgrade.sh   # Переустановить пакеты
```

---

## 🆘 Типовые «что-то сломалось — что нажать»

```bash
# 1. Сайт не открывается
vpn-mode status                  # В том ли я режиме?
awg show awg0 | grep handshake   # VPN живой?
travel-check                     # Полная картина

# 2. Wi-Fi клиенты не подключаются
logread | grep hostapd | tail
wifi reload

# 3. Пропал DNS
dns-provider status
dns-provider cloudflare          # Попробовать фейловер
/etc/init.d/dnsmasq restart

# 4. Висит VPN (handshake старый)
ifdown awg0 && ifup awg0

# 5. Всё сломалось (nuclear option)
/etc/init.d/podkop restart
/etc/init.d/network restart
reboot                           # Крайний случай
```

---

## 📚 Полный справочник

- [docs/09-troubleshooting.md](09-troubleshooting.md) — глубокая диагностика
- [docs/10-upgrades.md](10-upgrades.md) — lifecycle обновлений
- [AGENTS.md](../AGENTS.md) — архитектурный контекст для AI-ассистентов и инженеров

---

*Держите эту страницу открытой во вкладке. 90% admin-операций на роутере — это одна из этих команд.*
