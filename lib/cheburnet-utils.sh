# lib/cheburnet-utils.sh — общие pure-функции cheburnet-router.
#
# Source-only: ничего не выполняет, только определяет функции. Не имеет shebang
# (sourcer'ы — POSIX sh / busybox-ash / bats-core).
#
# Подключение:
#   . /opt/cheburnet/lib/cheburnet-utils.sh   # на роутере
#   . lib/cheburnet-utils.sh                   # из репо-чекаута / тестов
#
# Все функции — без side-effects (не читают/пишут глобальное состояние, не
# создают файлов). Это контракт: любое нарушение делает T2-тесты бессмысленными.
# Единственное исключение — awg_pick_version: делает HEAD-запрос к GitHub (но
# без побочных эффектов на ФС/окружение, что мокается через PATH-shim на wget).

# ─────────────────────────────────────────────────────────────────────────────
# JSON
# ─────────────────────────────────────────────────────────────────────────────

# json_escape STRING
# Экранирует произвольную строку для безопасной вставки в JSON-литерал.
# Делает: \ → \\, " → \", переносы строк → \n, tab → \t, \r → пусто.
# Используется ВЕЗДЕ где пользовательские/uci-данные подставляются в JSON-ответ.
json_escape() {
    printf '%s' "$1" | awk 'BEGIN{ORS=""}
        {
            gsub(/\\/, "\\\\");
            gsub(/"/, "\\\"");
            gsub(/\t/, "\\t");
            gsub(/\r/, "");
            if (NR > 1) printf "\\n";
            print
        }'
}

# ─────────────────────────────────────────────────────────────────────────────
# Парсер AmneziaWG-конфига (.conf формат wg-quick / awg-quick)
# ─────────────────────────────────────────────────────────────────────────────

# awg_get_iface FIELD FILE
# Печатает первое значение `FIELD = ...` найденное в файле (включая [Interface]
# секцию — она обычно идёт первой). Если поле не найдено — печатает пустую
# строку без ошибки.
awg_get_iface() {
    awk -F' *= *' "/^$1/{print \$2; exit}" "$2" | head -n1
}

# awg_get_peer FIELD FILE
# Печатает первое значение `FIELD = ...` после маркера [Peer]. Если [Peer]-секции
# нет или поле в ней отсутствует — печатает пустую строку, не падает.
awg_get_peer() {
    awk -F' *= *' "BEGIN{f=0} /^\\[Peer\\]/{f=1; next} f && /^$1/{print \$2; exit}" "$2"
}

# awg_endpoint_host ENDPOINT
# Из строки вида "host:port" или "[ipv6]:port" печатает host-часть.
awg_endpoint_host() {
    printf '%s\n' "${1%:*}"
}

# awg_endpoint_port ENDPOINT
# Из строки "host:port" или "[ipv6]:port" печатает port-часть.
awg_endpoint_port() {
    printf '%s\n' "${1##*:}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Выбор версии awg-openwrt-пакета
# ─────────────────────────────────────────────────────────────────────────────

# awg_pick_version PREFERRED ARCH
# Пытается найти подходящий релиз awg-openwrt: сначала PREFERRED ($DISTRIB_RELEASE),
# затем fallback "25.12.2". Печатает выбранную версию в stdout, return 0.
# Если ничего не нашлось — return 1, ничего не печатает.
# wget-вызов мокается в тестах через PATH-shim.
awg_pick_version() {
    _preferred="$1"
    _arch="$2"
    for _try in "$_preferred" "25.12.2"; do
        [ -z "$_try" ] && continue
        _url="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v${_try}/kmod-amneziawg_v${_try}_${_arch}.apk"
        if wget -q --spider --timeout=15 "$_url" 2>/dev/null; then
            printf '%s\n' "$_try"
            unset _preferred _arch _try _url
            return 0
        fi
    done
    unset _preferred _arch _try _url
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Валидаторы пользовательского ввода (для rpcd-cheburnet)
# ─────────────────────────────────────────────────────────────────────────────

# cheburnet_valid_mode VAL  → 0 если "home" | "travel", иначе 1.
cheburnet_valid_mode() {
    case "$1" in
        home|travel) return 0 ;;
        *)           return 1 ;;
    esac
}

# cheburnet_valid_tier VAL  → 0 если допустимый Hagezi-тир, иначе 1.
# Список синхронизирован с https://github.com/hagezi/dns-blocklists.
cheburnet_valid_tier() {
    case "$1" in
        light|normal|pro|pro.plus|ultimate|tif|tif.medium|tif.mini|multi.pro|fake)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

# cheburnet_valid_factory_confirm VAL  → 0 если строго "RESET", иначе 1.
# Защита от случайного срабатывания factory_reset.
cheburnet_valid_factory_confirm() {
    [ "$1" = "RESET" ]
}
