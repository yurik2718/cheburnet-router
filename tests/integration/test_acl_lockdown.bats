#!/usr/bin/env bats
# Сценарии #7, #8 спеки T3 — инвариант ACL.
#
# Реальный rpcd-enforce'ит ACL только в полной OpenWrt-VM (T3b). На уровне
# протокола мы можем гарантировать главное: ACL-файлы (pre-install и тот, что
# run-install.sh пишет post-install) имеют ПРАВИЛЬНУЮ структуру. Если эти
# инварианты сломаются — атаку через unauth.write словит злоумышленник, не CI.
#
# Поэтому тесты тут — про два контракта:
#   1. web/rpcd-acl.json (pre-install): unauth.write содержит ТОЛЬКО
#      install_start + install_cancel. Никаких mode_switch/factory_reset/etc.
#   2. ACL, который run-install.sh / setup/full-deploy.sh пишут после успешной
#      установки: unauth.write вообще отсутствует или пуст; все мутирующие
#      методы перешли в cheburnet-admin.write.

load 'helpers/sandbox'

setup() {
    sandbox_init
}

teardown() {
    sandbox_cleanup
}

# Извлечь embedded heredoc <<'ACL' из shell-скрипта.
extract_acl_heredoc() {
    sed -n "/<<'ACL'/,/^ACL$/p" "$1" | sed "/<<'ACL'/d;/^ACL$/d"
}

# ─── Pre-install ACL (web/rpcd-acl.json) ────────────────────────────────────

@test "pre-install ACL: валидный JSON" {
    python3 -m json.tool "$REPO_ROOT/web/rpcd-acl.json" >/dev/null
}

@test "pre-install ACL: unauth.read содержит только get_status и install_progress" {
    methods="$(python3 -c "
import json
acl = json.load(open('$REPO_ROOT/web/rpcd-acl.json'))
print(' '.join(sorted(acl['unauthenticated']['read']['ubus']['cheburnet'])))
")"
    [ "$methods" = "get_status install_progress" ]
}

@test "pre-install ACL: unauth.write содержит ТОЛЬКО install_start + install_cancel" {
    methods="$(python3 -c "
import json
acl = json.load(open('$REPO_ROOT/web/rpcd-acl.json'))
print(' '.join(sorted(acl['unauthenticated']['write']['ubus']['cheburnet'])))
")"
    [ "$methods" = "install_cancel install_start" ]
}

@test "pre-install ACL: НЕТ mode_switch в unauth.write (защита до установки)" {
    output="$(python3 -c "
import json
acl = json.load(open('$REPO_ROOT/web/rpcd-acl.json'))
methods = acl['unauthenticated']['write']['ubus']['cheburnet']
assert 'mode_switch' not in methods, methods
")"
}

@test "pre-install ACL: НЕТ factory_reset в unauth.write (защита до установки)" {
    python3 -c "
import json
acl = json.load(open('$REPO_ROOT/web/rpcd-acl.json'))
methods = acl['unauthenticated']['write']['ubus']['cheburnet']
assert 'factory_reset' not in methods, methods
"
}

@test "pre-install ACL: НЕТ set_blocklist_tier в unauth.write" {
    python3 -c "
import json
acl = json.load(open('$REPO_ROOT/web/rpcd-acl.json'))
methods = acl['unauthenticated']['write']['ubus']['cheburnet']
assert 'set_blocklist_tier' not in methods, methods
"
}

@test "pre-install ACL: НЕТ service_restart в unauth.write" {
    python3 -c "
import json
acl = json.load(open('$REPO_ROOT/web/rpcd-acl.json'))
methods = acl['unauthenticated']['write']['ubus']['cheburnet']
assert 'service_restart' not in methods, methods
"
}

# ─── Post-install ACL (записан run-install.sh / full-deploy.sh) ─────────────

@test "post-install ACL: heredoc в run-install.sh — валидный JSON" {
    extract_acl_heredoc "$REPO_ROOT/web/run-install.sh" | python3 -m json.tool >/dev/null
}

@test "post-install ACL: heredoc в full-deploy.sh — валидный JSON" {
    extract_acl_heredoc "$REPO_ROOT/setup/full-deploy.sh" | python3 -m json.tool >/dev/null
}

@test "post-install ACL: unauth.write ОТСУТСТВУЕТ (или пустой) — мутации только через login" {
    body="$(extract_acl_heredoc "$REPO_ROOT/web/run-install.sh")"
    printf '%s' "$body" | python3 -c "
import json, sys
acl = json.load(sys.stdin)
write = acl.get('unauthenticated', {}).get('write')
assert write is None or write == {} or write == {'ubus': {}}, f'unauth.write present: {write}'
"
}

@test "post-install ACL: unauth.read содержит ТОЛЬКО get_status + install_progress" {
    body="$(extract_acl_heredoc "$REPO_ROOT/web/run-install.sh")"
    methods="$(printf '%s' "$body" | python3 -c "
import json, sys
acl = json.load(sys.stdin)
print(' '.join(sorted(acl['unauthenticated']['read']['ubus']['cheburnet'])))
")"
    [ "$methods" = "get_status install_progress" ]
}

@test "post-install ACL: cheburnet-admin.write содержит ВСЕ мутирующие методы" {
    body="$(extract_acl_heredoc "$REPO_ROOT/web/run-install.sh")"
    methods="$(printf '%s' "$body" | python3 -c "
import json, sys
acl = json.load(sys.stdin)
print(' '.join(sorted(acl['cheburnet-admin']['write']['ubus']['cheburnet'])))
")"
    expected="factory_reset install_cancel install_start mode_switch service_restart set_blocklist_tier"
    [ "$methods" = "$expected" ]
}

@test "post-install ACL: cheburnet-admin.read покрывает get_status + install_progress" {
    body="$(extract_acl_heredoc "$REPO_ROOT/web/run-install.sh")"
    methods="$(printf '%s' "$body" | python3 -c "
import json, sys
acl = json.load(sys.stdin)
print(' '.join(sorted(acl['cheburnet-admin']['read']['ubus']['cheburnet'])))
")"
    [ "$methods" = "get_status install_progress" ]
}

@test "post-install ACL: run-install.sh и full-deploy.sh пишут БИТ-в-БИТ одинаковый ACL" {
    a="$(extract_acl_heredoc "$REPO_ROOT/web/run-install.sh")"
    b="$(extract_acl_heredoc "$REPO_ROOT/setup/full-deploy.sh")"
    [ "$a" = "$b" ]
}

# ─── install-токен: post-install контракт ───────────────────────────────────

@test "post-install: run-install.sh удаляет install-токен (grep'ом по коду)" {
    grep -q "rm -f /etc/cheburnet/install-token" "$REPO_ROOT/web/run-install.sh"
}

@test "post-install: full-deploy.sh тоже удаляет install-токен" {
    grep -q "rm -f /etc/cheburnet/install-token" "$REPO_ROOT/setup/full-deploy.sh"
}

@test "bootstrap.sh создаёт install-токен (32 hex символа, chmod 600)" {
    grep -q "head -c 16 /dev/urandom" "$REPO_ROOT/bootstrap.sh"
    grep -q 'chmod 600 /etc/cheburnet/install-token' "$REPO_ROOT/bootstrap.sh"
}
