# Money
Make as much money as possible..

This repository contains the Money ERC20 project. See CONTRACT_SPEC.md for the detailed contract specification, required public API, security notes, and a prioritized test matrix that contributors must implement before code is merged.

## Running the tests

The suite in `test/Money.t.sol` is Foundry-shaped. The toolchain config is committed
(`foundry.toml`, `remappings.txt`); the dependencies are not vendored, so fetch them once:

```
curl -L https://foundry.paradigm.xyz | bash && foundryup   # installs forge, once per machine
forge install foundry-rs/forge-std --no-commit
forge install OpenZeppelin/openzeppelin-contracts@v4.9.6 --no-commit
```

Both land in `lib/`, which `.gitignore` excludes and `remappings.txt` resolves:

```
forge-std/=lib/forge-std/src/
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
```

OpenZeppelin must stay on the 4.x line: `contracts/Money.sol` imports the v4 paths
`@openzeppelin/contracts/security/Pausable.sol`, `security/ReentrancyGuard.sol` and
`access/Ownable.sol`, which v5 moved or removed.

Then run:

```
forge build
forge test -vvv
```

`foundry.toml` pins `solc = "0.8.24"`: the tests emit events qualified by contract
(`emit Money.WithdrawalCancelled(amount);`), which solc only accepts from 0.8.21 onward.

Development checklist:
- Add CONTRACT_SPEC.md (present)
- Implement contracts/ (Solidity 0.8.x) and tests/ (Foundry or Hardhat) following CONTRACT_SPEC.md
- Open a contributor PR that references .d8a-governance and this repo's governance vote to merge code
