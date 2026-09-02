# Money
Make as much money as possible..

This repository contains the Money ERC20 project. See CONTRACT_SPEC.md for the detailed contract specification, required public API, security notes, and a prioritized test matrix that contributors must implement before code is merged.

## Build and test

The project is Foundry-based. From a fresh clone:

```
make install      # fetch pinned deps into lib/ (scripts/install-deps.sh)
make build        # forge build
make test         # forge test -vvv
```

Or without make:

```
./scripts/install-deps.sh
forge build
forge test -vvv
```

Layout and pinning:

- `foundry.toml` — `src = "contracts"`, `test = "test"`, `libs = ["lib"]`, solc `0.8.20`, EVM `paris`, optimizer on (200 runs).
- `remappings.txt` — resolves the import paths the sources already use:
  `forge-std/` → `lib/forge-std/src/` and `@openzeppelin/contracts/` → `lib/openzeppelin-contracts/contracts/`.
- `scripts/install-deps.sh` — pins **forge-std v1.9.4** and **openzeppelin-contracts v4.9.6**.
  OpenZeppelin **v4, not v5**: v5 moved `Pausable` to `utils/` and gave `Ownable` an
  `initialOwner` constructor argument, either of which breaks `contracts/Money.sol`.
- `lib/`, `out/` and `cache/` are ignored; dependencies are fetched, not committed.

The `.d8a` `run:` block declares one entry, `"test": "forge test -vvv"`, so the Server tab and the
VS Code ▶ button launch the suite. This repository serves no site, so `url:` stays unset and no
`run:` entry declares a port.

Development checklist:
- Add CONTRACT_SPEC.md (present)
- Implement contracts/ (Solidity 0.8.x) and test/ (Foundry) following CONTRACT_SPEC.md
- Run `make install && make test` and keep the suite green before proposing a change
- Open a contributor PR that references .d8a-governance and this repo's governance vote to merge code

Deployment

- A reproducible deploy script is included at `scripts/Deploy.s.sol` and Makefile targets `deploy-dry` and `deploy`.
- For a dry run (no broadcast): `make deploy-dry` with MONEY_RPC_URL set; this verifies the address and that setRate would succeed.
- For a live deploy: set MONEY_RPC_URL and MONEY_DEPLOYER_PRIVATE_KEY on the group's box and run `make deploy`. Optionally set MONEY_INITIAL_RATE and MONEY_OWNER to nominate a pending owner; the nominee must call `acceptOwnership()` to complete handover.
- The repository lists the required key NAMES in `.d8a` and `.env.example`; admins must set real values on the server before any broadcast deploy.
