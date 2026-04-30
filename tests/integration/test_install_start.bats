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

# Минимальный AWG-конфиг с обязательными секциями
read -r -d '' VALID_AWG_CONF <<'EOF' || true
[Interface]
PrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=
Address = 10.8.0.2/32

[Peer]
PublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=
Endpoint = 1.2.3.4:51820
EOF

valid_payload() {
    local token="$1"
    python3 -c "
import json
print(json.dumps({
    'token':     '$token',
    'ssid':      'TestNet',
    'wifi_key':  'longenoughpassword',
    'country':   'RU',
    'awg_conf':  '''$VALID_AWG_CONF''',
    'root_pass': 'longenoughpassword',
}))
"
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
    payload="$(python3 -c "import json; print(json.dumps({'token':'$token','ssid':'','wifi_key':'longenough','country':'RU','awg_conf':'''$VALID_AWG_CONF''','root_pass':'longenough'}))")"
    run run_rpcd install_start "$payload"
    assert_output --partial "ssid required"
}

@test "install_start: короткий wifi_key (<8) → 'wifi_key must be >= 8 chars'" {
    token="$(sandbox_set_token)"
    payload="$(python3 -c "import json; print(json.dumps({'token':'$token','ssid':'X','wifi_key':'short','country':'RU','awg_conf':'''$VALID_AWG_CONF''','root_pass':'longenough'}))")"
    run run_rpcd install_start "$payload"
    assert_output --partial "wifi_key must be >= 8"
}

@test "install_start: короткий root_pass (<8) → 'root_pass must be >= 8 chars'" {
    token="$(sandbox_set_token)"
    payload="$(python3 -c "import json; print(json.dumps({'token':'$token','ssid':'X','wifi_key':'longenough','country':'RU','awg_conf':'''$VALID_AWG_CONF''','root_pass':'short'}))")"
    run run_rpcd install_start "$payload"
    assert_output --partial "root_pass must be >= 8"
}

@test "install_start: AWG-конфиг без [Interface] → ошибка валидации" {
    token="$(sandbox_set_token)"
    bad_conf="$(printf '[Peer]\nPublicKey = xxx')"
    payload="$(BAD_CONF="$bad_conf" TOKEN="$token" python3 <<'PY'
import json, os
print(json.dumps({
    "token": os.environ["TOKEN"],
    "ssid": "X", "wifi_key": "longenough", "country": "RU",
    "awg_conf": os.environ["BAD_CONF"], "root_pass": "longenough",
}))
PY
)"
    run run_rpcd install_start "$payload"
    assert_output --partial "[Interface]"
}

@test "install_start: AWG-конфиг без [Peer] → ошибка валидации" {
    token="$(sandbox_set_token)"
    bad_conf="$(printf '[Interface]\nPrivateKey = xxx\nAddress = 10.8.0.2/32')"
    payload="$(BAD_CONF="$bad_conf" TOKEN="$token" python3 <<'PY'
import json, os
print(json.dumps({
    "token": os.environ["TOKEN"],
    "ssid": "X", "wifi_key": "longenough", "country": "RU",
    "awg_conf": os.environ["BAD_CONF"], "root_pass": "longenough",
}))
PY
)"
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
