SHELL := /bin/bash

.PHONY: install build test test-gas fmt clean deploy-dry deploy

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

# Deploy targets. These use the Deploy.s.sol script. A dry run does not broadcast
# (useful to verify the address and that setRate would succeed). A real deploy
# must provide MONEY_RPC_URL and MONEY_DEPLOYER_PRIVATE_KEY in the environment.

deploy-dry:
	forge script script/Deploy.s.sol:DeployScript --rpc-url $(MONEY_RPC_URL) --broadcast=false

deploy:
	forge script script/Deploy.s.sol:DeployScript --rpc-url $(MONEY_RPC_URL) --private-key $(MONEY_DEPLOYER_PRIVATE_KEY)
