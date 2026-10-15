# lidya-slt-contracts

Smart contracts for **SLT (Synthetic Liquidity Token)** V1 — Lidya Investments quant-arbitrage performance tokenization on Avalanche C-Chain.

> **Status**: v1.1-audit — contract set frozen for external audit (tag `v1.1-audit`). Not yet
> deployed to mainnet; Fuji testnet live. External audit (RFQ: Halborn / Zealynx / Cantina) is the
> gating step before mainnet deploy. Latest gate results: `SECURITY_CHECK_15Oct2026.md`.

## Contracts

| Contract           | Lines | Purpose                                                                   |
| ------------------ | ----- | ------------------------------------------------------------------------- |
| `IndexOracle.sol`  | 301   | Stores the synthetic performance index. Bounds-checked (±5%/update), throttled (≥20h), pausable; M-02 staleness guard. |
| `SLT.sol`          | 355   | ERC-20 + index-based read-only metadata. Non-redeemable. Sealed minter set (`lockMinterRole`) and burn source (`lockBurnSource`). |
| `MintContract.sol` | 322   | Accepts 6-dec USDC/USDT, mints SLT at current index, forwards stable atomically to Treasury Safe; 24h treasury-change timelock. |
| Treasury Safe      | n/a   | Gnosis Safe (deployed off-chain via `safe.global`). 3-of-5 multisig.       |

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full component diagram, roles matrix, and threat model.

## Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`curl -L https://foundry.paradigm.xyz | bash && foundryup`)
- Node.js 20+ (for any helper scripts)
- An Avalanche RPC endpoint (mainnet or Fuji testnet)

### Install dependencies

```sh
forge install
```

This pulls:

- `OpenZeppelin/openzeppelin-contracts` (v5.6.1, pinned in `foundry.lock`)
- `foundry-rs/forge-std` (v1.16.2, pinned in `foundry.lock`)

### Build

```sh
forge build --sizes
```

### Test

```sh
forge test -vvv
```

CI profile (deeper fuzz):

```sh
FOUNDRY_PROFILE=ci forge test -vvv
```

### Coverage

```sh
forge coverage --report summary
```

Target: ≥95% line coverage before audit submission.

### Static analysis

```sh
slither . --filter-paths "lib|test|script" --exclude-dependencies
```

## Deployment

**Fuji testnet (all roles on the deployer, lock sequence executed by the script):**

```sh
forge script script/DeployFuji.s.sol:DeployFuji --rpc-url $FUJI_RPC_URL --broadcast --slow
```

**Mainnet (Safe-driven):**

1. Deploy a Gnosis Safe via [safe.global](https://safe.global). Add 5 signers, set threshold to 3.
2. Copy `.env.example` to `.env` and fill in:
   - `DEPLOYER_PRIVATE_KEY`
   - `TREASURY_SAFE_ADDRESS`
   - `USDC_ADDRESS`, `USDT_ADDRESS` (Fuji or mainnet)
   - `INDEX_INITIAL=1000000000000000000` (1.0 in 1e18)
   - `MIN_MINT_AMOUNT`, `MAX_MINT_AMOUNT`
3. Run the deploy script:

```sh
forge script script/Deploy.s.sol --rpc-url avalanche --broadcast --verify
```

4. Post-deploy, execute these via Safe transaction (order matters; 7–8 are one-way):
   1. `SLT.grantRole(MINTER_ROLE, MintContract)`
   2. `MintContract.setStablecoinAccepted(USDC, true)`
   3. `MintContract.setStablecoinAccepted(USDT, true)`
   4. `IndexOracle.grantRole(ORACLE_UPDATER_ROLE, ChainlinkAdapter)` then `revokeRole` from deployer
   5. Verify on-chain: `SLT.minterCount() == 1`, `SLT.hasRole(MINTER_ROLE, MintContract)`,
      `SLT.burnSourceCount() == 1`, `SLT.authorizedBurnSource(Safe) == true`
   6. `SLT.lockMinterRole(MintContract)` — one-way (H-01 / L-04)
   7. `SLT.lockBurnSource()` — one-way; refuses unless the set is exactly one address (M-01)
   8. Treasury Safe changes later: `setTreasurySafe(new)` → wait 24h → `executeTreasurySafe()` (or `cancelTreasurySafe()`) (M-03)

## Repo Layout

```
src/
  SLT.sol
  MintContract.sol
  IndexOracle.sol
  interfaces/
    ISLT.sol
    IIndexOracle.sol
test/
  SLT.t.sol
  MintContract.t.sol
  IndexOracle.t.sol
  HardeningV11.t.sol        # M-01 / M-02 / M-03 / L-04 (v1.1-audit)
  PreAuditPoC.t.sol         # Moment Research PoCs, now regression tests
  PreAuditPoC2.t.sol
  invariants/               # stateful fuzz: Handler.sol + SLTInvariants.t.sol
script/
  Deploy.s.sol              # mainnet (Safe-driven post-steps printed)
  DeployFuji.s.sol          # Fuji end-to-end incl. lock sequence
docs/
  ARCHITECTURE.md
  THREAT_MODEL.md
  FUJI_DEPLOYMENT_RUNBOOK.md
.claude/                    # repo harness: slt-invariant-auditor agent, /doc-sync, /audit-gate
foundry.toml
foundry.lock                # dependency pins (OZ v5.6.1, forge-std v1.16.2)
remappings.txt
.env.example
```

## Audit Pipeline

1. **Internal review** — done (Jul–Aug 2026, `REVIEW_BRIEF.md`).
2. **Independent pre-review** — Moment Research, Sep 2026 (H-01 fixed; M-01/M-02/M-03/L-04 fixed in v1.1-audit; M-04 accepted, see THREAT_MODEL §5).
3. **External audit** — RFQ to Halborn / Zealynx / Cantina on tag `v1.1-audit`; one fix-verification round included.
4. **Fix loop** — findings → PRs → re-audit of the fix commit.
5. **Mainnet deploy** — Safe-batched, role topology verified on-chain before `lockMinterRole` / `lockBurnSource`.

## License

Business Source License 1.1 (BUSL-1.1). Converts to MIT after the change date specified in
each file header. Contact `altan@blockxell.com` for commercial licensing inquiries before
the change date.

## Contact

- Engineering: `altan@blockxell.com`
- Security disclosures: `altan@blockxell.com` (a `SECURITY.md` / bug-bounty policy will be published before mainnet)
