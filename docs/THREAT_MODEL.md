# SLT V1 — Threat Model

**Status**: v1.1-audit — frozen for external audit (RFQ: Halborn / Zealynx / Cantina)
**Scope**: V1 contracts in `src/` — `IndexOracle.sol`, `SLT.sol`, `MintContract.sol`, plus the Treasury Safe (Gnosis Safe v1.4, no custom code)
**Network**: Avalanche C-Chain (43114), Fuji testnet (43113)
**Last updated**: 2026-10-15 (v1.1-audit: H-01, M-01, M-02, M-03, L-04 fixed; M-04 accepted)

---

## 1. System Overview

SLT V1 is a permissionless ERC-20 token whose value tracks an off-chain performance index, enforced on-chain by three small contracts and a 3-of-5 multisig:

```
User wallet
   │ (USDC/USDT approve + mintSLT call)
   ▼
MintContract  ─── pulls stable, atomic forward ───▶  Treasury Safe (Gnosis 3-of-5)
   │ (calls indexOracle.isFresh + pricePerShare)
   ▼
IndexOracle  ◀── daily push ── Chainlink Adapter ── signed off-chain SPR signal
   │
   ▼
SLT (ERC-20 + index-based view-only metadata; no ERC-4626 surface)
   │ mint to user
```

**No redemption mechanism exists on-chain.** Holders exit only via secondary markets (Trader Joe DEX). The Treasury Safe is the central admin authority but is never the direct minter; only the Mint Contract can mint SLT.

---

## 2. Trust Boundaries

| Component | Trust Level | Justification |
|---|---|---|
| **User wallet** | Untrusted | Permissionless interaction |
| **MintContract** | Trusted code, audit-validated | Fully on-chain, deterministic, no admin keys can change accounting logic |
| **SLT contract** | Trusted code, audit-validated | Same |
| **IndexOracle** | Trusted code, audit-validated logic + trusted ORACLE_UPDATER signer | Code is bounded; the index value pushed is signed off-chain |
| **Treasury Safe (Gnosis)** | Trusted multisig (3-of-5) | Standard Safe v1.4 contracts, no custom code; quorum required for state changes |
| **Chainlink Adapter** | Trusted under standard Chainlink BUILD program assumptions | HSM-managed signing key; rotation supported via Safe role updates |
| **USDC, USDT contracts** | External, audited stablecoin issuers | Use SafeERC20 to defend against non-standard returns |
| **Off-chain Performance Engine** | Trusted operator (Treasury Manager + Blockxell) | Outside the on-chain trust boundary; on-chain bounds (±5%) limit damage from a buggy or malicious signal |

---

## 3. Attack Vectors and Mitigations

### 3.1 Reentrancy

| Item | Detail |
|---|---|
| **Vector** | A malicious or compromised stablecoin token re-enters `MintContract.mintSLT()` from inside its own `transferFrom` to mint additional SLT before the first call settles, or to drain by repeated re-entry. |
| **Likelihood** | Low (whitelisted stablecoins are USDC and USDT.e, both audited and standards-compliant). |
| **Severity** | High if exploited. |
| **Mitigation** | `mintSLT()` is decorated with `nonReentrant` (OZ ReentrancyGuard). Whitelist control by CONFIG_ROLE means a malicious token cannot be added without 3-of-5 multisig consent. Invariant tests include a `ReentrantUSDC` mock that confirms re-entry reverts. |
| **Test coverage** | `test_Mint_RevertOnReentrancy` (unit), 11 invariant tests including USDC/USDT balance flow. |

### 3.2 Oracle Manipulation

