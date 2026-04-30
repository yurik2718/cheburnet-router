# cheburnet-router — test targets
#
# Цели:
#   make lint   — статика (shellcheck + sh -n + JSON + SHA-sync). T1.
#   make test   — unit-тесты на pure-функции (bats-core). T2 (заглушка).
#   make qemu   — integration-тесты в OpenWrt-VM. T3 (заглушка).

.PHONY: lint test test-unit test-integration qemu

# bats-core поставляется submodule'ом — никаких внешних зависимостей.
BATS := tests/vendor/bats-core/bin/bats

lint:
	@bash tests/lint.sh

# test = unit + integration. Оба гоняются на bats-core, разница только в том
# что integration source'ит реальный web/rpcd-cheburnet через PATH-mock'и
# (uci, ubus, awg, jsonfilter, nslookup и т.п.).
test: test-unit test-integration

test-unit:
	@if [ ! -x "$(BATS)" ]; then \
		echo "✗ bats-core не найден в tests/vendor/bats-core/"; \
		echo "  Запустите: git submodule update --init --recursive"; \
		exit 1; \
	fi
	@$(BATS) tests/unit/

test-integration:
	@if [ ! -x "$(BATS)" ]; then \
		echo "✗ bats-core не найден"; exit 1; \
	fi
	@$(BATS) tests/integration/

# T3b — реальный QEMU+OpenWrt стенд. Не реализован (см. AGENTS.md / RELEASE-CHECKLIST).
qemu:
	@echo "→ T3b (QEMU-стенд) не реализован. Используйте 'make test' для T3a (mock-уровень)"
	@exit 1
