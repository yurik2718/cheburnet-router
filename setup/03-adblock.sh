#!/bin/sh
# 03-adblock.sh — поставить adblock-lean с Hagezi Pro списком.
set -e

echo "== 03. adblock-lean =="

# === 1. Установка ===
if [ -x /etc/init.d/adblock-lean ]; then
    echo "→ adblock-lean уже установлен"
else
    echo "→ скачиваем и устанавливаем adblock-lean"
    uclient-fetch -q \
        https://raw.githubusercontent.com/lynxthecat/adblock-lean/master/abl-install.sh \
        -O /tmp/abl-install.sh
    sh /tmp/abl-install.sh -v release
fi

# === 2. Генерация конфига ===
if [ ! -f /etc/adblock-lean/config ]; then
    echo "→ генерируем дефолтный конфиг"
    /etc/init.d/adblock-lean gen_config
fi

# Убедимся что блок-лист — Hagezi Pro
if ! grep -q 'raw_block_lists="hagezi:pro"' /etc/adblock-lean/config; then
    echo "→ ставим hagezi:pro"
    sed -i 's|^raw_block_lists=.*|raw_block_lists="hagezi:pro"|' /etc/adblock-lean/config
fi

# === 3. Enable + start ===
echo "→ enable + start adblock-lean (качает ~1.5 MB список)"
/etc/init.d/adblock-lean enable
/etc/init.d/adblock-lean start
sleep 5

# Перезапуск dnsmasq, чтобы подхватил блок-лист
/etc/init.d/dnsmasq restart
sleep 3

# === 4. Проверка ===
echo "→ проверяем"
if [ -f /var/run/adblock-lean/abl-blocklist.gz ]; then
    entries=$(zcat /var/run/adblock-lean/abl-blocklist.gz 2>/dev/null | tr '/' '\n' | grep -c '\.')
    echo "✓ блок-лист загружен: ~$entries доменов"
else
    echo "⚠ блок-лист не создан"
fi

# Тест конкретного известно-блокируемого домена
BLOCKED=$(nslookup pagead2.googlesyndication.com 127.0.0.1 2>/dev/null | grep -c 'Address' || true)
if [ "$BLOCKED" -le 1 ]; then
    echo "✓ тестовый домен (pagead2.googlesyndication.com) блокирован"
else
    echo "⚠ тестовый домен резолвится (возможно, кэш — попробуйте killall -HUP dnsmasq)"
fi

echo "✓ adblock-lean OK"
