# CLAUDE.md

Money (MNY) is a Foundry/Solidity ERC20 with payable `buy()`, owner-set rate, 48h-timelocked
ETH withdrawals, pause, two-step ownership and EIP-2612 permit (`contracts/Money.sol`, spec in `CONTRACT_SPEC.md`).

## Commands

```
./scripts/install-deps.sh   # or: make install  — forge-std v1.9.4 + OpenZeppelin v4.9.6 (v4, never v5) into lib/
forge build                 # or: make build    — solc 0.8.20, EVM paris
forge test -vvv             # or: make test     — the `test` entry of the .d8a run: block
pip3 install slither-analyzer && slither .   # static analysis; config in slither.config.json, triage in SECURITY.md
```

CI (`.github/workflows/ci.yml`) runs exactly these on every push and pull request: install, build and
test in one job, slither (`crytic/slither-action`, `fail-on: all`) in another. A new slither finding must
be fixed or triaged in `SECURITY.md` (and excluded in `slither.config.json` / `slither-disable-next-line`).
If `forge` is missing: `mkdir -p ~/.foundry/bin && curl -L https://github.com/foundry-rs/foundry/releases/download/stable/foundry_stable_linux_amd64.tar.gz | tar -xz -C ~/.foundry/bin && export PATH=~/.foundry/bin:$PATH`.

## Ground rules

- Work on a new branch from `main`; one focused PR per task, listing each command run and its result.
- Never modify `.d8a` or `.d8a-governance`. Never modify the group-store widget copied from the
  `payments:` block of `.d8a` (`id="group-store"`, `groupStoreVerify`).
- Ignore open pull requests by `d8a[bot]`: do not merge, close, rebase, cherry-pick from, or comment on them.
- Do not add a LICENSE file or any licence text.
- Install dependencies and run the checks above before and after a change; never report a result you did not run.
- Every test must be able to fail: no `require(x >= 0)` on unsigned values, no bare `vm.expectRevert()`
  (pass the expected reason), no `try/catch` accepting any error, no asserting a value equals itself.
  Import every symbol you use. If a test is wrong rather than the code, fix the test and say so.
- Tests compile with solc 0.8.20: declare mirrors of events locally for `vm.expectEmit`
  (`emit Money.X(...)` needs 0.8.21+). Don't put an external call between `vm.prank` and the call it targets.
- Nothing dev-only in code shipped to a browser (no localhost/private hosts, no debug fallbacks). No secrets in the repo.
- CI runs exactly the declared checks and fails when one fails: no `continue-on-error`, no `|| true`.
  Pin GitHub Actions to their current major versions.
- Keep changes focused: no reformatting untouched files, no unneeded dependency upgrades, no renaming
  public files or URLs, no rewriting git history.
