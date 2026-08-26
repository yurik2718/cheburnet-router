# OpenWrt-пакет cheburnet — движок (ucode) + ubus-обработчик + ACL + веб-мастер.
#
# Собирается OpenWrt SDK (apk-based ветка, см. .github/workflows). Чистые скрипты — компилировать
# нечего: Build/Compile пуст, install копирует файлы из репозитория. PKGARCH:=all — пакет
# arch-независим (ucode интерпретируется), а arch-зависимые зависимости (kmod-amneziawg и т.п.)
# apk подбирает сам. Реальная сборка/установка проверяется в QEMU (qemu-install, см. Makefile).

include $(TOPDIR)/rules.mk

PKG_NAME:=cheburnet
PKG_VERSION:=3.2.0
PKG_RELEASE:=1

PKG_MAINTAINER:=Andrey Yurik
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

# Корень репозитория относительно этого Makefile (package/cheburnet/Makefile). Feed в CI —
# src-link на репозиторий, поэтому ../.. указывает на корень с engine/ и package/files/.
CHEBURNET_REPO:=$(CURDIR)/../..

define Package/cheburnet
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=cheburnet — образовательный split-tunnel роутер (мастер настройки)
  URL:=https://github.com/
  PKGARCH:=all
  # Движок и data-plane. dnsmasq-full — ради nftset; https-dns-proxy — шифрованный DNS
  # (и блокировка рекламы/контента — через выбор фильтрующего DoH-резолвера, не локальным
  # списком); kmod-amneziawg + amneziawg-tools — туннель; nftables/ip-full — пометка и policy
  # routing; uhttpd-mod-ubus — мост браузер→ubus для веб-мастера.
  DEPENDS:= \
	+ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus \
	+rpcd +rpcd-mod-file \
	+dnsmasq-full +https-dns-proxy \
	+kmod-amneziawg +amneziawg-tools \
	+nftables +ip-full \
	+uhttpd +uhttpd-mod-ubus
endef

define Package/cheburnet/description
  Образовательный роутер на OpenWrt с настраиваемым split-tunnel: домены из direct-списка идут
  напрямую, остальной трафик — через зашифрованный VPN. Light-тир (дефолт): dnsmasq-nftset +
  nftables + policy routing + AmneziaWG (в ядре, для слабого железа). Full-тир (VLESS+Reality
  и Hysteria2 через sing-box) — опциональный пакет cheburnet-full для мощного железа.
  Логика — движок на ucode; настройка — веб-мастер через ubus RPC.
endef

# Full-тир (ADR 0004): VLESS+Reality и Hysteria2 через sing-box. ОТДЕЛЬНЫЙ пакет, а не +sing-box в
# DEPENDS базового — иначе тяжёлый userspace-туннель поехал бы на слабые MIPS-роутеры, которым
# хватает AmneziaWG. Движок (включая engine/steps/singbox) уже в базовом пакете; этот пакет лишь
# тянет бинарь. Ставится туда, где preflight подтвердил Full (AES-arch, RAM/флеш).
#
# ПОЧЕМУ sing-box-tiny, а не полная сборка: у tiny есть все нужные нам теги (with_quic → Hysteria2,
# with_utls → Reality), она объявляет PROVIDES:=sing-box и ставит тот же /usr/bin/sing-box, но
# весит на ~4.5 МБ меньше при скачивании. Отсутствующие в ней теги (with_wireguard, with_acme,
# with_dhcp, with_tailscale, …) в нашем data-plane не используются: WireGuard-ось у нас в ядре.
# Тот же порядок предпочтения зашит в install-singbox.sh (кнопка/автодогрузка) — основной путь.
define Package/cheburnet-full
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=cheburnet Full-тир — VLESS+Reality и Hysteria2 через sing-box
  URL:=https://github.com/
  PKGARCH:=all
  DEPENDS:=+cheburnet +sing-box-tiny
endef

define Package/cheburnet-full/description
  Метапакет: добавляет к cheburnet поддержку Full-тира на мощном железе — VLESS+Reality
  (проходит там, где трафик режут) и Hysteria2 (держит скорость на канале с потерями).
  На слабых роутерах не нужен — ставьте базовый cheburnet (AmneziaWG). Код движка — в пакете
  cheburnet; здесь только зависимость sing-box-tiny.
endef

# Скрипты — компилировать нечего.
define Build/Compile
endef

