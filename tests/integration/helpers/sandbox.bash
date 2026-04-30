# tests/integration/helpers/sandbox.bash
#
# Изолированный sandbox для запуска web/rpcd-cheburnet и bootstrap.sh без
# реального OpenWrt. Каждый bats-тест получает:
#
#   $SANDBOX           — корень временной директории (tmpdir)
#   $SANDBOX/root      — fake-rootfs (туда смотрят моки за /etc, /tmp и т.п.)
#   $SANDBOX/state     — что rpcd-cheburnet видит как $STATE_DIR (/tmp/cheburnet)
#   $SANDBOX/install   — что видит как $INSTALL_DIR (/opt/cheburnet)
#   $SANDBOX/mockdir   — PATH-prepend каталог с моками ubus/uci/awg/apk/wget
#   $SANDBOX/calls     — журнал вызовов моков (по одному файлу на команду)
#
# Важно: rpcd-cheburnet жёстко прописывает /etc/cheburnet/install-token,
# /etc/amnezia/amneziawg/awg0.conf, /etc/init.d/* и т.п. Поэтому моки uci/awg
# и сам helper подменяют эти пути через переменную $FAKE_ROOT, а скрипт
# вызывается с переопределёнными $INSTALL_DIR/$STATE_DIR через env.
#
# rpcd-cheburnet пишет напрямую в /etc/amnezia/amneziawg/, /etc/cheburnet/,
# /etc/adblock-lean/. Чтобы не трогать реальные пути, в каждом тесте делаем:
#
#   sandbox_init
#   run_rpcd <method> <json-input>
#   assert_json '.foo' "expected"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export REPO_ROOT

# bats-support / bats-assert
load "$REPO_ROOT/tests/vendor/bats-support/load.bash"
load "$REPO_ROOT/tests/vendor/bats-assert/load.bash"

# ─────────────────────────────────────────────────────────────────────────────
# Инициализация
# ─────────────────────────────────────────────────────────────────────────────

sandbox_init() {
    SANDBOX="$(mktemp -d)"
    export SANDBOX

    FAKE_ROOT="$SANDBOX/root"
    export FAKE_ROOT

    # Каталоги которые rpcd-cheburnet ожидает увидеть
    mkdir -p "$FAKE_ROOT/etc/cheburnet"
    mkdir -p "$FAKE_ROOT/etc/amnezia/amneziawg"
    mkdir -p "$FAKE_ROOT/etc/adblock-lean"
    mkdir -p "$FAKE_ROOT/etc/init.d"
    mkdir -p "$FAKE_ROOT/usr/bin"
    mkdir -p "$FAKE_ROOT/usr/share/rpcd/acl.d"
    mkdir -p "$FAKE_ROOT/usr/libexec/rpcd"

    # State / install dirs — переопределяем через env (rpcd-cheburnet их
    # читает из top-level переменных INSTALL_DIR/STATE_DIR).
    export STATE_DIR="$SANDBOX/state"
    export INSTALL_DIR="$SANDBOX/install"
    mkdir -p "$STATE_DIR" "$INSTALL_DIR/configs" "$INSTALL_DIR/setup" "$INSTALL_DIR/lib"

    # Системные пути роутера, которые rpcd-cheburnet читает из ETC_* env-vars
    # (см. refactor в web/rpcd-cheburnet:16-23). Все указывают в FAKE_ROOT.
    export ETC_CHEBURNET="$FAKE_ROOT/etc/cheburnet"
    export ETC_AWG_DIR="$FAKE_ROOT/etc/amnezia/amneziawg"
    export ETC_ADBLOCK_CFG="$FAKE_ROOT/etc/adblock-lean/config"
    export ETC_INIT_D="$FAKE_ROOT/etc/init.d"
    export ETC_VPN_MODE_STATE="$FAKE_ROOT/etc/vpn-mode.state"
    export USR_BIN_VPN_MODE="$FAKE_ROOT/usr/bin/vpn-mode"

    # lib подкладываем — rpcd-cheburnet source'ит cheburnet-utils.sh из
    # $INSTALL_DIR/lib/. Используем cp (не симлинк) чтобы тест видел тот же
    # код что в репо.
    cp "$REPO_ROOT/lib/cheburnet-utils.sh" "$INSTALL_DIR/lib/"

    # Моки в начале PATH
    MOCKDIR="$SANDBOX/mockdir"
    mkdir -p "$MOCKDIR"
    cp "$REPO_ROOT/tests/integration/mocks/"* "$MOCKDIR/"
    chmod +x "$MOCKDIR/"*
    export PATH="$MOCKDIR:$PATH"

    # Журнал вызовов
    CALLS_DIR="$SANDBOX/calls"
    mkdir -p "$CALLS_DIR"
    export CALLS_DIR

    # FAKE_ROOT — куда моки uci/awg должны смотреть вместо реального /
    # (см. mocks/uci, mocks/awg). Также используется хелперами ниже.
}

