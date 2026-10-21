# Security review: `contracts/Money.sol`

Scope: the Money (MNY) ERC20 at `contracts/Money.sol` as of this review, compiled with solc 0.8.20
against OpenZeppelin v4.9.6. Method: manual review of every ETH- and supply-moving path, the Foundry
unit/fuzz suite in `test/`, the invariant suite in `test/MoneyInvariants.t.sol`, and Slither
(`slither .`, config in `slither.config.json`), which CI runs on every push and pull request.

Reporting a vulnerability: open a GitHub issue on this repository describing the path and the
impact. Do not include exploit transactions against a live deployment.

## Findings

Severity is the reviewer's assessment of impact on users' ETH or token balances, not Slither's
label (shown separately in the triage table below).

| # | Area | Severity | Finding | Resolution |
|---|------|----------|---------|------------|
| F-1 | `executeWithdrawal()` | Medium | The queued entry was cleared only *after* the external `call{value}` to the recipient. `nonReentrant` already stopped the recipient from calling `executeWithdrawal()` again, but any other function it re-entered saw a withdrawal that had both been paid and was still queued. Slither flags this as `reentrancy-eth` (High). | **Fixed.** Checks-effects-interactions: the queued entry is cleared and `WithdrawalExecuted` is emitted before the call. A failing transfer still reverts the whole transaction (`require(ok, "Transfer failed")`), so the queued entry survives untouched exactly as before. Tests: `testExecuteWithdrawalReentryIsRefusedAndPaysOnce`, `testExecuteWithdrawalRecipientRevertsLeavesQueueIntact`, `testExecuteWithdrawalPaysRecipientAndClearsState`. |
| F-2 | Pricing maths | Low | `_buy` and `_buyTo` carried two copies of the normalisation `msg.value * rate * 10**decimals / 1 ether` and its guards. A future edit to one copy would silently change the price for one entry point only. | **Fixed.** `_buy(min)` now delegates to `_buyTo(msg.sender, min)`; every purchase runs through one pricing path. Behaviour and events are unchanged (`Bought` still logs the payer). |
| F-3 | Overflow in `buy`/`buyTo`/`previewBuy` | Info | `rate <= MAX_RATE = 1e12` and `msg.value <= type(uint256).max / MAX_RATE / 1e6` (about 1.16e59 wei) bound the product `msg.value * rate * 1e6` below `2**256` by construction. `previewWeiForTokens` guards its own numerator (`tokenUnits * 1 ether`). | **Verified, no change.** Tests: `testBuyRejectsValueAboveOverflowBound`, `testBuyAtExactOverflowBoundSucceeds`, `testPreviewBuyRejectsOverflow`, `testPreviewWeiForTokensRejectsOverflowAndZeroRate`. |
| F-4 | Rounding in `buy`/`buyTo` | Info | Token amounts are floored. The wei that does not make up a whole token unit (less than `1e12 / rate` wei, i.e. at most 1e-6 ETH at rate 1) stays in the contract. Sends that would mint zero units revert rather than taking the ETH. | **Accepted.** The dust is bounded by one token unit and `previewWeiForTokens` lets a buyer compute an exact spend. Tests: `testFuzz_BuyMintsFloorOfFormula` (pins the floor bounds for every rate), `testBuyRoundsDownAndKeepsTheDust`, `testBuyDustBelowOneTokenUnitReverts`, `testFuzz_PreviewWeiForTokensIsMinimal`. |
| F-5 | Zero-value calls | Info | `buy()`/`buyTo()` with `msg.value == 0` revert ("Must send ETH to buy"). A plain zero-wei send to `receive()`/`fallback()` is accepted and emits `Deposit(from, 0)`; it moves no value and mints nothing. | **Accepted.** Test: `testBuyRejectsZeroValue`. |
| F-6 | Ownership transfer | Info | Already two-step (`Ownable2Step`): `transferOwnership` only nominates, `acceptOwnership` must be called by the nominee, and `renounceOwnership` reverts for every caller so `owner()` can never become `address(0)`. | **Verified, no change.** Tests: `testOwnershipNominationDoesNotTransferRights`, `testAcceptOwnershipTransfersRights`, `testRenounceOwnershipRevertsForEveryone`, `testAcceptOwnershipWithoutNominationReverts`, invariant `invariant_ownerControlledStateMatchesOwnerActions`. |
| F-7 | Plain ETH (`receive`/`fallback`) | Info | Both accept ETH and emit `Deposit`. The claim that a merged PR had reverted plain sends was checked against the repository: the only merged PRs touching these functions are ERC20s/Money#23 and ERC20s/Money#72, which *added* the `Deposit` event; ERC20s/Money#50 ("revert plain ETH sends and add an explicit deposit()") is an **open** PR by `d8a[bot]` and is ignored per the ground rules. `CONTRACT_SPEC.md` requires acceptance. Residual risk: ETH sent with a mistyped selector lands in `fallback()` and is only recoverable through the owner's timelocked withdrawal. | **Confirmed, unchanged.** Any change here is a spec change for governance. Tests: `testDirectSendEmitsDeposit`, `testFallbackWithCalldataAcceptsEthAndEmitsDeposit`, invariant `invariant_ethBalanceMatchesFlows`. |
| F-8 | `queueWithdrawal()` recipient snapshot | Low | `queuedRecipient` is set to `owner()` at queue time. If ownership is handed over before execution, the ETH goes to the previous owner. | **Accepted, documented.** The new owner can `cancelQueuedWithdrawal()` and requeue; the previous owner chose the entry while they still held the key. |
| F-9 | `queueWithdrawal()` balance check | Info | The `amount <= address(this).balance` check runs at queue time only. If the balance is lower at execution the transfer fails and the entry stays queued. | **Accepted.** No ETH can leave the contract between queue and execute except through this same single queued slot. |
| F-10 | `ownerMint()` | Low (centralisation) | The owner can increase supply without an on-chain payment. | **Accepted per `CONTRACT_SPEC.md`.** The invariant suite accounts for owner mints separately from purchases so that every other token unit is provably backed by ETH at the quoted rate (`invariant_everyTokenWasPaidForOrOwnerMinted`). |
| F-11 | `pause()` and queued withdrawals | Info | While paused, `executeWithdrawal()` reverts, so a queued withdrawal can be delayed indefinitely by the owner; `cancelQueuedWithdrawal()` stays available. | **Accepted per spec.** |
| F-12 | `buyTo()` event | Info | `Bought` logs the payer, not the recipient; the ERC20 `Transfer` event logs the recipient. | **Accepted** for compatibility with existing off-chain tooling. |
| F-13 | Floating pragma `^0.8.13` | Info | The sources accept any 0.8.x >= 0.8.13; `foundry.toml` pins the compiler every build and CI use to 0.8.20. | **Accepted.** See the `solc-version` row below. |

