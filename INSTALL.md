# Installation Guide — Claude Code Handoff

This file is a step-by-step guide for getting the SLT contracts repo running on a new machine
(typically your laptop where Claude Code will live).

## 1. Install Foundry

```sh
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

Verify:

```sh
forge --version
cast --version
anvil --version
```

## 2. Initialize the repo

If you cloned/copied this folder fresh, set up Foundry libraries:

```sh
cd lidya-slt-contracts
forge install --no-commit OpenZeppelin/openzeppelin-contracts@v5.6.1   # pinned in foundry.lock (rev 5fd1781)
forge install --no-commit foundry-rs/forge-std@v1.16.2   # pinned in foundry.lock (rev bf647bd)
```

If you want submodules tracked under `lib/`:

```sh
git init
git submodule add https://github.com/OpenZeppelin/openzeppelin-contracts lib/openzeppelin-contracts
git -C lib/openzeppelin-contracts checkout v5.6.1   # must match foundry.lock
git submodule add https://github.com/foundry-rs/forge-std lib/forge-std
git -C lib/forge-std checkout v1.16.2               # must match foundry.lock
```

## 3. Verify the build

```sh
forge build
```

Should compile cleanly with `solc 0.8.24`.

## 4. Run tests

```sh
forge test -vvv
```

Expected: all tests pass; fuzz runs ≥ 1000.

## 5. Static analysis (optional, recommended pre-audit)

Install Slither:

```sh
pipx install slither-analyzer   # or: pip3 install slither-analyzer (use --break-system-packages on PEP 668 systems)
```

Run:

```sh
slither . --filter-paths "lib|test|script" --exclude-dependencies
```

## 6. Open in Claude Code

Once the repo is on your machine, open it in your editor / Claude Code session. You can ask Claude
Code to:

- Add new test cases (e.g., invariant tests with Echidna patterns).
- Refine NatSpec comments for audit readability.
- Wire up the Chainlink custom data feed adapter (Phase 1 dev).
- Scaffold the `stSLT.sol` ERC-4626 staking wrapper (Phase 2).
- Generate the audit handoff package (threat model, spec doc, deployed-address table).

## 7. Pre-mainnet checklist

- [ ] All Foundry tests pass with ≥95% coverage.
- [ ] Slither clean (no medium/high severity).
- [ ] Treasury Safe deployed on Fuji and mainnet, signers configured, threshold set.
- [ ] Deploy script tested on Fuji end-to-end (deploy + Safe role grants + first mint).
- [ ] External audit on tag `v1.1.1-audit` complete (Halborn / Zealynx / Cantina RFQ); all High/Medium findings resolved and fix commit re-reviewed.
- [ ] WP final published; GitBook live.
- [x] BVI regulatory memorandum received from BVI counsel (1 Jul 2026); Terms of Use in progress.
- [ ] US counsel memorandum received.
- [ ] Custodian RFP complete; partner engaged.
- [ ] Chainlink adapter live; index update cadence confirmed.
- [ ] Accountable PoR dashboard live.
