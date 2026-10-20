---
description: Pre-audit gate for Lidya SLT — runs forge build/test/coverage + Slither, pastes REAL outputs, writes SECURITY_CHECK_<date>.md. Fails loudly on any red. Never fabricates numbers.
allowed-tools: Read, Write, Grep, Glob, Bash
---

Run the pre-audit gate. Every number in the report must come from a command you ran in this session; quote the raw summary lines.

Steps (stop at the first failure and report it):
1. `forge --version`, `solc`, `via_ir`, `optimizer_runs`, `evm_version` from `forge config --json` (quote them), `cat foundry.lock` (pins). Also quote `git rev-parse HEAD` and `git describe --tags --always` up front so the report is bound to the tree it measured.
2. `forge fmt --check` (report, do not block).
3. `forge build` — quote last line.
4. `forge test` — quote the final "Ran N test suites" line and every FAIL line.
5. `forge test --match-path "test/invariants/*" -vv` — quote PASS lines with runs/calls.
6. `forge coverage --report summary --no-match-coverage "(script|test)"` — quote the table for `src/`.
7. `slither . --filter-paths "lib|test|script" --exclude-dependencies` — quote the final "analyzed N contracts with M detectors, found K result(s)" line and list every finding with severity and location; if slither is not installed, say so explicitly (do NOT write "0 findings").
8. Public ABI snapshot: `forge inspect SLT abi`, `forge inspect MintContract abi`, `forge inspect IndexOracle abi` → list function names per contract.
9. `git rev-parse HEAD`, `git status --short`.

Write `SECURITY_CHECK_<DDMonYYYY>.md` (date from `date -u`) with sections: Toolchain · Build · Tests · Invariants · Coverage · Slither · ABI surface · Commit. Each section = the quoted raw output plus one sentence. End with `GATE: PASS` only if build ok, 0 failed tests, coverage ≥ 95% lines on src/, Slither 0 High/Medium; otherwise `GATE: FAIL — <reason>`.
