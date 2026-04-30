#!/usr/bin/env bats
# Тесты парсера AmneziaWG-конфига: awg_get_iface, awg_get_peer,
# awg_endpoint_host, awg_endpoint_port.

load '../helpers/setup'

# ─── awg_get_iface — поля из [Interface] секции ─────────────────────────────

@test "awg_get_iface: PrivateKey из v1.0 минимального конфига" {
    run awg_get_iface PrivateKey "$FIXTURES/awg-v1.0-minimal.conf"
    assert_success
    # awk -F' *= *' обрезает trailing '=' base64-padding — это поведение
    # оригинального get_iface, сохраняем его (воссоздание AWG-ключа делает
    # awg(8), а не парсер).
    assert_output 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA'
}

@test "awg_get_iface: Address" {
    run awg_get_iface Address "$FIXTURES/awg-v1.0-minimal.conf"
    assert_success
    assert_output '10.8.0.2/32'
}

@test "awg_get_iface: Jc/Jmin/Jmax (AWG v1.0 obfuscation params)" {
    run awg_get_iface Jc "$FIXTURES/awg-v1.0-minimal.conf"
    assert_output '4'
    run awg_get_iface Jmin "$FIXTURES/awg-v1.0-minimal.conf"
    assert_output '50'
    run awg_get_iface Jmax "$FIXTURES/awg-v1.0-minimal.conf"
    assert_output '1000'
}

@test "awg_get_iface: S1/S2/H1-H4 (header obfuscation)" {
    run awg_get_iface S1 "$FIXTURES/awg-v1.0-minimal.conf"
    assert_output '100'
    run awg_get_iface H4 "$FIXTURES/awg-v1.0-minimal.conf"
    assert_output '4567890123'
}

@test "awg_get_iface: отсутствующее поле возвращает пустую строку (не падает)" {
    run awg_get_iface S3 "$FIXTURES/awg-v1.0-minimal.conf"
    assert_success
    assert_output ''
}

@test "awg_get_iface: S3/S4 присутствуют в v1.5 конфиге" {
    run awg_get_iface S3 "$FIXTURES/awg-v1.5-full.conf"
    assert_output '11'
    run awg_get_iface S4 "$FIXTURES/awg-v1.5-full.conf"
    assert_output '22'
}

@test "awg_get_iface: I1-I5 (Custom Protocol Signature, AWG v1.5)" {
    run awg_get_iface I1 "$FIXTURES/awg-v1.5-full.conf"
    assert_output '<b 0x0102030405>'
    run awg_get_iface I3 "$FIXTURES/awg-v1.5-full.conf"
    assert_output '<r 64>'
    run awg_get_iface I5 "$FIXTURES/awg-v1.5-full.conf"
    assert_output '<r 32>'
}

@test "awg_get_iface: I1-I5 отсутствуют в v1.0 → пусто" {
    run awg_get_iface I1 "$FIXTURES/awg-v1.0-minimal.conf"
    assert_output ''
    run awg_get_iface I5 "$FIXTURES/awg-v1.0-minimal.conf"
    assert_output ''
}

# ─── awg_get_peer — поля после [Peer] маркера ──────────────────────────────

@test "awg_get_peer: PublicKey" {
    run awg_get_peer PublicKey "$FIXTURES/awg-v1.0-minimal.conf"
    assert_success
    assert_output 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA'
}

@test "awg_get_peer: PresharedKey" {
    run awg_get_peer PresharedKey "$FIXTURES/awg-v1.0-minimal.conf"
    assert_output 'ccccccccccccccccccccccccccccccccccccccccccA'
}

@test "awg_get_peer: Endpoint (IPv4)" {
    run awg_get_peer Endpoint "$FIXTURES/awg-v1.0-minimal.conf"
    assert_output '1.2.3.4:51820'
}

@test "awg_get_peer: PersistentKeepalive" {
    run awg_get_peer PersistentKeepalive "$FIXTURES/awg-v1.0-minimal.conf"
    assert_output '25'
}

@test "awg_get_peer: Endpoint с DNS-именем (v1.5 fixture)" {
    run awg_get_peer Endpoint "$FIXTURES/awg-v1.5-full.conf"
    assert_output 'vpn.example.com:51820'
}

@test "awg_get_peer: отсутствующая [Peer] секция → пусто (не падает)" {
    run awg_get_peer PublicKey "$FIXTURES/awg-incomplete-no-peer.conf"
    assert_success
    assert_output ''
    run awg_get_peer Endpoint "$FIXTURES/awg-incomplete-no-peer.conf"
    assert_success
    assert_output ''
}

@test "awg_get_peer: PresharedKey отсутствует — пусто (PSK опционален)" {
    run awg_get_peer PresharedKey "$FIXTURES/awg-ipv6-endpoint.conf"
    assert_success
    assert_output ''
}

# ─── awg_endpoint_host / awg_endpoint_port ─────────────────────────────────

@test "awg_endpoint_host: IPv4 host:port" {
    run awg_endpoint_host '1.2.3.4:51820'
    assert_success
    assert_output '1.2.3.4'
}

@test "awg_endpoint_port: IPv4 host:port" {
    run awg_endpoint_port '1.2.3.4:51820'
    assert_success
    assert_output '51820'
}

@test "awg_endpoint_host: DNS-имя host:port" {
    run awg_endpoint_host 'vpn.example.com:51820'
    assert_output 'vpn.example.com'
}

@test "awg_endpoint_port: DNS-имя host:port" {
    run awg_endpoint_port 'vpn.example.com:51820'
    assert_output '51820'
}

@test "awg_endpoint_host: IPv6 [::1]:port → '[::1]'" {
    # Bracket-формат — стандарт wg-quick для IPv6. Скобки сохраняются.
    run awg_endpoint_host '[::1]:51820'
    assert_success
    assert_output '[::1]'
}

@test "awg_endpoint_port: IPv6 [::1]:port → '51820'" {
    run awg_endpoint_port '[::1]:51820'
    assert_success
    assert_output '51820'
}

@test "awg_endpoint_host: IPv6 со скобками и полным адресом" {
    run awg_endpoint_host '[2001:db8::cafe]:51820'
    assert_output '[2001:db8::cafe]'
    run awg_endpoint_port '[2001:db8::cafe]:51820'
    assert_output '51820'
}

@test "awg_endpoint: round-trip из реального конфига (IPv6 fixture)" {
    ep="$(awg_get_peer Endpoint "$FIXTURES/awg-ipv6-endpoint.conf")"
    [ "$ep" = '[2001:db8::1]:51820' ]
    [ "$(awg_endpoint_host "$ep")" = '[2001:db8::1]' ]
    [ "$(awg_endpoint_port "$ep")" = '51820' ]
}