define Package/cheburnet/install
	# Движок (ucode): весь engine/, но без тестов, README и host-раннера — на роутере не нужны
	# и зря едят флеш. Структуру сохраняем — рабочие относительные import'ы между модулями.
	$(INSTALL_DIR) $(1)/usr/share/cheburnet
	$(CP) $(CHEBURNET_REPO)/engine $(1)/usr/share/cheburnet/
	$(FIND) $(1)/usr/share/cheburnet/engine -type d -name tests -prune -exec rm -rf {} +
	rm -f $(1)/usr/share/cheburnet/engine/run-tests.sh
	$(FIND) $(1)/usr/share/cheburnet/engine -name 'README.md' -delete

	# ubus-обработчик через тонкий shim в /usr/libexec/rpcd/ (rpcd сканирует только его).
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/rpcd-cheburnet.sh $(1)/usr/libexec/rpcd/cheburnet

	# ACL движка (выведена из реестра методов; см. engine/ubus/acl.uc).
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) $(CHEBURNET_REPO)/engine/ubus/rpcd-acl.json $(1)/usr/share/rpcd/acl.d/cheburnet.json

	# Веб-мастер: SPA на Svelte, бандл собран Vite из web/ и закоммичен в files/web/.
	$(INSTALL_DIR) $(1)/www/cheburnet
	$(CP) ./files/web/. $(1)/www/cheburnet/
endef

# rpcd подхватит новый обработчик и ACL только после reload. На самом роутере (не в imagebuilder,
# где $IPKG_INSTROOT задан) — мягкий reload, без падения если rpcd ещё не запущен.
define Package/cheburnet/postinst
#!/bin/sh
# В imagebuilder ($IPKG_INSTROOT задан) на живой системе ничего не делаем.
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/rpcd reload 2>/dev/null

# Обновление ПОВЕРХ настроенного роутера: переприменить data-plane новым движком сразу, не ждать
# ребута — миграции (схема маршрута туннеля, cron-запись сторожа) живут в install/reapply.uc, а
# hotplug-хук зовёт его только когда что-то не сходится. До ребута роутер иначе жил бы на старой схеме.
if [ -f /etc/cheburnet/install.json ]; then
	ucode -R /usr/share/cheburnet/engine/install/reapply.uc >/dev/null 2>&1 || true
fi

# Самодостаточность установки: пакет мог встать НЕ через bootstrap (LuCI «Software», ручной
# apk add) — тогда токена мастера нет и мастер не запустить. Засеваем токен и печатаем ссылку в
# системный лог (виден в LuCI → Status → System Log), чтобы браузерная установка без SSH доходила
# до мастера так же, как SSH-однострочник. ТОЛЬКО на ненастроенной системе: если install.json уже
# есть — не трогаем (иначе upgrade пересоздал бы токен и заново открыл путь установки).
etc=/etc/cheburnet
if [ ! -f "$$etc/install.json" ]; then
	mkdir -p "$$etc"
	umask 077
	if [ ! -s "$$etc/install-token" ]; then
		cat /proc/sys/kernel/random/uuid 2>/dev/null > "$$etc/install-token" \
			|| tr -dc 'a-f0-9' < /dev/urandom | head -c 32 > "$$etc/install-token"
	fi
	chmod 600 "$$etc/install-token"
	tok="$$(cat "$$etc/install-token" 2>/dev/null)"
	ip="$$(uci -q get network.lan.ipaddr || echo 192.168.1.1)"
	# ipaddr бывает списком/в CIDR-форме — берём первый адрес и режем маску (как bootstrap).
	set -- $$ip; ip="$${1%%/*}"
	logger -t cheburnet "мастер настройки роутера открыт: http://$$ip/cheburnet/?token=$$tok"
	logger -t cheburnet "если ссылка не открывается — откройте http://$$ip/cheburnet/ и введите код: $$tok"
fi
exit 0
endef

# cheburnet-full — метапакет: файлов нет, только зависимость sing-box (движок уже в cheburnet).
define Package/cheburnet-full/install
	true
endef

$(eval $(call BuildPackage,cheburnet))
# cheburnet-full — метапакет Full-тира (ADR 0004): добавляет sing-box к базовому cheburnet.
# Ставится только там, где preflight подтвердил Full (AES-arch, RAM); слабое железо его не тянет.
$(eval $(call BuildPackage,cheburnet-full))
