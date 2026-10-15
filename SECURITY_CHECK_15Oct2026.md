# SECURITY CHECK — 15 Oct 2026 (v1.1-audit tag candidate)

Generated `Thu Oct 15 05:31:09 PM UTC 2026` (`date -u`). Every figure below is quoted from a command run in this session against commit `4db581d373ea83c3e33536f42aa949f5cab663d6`.

## Toolchain

```
$ forge --version
forge Version: 1.6.0-v1.7.0
Commit SHA: f83bad912a9dba7bf0371def1e70bb1896048356
Build Timestamp: 2026-04-28T14:07:10.568929921Z (1777385230)
Build Profile: dist

$ grep foundry.toml
solc_version = "0.8.24"
optimizer = true
optimizer_runs = 200
auto_detect_solc = false

$ cat foundry.lock
lib/forge-std               tag v1.16.2  rev bf647bd6046f2f7da30d0c2bf435e5c76a780c1b
lib/openzeppelin-contracts  tag v5.6.1   rev 5fd1781b1454fd1ef8e722282f86f9293cacf256

$ slither --version
0.11.6
```

The compiler is pinned to solc 0.8.24 with auto-detect off, and both dependencies are pinned by tag and rev.

`forge fmt --check`: exit 0, no output. Formatting is clean.

## Build

```
$ forge build --force
Compiling 51 files with Solc 0.8.24
Solc 0.8.24 finished in 50.55s
Compiler run successful with warnings:
```

Compiler warnings:
- `Warning (2072): Unused local variable.` at `script/Deploy.s.sol:62:9`
- `Warning (2018): Function state mutability can be restricted to pure` at `test/invariants/SLTInvariants.t.sol:174:5`

forge-lint notes:
- `warning[block-timestamp]` at `src/IndexOracle.sol:176:13`, `src/IndexOracle.sol:207:29`, `src/MintContract.sol:280:13`
- `warning[erc20-unchecked-transfer]` at `test/PreAuditPoC2.t.sol:230:9`, `test/SLT.t.sol:245:9`

The build succeeds (exit 0). The compiler warnings are only in script/ and test/. The three block-timestamp lint hits in src/ are the oracle staleness/interval checks and the treasury-safe timelock, where a validator can only shift the timestamp by seconds.

## Tests

```
$ forge test
Ran 7 test suites in 4.87s (9.82s CPU time): 155 tests passed, 0 failed, 0 skipped (155 total tests)
```

FAIL lines: none (`grep FAIL` returned nothing).

All 155 tests pass. The previous gate reported 152; the increase comes from the M-01 tests in `1ac0eee`.

## Invariants

```
$ forge test --match-path "test/invariants/*" -vv
Ran 11 tests for test/invariants/SLTInvariants.t.sol:SLTInvariantsTest
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
Suite result: ok. 11 passed; 0 failed; 0 skipped; finished in 3.15s (11.59s CPU time)
```

All 11 invariants hold over 256 runs × 8192 calls each, with 0 reverts.

## Coverage

```
$ forge coverage --report summary --no-match-coverage "(script|test)"
| File                 | % Lines           | % Statements      | % Branches      | % Funcs         |
| src/IndexOracle.sol  | 100.00% (52/52)   | 100.00% (70/70)   | 100.00% (10/10) | 100.00% (10/10) |
| src/MintContract.sol | 100.00% (66/66)   | 100.00% (78/78)   | 100.00% (15/15) | 100.00% (9/9)   |
| src/SLT.sol          | 100.00% (68/68)   | 100.00% (82/82)   | 100.00% (19/19) | 100.00% (17/17) |
| Total                | 100.00% (186/186) | 100.00% (230/230) | 100.00% (44/44) | 100.00% (36/36) |
```

src/ has 100% line, statement, branch and function coverage, above the 95% line threshold.

## Slither

```
$ slither . --filter-paths "lib|test|script" --exclude-dependencies
INFO:Slither:. analyzed (21 contracts with 102 detectors), 0 result(s) found
```

Findings: none (0 High, 0 Medium, 0 Low, 0 Informational). Slither 0.11.6 at `/root/.local/bin/slither` ran successfully.

## ABI surface

`forge inspect <C> abi`, function names (`[view]` = view/pure):

**SLT**: 41 functions, 10 events, 19 errors
BURNER_ROLE [view], DEFAULT_ADMIN_ROLE [view], INDEX_PRECISION [view], MINTER_ADMIN_LOCK [view], MINTER_ROLE [view], PAUSER_ROLE [view], adminBurn(address,uint256), allowance [view], approve(address,uint256), authorizedBurnSource(address) [view], balanceOf [view], burnSourceCount [view], burnSourceLocked [view], decimals [view], getRoleAdmin [view], grantRole(bytes32,address), hasRole [view], indexOracle [view], indexValueForSLT(uint256) [view], isFresh [view], lastUpdateTimestamp [view], lockBurnSource(), lockMinterRole(address), mint(address,uint256), minterCount [view], minterRoleLocked [view], name [view], pause(), paused [view], pricePerShare [view], renounceRole(bytes32,address), revokeRole(bytes32,address), setBurnSource(address,bool), sltForIndexValue(uint256) [view], supportsInterface [view], symbol [view], syntheticTotalValue [view], totalSupply [view], transfer(address,uint256), transferFrom(address,address,uint256), unpause()

**MintContract**: 28 functions, 11 events, 14 errors
CONFIG_ROLE [view], DEFAULT_ADMIN_ROLE [view], EXPECTED_STABLE_DECIMALS [view], PAUSER_ROLE [view], TREASURY_SAFE_DELAY [view], acceptedStablecoin(address) [view], cancelTreasurySafe(), executeTreasurySafe(), getRoleAdmin [view], grantRole(bytes32,address), hasRole [view], indexOracle [view], maxMintAmount [view], minMintAmount [view], mintSLT(address,uint256), pause(), paused [view], pendingTreasurySafe [view], pendingTreasurySafeExecutableAt [view], renounceRole(bytes32,address), revokeRole(bytes32,address), setMintLimits(uint256,uint256), setStablecoinAccepted(address,bool), setTreasurySafe(address), slt [view], supportsInterface [view], treasurySafe [view], unpause()

**IndexOracle**: 29 functions, 11 events, 8 errors
BPS [view], DEFAULT_ADMIN_ROLE [view], GUARDIAN_ROLE [view], INDEX_PRECISION [view], ORACLE_UPDATER_ROLE [view], SLT_TO_STABLE_SCALE [view], STABLE_PRECISION [view], STALENESS_SLACK [view], getRoleAdmin [view], gracePeriod [view], grantRole(bytes32,address), hasRole [view], isFresh [view], lastUpdateTimestamp [view], maxChangeBps [view], minUpdateInterval [view], pause(string), paused [view], pricePerShare [view], renounceRole(bytes32,address), revokeRole(bytes32,address), setGracePeriod(uint256), setMaxChangeBps(uint256), setMinUpdateInterval(uint256), sltToStable(uint256) [view], stableToSLT(uint256) [view], supportsInterface [view], unpause(), updateIndex(uint256)

This is the external surface the auditors will review: 98 functions across the three contracts.

## Commit

```
$ git rev-parse HEAD
4db581d373ea83c3e33536f42aa949f5cab663d6
$ git status --short
(empty — clean tree before this file was written)
```

The checks ran on a clean tree at `4db581d` (branch `v1.1-prereview`). The only change after the run is this report file.

---

GATE: PASS
