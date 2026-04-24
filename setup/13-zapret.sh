#!/bin/sh
# 13-zapret.sh — установить zapret для обхода DPI-блокировок без VPN.
#
# zapret перехватывает исходящие пакеты и меняет их так, что DPI-оборудование
# провайдера (ТСПУ) не распознаёт к какому сайту идёт запрос — и не блокирует.
# Всё работает локально на роутере, внешний сервер не нужен.
#
# Стратегия по умолчанию: fake+disorder2 для TCP, fake для QUIC/UDP.
# Работает у большинства российских провайдеров для YouTube, Twitch и других
# сайтов с DPI-блокировкой. Для IP-блокировок (Instagram, Facebook) нужен VPN.
set -e

echo "== 13. zapret (обход DPI) =="

ZAPRET_DIR="/opt/zapret"
NFT_RULES="/etc/nftables.d/99-zapret.nft"
INITD="/etc/init.d/zapret"

# Определяем архитектуру
ARCH=$(uname -m)
case "$ARCH" in
    aarch64) BIN_ARCH="aarch64" ;;
    mips)    BIN_ARCH="mips" ;;
    mipsel)  BIN_ARCH="mipsel" ;;
    x86_64)  BIN_ARCH="x86_64" ;;
    *)       BIN_ARCH="$ARCH" ;;
esac
echo "→ Архитектура: $ARCH"

# === 1. Зависимости ===
echo "→ Устанавливаем зависимости (nft-queue)"
apk add kmod-nft-queue 2>&1 | tail -3 || true
modprobe nfnetlink_queue 2>/dev/null && echo "→ nfnetlink_queue загружен" || true

# === 2. Скачиваем zapret ===
echo "→ Скачиваем zapret с GitHub..."
cd /tmp
rm -rf zapret-install && mkdir zapret-install && cd zapret-install

# Получаем тег последнего релиза через редирект
LATEST_TAG=$(wget -q --server-response --spider \
    "https://github.com/bol-van/zapret/releases/latest" 2>&1 \
    | grep -i 'Location:' | grep -o 'tag/[^"[:space:]]*' | cut -d/ -f2 | head -1)

if [ -z "$LATEST_TAG" ]; then
    # Fallback: используем известную стабильную версию
    LATEST_TAG="v70"
    echo "⚠ Не удалось определить последнюю версию — используем $LATEST_TAG"
fi
echo "→ Версия zapret: $LATEST_TAG"

ZAPRET_URL="https://github.com/bol-van/zapret/releases/download/${LATEST_TAG}/zapret-${LATEST_TAG}.tar.gz"
wget -q "$ZAPRET_URL" -O zapret.tar.gz 2>/dev/null || \
    wget -q --no-check-certificate "$ZAPRET_URL" -O zapret.tar.gz || {
    echo "✗ Не удалось скачать zapret."
    echo "  Проверьте интернет-соединение роутера: ping 8.8.8.8"
    exit 1
}

tar xzf zapret.tar.gz
ZAPRET_SRC=$(find . -maxdepth 1 -type d -name 'zapret*' | head -1)
[ -n "$ZAPRET_SRC" ] || { echo "✗ Не удалось распаковать zapret"; exit 1; }
echo "→ Распаковано: $ZAPRET_SRC"

# === 3. Устанавливаем nfqws бинарник ===
echo "→ Ищем бинарник nfqws для $BIN_ARCH..."

# Ищем бинарник в порядке приоритета
NFQWS_BIN=""
for SEARCH_PATH in \
    "$ZAPRET_SRC/binaries/openwrt/$BIN_ARCH/nfqws" \
    "$ZAPRET_SRC/binaries/openwrt/nfqws-$BIN_ARCH" \
    "$ZAPRET_SRC/binaries/$BIN_ARCH/nfqws" \
    "$ZAPRET_SRC/nfq/nfqws"; do
    if [ -f "$SEARCH_PATH" ]; then
        NFQWS_BIN="$SEARCH_PATH"
        break
    fi
done

# Если не нашли по прямому пути — ищем по шаблону
if [ -z "$NFQWS_BIN" ]; then
    NFQWS_BIN=$(find "$ZAPRET_SRC" -name "nfqws" -type f | grep -i "$BIN_ARCH" | head -1)
