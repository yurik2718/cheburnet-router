#!/usr/bin/env bats
# Тесты json_escape — экранирование строки для безопасной вставки в JSON-литерал.
# Контракт: после оборачивания результата в "..." получаем валидный JSON-string.

load '../helpers/setup'

# Хелпер: проверяет что "<output>" парсится как валидный JSON-string и
# decoded-значение совпадает с ожидаемым (round-trip через python3).
assert_json_roundtrip() {
    local original="$1"
    local escaped
    escaped="$(json_escape "$original")"
    local decoded
    decoded="$(printf '"%s"' "$escaped" | python3 -c 'import json,sys; print(json.load(sys.stdin), end="")')"
    [ "$decoded" = "$original" ] || {
        echo "round-trip failed:"
        echo "  original: $(printf '%q' "$original")"
        echo "  escaped:  $(printf '%q' "$escaped")"
        echo "  decoded:  $(printf '%q' "$decoded")"
        return 1
    }
}

@test "json_escape: пустая строка" {
    run json_escape ""
    assert_success
    assert_output ""
}

@test "json_escape: обычный ASCII текст без спецсимволов" {
    run json_escape "hello world"
    assert_success
    assert_output "hello world"
}

@test "json_escape: двойная кавычка экранируется как \\\"" {
    run json_escape 'He said "hi"'
    assert_success
    assert_output 'He said \"hi\"'
}

@test "json_escape: бэкслеш экранируется как \\\\" {
    run json_escape 'C:\Users'
    assert_success
    assert_output 'C:\\Users'
}

@test "json_escape: бэкслеш + кавычка (бэкслеш экранируется первым)" {
    # Если порядок gsub неправильный, мы получим "C:\\\"" вместо "C:\\\\\""
    assert_json_roundtrip 'C:\"'
}

@test "json_escape: tab" {
    run json_escape "$(printf 'a\tb')"
    assert_success
    assert_output 'a\tb'
}

@test "json_escape: \\r вырезается полностью (CRLF → LF)" {
    run json_escape "$(printf 'line1\r\nline2')"
    assert_success
    assert_output 'line1\nline2'
}

@test "json_escape: перенос строки превращается в \\n" {
    run json_escape "$(printf 'line1\nline2')"
    assert_success
    assert_output 'line1\nline2'
}

@test "json_escape: несколько переносов" {
    run json_escape "$(printf 'a\nb\nc')"
    assert_success
    assert_output 'a\nb\nc'
}

@test "json_escape: unicode (русский) проходит без изменений" {
    run json_escape 'Привет, мир'
    assert_success
    assert_output 'Привет, мир'
}

@test "json_escape: emoji (4-byte UTF-8) проходит без изменений" {
    run json_escape '🚀 launch'
    assert_success
    assert_output '🚀 launch'
}

@test "json_escape: попытка JSON-инъекции экранируется (round-trip safe)" {
    # Атакующая строка пытается закрыть JSON-литерал и инжектнуть свой ключ.
    # После экранирования и оборачивания в "..." должен получиться валидный JSON,
    # decoded-значение которого = исходная строка целиком.
    assert_json_roundtrip '","admin":true,"x":"'
}

@test "json_escape: SSID с шеллметасимволами (round-trip safe)" {
    assert_json_roundtrip '$(rm -rf /); echo pwn"`whoami`'
}

@test "json_escape: смешанная нагрузка (квоты + бэкслеши + переносы + tab)" {
    assert_json_roundtrip "$(printf 'mix \"quotes\" and \\backslash and\ttabs and\nnewlines')"
}

@test "json_escape: переносы внутри строки сохраняются (по одному \\n на строку)" {
    # NB: проверяем round-trip. Кейс "только \n\n\n" протестировать через
    # "$(...)" нельзя — shell обрезает trailing newlines у command-substitution
    # ещё до вызова функции. Поэтому обрамляем не-newline-символами.
    assert_json_roundtrip "$(printf 'x\n\n\nx')"
}
