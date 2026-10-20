# SLT V1 Smart Contract Architecture

## Overview

SLT (Synthetic Liquidity Token) V1 is a permissionless ERC-20 token deployed on Avalanche C-Chain. Its
on-chain value tracks an off-chain performance index (the ZSB SSF arbitrage strategy) via a
Chainlink-powered custom data feed. SLT is **non-redeemable** — holders exit only via secondary
markets. The token is designed to remain a synthetic, non-security instrument under BVI law
(BVI regulatory memorandum obtained from BVI counsel, 1 Jul 2026).

## Component Diagram

```
                    +------------------------+
                    | Off-chain Performance  |
                    |  Engine (Lidya/Block)  |
                    +-----------+------------+
                                |  signed daily signal
                                v
                    +------------------------+
                    |  Chainlink Custom Data |
                    |     Feed (off-chain)   |
                    +-----------+------------+
                                |  on-chain push
                                v
+------------+  pricePerShare   +------------------+
| SLT.sol    |<-----------------|  IndexOracle.sol |
| (ERC-20)   |                  |  (sanity caps)   |
+-----+------+                  +---------+--------+
      ^ MINTER_ROLE                       ^
      |                                   |  read-only
      |                                   |
+-----+-------------+              +------+--------------------+
| MintContract.sol  |--stable----->|  Treasury Safe (Gnosis)   |
| (USDC/USDT in)    |   transfer   |  3-of-5 multisig          |
+-------------------+              |  (BVI Issuer SPV signers) |
                                   +---------------------------+
```

## Contracts (V1)

### 1. `IndexOracle.sol`

Stores the synthetic performance index for SLT.

- **State**: `pricePerShare` (1e18 scale), `lastUpdateTimestamp`, `maxChangeBps`, `gracePeriod`,
  `minUpdateInterval`.
- **Roles**:
  - `DEFAULT_ADMIN_ROLE` — Treasury Safe; adjusts safety parameters.
  - `ORACLE_UPDATER_ROLE` — Chainlink adapter; pushes new index values.
  - `GUARDIAN_ROLE` — Treasury Safe; pauses updates during anomaly.
- **Invariants**:
  - Constructor `initialIndex` must lie in `[0.1, 10.0]` (1e17–1e19) — a typo guard, not a running band (L-2).
  - Updates throttled to `minUpdateInterval` (20 hours default = hard floor; ceiling 1 day).
  - Per-update change bounded to `maxChangeBps` (500 bps = 5% default = hard ceiling; admin may only lower it),
    evaluated exactly (`delta * 10000 > maxBps * previous` rejects — no rounding slack, L-1).
    The bound is **per update**, not per day; with the 20h floor the worst-case drift is one ±5% step per 20h.
    There is deliberately **no absolute index floor/ceiling** (accepted finding M-04, see THREAT_MODEL §5).
  - `isFresh()` returns `false` after `gracePeriod` (1 day default; range 1–7 days).
  - **M-02 guard**: setters enforce `gracePeriod ≥ minUpdateInterval + STALENESS_SLACK (4h)` so the
    oracle can never be configured into a self-halting state (update lands on the staleness edge).
  - When paused, updates revert and `isFresh()` is `false`; consumers should treat the index as frozen.

### 2. `SLT.sol`

The user-facing ERC-20 token.

- **Inherits**: OpenZeppelin `ERC20`, `AccessControl`, `Pausable`.
- **Roles**:
  - `DEFAULT_ADMIN_ROLE` — Treasury Safe; manages role grants.
  - `MINTER_ROLE` — `MintContract` only. Sealed post-deploy by `lockMinterRole(expectedMinter)`
    (one-way): the call refuses unless `expectedMinter` holds the role, is the only holder
    (`minterCount == 1`), **and** is a deployed contract whose `slt()` returns this token (M-4), then sets the
    role-admin to the `MINTER_ADMIN_LOCK` sentinel. The sentinel
    is its own admin from the constructor, so it can never be granted to anyone (H-01 / L-04).
  - `BURNER_ROLE` — Treasury Safe only; reconciliation and erroneous-mint correction. `adminBurn`
    only works on addresses in `authorizedBurnSource`; the Treasury Safe is authorized at construction
    and `lockBurnSource(expectedSource)` (one-way) seals the set post-deploy. The lock **refuses unless the set
    is exactly `{expectedSource}`** (`authorizedBurnSource[expectedSource] && burnSourceCount == 1`), so a
    pre-lock `setBurnSource` mistake or swap cannot be frozen in. After the lock **no role can ever burn a holder balance** (M-01) — enforced in code, not policy.
  - `PAUSER_ROLE` — Treasury Safe; **global emergency brake** for holder transfers and `mint()`. **`adminBurn`
    is not pausable** (reconciliation must work while paused). Not an address-level restriction: no allowlist,
    denylist, freeze or forced transfer exists (see THREAT_MODEL §5, "Global pause").