fi
if [ -z "$NFQWS_BIN" ]; then
    NFQWS_BIN=$(find "$ZAPRET_SRC" -name "nfqws" -type f | head -1)
fi

if [ -z "$NFQWS_BIN" ] || [ ! -f "$NFQWS_BIN" ]; then
    echo "✗ Не найден бинарник nfqws для архитектуры $BIN_ARCH"
    echo "  Доступные файлы в архиве:"
    find "$ZAPRET_SRC" -name "nfqws*" -type f 2>/dev/null || echo "  (ничего не найдено)"
    exit 1
fi

mkdir -p "$ZAPRET_DIR"
cp "$NFQWS_BIN" "$ZAPRET_DIR/nfqws"
chmod +x "$ZAPRET_DIR/nfqws"
echo "✓ nfqws установлен ($("$ZAPRET_DIR/nfqws" --version 2>&1 | head -1 || echo 'версия неизвестна'))"

# === 4. Nftables правила ===
echo "→ Создаём nftables правила"
mkdir -p /etc/nftables.d

cat > "$NFT_RULES" << 'NFTRULES'
# zapret — перехват HTTPS-трафика для обхода DPI
# bypass означает: если zapret не запущен — пакеты проходят насквозь (fail-open)
table inet zapret {
    chain forward {
        type filter hook forward priority mangle; policy accept;
        # TCP 443 (HTTPS) — для большинства сайтов
        tcp dport 443 ct state new,established queue num 200 bypass
        # UDP 443 (QUIC / HTTP3) — YouTube, Google и другие используют QUIC
        udp dport 443 queue num 200 bypass
    }
}
NFTRULES

# Применяем правила сейчас
nft -f "$NFT_RULES" 2>/dev/null && echo "✓ nftables правила применены" || \
    echo "⚠ nftables — правила будут применены при следующей перезагрузке"

# === 5. Init.d сервис (автозапуск) ===
echo "→ Создаём сервис автозапуска"
cat > "$INITD" << INITSCRIPT
#!/bin/sh /etc/rc.common
# zapret — обход DPI-блокировок
START=95
STOP=10
USE_PROCD=1

NFQWS=$ZAPRET_DIR/nfqws
NFT_RULES=$NFT_RULES

# Стратегия для России:
# fake,disorder2 — эффективна для большинства провайдеров
# autottl — TTL подбирается автоматически чтобы fake-пакеты не дошли до сервера
# badsum — ещё один признак "мусора" для DPI
OPTS_TCP="--dpi-desync=fake,disorder2 --dpi-desync-autottl=2 --dpi-desync-fooling=badsum"
OPTS_UDP="--dpi-desync=fake --dpi-desync-autottl=2"

start_service() {
    procd_open_instance
    procd_set_param command \$NFQWS \
        --qnum=200 \
        --filter-tcp=443 \$OPTS_TCP \
        --filter-udp=443 \$OPTS_UDP \
        --new
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
    # Применяем nftables правила
    nft -f "\$NFT_RULES" 2>/dev/null || true
}

stop_service() {
    nft delete table inet zapret 2>/dev/null || true
}

reload_service() {
    stop_service
    start_service
}
INITSCRIPT

chmod +x "$INITD"

# === 6. Включаем и запускаем ===
/etc/init.d/zapret enable
/etc/init.d/zapret start

sleep 3

# === 7. Проверка ===
if /etc/init.d/zapret status 2>/dev/null | grep -q running; then
    echo "✓ zapret запущен"
elif pgrep -f nfqws >/dev/null 2>&1; then
    echo "✓ nfqws процесс работает"
else
    echo "⚠ zapret не запустился — проверьте: logread | grep zapret"
fi

echo "✓ zapret установлен и настроен"
echo ""
echo "  Если нужные сайты не открылись — попробуйте другую стратегию."
echo "  Смените строку OPTS_TCP в $INITD:"
echo "    fake,disorder2  (по умолчанию)"
echo "    fake,split2     (альтернатива)"
echo "    disorder2       (только disorder)"
echo "  После смены: /etc/init.d/zapret restart"
