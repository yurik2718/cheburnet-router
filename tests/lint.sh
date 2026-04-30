#!/usr/bin/env bash
# tests/lint.sh — статические проверки cheburnet-router.
#
# Один и тот же скрипт вызывается из CI (.github/workflows/lint.yml) и локально
# через `make lint`. Никакой логики не должно быть в Makefile/CI помимо вызова
# этого файла — DRY.
#
# Что проверяется:
#   1. shellcheck --shell=sh   на всех POSIX-скриптах (роутер = busybox-ash)
#   2. shellcheck --shell=bash на хост-тулинге (setup.sh)
#   3. sh -n / bash -n         синтаксис (safety net поверх shellcheck)
#   4. JSON-валидность         web/rpcd-acl.json + embedded ACL-heredoc'и
#   5. SHA-sync                sha256(bootstrap.sh) совпадает с захардкоженным
#                               значением в README.md (строка sha256sum -c -)
#
# Любой провал → exit 1.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1

# === Списки файлов ===
# POSIX sh — всё что идёт на роутер (busybox-ash) или на хост, но без bash-фич.
POSIX_FILES=(
    bootstrap.sh
    lib/cheburnet-utils.sh
    web/run-install.sh
    web/rpcd-cheburnet
    setup/00-prerequisites.sh
    setup/01-amneziawg.sh
    setup/02-podkop.sh
    setup/03-adblock.sh
    setup/04-dns.sh
    setup/05-wifi.sh
    setup/06-vpn-mode.sh
    setup/07-killswitch.sh
    setup/08-watchdog.sh
    setup/09-ssh-hardening.sh
    setup/10-quality.sh
    setup/11-travel.sh
    setup/12-travel-plus.sh
    setup/full-deploy.sh
    setup/post-upgrade.sh
    scripts/awg-watchdog
    scripts/conntrack-monitor
    scripts/conntrack-tune
    scripts/dns-healthcheck
    scripts/dns-provider
    scripts/log-snapshot
    scripts/net-benchmark
    scripts/sqm-tune
    scripts/travel-check
    scripts/travel-connect
    scripts/travel-mac
    scripts/travel-portal
    scripts/travel-scan
    scripts/travel-tether
    scripts/travel-vpn-on
    scripts/travel-wifi
    scripts/vpn-mode
    scripts/hotplug/button/10-vpn-mode
    scripts/init.d/vpn-mode
    backup/backup.sh
    backup/restore.sh
)

BASH_FILES=(
    setup.sh
    tests/lint.sh
    tests/helpers/setup.bash
    tests/integration/helpers/sandbox.bash
    tests/integration/mocks/uci
    tests/integration/mocks/awg
    tests/integration/mocks/wget
    tests/integration/mocks/nslookup
    tests/integration/mocks/apk
    tests/integration/mocks/awg-quick
    tests/integration/mocks/firstboot
    tests/integration/mocks/ifup
    tests/integration/mocks/ifdown
    tests/integration/mocks/logger
    tests/integration/mocks/lsmod
    tests/integration/mocks/modprobe
    tests/integration/mocks/passwd
    tests/integration/mocks/reboot
    tests/integration/mocks/setsid
)

# .bats-файлы прогоняются bats-парсером, но как обычный bash они тоже должны
# быть валидны. Shellcheck с --shell=bash на них работает (через `--ext=bats`
# не нужно — bats-синтаксис надмножество bash).
BATS_FILES=(
    tests/unit/test_json_escape.bats
    tests/unit/test_awg_conf_parser.bats
    tests/unit/test_awg_version_selection.bats
    tests/unit/test_input_validation.bats
    tests/integration/test_get_status.bats
    tests/integration/test_install_start.bats
    tests/integration/test_mutations.bats
    tests/integration/test_acl_lockdown.bats
    tests/integration/test_protocol.bats
)

# === Цветовой helper ===
if [ -t 1 ]; then
    R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; N=$'\033[0m'
else
    R=""; G=""; Y=""; N=""
fi

FAILS=0
section() { printf '\n%s━━━ %s ━━━%s\n' "$Y" "$1" "$N"; }
ok()      { printf '  %s✓%s %s\n' "$G" "$N" "$1"; }
fail()    { printf '  %s✗%s %s\n' "$R" "$N" "$1"; FAILS=$((FAILS + 1)); }

# === 1. shellcheck (POSIX) ===
section "shellcheck --shell=sh (severity=warning)"
if ! command -v shellcheck >/dev/null 2>&1; then
    fail "shellcheck не установлен (apt-get install shellcheck / dnf install ShellCheck)"
else
    if shellcheck --shell=sh --severity=warning --external-sources "${POSIX_FILES[@]}"; then
        ok "${#POSIX_FILES[@]} POSIX-файлов чисты"
    else
        fail "shellcheck warnings в POSIX-файлах"
    fi