- **Index-based read-only metadata** (18-dec index units, deliberately *not* ERC-4626 names):
  `pricePerShare()`, `isFresh()`, `lastUpdateTimestamp()`, `syntheticTotalValue()`,
  `sltForIndexValue()`, `indexValueForSLT()`. **No `deposit/withdraw/redeem/totalAssets/convertTo*`.**
- **No redeem function. No payout in `adminBurn`. Holders never receive treasury assets.**

### 3. `MintContract.sol`

Accepts approved stablecoins and mints SLT at the current index price.

- **Inherits**: OZ `AccessControl`, `Pausable`, `ReentrancyGuard`.
- **Roles**:
  - `DEFAULT_ADMIN_ROLE` — Treasury Safe.
  - `CONFIG_ROLE` — Treasury Safe; proposes (24h) / executes / cancels stablecoin additions, delists immediately; sets mint limits.
  - `PAUSER_ROLE` — Treasury Safe.
- **Mint flow**:
  1. User calls `mintSLT(stablecoin, amount)` or `mintSLT(stablecoin, amount, minSltOut, deadline)`.
  2. Contract checks: deadline not passed, stablecoin whitelisted, amount within bounds, oracle fresh,
     SLT out ≥ `minSltOut`.
  3. Stablecoin pulled from user straight to the Treasury Safe via one `safeTransferFrom`; the Safe's
     balance delta must equal `amount` (L-6 receipt check).
  4. SLT minted to user at current `pricePerShare`.
  5. Event emitted with stable amount, SLT amount, index used.
- **Critical invariant**: Contract NEVER holds stablecoin balance after a successful mint
  (verified by `invariant_MintContractHoldsNoUSDC/USDT`).
- **Stablecoin whitelist (H-1)**: seeded in the constructor (USDC, USDt; each must report 6 decimals — the
  conversion math assumes 6-dec). Later additions are timelocked: `setStablecoinAccepted(token, true)` *proposes*,
  `executeStablecoinAccepted(token)` applies after `STABLECOIN_DELAY = 24h` (decimals re-checked),
  `cancelStablecoinProposal(token)` aborts. Delisting is immediate and cancels any pending proposal.
- **Slippage protection (M-1)**: `mintSLT(stable, amount, minSltOut, deadline)` reverts if the SLT out would be
  below the caller's floor or the deadline has passed; the 2-arg `mintSLT` is kept for interface stability.
- **Receipt check (L-6)**: the Treasury Safe's balance is read before/after the pull; any shortfall reverts.
  Side effect: the Safe cannot mint for itself (zero-delta self-transfer) — intended.
- **Treasury Safe change (M-03)**: `setTreasurySafe(new)` only *proposes*; `executeTreasurySafe()` applies
  it after `TREASURY_SAFE_DELAY = 24h`; `cancelTreasurySafe()` aborts. Deposits keep flowing to the
  current safe until execution. In-contract timelock — no external `TimelockController`.

### 4. Treasury Safe (Gnosis Safe)

Off-the-shelf Gnosis Safe deployed via `safe.global` UI.

- **Signer composition**: 3-of-5
  - Onur Altan Tan (Blockxell founder)
  - Blockxell engineering signer
  - Blockxell operations signer
  - Lidya treasury manager rep
  - Independent external signer (e.g., legal counsel or board observer)
- **Holds**:
  - All USDC/USDT received from minting.
  - Admin/Guardian/Pauser roles on all SLT contracts.
  - Authority to grant/revoke `CONFIG_ROLE`, `PAUSER_ROLE`, `BURNER_ROLE`, etc. — **not** `MINTER_ROLE` once `lockMinterRole` has run.

