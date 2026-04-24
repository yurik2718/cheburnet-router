# 🔄 10. Обновления и поддержка

## TL;DR

OpenWrt **ничего не обновляет автоматически** — ни прошивку, ни пакеты. Единственные авто-обновления в нашем стеке — это **данные** (блок-листы adblock и podkop), которые fail-safe (rollback при проблемах). Чтобы обновление прошивки (`sysupgrade`) не стирало нашу конфигурацию, критические файлы добавлены в `/etc/sysupgrade.conf`. Для восстановления out-of-tree пакетов после апгрейда есть `setup/post-upgrade.sh`.

## Что обновляется само

| Компонент | Механизм | Частота | Риск |
|---|---|---|---|
| Podkop blocklists (`russia_outside.srs`) | cron `13 9 * * *` | раз в сутки | низкий — только данные |
| Adblock-lean blocklists (Hagezi) | cron (внутри adblock-lean) | раз в сутки | очень низкий — rollback при failed test_domains |
| AmneziaWG rule-sets | через sing-box (update_interval=1d) | раз в сутки | низкий |

Эти обновления не трогают код, только данные. Если GitHub недоступен — используются закешированные версии.

## Что НЕ обновляется само

Всё остальное. OpenWrt в отличие от Debian/Ubuntu **не имеет `unattended-upgrades`**. Вы полностью контролируете:
- Версию прошивки (`sysupgrade`)
- Версии установленных пакетов (`apk upgrade`)
- Версии подkop/sing-box/adblock-lean (manual через их install-scripts)

## Что сохраняется при `sysupgrade`

Когда вы в будущем обновляете OpenWrt (например, с 25.12.2 на 25.12.3 или на 26.x), процесс выглядит так:

1. Скачиваете новый образ `.bin` с openwrt.org (или через owut)
2. `sysupgrade /path/to/image.bin`
3. Роутер сохраняет определённые файлы, перезаписывает всё остальное, перезагружается

**По умолчанию OpenWrt preserve'ит:**
- `/etc/config/*` — все UCI (podkop, firewall, wireless, sqm, network, dhcp)
- `/etc/crontabs/root` — наши cron-записи
- `/etc/dropbear/authorized_keys` — SSH-ключ
- SSH host keys
- Ряд системных файлов

**Благодаря нашему `/etc/sysupgrade.conf` дополнительно сохраняются:**

```
# Наши CLI-скрипты
/usr/bin/vpn-mode
/usr/bin/dns-provider
/usr/bin/dns-healthcheck
/usr/bin/awg-watchdog
/usr/bin/log-snapshot
/usr/bin/sqm-tune

# Хендлеры и сервисы
/etc/hotplug.d/button/10-vpn-mode
/etc/init.d/vpn-mode
/etc/vpn-mode.state

# AWG-конфиг (КРИТИЧНО — содержит приватный ключ!)
/etc/amnezia/

# Adblock-lean настройки
/etc/adblock-lean/

# Persistent-логи
/root/logs/
```

Проверить список вручную: `sysupgrade -l` на роутере.

## Что НЕ сохраняется (требует переустановки)

Out-of-tree пакеты, которые мы ставили вручную:
- `kmod-amneziawg`, `amneziawg-tools`, `luci-proto-amneziawg`
- `podkop`, `luci-app-podkop`, `sing-box`
- `adblock-lean`
- `sqm-scripts`
- `wpad-mbedtls` (заменяющий `wpad-basic-mbedtls`)

**Решение:** скрипт `setup/post-upgrade.sh`. Запустить после sysupgrade — он поставит всё обратно. Конфиги уже сохранены, так что после установки пакетов всё сразу заработает с вашими настройками.

## Lifecycle обновлений (рекомендуемый процесс)

### A) Мелкие обновления пакетов (например, dnsmasq → новая версия)

Раз в 3-6 месяцев:

```bash
# 1. Backup перед обновлением (safety)
./backup/backup.sh root@192.168.1.1

# 2. Смотрите, что доступно к апгрейду
ssh root@192.168.1.1 'apk list --upgradable'

# 3. Осторожно обновляете (избегаем kmod-amneziawg — он привязан к ядру)
ssh root@192.168.1.1 'apk upgrade --no-interactive'

# 4. Проверяете что всё работает
ssh root@192.168.1.1 'awg show awg0; vpn-mode status; /etc/init.d/sing-box status'
```

⚠️ **Осторожно с `kmod-*` пакетами.** Если автоматический apk upgrade притянет новое ядро — модуль AmneziaWG может не сработать (несовместимая версия kmod). В этом случае: re-install AmneziaWG вручную через `setup/01-amneziawg.sh`.

### B) Обновление прошивки OpenWrt (sysupgrade)

Раз в 6-12 месяцев или при важных security-patch'ах:

```bash
# На ноутбуке:
# 1. Backup
./backup/backup.sh root@192.168.1.1

# 2. Скачайте новый образ с openwrt.org для вашего железа
# Для Beryl AX: https://openwrt.org/toh/glinet/gl-mt3000

# 3. Загрузите образ на роутер
scp openwrt-XX.XX.X-mediatek-filogic-glinet_gl-mt3000-squashfs-sysupgrade.itb \
  root@192.168.1.1:/tmp/

# 4. Запустите sysupgrade (роутер перезагрузится, ~3 минуты downtime)
ssh root@192.168.1.1 'sysupgrade /tmp/openwrt-*.itb'

# 5. После перезагрузки выполните post-upgrade (переустанавливает wiped-пакеты)
ssh root@192.168.1.1 'sh -s' < ./setup/post-upgrade.sh

# 6. Проверка
ssh root@192.168.1.1 'awg show awg0 | grep handshake; vpn-mode status'
```

