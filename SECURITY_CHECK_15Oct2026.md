# Security Check — 15 Oct 2026

Pre-audit gate for Lidya SLT v1.1-audit candidate. Every number below is quoted from commands run on the VPS on `Thu Oct 15 05:16:23 PM UTC 2026` (`date -u`).

## Toolchain

```
forge Version: 1.6.0-v1.7.0
Commit SHA: f83bad912a9dba7bf0371def1e70bb1896048356
Build Timestamp: 2026-04-28T14:07:10.568929921Z (1777385230)
```

`foundry.toml`:
```
7:solc_version = "0.8.24"
8:optimizer = true
9:optimizer_runs = 200
10:via_ir = true
12:auto_detect_solc = false
```

`foundry.lock`:
```
lib/forge-std               tag v1.16.2  rev bf647bd6046f2f7da30d0c2bf435e5c76a780c1b
lib/openzeppelin-contracts  tag v5.6.1   rev 5fd1781b1454fd1ef8e722282f86f9293cacf256
```

`forge fmt --check` → `fmt exit=0` (no diff).

The toolchain uses pinned solc 0.8.24 with via-IR, and both dependencies are tag- and rev-pinned.

## Build

`forge build --force`:
```
Compiling 51 files with Solc 0.8.24
Solc 0.8.24 finished in 51.03s
Compiler run successful with warnings:
```

Warnings:

| Source | Location | Warning |
|---|---|---|
| solc 2072 | `script/Deploy.s.sol:62` | Unused local variable `CONFIG_ROLE` |
| solc 2018 | `test/invariants/SLTInvariants.t.sol:173` | `invariant_callSummary` could be `pure` |
| forge-lint `erc20-unchecked-transfer` | `test/PreAuditPoC2.t.sol:230`, `test/SLT.t.sol:245` | unchecked `slt.transfer` in tests |
| forge-lint `block-timestamp` | `src/IndexOracle.sol:176`, `src/IndexOracle.sol:207`, `src/MintContract.sol:280` | `block.timestamp` comparison (interval / staleness / timelock checks) |

The build passes. The only `src/` warnings are the three intentional `block.timestamp` comparisons; the rest are in script and test files.

## Tests

`forge test`:
```
Suite result: ok. 6 passed; 0 failed; 0 skipped
Suite result: ok. 32 passed; 0 failed; 0 skipped
Suite result: ok. 6 passed; 0 failed; 0 skipped
Suite result: ok. 31 passed; 0 failed; 0 skipped
Suite result: ok. 37 passed; 0 failed; 0 skipped
Suite result: ok. 29 passed; 0 failed; 0 skipped
Suite result: ok. 11 passed; 0 failed; 0 skipped
Ran 7 test suites in 2.96s (3.23s CPU time): 152 tests passed, 0 failed, 0 skipped (152 total tests)
```

FAIL lines: none.

All 152 tests in the 7 suites pass, with none skipped.

## Invariants

`forge test --match-path "test/invariants/*" -vv`:
```
[PASS] invariant_HolderBalancesUntouchableAfterBurnLock() (runs: 256, calls: 8192, reverts: 0)
[PASS] invariant_MintContractHoldsNoUSDC() (runs: 256, calls: 8192, reverts: 0)
[PASS] invariant_MintContractHoldsNoUSDT() (runs: 256, calls: 8192, reverts: 0)
[PASS] invariant_OracleNeverZero() (runs: 256, calls: 8192, reverts: 0)
[PASS] invariant_SingleMinterForever() (runs: 256, calls: 8192, reverts: 0)
[PASS] invariant_StablecoinsRemainAccepted() (runs: 256, calls: 8192, reverts: 0)
[PASS] invariant_TotalAssetsMathConsistent() (runs: 256, calls: 8192, reverts: 0)
[PASS] invariant_TotalSupplyMatchesMintContractCalls() (runs: 256, calls: 8192, reverts: 0)
[PASS] invariant_USDCDepositsReachTreasury() (runs: 256, calls: 8192, reverts: 0)
[PASS] invariant_USDTDepositsReachTreasury() (runs: 256, calls: 8192, reverts: 0)
[PASS] invariant_callSummary() (runs: 256, calls: 8192, reverts: 0)
Ran 1 test suite in 3.10s (3.10s CPU time): 11 tests passed, 0 failed, 0 skipped (11 total tests)
```

Handler call distribution:
```
| Handler  | adminBurnAttempt       | 832   | 0 | 0 |
| Handler  | grantMinterAttempt     | 793   | 0 | 0 |
| Handler  | mintWithUSDC           | 754   | 0 | 0 |
| Handler  | mintWithUSDT           | 822   | 0 | 0 |
| Handler  | pauseMint              | 844   | 0 | 0 |
| Handler  | pauseOracle            | 823   | 0 | 0 |
| Handler  | unpauseMint            | 820   | 0 | 0 |
| Handler  | unpauseOracle          | 810   | 0 | 0 |
| Handler  | updateOracleIndex      | 851   | 0 | 0 |
| Handler  | widenBurnSourceAttempt | 843   | 0 | 0 |
```

All 11 invariants hold over 256 runs × 8192 calls each, and all 10 handler selectors were exercised. `reverts: 0` is a handler-level figure: the mint/oracle/pause handlers pre-check state and return early, and the M-01/L-04 attack handlers (`adminBurnAttempt`, `widenBurnSourceAttempt`, `grantMinterAttempt`) wrap the expected protocol revert in `try/catch` and *fail the invariant* if the call unexpectedly succeeds (`fail_on_revert = true` in foundry.toml).

## Coverage

