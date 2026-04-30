# tests/helpers/setup.bash — общий setup для всех bats-файлов.
#
# Подключение в каждом *.bats:
#   load '../helpers/setup'
#
# Что делает:
#   - вычисляет REPO_ROOT (корень репозитория)
#   - source'ит lib/cheburnet-utils.sh — все pure-функции доступны в тестах
#   - подгружает bats-support и bats-assert (для assert_output, assert_failure и т.п.)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT
FIXTURES="$REPO_ROOT/tests/fixtures"
export FIXTURES

# shellcheck source=../../lib/cheburnet-utils.sh
. "$REPO_ROOT/lib/cheburnet-utils.sh"

# shellcheck source=../vendor/bats-support/load.bash
load "$REPO_ROOT/tests/vendor/bats-support/load.bash"
# shellcheck source=../vendor/bats-assert/load.bash
load "$REPO_ROOT/tests/vendor/bats-assert/load.bash"