fi

# === 2. shellcheck (bash) ===
section "shellcheck --shell=bash (severity=warning)"
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck --shell=bash --severity=warning --external-sources "${BASH_FILES[@]}"; then
        ok "${#BASH_FILES[@]} bash-файлов чисты"
    else
        fail "shellcheck warnings в bash-файлах"
    fi

    # .bats — надмножество bash (макрос @test переписывается в функции при
    # выполнении). Shellcheck парсит их как bash и ловит опечатки/quoting.
    # SC2317 (unused command) глушим: bats-функции не вызываются напрямую,
    # их исполняет сам bats-runner.
    if shellcheck --shell=bash --severity=warning --external-sources \
            --exclude=SC2317 "${BATS_FILES[@]}"; then
        ok "${#BATS_FILES[@]} .bats-файлов чисты"
    else
        fail "shellcheck warnings в .bats-файлах"
    fi
fi

# === 3. Синтаксис (sh -n / bash -n) ===
section "syntax check (sh -n / bash -n)"
syntax_fail=0
for f in "${POSIX_FILES[@]}"; do
    # init.d/vpn-mode имеет шебанг "#!/bin/sh /etc/rc.common" — sh -n парсит сам файл,
    # вторая часть шебанга для парсера неважна.
    if ! sh -n "$f" 2>/tmp/lint-syntax.err; then
        printf '  %s✗%s %s\n' "$R" "$N" "$f"
        cat /tmp/lint-syntax.err
        syntax_fail=1
    fi
done
for f in "${BASH_FILES[@]}"; do
    if ! bash -n "$f" 2>/tmp/lint-syntax.err; then
        printf '  %s✗%s %s\n' "$R" "$N" "$f"
        cat /tmp/lint-syntax.err
        syntax_fail=1
    fi
done
rm -f /tmp/lint-syntax.err
if [ "$syntax_fail" -eq 0 ]; then
    ok "$(( ${#POSIX_FILES[@]} + ${#BASH_FILES[@]} )) файлов парсятся без синтаксических ошибок"
else
    fail "найдены синтаксические ошибки (см. выше)"
fi

# === 4. JSON-валидность ===
section "JSON validity"
if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 не найден — пропустить JSON-проверки нельзя"
else
    # 4a. Standalone JSON
    if python3 -m json.tool web/rpcd-acl.json >/dev/null; then
        ok "web/rpcd-acl.json"
    else
        fail "web/rpcd-acl.json — невалидный JSON"
    fi

    # 4b. Embedded heredoc'и <<'ACL' ... ACL в run-install.sh и full-deploy.sh.
    # Извлекаем содержимое между маркерами и валидируем.
    extract_acl() {
        # $1 — путь к скрипту. Печатает содержимое первого ACL-heredoc'а.
        sed -n "/<<'ACL'/,/^ACL$/p" "$1" | sed "/<<'ACL'/d;/^ACL$/d"
    }

    for src in web/run-install.sh setup/full-deploy.sh; do
        body="$(extract_acl "$src")"
        if [ -z "$body" ]; then
            fail "$src — heredoc <<'ACL' не найден (формат поменялся?)"
            continue
        fi
        if printf '%s\n' "$body" | python3 -m json.tool >/dev/null 2>/tmp/lint-json.err; then
            ok "$src (embedded ACL heredoc)"
        else
            fail "$src — невалидный embedded JSON"
            cat /tmp/lint-json.err
        fi
    done
    rm -f /tmp/lint-json.err
fi

# === 5. SHA-sync: bootstrap.sh hash в README ===
section "SHA-sync (bootstrap.sh ↔ README.md)"
ACTUAL_SHA="$(sha256sum bootstrap.sh | awk '{print $1}')"
# README содержит строку вида:
#   echo "<sha256>  $BS" | sha256sum -c - && \
EXPECTED_SHA="$(grep -oE '[0-9a-f]{64}' README.md | head -1 || true)"
if [ -z "$EXPECTED_SHA" ]; then
    fail "В README.md не найдено sha256-значение"
elif [ "$ACTUAL_SHA" = "$EXPECTED_SHA" ]; then
    ok "sha256(bootstrap.sh) = $ACTUAL_SHA (совпадает с README)"
else
    fail "sha256-mismatch:"
    printf '      bootstrap.sh:  %s\n' "$ACTUAL_SHA"
    printf '      README.md:     %s\n' "$EXPECTED_SHA"
    printf '    Подсказка: обновите хэш в README.md (строка с sha256sum -c -).\n'
fi

# === Итог ===
echo
if [ "$FAILS" -eq 0 ]; then
    printf '%s✓ lint OK%s\n' "$G" "$N"
    exit 0
else
    printf '%s✗ lint FAILED — %d проверок упало%s\n' "$R" "$FAILS" "$N"
    exit 1
fi
