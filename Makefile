SHELL := /bin/bash

.PHONY: install build test test-gas fmt clean

# Fetch the pinned dependencies into lib/. Versions are pinned by tag in
# scripts/install-deps.sh — OpenZeppelin v4, NOT v5 (v5 moves Pausable to
# utils/ and gives Ownable a constructor argument, which would break
# contracts/Money.sol).
install:
	./scripts/install-deps.sh

build:
	forge build

test:
	forge test -vvv

test-gas:
	forge test --gas-report

fmt:
	forge fmt

clean:
	forge clean