### C) Обновление стека (podkop, sing-box, adblock)

**Adblock-lean:** сам НЕ обновляется. Запустите обновлятор:
```bash
/etc/init.d/adblock-lean update
```

**Podkop:** также manual:
```bash
wget -qO /tmp/podkop-install.sh https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh
sh /tmp/podkop-install.sh
```
Install-скрипт обнаружит существующую установку и проведёт апгрейд. При major-версионных скачках (0.x → 1.x) может потребоваться ручная правка конфига — проверьте release notes.

**Sing-box:** обновляется через podkop. Обычно не надо руками трогать.

### D) Обновление AmneziaWG (новая версия прошивки OpenWrt)

Переходите на, скажем, OpenWrt 26.x — нужен kmod-amneziawg для нового ядра:

1. Проверить https://github.com/Slava-Shchipunov/awg-openwrt/releases — вышел ли пакет под вашу версию
2. Обновить `setup/post-upgrade.sh` — строку `BASE=.../v25.12.2` заменить на новую
3. Запустить post-upgrade

Если пакета ещё нет — **ждите** (автор обновляет обычно в течение недели-двух после релиза OpenWrt). В это время не делайте sysupgrade.

## Best practices

1. **Всегда делайте backup ДО любых обновлений.**
   ```
   ./backup/backup.sh root@192.168.1.1
   ```
   Снапшоты живут в `backup/snapshots/<timestamp>.tar.gz` с AWG-ключами. Храните приватно.

2. **Тестируйте на своём роутере ПЕРЕД отправкой родственникам.**
   Если у вас есть второй OpenWrt-роутер или VM — проверьте `full-deploy.sh` на нём.

3. **Не обновляйте в середине недели.** Если после апгрейда что-то сломается, а вы в отпуске — родственники без интернета. Апгрейды — перед выходными, чтобы было время откатиться.

4. **Читайте release notes** (особенно podkop и AmneziaWG) ПЕРЕД обновлением. Major-версии могут менять UCI-схему.

5. **Закрепите версии критических пакетов в `setup/01-amneziawg.sh`** и `setup/post-upgrade.sh`. Сейчас мы пиним `v25.12.2` в URL — это не просто так. Не меняйте без причины.

## Аварийное восстановление: полный reset

Если что-то совсем сломалось — fall-back: прошить роутер заводским образом OpenWrt (через OpenWrt TFTP recovery или factory image через `sysupgrade -n`), потом:

```bash
# На чистом OpenWrt:
./setup/full-deploy.sh root@192.168.1.1
```

У вас же есть `backup/snapshots/<timestamp>/`? → восстановите конфиги:
```bash
./backup/restore.sh backup/snapshots/20260417-120000 root@192.168.1.1
```

В худшем случае — поднимайте заново руками по `setup/*.sh`.

## Проверь себя

1. **Я сделал `sysupgrade`. После перезагрузки ни Wi-Fi, ни SSH. Что делать?**
   <details><summary>Ответ</summary>
   UCI wireless.key и SSH authorized_keys сохраняются по дефолту — Wi-Fi и SSH должны работать сразу. Если нет:
   - Проверьте физ. подключение (Ethernet к LAN-порту роутера)
   - Сброс: зажать кнопку reset на 10+ сек (factory → возвращает OpenWrt-дефолты, IP `192.168.1.1`, без пароля)
   - Если SSH сломался — через веб-интерфейс зайти (http://192.168.1.1 после reset)
   - Перейти к `restore.sh` из backup
   </details>

2. **Можно ли авто-обновлять adblock-lean через cron?**
   <details><summary>Ответ</summary>
   Не рекомендую. Списки Hagezi Pro меняются редко, формат стабилен. Risk: pull от upstream притащит регрессию, которая сломает резолв популярного домена (бывает). Наш adblock-lean делает rollback при сбое test_domains, но всё равно — update тула раз в пол-года, руками. Списки обновляются автоматически каждый день — это data, не code, rollback есть.
   </details>

3. **Как проверить, переживёт ли мой `sysupgrade` конфигурацию до того как его запускать?**
   <details><summary>Ответ</summary>
   `sysupgrade -l` на роутере — печатает список всех файлов, которые будут сохранены. Проверьте, что в нём есть: `/etc/amnezia/amneziawg/awg0.conf`, `/usr/bin/vpn-mode`, остальные ваши скрипты. Если чего-то нет — добавьте в `/etc/sysupgrade.conf`.
   </details>

## 📚 Глубже изучить

- [OpenWrt: sysupgrade documentation](https://openwrt.org/docs/guide-user/installation/sysupgrade.howto)
- [OpenWrt: owut (unified upgrade tool)](https://openwrt.org/docs/guide-user/installation/attended.sysupgrade) — будущий стандарт
- [apk package manager](https://wiki.alpinelinux.org/wiki/Package_management) — знания переносимы с Alpine Linux
- [Slava-Shchipunov/awg-openwrt releases](https://github.com/Slava-Shchipunov/awg-openwrt/releases) — отсюда узнаёте о новых пакетах под OpenWrt-версии
