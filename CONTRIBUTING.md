Contributing to Money

This repository is intentionally small and focused. To keep contributions reviewable and high-quality, please follow the guidance below before opening a pull request.

Development expectations

- Target Solidity versions compatible with ^0.8.0 (maintainers may update this in future).
- Prefer OpenZeppelin audited base contracts where appropriate (ERC20, Ownable, Pausable, Timelock patterns).
- Use deterministic builds and pin toolchain versions in configuration where possible.

Testing and quality

- Required unit tests: buy() happy path, buy() failure/revert paths, owner withdraw happy and failure paths, access control checks, pause/pausable behaviors, timelock behaviors if applicable.
- Aim for meaningful coverage; new features should include unit tests exercising edge cases. We recommend using coverage tools and reporting results in the PR.
- Add gas usage notes for public/external functions that will be part of the economic surface (e.g. buy, withdraw).
- Run a linter (Solhint/Prettier or the repository's chosen tools) before opening a PR.

Pull request checklist

Before opening your PR, confirm:
- [ ] Tests added for all new behaviors and regressions fixed where applicable.
- [ ] Linter and formatter run, and code follows the repository style.
- [ ] Test coverage reported and meets the project's expectations.
- [ ] Gas-sensitive functions annotated with measured gas use.
- [ ] A clear description of the economic invariants your change affects (if any).
- [ ] If the change alters governance or merging policy, or is large, note that a separate Code governance proposal may be required.

If you're unsure about requirements or want to propose a design change first, open an issue using the feature request template. Maintainers will respond with guidance.