| Item | Detail |
|---|---|
| **Vector** | A compromised ORACLE_UPDATER_ROLE signer pushes an arbitrary index value to inflate or deflate SLT pricing relative to underlying performance. |
| **Likelihood** | Low (HSM-managed key, Chainlink BUILD operational standards). |
| **Severity** | High — could distort mint pricing and downstream DeFi market valuations. |
| **Mitigation** | Three layers:<br>1. **Per-update bounds**: `IndexOracle.updateIndex()` reverts if `|new − prev| / prev > maxChangeBps` (default 500 bps = 5% = hard ceiling; admin may only lower it).<br>2. **Throttle**: `minUpdateInterval` floor 20 hours (default), ceiling 1 day — one bounded step per ~day; `gracePeriod ≥ minUpdateInterval + 4h` is enforced so the throttle can never starve `isFresh()` (M-02).<br>3. **Guardian pause**: GUARDIAN_ROLE (Treasury Safe) can call `pause(reason)` to halt all updates pending investigation. |
| **Test coverage** | `test_UpdateIndex_RevertOnExceedingMaxDelta`, `test_UpdateIndex_RevertOnTooFrequent`, `test_UpdateIndex_RevertOnUnauthorized`, `test_Pause_BlocksUpdates`, plus invariant `invariant_OracleNeverZero`. |
| **Residual risk** | Within the ±5% **per-update** bound (one update per ≥20h), a compromised signer can still push a legitimate-looking but incorrect value, and a sustained walk compounds (36 max-steps ≈ 30 days → ≈0.16× or ≈5.8× — **M-04, accepted**, see §5). The Treasury Safe's GUARDIAN_ROLE response pattern (pause within one update interval) is the control; it is documented in operational runbooks. |

### 3.3 Multisig Compromise (Treasury Safe)

| Item | Detail |
|---|---|
| **Vector** | Compromise of 3 or more of the 5 Treasury Safe signers, granting unrestricted access to all admin roles. |
| **Likelihood** | Very Low (3-of-5 quorum across diversified geographic and organizational signers). |
| **Severity** | High — quorum holder can pause/unpause, change oracle parameters within hard bounds, and *propose* a Treasury Safe change. It **cannot** grant MINTER_ROLE after `lockMinterRole` (H-01 fix: sentinel sealed in constructor), **cannot** burn holder balances after `lockBurnSource` (M-01), and a Treasury Safe redirect only takes effect 24h after proposal and is cancellable (M-03). |
| **Mitigation** | Code-level: `lockMinterRole(expectedMinter)`, `lockBurnSource()`, 24h treasury timelock. Operational: diversified 3-of-5 signer set as listed in ARCHITECTURE §4 (founder, Blockxell engineering, Blockxell operations, Lidya treasury manager rep, independent external signer). Safe transactions are public on-chain. |
| **Residual risk** | Out of scope for smart contract audit; mitigated through operational and key-management hygiene. |

### 3.4 Stablecoin Behavior Anomalies

| Item | Detail |
|---|---|
| **Vector** | USDT historically permitted approve-race attacks (must zero allowance before re-approving); some non-standard tokens silently fail without reverting; USDC implements blacklisting. |
| **Likelihood** | USDT approve race is negligible at MintContract level (we never re-approve from MintContract — we only `safeTransferFrom`). USDC blacklist could theoretically block deposits or transfers from blacklisted addresses. |
| **Severity** | Low — affects individual blacklisted users, not protocol integrity. |
| **Mitigation** | All ERC-20 calls go through `SafeERC20`, which checks return values and reverts on failure. Whitelist is finite (USDC + USDT.e on V1). Adding a new stablecoin requires 3-of-5 Treasury Safe consent. |
| **Test coverage** | Standard SafeERC20 path covered by `test_Mint_HappyPath` and edge revert tests. |

### 3.5 Front-Running at Oracle Update Boundary

| Item | Detail |
|---|---|
| **Vector** | A user observes a pending oracle update transaction in mempool predicting a positive index move and front-runs with a mint at the lower current index, then sells immediately after the update. |
| **Likelihood** | Low — index moves are bounded at ±5% per update with a ≥20h interval, capped daily through smoothing in the off-chain engine. Practical capture is ≤5% gross minus DEX fees and gas. |
| **Severity** | Low — does not harm protocol balance integrity, only marginal value extraction from the user's own funds. |
| **Mitigation** | The `Minted` event records the exact `indexUsed`, providing transparency. Avalanche C-Chain has shorter block times (~2s) and lower mempool-visibility windows than Ethereum, reducing the practical attack window. The mint cap (`maxMintAmount = $5M per tx`) bounds individual capture. |
| **Residual risk** | Accepted as a normal market-microstructure phenomenon, comparable to sUSDe and other index-tracking tokens. |

