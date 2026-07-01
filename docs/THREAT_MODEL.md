# SLT V1 — Threat Model

**Status**: Pre-audit (Halborn handoff document)
**Scope**: V1 contracts in `src/` — `IndexOracle.sol`, `SLT.sol`, `MintContract.sol`, plus the Treasury Safe (Gnosis Safe v1.4, no custom code)
**Network**: Avalanche C-Chain (43114), Fuji testnet (43113)
**Last updated**: 2026-05-04

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
SLT (ERC-20 + ERC-4626 view-only metadata)
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
| **Test coverage** | `test_Mint_RevertOnReentrancy` (unit), 8 invariant tests including USDC/USDT balance flow. |

### 3.2 Oracle Manipulation

| Item | Detail |
|---|---|
| **Vector** | A compromised ORACLE_UPDATER_ROLE signer pushes an arbitrary index value to inflate or deflate SLT pricing relative to underlying performance. |
| **Likelihood** | Low (HSM-managed key, Chainlink BUILD operational standards). |
| **Severity** | High — could distort mint pricing and downstream DeFi market valuations. |
| **Mitigation** | Three layers:<br>1. **Per-update bounds**: `IndexOracle.updateIndex()` reverts if `|new − prev| / prev > maxChangeBps` (default 500 bps = 5%; hard ceiling 2000 bps = 20%).<br>2. **Throttle**: minimum 1-hour interval between updates blocks rapid-fire manipulation bursts.<br>3. **Guardian pause**: GUARDIAN_ROLE (Treasury Safe) can call `pause(reason)` to halt all updates pending investigation. |
| **Test coverage** | `test_UpdateIndex_RevertOnExceedingMaxDelta`, `test_UpdateIndex_RevertOnTooFrequent`, `test_UpdateIndex_RevertOnUnauthorized`, `test_Pause_BlocksUpdates`, plus invariant `invariant_OracleNeverZero`. |
| **Residual risk** | Within the ±5% per-day bound, a compromised signer can still push a legitimate-looking but incorrect value. The Treasury Safe's GUARDIAN_ROLE response pattern is documented in operational runbooks. |

### 3.3 Multisig Compromise (Treasury Safe)

| Item | Detail |
|---|---|
| **Vector** | Compromise of 3 or more of the 5 Treasury Safe signers, granting unrestricted access to all admin roles. |
| **Likelihood** | Very Low (3-of-5 quorum across diversified geographic and organizational signers). |
| **Severity** | Catastrophic — quorum holder can grant MINTER_ROLE, change Treasury Safe target, redirect deposits, pause/unpause anything. |
| **Mitigation** | Diversified signer set: founder (Onur Altan Tan), 2 Blockxell engineering, 1 Treasury Manager representative, 1 independent (intended: Hex Trust or Ogier representative). Safe transactions are public on-chain. |
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
| **Likelihood** | Low — index moves are bounded at ±5% per day, capped daily through smoothing in the off-chain engine. Practical capture is ≤5% gross minus DEX fees and gas. |
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
| **Mitigation** | OpenZeppelin AccessControl pattern. DEFAULT_ADMIN_ROLE is granted only to the Treasury Safe in constructor. No backdoor admin paths exist. Constructor revert tests confirm zero-address admin is rejected. |
| **Test coverage** | `test_Constructor_RevertOnZeroAdmin`, role authorization tests on every admin function (`test_Set*_RevertWhenUnauthorized`). |

### 3.9 Integer Overflow / Precision Loss

| Item | Detail |
|---|---|
| **Vector** | Arithmetic overflow or significant precision loss in conversion math (`stableToSLT`, `sltToStable`, `convertToShares`, `convertToAssets`). |
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
3. **Off-chain Performance Engine logic** (NAV computation, smoothing, fee calculation) — bounded by ±5% on-chain limit but not audited as part of contract scope.
4. **Treasury Safe signer key management** — operational security responsibility of each individual signer.
5. **Front-end / wallet application security** — separate scope (Phase 2 frontend audit).
6. **DEX liquidity manipulation** (Trader Joe SLT/USDC pair) — secondary market behavior; not enforced by SLT contracts.
7. **Regulatory or jurisdictional compliance** — addressed at the BVI Issuer SPV and frontend geo-restriction layers.
8. **Cross-chain bridges or Phase 2/3/4 contracts** (`stSLT`, `wSLT`, `InsuranceVault`) — not deployed in V1.

---

## 5. Code-Specific Notes for Auditors

| Area | Note |
|---|---|
| `IndexOracle.updateIndex()` | `block.timestamp` comparisons are `slither-disable-next-line timestamp` annotated. Validator skew (~12s) << throttle (1h). |
| `IndexOracle.stableToSLT/sltToStable` | Refactored to use `SLT_TO_STABLE_SCALE` compile-time constant to avoid divide-before-multiply pattern. Slither now reports zero findings on these functions. |
| `IndexOracle.updateIndex` int256 cast | `int256(deltaBps)` is provably safe — `deltaBps ≤ maxChangeBps ≤ 2000` (hard ceiling), well below `int256.max`. Annotated with `forge-lint: disable-next-line(unsafe-typecast)`. |
| `SLT.adminBurn` | Intentionally NOT gated by `Pausable` so reconciliation remains possible during emergencies. Documented in NatSpec. |
| `MintContract.mintSLT` | Atomic forward pattern: `safeTransferFrom(msg.sender, treasurySafe, amount)` — MintContract never holds stable balance at rest. Invariant-tested under stateful fuzz. |
| `setMaxChangeBps` time-lock | The whitepaper (`oracles.md`) describes admin parameter changes as "subject to time-locked governance." V1 implementation relies on the 3-of-5 Treasury Safe quorum for governance and does not include an on-chain `TimelockController`. **Recommendation for auditor consideration**: either add a 24-48h `TimelockController` on the admin role, or amend the whitepaper to remove the "time-locked" wording. Either path is acceptable from a security standpoint; the choice is operational/communications. |

---

## 6. Coverage and Validation Summary

| Category | Tool / Suite | Status |
|---|---|---|
| Unit tests | Foundry | 88 tests, 100% line/branch/func coverage on `src/` |
| Stateful fuzz | Foundry invariant suite | 9 invariants × 65,536 calls each (CI profile) — zero reverts |
| Static analysis | Slither | 0 findings (after refactor) |
| Static analysis | Mythril | Deferred to Halborn pipeline (sandbox dependency issues) |
| Build lint | forge fmt + forge-lint | Clean, by-design exceptions annotated |

---

## 7. Recommendation Summary for Halborn Engagement

1. **Primary scope**: 3 Solidity files in `src/` (~600 LoC). Treasury Safe is standard Gnosis Safe v1.4 — out of custom-code scope.
2. **Secondary scope (light)**: review the `setMaxChangeBps` time-lock decision (Section 5).
3. **Optional**: Mythril / Manticore symbolic execution as part of standard pipeline.
4. **Test base**: 97 tests provided, all passing. Coverage report and invariant logs in `docs/AUDIT_HANDOFF.md` (separate document).
5. **Engagement sequence**: 2-week private audit → fix loop → Code4rena public contest → Halborn fix re-review → mainnet deploy.

---

**Contact for clarifications**: `altan@blockxell.com`