sandbox_cleanup() {
    [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
}

# ─────────────────────────────────────────────────────────────────────────────
# Подготовка состояния роутера
# ─────────────────────────────────────────────────────────────────────────────

# Создать install-токен (как это делает bootstrap.sh)
sandbox_set_token() {
    local token="${1:-$(head -c 16 /dev/urandom | hexdump -e '16/1 "%02x"')}"
    printf '%s' "$token" > "$FAKE_ROOT/etc/cheburnet/install-token"
    chmod 600 "$FAKE_ROOT/etc/cheburnet/install-token"
    echo "$token"
}

sandbox_remove_token() {
    rm -f "$FAKE_ROOT/etc/cheburnet/install-token"
}

# Симулировать «после успешной установки» — кладём ACL-lock конфиг и
# отмечаем что VPN установлен.
sandbox_mark_installed() {
    cat > "$FAKE_ROOT/usr/share/rpcd/acl.d/cheburnet.json" <<'ACL'
{
    "unauthenticated": {
        "description": "cheburnet read-only status (post-install LAN-локально)",
        "read": { "ubus": { "cheburnet": ["get_status", "install_progress"] } }
    },
    "cheburnet-admin": {
        "description": "cheburnet admin (login as root required)",
        "read":  { "ubus": { "cheburnet": ["get_status", "install_progress"] } },
        "write": { "ubus": { "cheburnet": ["install_start", "install_cancel", "mode_switch", "service_restart", "set_blocklist_tier", "factory_reset"] } }
    }
}
ACL
    # awg0.conf + podkop init — get_status видит установку
    : > "$FAKE_ROOT/etc/amnezia/amneziawg/awg0.conf"
    cat > "$FAKE_ROOT/etc/init.d/podkop" <<'EOF'
#!/bin/sh
echo "Service podkop is running"
EOF
    chmod +x "$FAKE_ROOT/etc/init.d/podkop"
    # Удаляем токен (как run-install.sh)
    sandbox_remove_token
}

# ─────────────────────────────────────────────────────────────────────────────
# Запуск rpcd-cheburnet
# ─────────────────────────────────────────────────────────────────────────────

# run_rpcd METHOD [JSON_INPUT]
# Эмулирует то, что делает rpcd: вызывает скрипт с "call <method>", JSON на stdin.
# Stdout — JSON-ответ; журнал моков — в $CALLS_DIR.
run_rpcd() {
    local method="$1"
    local input="${2:-{\}}"
    # Передаём $input через stdin
    printf '%s' "$input" | "$REPO_ROOT/web/rpcd-cheburnet" call "$method"
}

# run_rpcd_list — вызывает list-метод (description методов)
run_rpcd_list() {
    "$REPO_ROOT/web/rpcd-cheburnet" list
}

# ─────────────────────────────────────────────────────────────────────────────
# JSON-хелперы (через python3 — он уже есть в T2)
# ─────────────────────────────────────────────────────────────────────────────

# json_get JSON_STRING JQ_PATH
# Печатает значение по jq-style пути. Возвращает 1 если пути нет.
# Пример: json_get "$output" .install_token_required
json_get() {
    printf '%s' "$1" | python3 -c '
import json, sys
data = json.load(sys.stdin)
path = sys.argv[1].lstrip(".").split(".")
for p in path:
    if isinstance(data, dict) and p in data:
        data = data[p]
    else:
        sys.exit(1)
if isinstance(data, bool):
    print("true" if data else "false")
elif data is None:
    print("null")
else:
    print(data)
' "$2"
}

# assert_json_field — assertion-удобство.
# assert_json_field JSON_STRING .path expected_value
assert_json_field() {
    local actual
    actual="$(json_get "$1" "$2")" || {
        echo "json path '$2' not found in:"
        echo "$1"
        return 1
    }
    if [ "$actual" != "$3" ]; then
        echo "json field '$2' mismatch:"
        echo "  expected: $3"
        echo "  actual:   $actual"
        echo "  full json:"
        echo "$1"
        return 1
    fi
}

# Проверить что mock был вызван хотя бы раз с заданным argv-substring.
# assert_mock_called CMD SUBSTRING
assert_mock_called() {
    local cmd="$1" needle="$2"
    if [ ! -f "$CALLS_DIR/$cmd" ]; then
        echo "mock '$cmd' was never called"
        return 1
    fi
    if ! grep -qF -- "$needle" "$CALLS_DIR/$cmd"; then
        echo "mock '$cmd' was called, but not with '$needle'. log:"
        cat "$CALLS_DIR/$cmd"
        return 1
    fi
}
