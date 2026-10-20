---
description: Check docs (README, INSTALL, docs/ARCHITECTURE, docs/THREAT_MODEL, REVIEW_BRIEF) against src/*.sol and foundry.lock; report every stale number, name, file reference or claim. Docs are the spec — mismatches are listed, code is never changed by this command.
allowed-tools: Read, Grep, Glob, Bash
---

Audit documentation ↔ code consistency for Lidya SLT. Read-only on `src/`; you MAY propose exact doc edits.

Check and report, with file:line for both sides:
1. **Oracle parameters** — maxChangeBps default/ceiling, minUpdateInterval floor/ceiling, gracePeriod floor/ceiling, STALENESS_SLACK, "per update" vs "per day" wording. Source of truth: `src/IndexOracle.sol`.
2. **Mint limits** — min/max defaults in docs vs `script/*.s.sol` / `.env.example`.
3. **Token name/symbol** — must be "Synthetic Liquidity Token" / "SLT" everywhere.
4. **Dependency pins** — OZ and forge-std versions in INSTALL.md/README vs `foundry.lock` (`tag.name`).
5. **Dead references** — every relative file link in README/INSTALL/docs must exist (SECURITY.md, .github/workflows/ci.yml, etc.).
6. **Role / lock claims** — "backdoor admin path", "compromised multisig cannot bypass mint", "holder balances untouchable": each must match the code (lockMinterRole(expectedMinter) + slt() wiring check, lockBurnSource(expectedSource), MINTER_ADMIN_LOCK sealed in constructor, 24h whitelist-addition timelock, constructor-seeded stablecoins, minSltOut/deadline overload, L-6 receipt check).
7. **Treasury Safe change** — docs must describe propose → 24h → execute (cancel possible).
8. **Pause semantics** — pause table must say adminBurn is NOT pausable.
9. **Test/coverage/Slither figures** — any number stated in docs must match the latest SECURITY_CHECK_*.md.
10. **Known/accepted findings** — THREAT_MODEL must list M-04 (no absolute index floor/ceiling) as "known, accepted".

Output: a table `| # | File:line | Says | Code says | Fix |`, then a count. If `$ARGUMENTS` contains `--fix`, apply the doc edits (never src/) and re-run the check.
