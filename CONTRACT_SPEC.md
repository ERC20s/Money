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
- A payable buy() function that mints tokens in exchange for ETH sent, at the owner-set `rate`. Kept for backwards compatibility; it has no slippage protection.
- A payable buy(uint256 minTokenAmount) that mints as buy() does but reverts with "Insufficient tokens out" unless at least `minTokenAmount` token units are minted. This is the recommended entry point: it binds a quote from previewBuy(weiAmount) to the trade, so an owner rate change mined between quote and execution cannot shortchange the buyer.
- previewBuy(uint256 weiAmount) view returning (tokenAmount, wouldSucceed) — the quote a caller passes as `minTokenAmount`.
- Both buy entry points carry whenNotPaused and nonReentrant and share one private `_buy(uint256 minTokenAmount)` body, so the reentrancy guard is entered exactly once per call.
- ownerWithdraw() that withdraws accumulated ETH to owner after timelock conditions are satisfied.
- pause()/unpause() callable by owner to enable emergency pause of buy() and withdrawals.
- Two-step ownership handover (OpenZeppelin Ownable2Step): transferOwnership(newOwner) only records a pending owner and emits OwnershipTransferStarted; the current owner keeps every owner power until the nominee calls acceptOwnership(). pendingOwner() exposes the nomination. transferOwnership(address(0)) clears a pending handover, and a later transferOwnership replaces it. Any caller other than the pending owner gets "Ownable2Step: caller is not the new owner".
- renounceOwnership() is disabled: it reverts with "Ownership cannot be renounced" for every caller, owner included.

buy() unit normalization

- The implementation must explicitly normalize units between wei and token decimals. Tests must show identical token quantities independent of wei/token-decimal differences.

Security considerations

- Reentrancy guards on buy() and withdrawal flows.
- Use OpenZeppelin/ERC20 tested primitives where possible.
- Explicit owner-only modifiers and events for pause/unpause, queueWithdrawal, executeWithdrawal.
- Ownership is the single point of failure for the ETH the contract custodies: queueWithdrawal, queueWithdrawalTo, cancelQueuedWithdrawal, setRate, pause/unpause and rescueERC20 are all onlyOwner. Handover is therefore two-step and never one-shot — a mistyped address, a wrong-chain address or a contract that cannot call acceptOwnership() is simply never accepted, and the sitting owner keeps control. Ownership cannot be renounced, so owner() can never become address(0) and strand the balance.
- Trade-off accepted deliberately: any deploy or ops runbook must call acceptOwnership() from the new owner to finish a handover, and the contract deviates from ERC-173 tooling that expects renounceOwnership() to succeed.

File layout and toolchain

- Suggest directories: contracts/ (Solidity 0.8.x), test/ or src/ (Foundry or Hardhat tests).

Prioritized test matrix

- buy() normalization tests
- buy(minTokenAmount) slippage tests: succeeds when a previewBuy quote is met; reverts with "Insufficient tokens out" when the owner lowers the rate between quote and buy, minting nothing; accepts a rate that moved in the buyer's favour; still blocked while paused; legacy buy() behaviour unchanged
- withdraw timelock enqueue/execute tests
- pause/resume blocks buys and withdrawals
- owner-only access tests and basic ERC20 unit tests
- ownership handover tests: transferOwnership only nominates (old owner still queues and executes a withdrawal, nominee is refused by setRate/queueWithdrawal/pause); acceptOwnership reverts for anyone but the pending owner; acceptOwnership moves control and the new owner can queue and execute; transferOwnership(address(0)) cancels a pending handover; a second nomination replaces the first; renounceOwnership reverts for owner and non-owner with the contract's ETH still withdrawable

PR checklist (for reviewers)

- CONTRACT_SPEC.md present and referenced from README.md
- .d8a-governance remains in default branch
- Tests cover the prioritized matrix
- Timelock length is explicit and justified

Notes

This spec is intentionally conservative: it expresses assumptions for clarity. Treat changes to assumptions as governance decisions.
