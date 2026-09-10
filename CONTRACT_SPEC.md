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

- Full ERC20 interface (name, symbol, decimals, totalSupply, balanceOf, transfer, approve, allowance, transferFrom). decimals() is overridden to 6 to force explicit wei/token normalization.
- A payable buy() function that mints tokens in exchange for ETH sent, at the owner-set `rate`. Kept for backwards compatibility; it has no slippage protection.
- A payable buy(uint256 minTokenAmount) that mints as buy() does but reverts with "Insufficient tokens out" unless at least `minTokenAmount` token units are minted. This is the recommended entry point: it binds a quote from previewBuy(weiAmount) to the trade, so an owner rate change mined between quote and execution cannot shortchange the buyer.
- previewBuy(uint256 weiAmount) view returning (tokenAmount, wouldSucceed) — the quote a caller passes as `minTokenAmount`.
- previewWeiForTokens(uint256 tokenUnits) view returning (weiRequired, wouldSucceed) — the minimum wei (ceil-divided) that mints at least `tokenUnits`, for a caller who wants a target token amount rather than a target spend.
- Both buy entry points carry whenNotPaused and nonReentrant and share one private `_buy(uint256 minTokenAmount)` body, so the reentrancy guard is entered exactly once per call.
- setRate(uint256 newRate) — onlyOwner, requires 0 < newRate <= MAX_RATE (MAX_RATE is a constant cap of 1e12 tokens per ETH, chosen to keep the multiplication in `_buy`/previewBuy/previewWeiForTokens from overflowing), emits RateChanged.
- ownerMint(address to, uint256 amount) — onlyOwner, whenNotPaused, nonReentrant. A minimal, auditable mint endpoint that allows the owner to credit buyers after off-chain payments. Requires `to != address(0)` and `amount > 0`, mints `amount` token units to `to` and emits Minted(to, amount). Voters should weigh the centralisation risk: the owner may increase circulating supply without an on-chain payment.
- No ownerWithdraw(). ETH leaves the contract only through the queued-withdrawal path: queueWithdrawal(uint256 amount) and queueWithdrawalTo(address recipient, uint256 amount), both onlyOwner and whenNotPaused, record one pending withdrawal (amount, recipient, and executeAfter = now + TIMELOCK) and emit WithdrawalQueued; a second queue call reverts with "Existing queued withdrawal" until the pending one is executed or cancelled. executeWithdrawal() is permissionless (anyone may call it) and whenNotPaused; it reverts "Timelock not expired" before executeAfter, sends the ETH, and only clears the queued state on success, so a reverting recipient leaves the entry intact to retry or cancel. cancelQueuedWithdrawal() is onlyOwner and callable even while paused, for emergency retraction. timeUntilQueuedWithdrawal() view returns the seconds remaining, or 0 when there is nothing queued or the timelock has expired.
- pause()/unpause() — onlyOwner. While paused: buy(), buy(minTokenAmount), queueWithdrawal, queueWithdrawalTo, executeWithdrawal, queueEnableRescueToZero, executeEnableRescueToZero and rescueERC20 all revert; cancelQueuedWithdrawal and cancelQueuedEnableRescueToZero remain callable by the owner so a queued action can still be retracted during an incident.
- rescueERC20(IERC20 token, address to, uint256 amount) — onlyOwner, whenNotPaused, nonReentrant. Reverts "Cannot sweep Money token" if `token` is this contract, and reverts "Rescue to zero disabled" if `to == address(0)` unless the one-way `rescueToZeroEnabled` switch has been turned on. Uses OpenZeppelin SafeERC20 so non-standard (no-bool-return) tokens are supported. Emits ERC20Rescued.
- Rescue-to-zero opt-in timelock, mirroring the withdrawal pattern: queueEnableRescueToZero() (onlyOwner, whenNotPaused) records queuedRescueToZeroExecuteTime = now + TIMELOCK and emits RescueToZeroQueued; cancelQueuedEnableRescueToZero() (onlyOwner, callable while paused) clears it and emits RescueToZeroCancelled; executeEnableRescueToZero() (permissionless, whenNotPaused, nonReentrant) sets the permanent public flag `rescueToZeroEnabled` to true after the timelock and emits RescueToZeroExecuted. timeUntilQueuedRescueToZero() view returns the seconds remaining, or 0 when nothing is queued or the timelock has expired.
- Two-step ownership handover (OpenZeppelin Ownable2Step): transferOwnership(newOwner) only records a pending owner and emits OwnershipTransferStarted; the current owner keeps every owner power until the nominee calls acceptOwnership(). pendingOwner() exposes the nomination. transferOwnership(address(0)) clears a pending handover, and a later transferOwnership replaces it. Any caller other than the pending owner gets "Ownable2Step: caller is not the new owner".
- renounceOwnership() is disabled: it reverts with "Ownership cannot be renounced" for every caller, owner included.
- receive() and fallback() both accept plain ETH transfers and emit Deposit(from, amount), so off-chain tooling sees ETH that arrives outside buy().