### 3.6 Mint Cap Exhaustion / Griefing

| Item | Detail |
|---|---|
| **Vector** | An attacker repeatedly mints small amounts to inflate `totalSupply` for downstream griefing (e.g., DeFi market manipulation, liquidity dilution). |
| **Likelihood** | Low — each mint requires bringing real stablecoin into the Treasury Safe. The "attack" is functionally identical to a legitimate user mint. |
| **Severity** | Negligible — supply growth tracks deposit growth. |
| **Mitigation** | Mint floor (`minMintAmount = $1,000`) prevents dust-spam griefing. Supply growth is deterministic with deposits and visible on-chain. |
| **Residual risk** | Out of scope; not a vulnerability. |

### 3.7 Stale Oracle Mint

| Item | Detail |
|---|---|
| **Vector** | A user attempts to mint SLT after an oracle outage, while the index is still showing the pre-outage value (potentially significantly stale). |
| **Likelihood** | Possible during real Chainlink outages or network congestion. |
| **Severity** | Medium — minting at a stale index could produce SLT priced incorrectly relative to current strategy performance. |
| **Mitigation** | `MintContract.mintSLT()` calls `indexOracle.isFresh()` before processing. If the oracle is stale (`block.timestamp - lastUpdate > gracePeriod`, default 1 day) or paused, the mint reverts with `MintContract_OracleStale`. Existing SLT balances are unaffected. |
| **Test coverage** | `test_Mint_RevertWhenOracleStale`. |

### 3.8 Role Escalation via Unauthorized Grant

| Item | Detail |
|---|---|
| **Vector** | An unauthorized address attempts to grant itself or an accomplice MINTER_ROLE / BURNER_ROLE / CONFIG_ROLE to mint SLT, burn user tokens, or whitelist a malicious stablecoin. |
| **Likelihood** | Very low — role grants require DEFAULT_ADMIN_ROLE, held only by the Treasury Safe. |
| **Severity** | High if exploited. |
| **Mitigation** | OpenZeppelin AccessControl pattern. DEFAULT_ADMIN_ROLE is granted only to the Treasury Safe in constructor. **History (H-01, Moment Research Sep 2026):** in `v1.1-prereview` the `MINTER_ADMIN_LOCK` sentinel could be granted by DEFAULT_ADMIN *before* `lockMinterRole()`, creating a permanent backdoor to grant MINTER_ROLE after the lock — an admin-path backdoor did exist and was exploitable (1,000,000 SLT in the PoC). Fixed in `b088846`: the sentinel is made its own role-admin in the constructor, so it can never be held; `lockMinterRole(expectedMinter)` additionally refuses to seal unless the minter set is exactly `{expectedMinter}` (L-04). After the lock, no address can grant/revoke MINTER_ROLE. BURNER_ROLE grants remain possible but are useless against holders once `lockBurnSource()` has run (M-01). |
| **Test coverage** | `test_Constructor_RevertOnZeroAdmin`, `test_PoC_LockSentinelCannotBePreGranted`, `test_PoC_SentinelUnheldBeforeAndAfterLock`, `test_L04_*`, `testFuzz_M01_HolderBalanceUntouchableAfterLock`, invariants `invariant_SingleMinterForever`, `invariant_HolderBalancesUntouchableAfterBurnLock`, role authorization tests on every admin function (`test_Set*_RevertWhenUnauthorized`). |

### 3.9 Integer Overflow / Precision Loss

