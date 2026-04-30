#!/usr/bin/env bats
# Сценарии #4-#6 спеки T3 (через mock-окружение, не через uhttpd POST):
# защита install_start от LAN-сквоттинга через install-токен.

load 'helpers/sandbox'

setup() {
    sandbox_init
}

teardown() {
    sandbox_cleanup
}

# Минимальный AWG-конфиг с обязательными секциями.
# Передаём в python через env-переменную VALID_AWG_CONF — это устраняет
# bash/python quoting-проблемы с многострочной строкой и спецсимволами
# (см. историю: один и тот же хак с triple-quote работает на Fedora bash 5.2,
# но падает в Ubuntu CI runner'е с другим shell-парсером).
VALID_AWG_CONF="$(cat <<'EOF'
[Interface]
PrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=
Address = 10.8.0.2/32

[Peer]
PublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=
Endpoint = 1.2.3.4:51820
EOF
)"
export VALID_AWG_CONF

# build_payload SSID WIFI_KEY ROOT_PASS AWG_CONF TOKEN [COUNTRY=RU]
# Собирает install_start-payload через env+heredoc — устойчиво к любому
# содержимому полей. Все аргументы передаются через os.environ.
build_payload() {
    SSID="$1" WIFI_KEY="$2" ROOT_PASS="$3" AWG_CONF="$4" TOKEN="$5" COUNTRY="${6:-RU}" \
    python3 <<'PY'
import json, os
print(json.dumps({
    "token":     os.environ["TOKEN"],
    "ssid":      os.environ["SSID"],
    "wifi_key":  os.environ["WIFI_KEY"],
    "country":   os.environ["COUNTRY"],
    "awg_conf":  os.environ["AWG_CONF"],
    "root_pass": os.environ["ROOT_PASS"],
}))
PY
}

# valid_payload TOKEN — backward-compat обёртка
valid_payload() {
    build_payload "TestNet" "longenoughpassword" "longenoughpassword" "$VALID_AWG_CONF" "$1"
}

# ─── Защита токеном ─────────────────────────────────────────────────────────

@test "install_start: отсутствие токен-файла → 'install token not found'" {
    sandbox_remove_token
    payload="$(valid_payload "deadbeef0000")"
    run run_rpcd install_start "$payload"
    assert_success  # rpcd-cheburnet всегда exit 0, ошибки в JSON
    assert_output --partial "install token not found"
}

@test "install_start: токен в payload отсутствует → 'invalid install token'" {
    sandbox_set_token "abcdef1234567890abcdef1234567890" >/dev/null
    # payload с пустым token
    payload='{"ssid":"X","wifi_key":"longenough","country":"RU","awg_conf":"x","root_pass":"longenough"}'
    run run_rpcd install_start "$payload"
    assert_success
    assert_output --partial "invalid install token"
}

@test "install_start: неверный токен → 'invalid install token'" {
    sandbox_set_token "abcdef1234567890abcdef1234567890" >/dev/null
    payload="$(valid_payload "wrongwrongwrongwrongwrongwrongwr")"
    run run_rpcd install_start "$payload"
    assert_success
    assert_output --partial "invalid install token"
}

@test "install_start: правильный токен + валидные поля → status=started, PID > 0" {
    token="$(sandbox_set_token "abcdef1234567890abcdef1234567890")"
    payload="$(valid_payload "$token")"
    run run_rpcd install_start "$payload"
    assert_success
    assert_json_field "$output" .status "started"
    pid="$(json_get "$output" .pid)"
    [ "$pid" -gt 0 ]
}

# ─── Валидация полей (после прохождения токена) ─────────────────────────────

@test "install_start: пустой ssid → 'ssid required'" {
    token="$(sandbox_set_token)"
    payload="$(build_payload "" "longenough" "longenough" "$VALID_AWG_CONF" "$token")"
    run run_rpcd install_start "$payload"
    assert_output --partial "ssid required"
}

@test "install_start: короткий wifi_key (<8) → 'wifi_key must be >= 8 chars'" {
    token="$(sandbox_set_token)"
    payload="$(build_payload "X" "short" "longenough" "$VALID_AWG_CONF" "$token")"
    run run_rpcd install_start "$payload"
    assert_output --partial "wifi_key must be >= 8"
}

@test "install_start: короткий root_pass (<8) → 'root_pass must be >= 8 chars'" {
    token="$(sandbox_set_token)"
    payload="$(build_payload "X" "longenough" "short" "$VALID_AWG_CONF" "$token")"
    run run_rpcd install_start "$payload"
    assert_output --partial "root_pass must be >= 8"
}

@test "install_start: AWG-конфиг без [Interface] → ошибка валидации" {
    token="$(sandbox_set_token)"
    bad_conf="$(printf '[Peer]\nPublicKey = xxx')"
    payload="$(build_payload "X" "longenough" "longenough" "$bad_conf" "$token")"
    run run_rpcd install_start "$payload"
    assert_output --partial "[Interface]"
}

@test "install_start: AWG-конфиг без [Peer] → ошибка валидации" {
    token="$(sandbox_set_token)"
    bad_conf="$(printf '[Interface]\nPrivateKey = xxx\nAddress = 10.8.0.2/32')"
    payload="$(build_payload "X" "longenough" "longenough" "$bad_conf" "$token")"
    run run_rpcd install_start "$payload"
    assert_output --partial "[Peer]"
}

@test "install_start: токен сравнивается побайтно (timing-safe не требуется, но префикс != полный токен)" {
    token="$(sandbox_set_token "abcdef1234567890abcdef1234567890")"
    # Префикс правильного токена — должен быть отвергнут
    payload="$(valid_payload "abcdef")"
    run run_rpcd install_start "$payload"
    assert_output --partial "invalid install token"
}