buy() unit normalization

- The implementation must explicitly normalize units between wei and token decimals. Tests must show identical token quantities independent of wei/token-decimal differences.

Security considerations

- Reentrancy guards: buy(), buy(minTokenAmount) (via shared _buy), executeWithdrawal(), executeEnableRescueToZero() and rescueERC20() all carry nonReentrant.
- Use OpenZeppelin/ERC20 tested primitives where possible (ERC20, Pausable, Ownable2Step, ReentrancyGuard, SafeERC20).
- Explicit owner-only modifiers and events for pause/unpause, queueWithdrawal/queueWithdrawalTo, cancelQueuedWithdrawal, setRate, queueEnableRescueToZero/cancelQueuedEnableRescueToZero and rescueERC20.
- Ownership is the single point of failure for the ETH and any stray ERC20 the contract custodies: queueWithdrawal, queueWithdrawalTo, cancelQueuedWithdrawal, setRate, pause/unpause, queueEnableRescueToZero, cancelQueuedEnableRescueToZero and rescueERC20 are all onlyOwner. Handover is therefore two-step and never one-shot — a mistyped address, a wrong-chain address or a contract that cannot call acceptOwnership() is simply never accepted, and the sitting owner keeps control. Ownership cannot be renounced, so owner() can never become address(0) and strand the balance.
- rescueERC20 can never sweep the Money token itself, and can only send to address(0) after the owner has queued and, 48 hours later, executed a one-way opt-in (queueEnableRescueToZero / executeEnableRescueToZero) — a deliberate speed bump against an accidental or coerced burn-by-rescue.
- A queued withdrawal that hits a reverting or gas-griefing recipient is not lost: executeWithdrawal() only clears state on a successful call, so the owner can cancelQueuedWithdrawal() and requeue to a working address; cancelQueuedWithdrawal and cancelQueuedEnableRescueToZero both stay callable while paused so an incident cannot lock in a queued action.
- Trade-off accepted deliberately: any deploy or ops runbook must call acceptOwnership() from the new owner to finish a handover, and the contract deviates from ERC-173 tooling that expects renounceOwnership() to succeed.

File layout and toolchain

- Suggest directories: contracts/ (Solidity 0.8.x), test/ or src/ (Foundry or Hardhat tests).

Prioritized test matrix

- buy() normalization tests
- buy(minTokenAmount) slippage tests: succeeds when a previewBuy quote is met; reverts with "Insufficient tokens out" when the owner lowers the rate between quote and buy, minting nothing; accepts a rate that moved in the buyer's favour; still blocked while paused; legacy buy() behaviour unchanged
- previewWeiForTokens tests: returned wei mints at least the requested token amount (ceil division), and (0, false) for rate==0, tokenUnits==0 or an input that would overflow
- withdraw timelock enqueue/execute tests, including a case where the recipient's receive reverts: executeWithdrawal reverts "Transfer failed" and the queued withdrawal remains in place for the owner to cancel or retry, rather than being silently cleared
- pause/resume tests: pause blocks buy(), buy(minTokenAmount), queueWithdrawal, queueWithdrawalTo and executeWithdrawal; cancelQueuedWithdrawal still succeeds for the owner while paused; unpause restores normal operation
- rescue-to-zero timelock tests: rescueERC20(to = address(0)) reverts "Rescue to zero disabled" before the opt-in; queueEnableRescueToZero/executeEnableRescueToZero enable it only after TIMELOCK has elapsed; cancelQueuedEnableRescueToZero retracts a queued opt-in, including while paused; rescueERC20 reverts "Cannot sweep Money token" for the Money token itself and is blocked entirely while paused; rescueERC20 carries nonReentrant
- timeUntilQueuedWithdrawal / timeUntilQueuedRescueToZero view tests: 0 when nothing is queued, a positive countdown before the timelock, 0 once it has elapsed
- owner-only access tests and basic ERC20 unit tests
- ownership handover tests: transferOwnership only nominates (old owner still queues and executes a withdrawal, nominee is refused by setRate/queueWithdrawal/pause); acceptOwnership reverts for anyone but the pending owner; acceptOwnership moves control and the new owner can queue and execute; transferOwnership(address(0)) cancels a pending handover; a second nomination replaces the first; renounceOwnership reverts for owner and non-owner with the contract's ETH still withdrawable

PR checklist (for reviewers)

- CONTRACT_SPEC.md present and referenced from README.md
- .d8a-governance remains in default branch
- Tests cover the prioritized matrix
- Timelock length is explicit and justified

Notes

This spec is intentionally conservative: it expresses assumptions for clarity. Treat changes to assumptions as governance decisions.