| Item | Detail |
|---|---|
| **Vector** | Arithmetic overflow or significant precision loss in conversion math (`stableToSLT`, `sltToStable`, `sltForIndexValue`, `indexValueForSLT`). |
| **Likelihood** | Solidity 0.8+ reverts on arithmetic overflow by default. Precision loss at 18-decimal scale is below 1 wei for all realistic inputs. |
| **Severity** | None at current input ranges. |
| **Mitigation** | Constants hoisted to compile-time values (`SLT_TO_STABLE_SCALE = 1e12`) so multiply happens before divide where possible. `maxMintAmount = $5M (5e12 in 6-dec)` × `SLT_TO_STABLE_SCALE (1e12)` × `INDEX_PRECISION (1e18)` = 5e42, well within uint256.max (~1.16e77). |
| **Test coverage** | Math fuzz `testFuzz_UpdateIndex_WithinBounds` (1000 runs default, 10_000 in CI), `test_StableToSLT_RoundTrip`, `test_SltToStable_RoundTrip`. |

### 3.10 Non-Atomic Stable Forward (Hypothetical)

| Item | Detail |
|---|---|
| **Vector** | If a future code change broke the atomic forward (stable transferred to MintContract first, then later forwarded), an attacker could grief by causing a partial state. |
| **Likelihood** | None in current code — `safeTransferFrom(msg.sender, treasurySafe, amount)` directly forwards. MintContract never holds stable. |
| **Mitigation** | Invariant tests `invariant_MintContractHoldsNoUSDC` and `invariant_MintContractHoldsNoUSDT` enforce zero balance across 65,536 random state transitions in CI profile. Any future regression that breaks this property will fail the invariant suite. |

---

## 4. Out-of-Scope Threats

The following are explicitly outside the V1 smart contract audit scope:

1. **Avalanche C-Chain validator failures or chain-level reorgs** — Layer-1 risk inherited from Avalanche, not addressable at contract level.
2. **Off-chain Treasury operations** (capital allocation between Treasury Safe, Hex Trust custody, and Treasury Manager) — governed by management agreements and Hex Trust custody contracts, not on-chain code.
3. **Off-chain Performance Engine logic** (NAV computation, smoothing, fee calculation) and the engine→`updateIndex` signing path (key custody, rotation, NAV attestation) — bounded by the ±5%/update on-chain limit but not audited as part of contract scope. This is the largest known residual risk and is being addressed operationally (HSM, attestation).
4. **Treasury Safe signer key management** — operational security responsibility of each individual signer.
5. **Front-end / wallet application security** — separate scope (Phase 2 frontend audit).
6. **DEX liquidity manipulation** (Trader Joe SLT/USDC pair) — secondary market behavior; not enforced by SLT contracts.
7. **Regulatory or jurisdictional compliance** — addressed at the BVI Issuer SPV and frontend geo-restriction layers.
8. **Cross-chain bridges or Phase 2/3/4 contracts** (`stSLT`, `wSLT`, `InsuranceVault`) — not deployed in V1.

---

## 5. Code-Specific Notes for Auditors

| Area | Note |
|---|---|
| `IndexOracle.updateIndex()` | `block.timestamp` comparisons are `slither-disable-next-line timestamp` annotated. Validator skew (~12s) << throttle (20h). |
| `IndexOracle.stableToSLT/sltToStable` | Refactored to use `SLT_TO_STABLE_SCALE` compile-time constant to avoid divide-before-multiply pattern. Slither now reports zero findings on these functions. |
| `IndexOracle.updateIndex` int256 cast | `int256(deltaBps)` is provably safe — `deltaBps ≤ maxChangeBps ≤ 500` (hard ceiling), well below `int256.max`. Annotated with `forge-lint: disable-next-line(unsafe-typecast)`. |
| `SLT.adminBurn` | Intentionally NOT gated by `Pausable` so reconciliation remains possible during emergencies. Documented in NatSpec. |
| `MintContract.mintSLT` | Atomic forward pattern: `safeTransferFrom(msg.sender, treasurySafe, amount)` — MintContract never holds stable balance at rest. Invariant-tested under stateful fuzz. |
| `MintContract.setTreasurySafe` (M-03) | In-contract 24h timelock: `setTreasurySafe` proposes, `executeTreasurySafe` applies after `TREASURY_SAFE_DELAY`, `cancelTreasurySafe` aborts. No external `TimelockController` (keeps role topology minimal). Oracle parameter setters are **not** timelocked — they are bounded by hard floors/ceilings and governed by the 3-of-5 quorum; the whitepaper wording "time-locked governance" applies to the Treasury Safe change only. |
| `SLT.lockMinterRole(address)` — see §5.1 Deliberate signature changes | v1.1-prereview had `lockMinterRole()`. v1.1-audit takes `expectedMinter` (L-04) so a mis-wired deployment cannot be sealed. No deployed mainnet contract is affected; Fuji is redeployed. All other v1.0/v1.1 public signatures are unchanged (`setTreasurySafe(address)` kept, semantics now propose-only). |
| **M-04 — no absolute index floor/ceiling (known, accepted)** | The ±5% per-update bound limits *speed*, not *direction*: at the 20h floor, 36 consecutive max-steps (~30 days) reach ≈0.16× or ≈5.8× of the starting index without any single update being rejected. We deliberately do **not** add an absolute band: (a) the index tracks a real strategy whose NAV may legitimately trend; a hard band would require governance to move it and becomes a de-facto peg/price commitment, which counsel's structure excludes; (b) a slow walk is observable on-chain for weeks and the GUARDIAN pause is the designed response; (c) off-chain attestation of the published index against treasury NAV is the control for this class of risk and is outside contract scope. Auditors are asked to assess, not to remove, this decision. |

