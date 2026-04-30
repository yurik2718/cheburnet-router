#!/usr/bin/env bats
# Контракт RPC-протокола rpcd-cheburnet:
# - list возвращает все 8 методов с правильной сигнатурой
# - install_progress корректно возвращает state/log/done
# - неизвестный метод → error
# - неизвестное действие (не list/call) → error на stderr

load 'helpers/sandbox'

setup() {
    sandbox_init
}

teardown() {
    sandbox_cleanup
}

# ─── list ───────────────────────────────────────────────────────────────────

@test "list: возвращает валидный JSON" {
    run run_rpcd_list
    assert_success
    printf '%s' "$output" | python3 -m json.tool >/dev/null
}

@test "list: содержит все 8 методов" {
    out="$(run_rpcd_list)"
    methods="$(printf '%s' "$out" | python3 -c '
import json, sys
print(" ".join(sorted(json.load(sys.stdin).keys())))
')"
    expected="factory_reset get_status install_cancel install_progress install_start mode_switch service_restart set_blocklist_tier"
    [ "$methods" = "$expected" ]
}

@test "list: install_start описывает все требуемые поля" {
    out="$(run_rpcd_list)"
    fields="$(printf '%s' "$out" | python3 -c '
import json, sys
print(" ".join(sorted(json.load(sys.stdin)["install_start"].keys())))
')"
    expected="awg_conf country root_pass ssid token wifi_key"
    [ "$fields" = "$expected" ]
}

@test "list: factory_reset требует поле confirm" {
    out="$(run_rpcd_list)"
    field="$(printf '%s' "$out" | python3 -c '
import json, sys
print(list(json.load(sys.stdin)["factory_reset"].keys())[0])
')"
    [ "$field" = "confirm" ]
}

# ─── unknown method/action ──────────────────────────────────────────────────

@test "call неизвестного метода → JSON-error" {
    run run_rpcd does_not_exist
    assert_success
    assert_output --partial "unknown method"
}

@test "неизвестное действие (не list, не call) → error на stderr, exit 1" {
    run "$REPO_ROOT/web/rpcd-cheburnet" foobar
    assert_failure
}

# ─── install_progress ───────────────────────────────────────────────────────

@test "install_progress: пустой state → step=idle, running=false, done=false" {
    run run_rpcd install_progress
    assert_success
    assert_json_field "$output" .step "idle"
    assert_json_field "$output" .running "false"
    assert_json_field "$output" .done "false"
    assert_json_field "$output" .log ""
}

@test "install_progress: state-файл с шагом → step возвращается" {
    echo "[STEP] 02-podkop" > "$STATE_DIR/state"
    run run_rpcd install_progress
    assert_success
    assert_output --partial '"step": "[STEP] 02-podkop"'
}

@test "install_progress: done-файл присутствует → done=true, result из файла" {
    echo "[STEP] finished" > "$STATE_DIR/state"
    echo "ok" > "$STATE_DIR/done"
    run run_rpcd install_progress
    assert_success
    assert_json_field "$output" .done "true"
    assert_json_field "$output" .result "ok"
}

@test "install_progress: process-PID мёртв и done-маркера нет → result=crashed" {
    # Кладём PID несуществующего процесса
    echo "999999" > "$STATE_DIR/pid"
    : > "$STATE_DIR/install.log"
    run run_rpcd install_progress
    assert_success
    assert_json_field "$output" .done "true"
    assert_json_field "$output" .result "crashed"
}

@test "install_progress: log с спецсимволами проходит JSON-escape" {
    printf 'line1\n"quote"\n\\backslash' > "$STATE_DIR/install.log"
    run run_rpcd install_progress
    assert_success
    # Если бы escape сломался — JSON был бы битый
    printf '%s' "$output" | python3 -m json.tool >/dev/null
}

# ─── токен-flow: повторная установка после успешной — невозможна ────────────

@test "post-install: install_start с любым токеном → 'install token not found'" {
    sandbox_mark_installed
    payload='{"token":"deadbeef","ssid":"X","wifi_key":"longenough","country":"RU","awg_conf":"x","root_pass":"longenough"}'
    run run_rpcd install_start "$payload"
    assert_success
    assert_output --partial "install token not found"
}

# ─── параллельная защита от двойного запуска ────────────────────────────────

@test "install_start: уже идёт установка (PID жив) → 'already running'" {
    sandbox_set_token "abcdef1234567890abcdef1234567890" >/dev/null
    sleep 30 &
    pid=$!
    echo "$pid" > "$STATE_DIR/pid"
    payload='{"token":"abcdef1234567890abcdef1234567890","ssid":"X","wifi_key":"longenough","country":"RU","awg_conf":"x","root_pass":"longenough"}'
    run run_rpcd install_start "$payload"
    kill "$pid" 2>/dev/null || true
    assert_success
    assert_output --partial "already running"
}