## Roles Matrix

| Role                    | Holder         | Authority                                    |
| ----------------------- | -------------- | -------------------------------------------- |
| `DEFAULT_ADMIN_ROLE`    | Treasury Safe  | Manage role grants (except MINTER after lock); propose → 24h → execute, or cancel, Treasury Safe change (M-03) |
| `MINTER_ROLE` (SLT)     | MintContract   | Mint SLT to depositors — sole holder, sealed by `lockMinterRole(MintContract)` |
| `BURNER_ROLE` (SLT)     | Treasury Safe  | Reconciliation burns from `authorizedBurnSource` only (= Treasury Safe, sealed by `lockBurnSource`) |
| `PAUSER_ROLE`           | Treasury Safe  | Emergency pause                              |
| `CONFIG_ROLE` (Mint)    | Treasury Safe  | Propose → 24h → execute stablecoin additions (H-1); instant delist; mint limits |
| `ORACLE_UPDATER_ROLE`   | Chainlink feed | Push new index values                        |
| `GUARDIAN_ROLE` (Oracle)| Treasury Safe  | Pause oracle in anomalies                    |

## Threat Model

### In Scope

- **Smart contract logic**: reentrancy, integer overflow/underflow, access control bypass,
  oracle manipulation, frontrunning of index updates.
- **Stablecoin transfer**: handle non-standard ERC-20 implementations safely (USDT historic
  approve race, USDC blacklist behavior).
- **Multisig compromise**: assume 1-2 signers compromised; 3-of-5 quorum protects.
- **Oracle bound bypass**: ensure `maxChangeBps` cannot be set to 0 or excessive value;
  guardian pause cannot be bypassed.

### Out of Scope (V1)

- Cross-chain logic (no LayerZero/CCIP in V1; deferred to Phase 4).
- Staking/yield wrappers (`stSLT` deferred to Phase 2).
- Rebase wrapper (`rSLT` deferred to Phase 2/3).
- Lending market parameter setting (handled by external protocols: BENQI, Morpho).

## Audit Targets

- **External audit** on tag `v1.1.1-audit`: RFQ to Halborn / Zealynx / Cantina — full audit of SLT,
  MintContract, IndexOracle + deploy script and role topology. One fix-verification round included.
- **Pre-audit assurance**: independent pre-review (Moment Research, Sep 2026) + second independent review
  (Oct 2026, all findings closed in v1.1.1), 190 Foundry tests, 100% line/branch/function coverage on `src/`,
  11 stateful invariants, Slither 0 findings (`SECURITY_CHECK_20Oct2026.md`).

## Post-deploy lock sequence (mainnet, Safe transactions)

1. `SLT.grantRole(MINTER_ROLE, MintContract)`
2. (whitelist is seeded in the constructor — nothing to do; later additions take 24h)
3. `IndexOracle` updater is set at deploy (`ORACLE_UPDATER_ADDRESS`); rotate via Safe only if the adapter key changes
4. Verify on-chain: `minterCount() == 1`, `hasRole(MINTER_ROLE, MintContract)`, `MintContract.slt() == SLT`, `burnSourceCount() == 1`, `authorizedBurnSource(Safe) == true`, `acceptedStablecoin(USDC/USDt) == true`
5. `SLT.lockMinterRole(MintContract)` — one-way; reverts unless the minter set is exactly `{MintContract}` and it is wired to this token
6. `SLT.lockBurnSource(Safe)` — one-way; reverts unless the burn-source set is exactly `{Safe}`

## References

- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts)
- [Mountain Protocol USDM (Etherscan)](https://etherscan.io/token/0x59d9356e565ab3a36dd77763fc0d87feaf85508c) — permissionless mint pattern reference.
- [Ethena StakedUSDe (sUSDe)](https://etherscan.io/token/0x9d39a5de30e57443bff2a8307a4256c8797a3497) — ERC-4626 staking vault reference (for Phase 2 stSLT).
- [Frax sFRAX](https://docs.frax.finance/frax-v3-100-cr-and-more/sfrax) — `LinearRewardsErc4626` pattern reference (for Phase 2).
- [Chainlink BUILD program](https://chain.link/build) — custom data feed integration.
- [Gnosis Safe](https://safe.global) — multisig deployment.
