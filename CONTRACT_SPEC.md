CONTRACT SPEC: Money ERC20

Overview

This document describes the expected behavior of the Money ERC20 token and the minimal test matrix and repository layout to guide contributors implementing code. It is intentionally concise: it should be unambiguous about public API, expected economic behavior, and security constraints so work lands faster and with fewer rejections.

Governance wiring (excerpt)

# Governance marker: code lands in this repository's default branch only
# by the named group's passed vote. The merge executor refuses to act for
# any other group. Keep this file in the default branch; delete it to
# withdraw consent.

Goals

- Make as much money as possible while preserving basic safety for users and the project.
- Provide a simple, auditable ERC20 token with a payable buy mechanism and owner withdrawal that is constrained by a timelock and emergency pause.

Assumptions (to be confirmed in PR discussion)

- Withdrawals by owner are subject to a 48-hour timelock. This is an explicit assumption; if the group prefers a different delay length, the PR must call that out for vote.

Public API (required)

- Full ERC20 interface (name, symbol, decimals, totalSupply, balanceOf, transfer, approve, allowance, transferFrom).
- A payable buy(uint256 rate) or buy() function that mints tokens in exchange for ETH sent; the exact signature may vary but must be described in the PR.
- ownerWithdraw() that withdraws accumulated ETH to owner after timelock conditions are satisfied.
- pause()/unpause() callable by owner to enable emergency pause of buy() and withdrawals.

ETH entry points

- buy() is the ONLY minting path: ETH in, tokens out, at the owner-set rate.
- deposit() is the ONLY funding path: payable, requires msg.value > 0, emits Deposit, mints nothing. Use it for treasury funding and for test/ops setup.
- receive() reverts with "Use buy() or deposit()" and fallback() reverts with "Unknown function". A plain ETH send, or a call against a stale ABI (for example the buy(uint256 rate) signature above), fails and the sender keeps their ETH instead of losing it with zero tokens minted.
- Force-fed ETH (selfdestruct, block rewards) cannot be blocked by any contract, so balance-based checks must not assume the contract balance only grew through buy()/deposit().

buy() unit normalization

- The implementation must explicitly normalize units between wei and token decimals. Tests must show identical token quantities independent of wei/token-decimal differences.

Security considerations

- Reentrancy guards on buy() and withdrawal flows.
- Use OpenZeppelin/ERC20 tested primitives where possible.
- Explicit owner-only modifiers and events for pause/unpause, queueWithdrawal, executeWithdrawal.

File layout and toolchain

- Suggest directories: contracts/ (Solidity 0.8.x), test/ or src/ (Foundry or Hardhat tests).

Prioritized test matrix

- buy() normalization tests
- withdraw timelock enqueue/execute tests
- pause/resume blocks buys and withdrawals
- owner-only access tests and basic ERC20 unit tests

PR checklist (for reviewers)

- CONTRACT_SPEC.md present and referenced from README.md
- .d8a-governance remains in default branch
- Tests cover the prioritized matrix
- Timelock length is explicit and justified

Notes

This spec is intentionally conservative: it expresses assumptions for clarity. Treat changes to assumptions as governance decisions.
