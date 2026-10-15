# SLT V1 Smart Contract Architecture

## Overview

SLT (Synthetic Liquidity Token) V1 is a permissionless ERC-20 token deployed on Avalanche C-Chain. Its
on-chain value tracks an off-chain performance index (the ZSB SSF arbitrage strategy) via a
Chainlink-powered custom data feed. SLT is **non-redeemable** — holders exit only via secondary
markets. The token is designed to remain a synthetic, non-security instrument under BVI law
(pending Harneys legal opinion).

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
  - Updates throttled to `minUpdateInterval` (20 hours default = hard floor; ceiling 1 day).
  - Per-update change bounded to `maxChangeBps` (500 bps = 5% default = hard ceiling; admin may only lower it).
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
    (one-way): the call refuses unless `expectedMinter` holds the role **and** it is the only holder
    (`minterCount == 1`), then sets the role-admin to the `MINTER_ADMIN_LOCK` sentinel. The sentinel
    is its own admin from the constructor, so it can never be granted to anyone (H-01 / L-04).
  - `BURNER_ROLE` — Treasury Safe only; reconciliation and erroneous-mint correction. `adminBurn`
    only works on addresses in `authorizedBurnSource`; the Treasury Safe is authorized at construction
    and `lockBurnSource()` (one-way) seals the set post-deploy. The lock **refuses unless the set is exactly
    one address** (`burnSourceCount == 1`), so a pre-lock `setBurnSource` addition cannot be frozen in by
    mistake. After the lock **no role can ever burn a holder balance** (M-01) — enforced in code, not policy.
  - `PAUSER_ROLE` — Treasury Safe; emergency pause for holder transfers and mints. **`adminBurn` is
    not pausable** (reconciliation must work while paused).
- **Index-based read-only metadata** (18-dec index units, deliberately *not* ERC-4626 names):
  `pricePerShare()`, `isFresh()`, `lastUpdateTimestamp()`, `syntheticTotalValue()`,
  `sltForIndexValue()`, `indexValueForSLT()`. **No `deposit/withdraw/redeem/totalAssets/convertTo*`.**
- **No redeem function. No payout in `adminBurn`. Holders never receive treasury assets.**

### 3. `MintContract.sol`

Accepts approved stablecoins and mints SLT at the current index price.

- **Inherits**: OZ `AccessControl`, `Pausable`, `ReentrancyGuard`.
- **Roles**:
  - `DEFAULT_ADMIN_ROLE` — Treasury Safe.
  - `CONFIG_ROLE` — Treasury Safe; updates accepted stablecoin list and mint limits.
  - `PAUSER_ROLE` — Treasury Safe.
- **Mint flow**:
  1. User calls `mintSLT(stablecoin, amount)`.
  2. Contract checks: stablecoin whitelisted, amount within bounds, oracle fresh.
  3. Stablecoin pulled from user via `safeTransferFrom`, forwarded to Treasury Safe in same tx.
  4. SLT minted to user at current `pricePerShare`.
  5. Event emitted with stable amount, SLT amount, index used.
- **Critical invariant**: Contract NEVER holds stablecoin balance after a successful mint
  (verified by `invariant_MintContractHoldsNoUSDC/USDT`).
- **Stablecoin whitelist**: `setStablecoinAccepted(token, true)` reverts unless `token.decimals() == 6`
  (conversion math assumes 6-dec); delisting is never blocked.
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
| `CONFIG_ROLE` (Mint)    | Treasury Safe  | Whitelist stablecoins, adjust mint limits    |
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

- **External audit** on tag `v1.1-audit`: RFQ to Halborn / Zealynx / Cantina — full audit of SLT,
  MintContract, IndexOracle + deploy script and role topology. One fix-verification round included.
- **Pre-audit assurance**: independent pre-review (Moment Research, Sep 2026), 152 Foundry tests,
  100% line/branch/function coverage on `src/`, 11 stateful invariants, Slither 0 findings
  (`SECURITY_CHECK_15Oct2026.md`).

## Post-deploy lock sequence (mainnet, Safe transactions)

1. `SLT.grantRole(MINTER_ROLE, MintContract)`
2. `MintContract.setStablecoinAccepted(USDC/USDT, true)`
3. `IndexOracle.grantRole(ORACLE_UPDATER_ROLE, adapter)` + revoke from deployer
4. Verify on-chain: `minterCount() == 1`, `hasRole(MINTER_ROLE, MintContract)`, `burnSourceCount() == 1`, `authorizedBurnSource(Safe) == true`
5. `SLT.lockMinterRole(MintContract)` — one-way
6. `SLT.lockBurnSource()` — one-way; reverts unless `burnSourceCount() == 1`

## References

- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts)
- [Mountain Protocol USDM (Etherscan)](https://etherscan.io/token/0x59d9356e565ab3a36dd77763fc0d87feaf85508c) — permissionless mint pattern reference.
- [Ethena StakedUSDe (sUSDe)](https://etherscan.io/token/0x9d39a5de30e57443bff2a8307a4256c8797a3497) — ERC-4626 staking vault reference (for Phase 2 stSLT).
- [Frax sFRAX](https://docs.frax.finance/frax-v3-100-cr-and-more/sfrax) — `LinearRewardsErc4626` pattern reference (for Phase 2).
- [Chainlink BUILD program](https://chain.link/build) — custom data feed integration.
- [Gnosis Safe](https://safe.global) — multisig deployment.
