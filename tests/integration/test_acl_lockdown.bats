#!/usr/bin/env bats
# Сценарии #7, #8 спеки T3 — инвариант ACL.
#
# Реальный rpcd-enforce'ит ACL только в полной OpenWrt-VM (T3b). На уровне
# протокола мы можем гарантировать главное: ACL-файлы (pre-install и тот, что
# run-install.sh пишет post-install) имеют ПРАВИЛЬНУЮ структуру. Если эти
# инварианты сломаются — атаку через unauth.write словит злоумышленник, не CI.

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

PRE_ACL="$REPO_ROOT/web/rpcd-acl.json"
POST_ACL_RUN="$REPO_ROOT/web/run-install.sh"
POST_ACL_FULL="$REPO_ROOT/setup/full-deploy.sh"

# ─── Pre-install ACL (web/rpcd-acl.json) ────────────────────────────────────

@test "pre-install ACL: валидный JSON" {
    python3 -m json.tool "$PRE_ACL" >/dev/null
}

@test "pre-install ACL: unauth.read содержит только get_status и install_progress" {
    methods="$(acl_methods "$PRE_ACL" .unauthenticated.read.ubus.cheburnet)"
    [ "$methods" = "get_status install_progress" ]
}

@test "pre-install ACL: unauth.write содержит ТОЛЬКО install_start + install_cancel" {
    methods="$(acl_methods "$PRE_ACL" .unauthenticated.write.ubus.cheburnet)"
    [ "$methods" = "install_cancel install_start" ]
}

# Параметризованная проверка: ни один из мутирующих методов НЕ должен попасть
# в unauth.write до установки. Запрещённые методы перечислены явно — если
# завтра в unauth.write попадёт mode_switch, тест #4 покраснеет.
@test "pre-install ACL: НЕТ запрещённых методов в unauth.write" {
    for forbidden in mode_switch factory_reset set_blocklist_tier service_restart; do
        if acl_has "$PRE_ACL" .unauthenticated.write.ubus.cheburnet "$forbidden"; then
            echo "FAIL: '$forbidden' попал в pre-install unauth.write" >&2
            return 1
        fi
    done
}

# ─── Post-install ACL (записан run-install.sh / full-deploy.sh) ─────────────

@test "post-install ACL: heredoc в run-install.sh — валидный JSON" {
    extract_acl_heredoc "$POST_ACL_RUN" | python3 -m json.tool >/dev/null
}

@test "post-install ACL: heredoc в full-deploy.sh — валидный JSON" {
    extract_acl_heredoc "$POST_ACL_FULL" | python3 -m json.tool >/dev/null
}

@test "post-install ACL: unauth.write ОТСУТСТВУЕТ — мутации только через login" {
    body="$(extract_acl_heredoc "$POST_ACL_RUN")"
    printf '%s' "$body" | python3 -c '
import json, sys
acl = json.load(sys.stdin)
write = acl.get("unauthenticated", {}).get("write")
assert write is None or write == {} or write == {"ubus": {}}, \
    f"unauth.write present in post-install ACL: {write}"
'
}

@test "post-install ACL: unauth.read содержит ТОЛЬКО get_status + install_progress" {
    methods="$(extract_acl_heredoc "$POST_ACL_RUN" \
               | acl_methods_in_stdin .unauthenticated.read.ubus.cheburnet)"
    [ "$methods" = "get_status install_progress" ]
}

@test "post-install ACL: cheburnet-admin.write содержит ВСЕ мутирующие методы" {
    methods="$(extract_acl_heredoc "$POST_ACL_RUN" \
               | acl_methods_in_stdin .cheburnet-admin.write.ubus.cheburnet)"
    expected="factory_reset install_cancel install_start mode_switch service_restart set_blocklist_tier"
    [ "$methods" = "$expected" ]
}

@test "post-install ACL: cheburnet-admin.read покрывает get_status + install_progress" {
    methods="$(extract_acl_heredoc "$POST_ACL_RUN" \
               | acl_methods_in_stdin .cheburnet-admin.read.ubus.cheburnet)"
    [ "$methods" = "get_status install_progress" ]
}

@test "post-install ACL: run-install.sh и full-deploy.sh пишут БИТ-в-БИТ одинаковый ACL" {
    a="$(extract_acl_heredoc "$POST_ACL_RUN")"
    b="$(extract_acl_heredoc "$POST_ACL_FULL")"
    [ "$a" = "$b" ]
}

# ─── install-токен: post-install контракт ───────────────────────────────────

@test "post-install: run-install.sh удаляет install-токен (grep'ом по коду)" {
    grep -q "rm -f /etc/cheburnet/install-token" "$POST_ACL_RUN"
}

@test "post-install: full-deploy.sh тоже удаляет install-токен" {
    grep -q "rm -f /etc/cheburnet/install-token" "$POST_ACL_FULL"
}

@test "bootstrap.sh создаёт install-токен (32 hex символа, chmod 600)" {
    grep -q "head -c 16 /dev/urandom" "$REPO_ROOT/bootstrap.sh"
    grep -q 'chmod 600 /etc/cheburnet/install-token' "$REPO_ROOT/bootstrap.sh"
}