## Fuzz and invariant coverage

`test/MoneyInvariants.t.sol` drives the contract through a handler with three non-owner actors and
the owner. Every handler action either succeeds and updates ghost accounting, or asserts the
exact revert reason the contract must give; the suite runs with `fail-on-revert` so a handler call
that reverts for any other reason fails the run. Invariants checked after every call:

- `invariant_totalSupplyEqualsSumOfBalances`: total supply conservation.
- `invariant_everyTokenWasPaidForOrOwnerMinted`: no balance is created without payment at the
  quoted `wei * rate * 10**decimals / 1 ether`, or an explicit `ownerMint`.
- `invariant_ethBalanceMatchesFlows`: ETH only enters through buys and plain sends and only leaves
  through an executed, timelocked withdrawal.
- `invariant_ownerControlledStateMatchesOwnerActions`: owner-only paths stay owner-only (rate,
  pause state, ownership, pending owner and the rescue-to-zero switch match what the owner did).
- `invariant_queuedWithdrawalIsConsistent`: the queued slot is never half-cleared.

The suite was checked against mutants of the contract: removing `nonReentrant` from
`executeWithdrawal`, `onlyOwner` from `setRate` or `ownerMint`, `whenNotPaused` from `buy()`,
the timelock check, or adding one token unit to the buy formula each makes at least one test fail.

## Slither triage

Run locally with `pip3 install slither-analyzer && slither .` (the config file is picked up
automatically). CI runs the same through `crytic/slither-action` with `fail-on: all`, so any
finding that is not triaged below fails the build.

| Detector | Slither impact | Where | Disposition |
|----------|----------------|-------|-------------|
| `reentrancy-eth` | High | `executeWithdrawal()` | **Fixed** (F-1). No longer reported. |
| `incorrect-equality` | Medium | `timeUntilQueuedRescueToZero()`: `queuedRescueToZeroExecuteTime == 0` | **False positive**, suppressed in place with `slither-disable-next-line`. `0` is the "nothing queued" sentinel written by the contract itself, never a timestamp a caller can steer towards. |
| `low-level-calls` | Informational | `executeWithdrawal()`: `recipient.call{value: amount}("")` | **Accepted**, suppressed in place. A low-level call is the recommended way to send ETH: `transfer()`'s 2300-gas stipend breaks contract recipients. The return value is checked and the call is behind `nonReentrant` and a 48h timelock. |
| `timestamp` | Low | every `block.timestamp` comparison in the two timelocks | **Accepted**, detector excluded in `slither.config.json`. The contract *is* a timelock; a validator can shift `block.timestamp` by seconds against a 48-hour delay, which does not matter. |
| `pragma` | Informational | `^0.8.13` in Money vs `^0.8.0`/`^0.8.1`/`^0.8.8` in vendored OpenZeppelin | **Accepted**, detector excluded. The dependency pragmas are not ours to edit; `foundry.toml` pins solc 0.8.20 for every file. |
| `solc-version` | Informational | `^0.8.13` admits versions with known bugs | **Accepted**, detector excluded. The compiler is pinned to 0.8.20. The bugs listed for 0.8.20 (`FullInlinerNonExpressionSplitArgumentEvaluationOrder`, `VerbatimInvalidDeduplication`) need Yul inline assembly or `verbatim`, which neither Money nor the OpenZeppelin modules it uses contain. |
