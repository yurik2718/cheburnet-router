#!/usr/bin/env bats
# Тесты awg_pick_version: выбор подходящего релиза awg-openwrt-пакета.
# wget мокается через PATH-shim — определяем что-«есть»/«нет» по списку URL.

load '../helpers/setup'

# ─── Мок-инфраструктура ─────────────────────────────────────────────────────
#
# Тест-каждый пишет в $MOCK_DIR/available_urls список URL'ов, которые wget-shim
# должен считать "доступными" (HEAD/spider 200). Все остальные → exit 1.

setup() {
    MOCK_DIR="$(mktemp -d)"
    export MOCK_DIR
    AVAILABLE_URLS="$MOCK_DIR/available_urls"
    export AVAILABLE_URLS
    : > "$AVAILABLE_URLS"

    # wget-shim: проверяет последний аргумент (URL) против available_urls.
    # Эмулирует только режим --spider/-q --timeout=...; никакого сетевого I/O.
    cat > "$MOCK_DIR/wget" <<'SHIM'
#!/usr/bin/env bash
url="${!#}"  # last positional arg = URL
while IFS= read -r allowed; do
    [ "$url" = "$allowed" ] && exit 0
done < "$AVAILABLE_URLS"
exit 1
SHIM
    chmod +x "$MOCK_DIR/wget"
    PATH="$MOCK_DIR:$PATH"
    export PATH
}

teardown() {
    rm -rf "$MOCK_DIR"
}

# Хелпер: добавить URL в список «доступных» для текущего теста.
allow_url() { echo "$1" >> "$AVAILABLE_URLS"; }

url_for() {
    # url_for VERSION ARCH
    printf 'https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v%s/kmod-amneziawg_v%s_%s.apk\n' \
        "$1" "$1" "$2"
}

# ─── Тесты ──────────────────────────────────────────────────────────────────

@test "awg_pick_version: preferred доступен → возвращает preferred" {
    allow_url "$(url_for 25.12.2 aarch64_cortex-a53_mediatek_filogic)"
    run awg_pick_version "25.12.2" "aarch64_cortex-a53_mediatek_filogic"
    assert_success
    assert_output "25.12.2"
}

@test "awg_pick_version: preferred недоступен, fallback 25.12.2 доступен → 25.12.2" {
    allow_url "$(url_for 25.12.2 aarch64_cortex-a53_mediatek_filogic)"
    run awg_pick_version "26.01.0" "aarch64_cortex-a53_mediatek_filogic"
    assert_success
    assert_output "25.12.2"
}

@test "awg_pick_version: preferred = fallback (25.12.2) и доступен — не дублирует попытки" {
    allow_url "$(url_for 25.12.2 x86_64)"
    run awg_pick_version "25.12.2" "x86_64"
    assert_success
    assert_output "25.12.2"
}

@test "awg_pick_version: ничего не доступно → exit 1, пустой stdout" {
    # available_urls пустой
    run awg_pick_version "26.01.0" "x86_64"
    assert_failure
    assert_output ""
}

@test "awg_pick_version: пустой preferred → пробует только fallback 25.12.2" {
    allow_url "$(url_for 25.12.2 x86_64)"
    run awg_pick_version "" "x86_64"
    assert_success
    assert_output "25.12.2"
}

@test "awg_pick_version: пустой preferred + fallback недоступен → fail" {
    run awg_pick_version "" "exotic_arch"
    assert_failure
    assert_output ""
}

@test "awg_pick_version: разные архитектуры различимы (mediatek vs x86)" {
    # Доступен только x86 — для mediatek-arch должно вернуть failure
    allow_url "$(url_for 25.12.2 x86_64)"
    run awg_pick_version "25.12.2" "aarch64_cortex-a53_mediatek_filogic"
    assert_failure

    run awg_pick_version "25.12.2" "x86_64"
    assert_success
    assert_output "25.12.2"
}

@test "awg_pick_version: preferred приоритетнее fallback (если оба доступны)" {
    allow_url "$(url_for 26.01.0 x86_64)"
    allow_url "$(url_for 25.12.2 x86_64)"
    run awg_pick_version "26.01.0" "x86_64"
    assert_success
    assert_output "26.01.0"
}
