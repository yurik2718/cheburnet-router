#!/bin/sh
# 09-ssh-hardening.sh — усилить SSH (dropbear):
# - Выключить password authentication (key-only)
# - Добавить явное fw4-правило REJECT для SSH с WAN zone
#
# ВАЖНО: перед запуском убедитесь что у вас есть рабочий SSH-ключ в
# /etc/dropbear/authorized_keys. Иначе заблокируетесь от роутера.
set -e

echo "== 09. SSH hardening =="

# === 0. Safety check: есть хотя бы один ключ? ===
AUTH_KEYS=/etc/dropbear/authorized_keys
if [ ! -s "$AUTH_KEYS" ]; then
    echo "ERROR: $AUTH_KEYS пуст или отсутствует."
    echo "Добавьте ваш публичный ключ ПЕРЕД запуском этого скрипта:"
    echo "  echo 'ssh-ed25519 ...' >> $AUTH_KEYS"
    exit 1
fi
echo "→ найдено ключей в authorized_keys: $(wc -l < $AUTH_KEYS)"

# === 1. Выключаем password auth ===
echo "→ выключаем PasswordAuth + RootPasswordAuth в dropbear"
uci set dropbear.main.PasswordAuth='off'
uci set dropbear.main.RootPasswordAuth='off'
uci commit dropbear
/etc/init.d/dropbear restart

# === 2. fw4 rule: Block-SSH-from-WAN ===
echo "→ добавляем явное REJECT SSH (tcp/22) с WAN zone"
if uci show firewall | grep -q "name='Block-SSH-from-WAN'"; then
    echo "  правило уже есть, пропускаю"
else
    uci add firewall rule
    uci set firewall.@rule[-1].name='Block-SSH-from-WAN'
    uci set firewall.@rule[-1].src='wan'
    uci set firewall.@rule[-1].proto='tcp'
    uci set firewall.@rule[-1].dest_port='22'
    uci set firewall.@rule[-1].target='REJECT'
    uci commit firewall
    /etc/init.d/firewall reload >/dev/null 2>&1
fi

# === 3. Проверка ===
echo "→ проверка"
uci show dropbear | grep -E 'PasswordAuth|Port'
nft list chain inet fw4 input_wan 2>/dev/null | grep -i "block-ssh" | head

echo "✓ SSH hardening OK"
echo
echo "ВАЖНО: проверьте что вы всё ещё можете зайти по ключу В ДРУГОЙ ССЕССИИ"
echo "перед тем как закрыть текущую, чтобы не остаться без доступа:"
echo "  ssh -i ~/.ssh/your-key -o BatchMode=yes root@192.168.1.1 exit"