### 5.1 Deliberate signature changes (v1.1-prereview → v1.1-audit)

| Function | Before | After | Reason |
|---|---|---|---|
| `SLT.lockMinterRole` | `lockMinterRole()` | `lockMinterRole(address expectedMinter)` | L-04: refuse to seal a minter set that is not exactly `{expectedMinter}`. Selector changes; no mainnet deployment exists, Fuji is redeployed. |

All other v1.0/v1.1 public signatures are unchanged. `setTreasurySafe(address)` keeps its signature; semantics are now propose-only (M-03).

**Additions in v1.1-audit** (full list in `docs/ABI_BASELINE_v1.1.txt`): `SLT.lockBurnSource()`, `SLT.burnSourceLocked()`, `SLT.minterCount()`, `MintContract.executeTreasurySafe()`, `MintContract.cancelTreasurySafe()`, `MintContract.pendingTreasurySafe()`, `MintContract.pendingTreasurySafeExecutableAt()`, `MintContract.TREASURY_SAFE_DELAY()`, `IndexOracle.STALENESS_SLACK()`.

---

## 6. Coverage and Validation Summary

| Category | Tool / Suite | Status |
|---|---|---|
| Unit + fuzz tests | Foundry | 152 tests (incl. 2 PoC regression files + `HardeningV11.t.sol`), 100% line/statement/branch/function coverage on `src/` |
| Stateful fuzz | Foundry invariant suite | 11 invariants × 8,192 calls (default profile; 65,536 in CI profile) — zero reverts; includes INV-8 (holder balances untouchable after burn lock) and INV-9 (single minter forever) |
| Static analysis | Slither 0.11.6 | 0 findings (21 contracts, 102 detectors; `--filter-paths "lib|test|script" --exclude-dependencies`) |
| Static analysis | Mythril | Deferred to Halborn pipeline (sandbox dependency issues) |
| Build lint | forge fmt + forge-lint | Clean, by-design exceptions annotated |

---

## 7. Recommendation Summary for the External Audit (tag `v1.1-audit`)

1. **Primary scope**: 3 Solidity files in `src/` + 2 interfaces, plus `script/Deploy.s.sol` and the post-deploy lock sequence. Treasury Safe is standard Gnosis Safe v1.4 — out of custom-code scope.
2. **Design decisions to assess, not remove**: non-redeemable / immutable / permissionless-transfer structure; M-04 (Section 5); in-contract treasury timelock vs. `TimelockController`.
3. **Optional**: Mythril / Manticore symbolic execution as part of standard pipeline.
4. **Test base**: 152 tests, all passing; coverage and invariant logs in `SECURITY_CHECK_15Oct2026.md`.
5. **Engagement sequence**: external audit → fix loop → fix re-review on the fix commit → mainnet deploy.

---

**Contact for clarifications**: `altan@blockxell.com`
