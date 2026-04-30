#!/usr/bin/env bats
# Сценарии #1, #2, #3 из спеки T3 (адаптировано под mock-окружение):
# - bootstrap создал токен → get_status должен сообщать install_token_required: true
# - после install_progress / lock-acl токен исчезает → install_token_required: false
# - DNS-probe возвращает корректный dns_up / podkop_up

load 'helpers/sandbox'

setup() {
    sandbox_init
}

teardown() {
    sandbox_cleanup
}

@test "get_status: pre-install (токен на месте) → install_token_required=true, install_type=none" {
    sandbox_set_token "deadbeefcafebabe1234567890abcdef" >/dev/null
    run run_rpcd get_status
    assert_success
    assert_json_field "$output" .install_token_required "true"
    assert_json_field "$output" .install_type "none"
    assert_json_field "$output" .installing "false"
}

@test "get_status: post-install (токена нет, awg0.conf+podkop есть) → install_token_required=false, install_type=vpn" {
    sandbox_mark_installed
    run run_rpcd get_status
    assert_success
    assert_json_field "$output" .install_token_required "false"
    assert_json_field "$output" .install_type "vpn"
}

@test "get_status: dns_up=false когда dnsmasq не running" {
    sandbox_set_token >/dev/null
    # dnsmasq init.d отсутствует → status fail → dns_up false
    run run_rpcd get_status
    assert_success
    assert_json_field "$output" .dns_up "false"
}

@test "get_status: dns_up=true когда dnsmasq running и nslookup отвечает" {
    sandbox_set_token >/dev/null
    # Мокаем dnsmasq init.d как running
    cat > "$FAKE_ROOT/etc/init.d/dnsmasq" <<'EOF'
#!/bin/sh
echo "Service dnsmasq is running"
EOF
    chmod +x "$FAKE_ROOT/etc/init.d/dnsmasq"
    ETC_INIT_D="$FAKE_ROOT/etc/init.d" run run_rpcd get_status
    assert_success
    assert_json_field "$output" .dns_up "true"
}

@test "get_status: dns_up=false когда dnsmasq running но nslookup падает" {
    sandbox_set_token >/dev/null
    cat > "$FAKE_ROOT/etc/init.d/dnsmasq" <<'EOF'
#!/bin/sh
echo "Service dnsmasq is running"
EOF
    chmod +x "$FAKE_ROOT/etc/init.d/dnsmasq"
    : > "$FAKE_ROOT/dns-broken"
    ETC_INIT_D="$FAKE_ROOT/etc/init.d" run run_rpcd get_status
    assert_success
    assert_json_field "$output" .dns_up "false"
}

@test "get_status: возвращает валидный JSON" {
    sandbox_set_token >/dev/null
    run run_rpcd get_status
    assert_success
    # Если JSON битый — python кинет exception
    printf '%s' "$output" | python3 -m json.tool >/dev/null
}
