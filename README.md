# lidya-slt-contracts

Smart contracts for **SLT (Synthetic Liquidity Token)** V1 — Lidya Investments quant-arbitrage performance tokenization on Avalanche C-Chain.

> **Status**: v1.1.1-audit — contract set frozen for external audit (tag `v1.1.1-audit`, cut after the gate run recorded in `SECURITY_CHECK_20Oct2026.md`). Not yet
> deployed to mainnet; Fuji testnet live. External audit (RFQ: Halborn / Zealynx / Cantina) is the
> gating step before mainnet deploy. Latest gate results: `SECURITY_CHECK_20Oct2026.md`.

## Contracts

| Contract           | Lines | Purpose                                                                   |
| ------------------ | ----- | ------------------------------------------------------------------------- |
| `IndexOracle.sol`  | 318   | Stores the synthetic performance index. Bounds-checked (±5%/update), throttled (≥20h), pausable; M-02 staleness guard. |
| `SLT.sol`          | 401   | ERC-20 + index-based read-only metadata. Non-redeemable. Sealed minter set (`lockMinterRole(expected)`) and burn source (`lockBurnSource(expected)`). |
| `MintContract.sol` | 463   | Accepts 6-dec USDC/USDt (seeded at deploy; additions timelocked 24h), mints SLT at current index with optional `minSltOut`/`deadline`, forwards stable atomically to Treasury Safe with receipt check; 24h treasury-change timelock. |
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

4. Post-deploy, execute these via Safe transaction (order matters; 3–4 are one-way). The stablecoin
   whitelist and the oracle updater are set by the constructor/script (`USDC_ADDRESS`, `USDT_ADDRESS`,
   `ORACLE_UPDATER_ADDRESS` env), so there is no instant post-deploy whitelist step.
   1. `SLT.grantRole(MINTER_ROLE, MintContract)`
   2. Verify on-chain: `SLT.minterCount() == 1`, `SLT.hasRole(MINTER_ROLE, MintContract)`, `MintContract.slt() == SLT`,
      `SLT.burnSourceCount() == 1`, `SLT.authorizedBurnSource(Safe) == true`, `MintContract.acceptedStablecoin(USDC/USDt) == true`
   3. `SLT.lockMinterRole(MintContract)` — one-way (H-01 / L-04 / M-4)
   4. `SLT.lockBurnSource(Safe)` — one-way; refuses unless the set is exactly `{Safe}` (M-01 / M-3)
   5. Later changes, all 24h propose → execute (or cancel): Treasury Safe (`setTreasurySafe` → `executeTreasurySafe`, M-03);
      stablecoin additions (`setStablecoinAccepted(tok,true)` → `executeStablecoinAccepted(tok)`, H-1). Delisting is immediate.

## Repo Layout

```
src/
  SLT.sol
  MintContract.sol
  IndexOracle.sol
  interfaces/
    ISLT.sol
    IIndexOracle.sol
    IMintContractView.sol     # slt() view used by lockMinterRole's wiring check (M-4)
test/
  SLT.t.sol
  MintContract.t.sol
  IndexOracle.t.sol
  HardeningV11.t.sol        # M-01..M-04, L-04, H-1, M-1, M-3, L-1..L-6 (v1.1 / v1.1.1)
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
docs/ABI_BASELINE_v1.1.1.txt # public ABI snapshot the invariant auditor diffs against
remappings.txt
.env.example
```

## Audit Pipeline

1. **Internal review** — done (Jul–Aug 2026, `REVIEW_BRIEF.md`).
2. **Independent pre-review** — Moment Research, Sep 2026 (H-01 fixed; M-01/M-02/M-03/L-04 fixed in v1.1-audit; M-04 accepted, see THREAT_MODEL §5).
3. **Second independent review** — Oct 2026 (security + code-quality passes); H-1/M-1/M-3/M-4/L-1…L-6 closed in `v1.1.1-audit`.
4. **External audit** — RFQ to Halborn / Zealynx / Cantina on tag `v1.1.1-audit`; one fix-verification round included.
5. **Fix loop** — findings → PRs → re-audit of the fix commit.
6. **Mainnet deploy** — Safe-batched, role topology verified on-chain before `lockMinterRole` / `lockBurnSource`.

## License

Business Source License 1.1 (BUSL-1.1). Converts to MIT after the change date specified in
each file header. Contact `altan@blockxell.com` for commercial licensing inquiries before
the change date.

## Contact

- Engineering: `altan@blockxell.com`
- Security disclosures: `altan@blockxell.com` (a `SECURITY.md` / bug-bounty policy will be published before mainnet)
