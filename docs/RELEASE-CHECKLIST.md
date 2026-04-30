# RELEASE CHECKLIST — ручная проверка перед релизом

Что **не** покрывается автоматически (T1 lint + T2 unit + T3a integration) и должно быть проверено руками на живом железе перед каждым тегом.

Стенд: один из поддерживаемых роутеров (Cudy TR3000 v1, Beryl AX) с прошитой ванильной OpenWrt 25.12+, чистый `firstboot`, рабочий WAN.

## Bootstrap (LAN-сторона, защита установки)

- [ ] **Bootstrap по одной команде из README** работает с чистой прошивки до экрана веб-мастера. Проверяется команда из `README.md` целиком, не отдельные части.
- [ ] **SHA bootstrap.sh** в README совпадает с тем, что лежит на `main` в GitHub. Вытаскивается командой `wget -qO- https://raw.../bootstrap.sh | sha256sum`.
- [ ] **Install-токен** в `/etc/cheburnet/install-token` ровно 32 hex-символа, `chmod 600`, owner `root:root`.
- [ ] **URL c автоподстановкой токена** (`http://192.168.1.1/cheburnet/?token=...`) открывается и веб-мастер показывает экран Шаг 1 без поля «введите токен».
- [ ] **Без токена** мастер показывает экран ввода токена. Вставка неверного токена → отказ; правильного → переход к Шагу 2.

## Установка (полный 12-минутный прогон)

- [ ] **Все 12 шагов** `setup/00..12-*.sh` отрабатывают без ошибок. Лог в браузере (`install_progress`) обновляется.
- [ ] **AWG handshake** ловится в течение 10 секунд после `01-amneziawg.sh` (см. `awg show awg0`).
- [ ] **Podkop split-routing** работает: `curl https://yandex.ru/ip` показывает RU-IP, `curl https://api.ipify.org` через VPN — IP сервера.
- [ ] **Hagezi-блок-лист** грузится (`/etc/init.d/adblock-lean status` → running, размер `/tmp/dnsmasq.d/.adb-list` > 1 MB).
- [ ] **DNS-DoH** работает: `nslookup cloudflare.com 192.168.1.1` отвечает; в `tcpdump -i wan port 53` (с подключенного клиента) — пусто (всё через DoH порт 853).

## Wi-Fi (WPA3-mixed)

- [ ] **SSID/пароль из мастера** реально применился, виден в `iw dev phy0-ap0 info`.
- [ ] **WPA3 (sae-mixed)** — клиент с WPA3-only подключается, клиент с WPA2-only тоже (mixed mode).
- [ ] **5 GHz radio** работает. Проверить на устройстве с 5G: `iwinfo wlan1 info`.

## Физическая кнопка / слайдер (HOME ↔ TRAVEL)

- [ ] **Cudy TR3000**: однократное нажатие физической кнопки → `vpn-mode toggle` сработал, `cat /etc/vpn-mode.state` поменялся.
- [ ] **Beryl AX**: переключение слайдера → `vpn-mode detect` → состояние применилось, `logread -t vpn-mode` показывает событие.
- [ ] После перезагрузки роутера состояние восстанавливается (`/etc/init.d/vpn-mode` boot-hook).

## Three-layer kill switch

- [ ] **Слой 1 (route_allowed_ips=0)** — при ifdown awg0 трафик через VPN-зону умирает.
- [ ] **Слой 2 (firewall fw4)** — `nft list ruleset | grep 'iifname \"awg0\"'` показывает реджект если awg0 down.
- [ ] **Слой 3 (podkop sing-box)** — без AWG-handshake'а `curl http://1.1.1.1` через split-routing блокируется.

## Post-install ACL lockdown

- [ ] После завершения установки `cat /usr/share/rpcd/acl.d/cheburnet.json` — без `unauthenticated.write` блока.
- [ ] **POST `mode_switch` без login** через `curl -d ... http://192.168.1.1/ubus` → ACL deny (статус 6 от ubus).
- [ ] **POST `mode_switch` с правильным root-login** → 200 OK, режим переключился.
- [ ] **`/etc/cheburnet/install-token`** удалён (`ls -la` — нет файла).
- [ ] Повторный `install_start` с любым токеном → `install token not found`.

## Сценарии Travel

- [ ] **`travel-scan`** видит окружающие сети, сортирует по сигналу.
- [ ] **`travel-connect "<SSID>" "<password>"`** подключается к гостевому Wi-Fi, получает IP.
- [ ] **Captive portal** (если есть на гостевой сети) — `travel-portal` редиректит на login-страницу.
- [ ] **Travel-VPN-on** — поверх hotel Wi-Fi поднимается AWG-туннель.

## Стабильность / watchdog

- [ ] **AWG watchdog** (`scripts/awg-watchdog`) — после `wg-quick down awg0` восстанавливает соединение в течение 1 минуты.
- [ ] **DNS healthcheck** — при недоступности Quad9 переключается на Cloudflare. Проверить через `iptables -A OUTPUT -d 9.9.9.9 -j DROP`.
- [ ] **24-часовой uptime** (предрелизный smoke): роутер в боевом режиме сутки, никаких kernel panic / отвалов VPN.

## Smoke-тест factory_reset

- [ ] **`factory_reset {confirm:"RESET"}` через web** (после login) — роутер уходит в перезагрузку через ~5 секунд.
- [ ] После firstboot токен-файл создан заново, веб-мастер снова показывает Шаг 1.

---

**Если хотя бы один пункт упал — НЕ публикуем тег.** Пишем баг в `bugs/`, чиним, прогоняем чек-лист с начала.
