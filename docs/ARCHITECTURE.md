# SLT V1 Smart Contract Architecture

## Overview

SLT (Synthetic Liquid Token) V1 is a permissionless ERC-20 token deployed on Avalanche C-Chain. Its
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
  - Updates throttled to `minUpdateInterval` (1 hour default).
  - Per-update change bounded to `maxChangeBps` (5% default; admin-adjustable up to 20% ceiling).
  - When paused, updates revert; consumers should treat the index as frozen.
  - `isFresh()` returns `false` after `gracePeriod` (1 day default).

### 2. `SLT.sol`

The user-facing ERC-20 token.

- **Inherits**: OpenZeppelin `ERC20`, `AccessControl`, `Pausable`.
- **Roles**:
  - `DEFAULT_ADMIN_ROLE` — Treasury Safe; manages role grants.
  - `MINTER_ROLE` — `MintContract` only.
  - `BURNER_ROLE` — Treasury Safe only; reserved for reconciliation and erroneous-mint correction.
  - `PAUSER_ROLE` — Treasury Safe; emergency pause for transfers/mints/burns.
- **ERC-4626 read-only metadata**: `pricePerShare()`, `totalAssets()`, `convertToShares()`,
  `convertToAssets()`. **Deposit/withdraw functions intentionally absent.**
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
  (verified by `test_Invariant_NoStableEverHeldByMintContract`).

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
  - Authority to grant/revoke `MINTER_ROLE`, `CONFIG_ROLE`, etc.

## Roles Matrix

| Role                    | Holder         | Authority                                    |
| ----------------------- | -------------- | -------------------------------------------- |
| `DEFAULT_ADMIN_ROLE`    | Treasury Safe  | Manage all role grants                       |
| `MINTER_ROLE` (SLT)     | MintContract   | Mint SLT to depositors                       |
| `BURNER_ROLE` (SLT)     | Treasury Safe  | Reconciliation burns only; never user-facing |
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

- **Halborn (private)**: full audit of SLT, MintContract, IndexOracle. ~2 weeks engagement.
- **Code4rena (public)**: 7-day public competition post-Halborn fixes. Award pool $20-30K.

## References

- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts)
- [Mountain Protocol USDM (Etherscan)](https://etherscan.io/token/0x59d9356e565ab3a36dd77763fc0d87feaf85508c) — permissionless mint pattern reference.
- [Ethena StakedUSDe (sUSDe)](https://etherscan.io/token/0x9d39a5de30e57443bff2a8307a4256c8797a3497) — ERC-4626 staking vault reference (for Phase 2 stSLT).
- [Frax sFRAX](https://docs.frax.finance/frax-v3-100-cr-and-more/sfrax) — `LinearRewardsErc4626` pattern reference (for Phase 2).
- [Chainlink BUILD program](https://chain.link/build) — custom data feed integration.
- [Gnosis Safe](https://safe.global) — multisig deployment.