`forge coverage --report summary --no-match-coverage "(script|test)"`:
```
| File                 | % Lines           | % Statements      | % Branches      | % Funcs         |
| src/IndexOracle.sol  | 100.00% (52/52)   | 100.00% (70/70)   | 100.00% (10/10) | 100.00% (10/10) |
| src/MintContract.sol | 100.00% (66/66)   | 100.00% (78/78)   | 100.00% (15/15) | 100.00% (9/9)   |
| src/SLT.sol          | 100.00% (63/63)   | 100.00% (72/72)   | 100.00% (16/16) | 100.00% (17/17) |
| Total                | 100.00% (181/181) | 100.00% (220/220) | 100.00% (41/41) | 100.00% (36/36) |
```

`src/` has 100% line, statement, branch and function coverage, above the 95% gate threshold.

## Slither

`slither --version` → `0.11.6` (`/root/.local/bin/slither`).

`slither . --filter-paths "lib|test|script" --exclude-dependencies`:
```
'forge clean' running (wd: /projects/blockxell/lidya/contracts)
'forge config --json' running
'forge build --build-info --deny never --skip ./test/** ./script/** --force' running (wd: /projects/blockxell/lidya/contracts)
INFO:Slither:. analyzed (21 contracts with 102 detectors), 0 result(s) found
```

JSON cross-check (`--json -`): `success True n 0`, impact counter empty.

Findings: **none** (High 0 · Medium 0 · Low 0 · Informational 0 · Optimization 0).

Disclosure: there are 3 inline suppressions in `src/`, all for the `timestamp` detector, at the same lines forge-lint flags:
```
src/IndexOracle.sol:175:        // slither-disable-next-line timestamp
src/IndexOracle.sol:206:        // slither-disable-next-line timestamp
src/MintContract.sol:279:        // slither-disable-next-line timestamp
```
There is no `slither.config.json` in the repo.

Slither reports 0 findings across 102 detectors. The 0 count depends on the 3 `timestamp` suppressions above, which are Low severity by detector class and are disclosed here for the auditor.

## ABI surface

`forge inspect <C> abi` (functions only; `[view]` = view/pure):

**SLT — 40 functions**
BURNER_ROLE [view], DEFAULT_ADMIN_ROLE [view], INDEX_PRECISION [view], MINTER_ADMIN_LOCK [view], MINTER_ROLE [view], PAUSER_ROLE [view], adminBurn(address,uint256), allowance(address,address) [view], approve(address,uint256), authorizedBurnSource(address) [view], balanceOf(address) [view], burnSourceLocked [view], decimals [view], getRoleAdmin(bytes32) [view], grantRole(bytes32,address), hasRole(bytes32,address) [view], indexOracle [view], indexValueForSLT(uint256) [view], isFresh [view], lastUpdateTimestamp [view], lockBurnSource(), lockMinterRole(address), mint(address,uint256), minterCount [view], minterRoleLocked [view], name [view], pause(), paused [view], pricePerShare [view], renounceRole(bytes32,address), revokeRole(bytes32,address), setBurnSource(address,bool), sltForIndexValue(uint256) [view], supportsInterface(bytes4) [view], symbol [view], syntheticTotalValue [view], totalSupply [view], transfer(address,uint256), transferFrom(address,address,uint256), unpause()

**MintContract — 28 functions**
CONFIG_ROLE [view], DEFAULT_ADMIN_ROLE [view], EXPECTED_STABLE_DECIMALS [view], PAUSER_ROLE [view], TREASURY_SAFE_DELAY [view], acceptedStablecoin(address) [view], cancelTreasurySafe(), executeTreasurySafe(), getRoleAdmin(bytes32) [view], grantRole(bytes32,address), hasRole(bytes32,address) [view], indexOracle [view], maxMintAmount [view], minMintAmount [view], mintSLT(address,uint256), pause(), paused [view], pendingTreasurySafe [view], pendingTreasurySafeExecutableAt [view], renounceRole(bytes32,address), revokeRole(bytes32,address), setMintLimits(uint256,uint256), setStablecoinAccepted(address,bool), setTreasurySafe(address), slt [view], supportsInterface(bytes4) [view], treasurySafe [view], unpause()

**IndexOracle — 29 functions**
BPS [view], DEFAULT_ADMIN_ROLE [view], GUARDIAN_ROLE [view], INDEX_PRECISION [view], ORACLE_UPDATER_ROLE [view], SLT_TO_STABLE_SCALE [view], STABLE_PRECISION [view], STALENESS_SLACK [view], getRoleAdmin(bytes32) [view], gracePeriod [view], grantRole(bytes32,address), hasRole(bytes32,address) [view], isFresh [view], lastUpdateTimestamp [view], maxChangeBps [view], minUpdateInterval [view], pause(string), paused [view], pricePerShare [view], renounceRole(bytes32,address), revokeRole(bytes32,address), setGracePeriod(uint256), setMaxChangeBps(uint256), setMinUpdateInterval(uint256), sltToStable(uint256) [view], stableToSLT(uint256) [view], supportsInterface(bytes4) [view], unpause(), updateIndex(uint256)

The v1.1 hardening functions are all in the ABI: `lockBurnSource`, `lockMinterRole(address)`, the treasury timelock trio, and `isFresh` passthrough on SLT. SLT has no `burn`/`burnFrom`; `adminBurn` is the only burn path.

## Commit

```
git rev-parse HEAD   → 2db3d44868ae9c466b9c9794d0ef7b962cb5a9b0
git status --short   → (empty)
```

The working tree was clean at HEAD `2db3d44` when the gate ran, before this report file was written.

---

GATE: PASS
