# cheburnet-router — test targets
#
# Цели:
#   make lint   — статика (shellcheck + sh -n + JSON + SHA-sync). T1.
#   make test   — unit-тесты на pure-функции (bats-core). T2 (заглушка).
#   make qemu   — integration-тесты в OpenWrt-VM. T3 (заглушка).

.PHONY: lint test qemu

lint:
	@bash tests/lint.sh

test:
	@echo "→ T2 не реализован (unit-тесты на bats-core, см. AGENTS.md)"
	@exit 1

qemu:
	@echo "→ T3 не реализован (QEMU-стенд, см. AGENTS.md)"
	@exit 1
