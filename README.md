# lidya-slt-contracts

Smart contracts for **SLT (Synthetic Liquid Token)** V1 — Lidya Investments quant-arbitrage performance tokenization on Avalanche C-Chain.

> **Status**: V1 starter kit, pre-audit. Not yet deployed to mainnet. Audit by Halborn (private)
> + Code4rena (public) is the gating step before mainnet deploy.

## Contracts

| Contract           | Lines | Purpose                                                                   |
| ------------------ | ----- | ------------------------------------------------------------------------- |
| `IndexOracle.sol`  | ~140  | Stores the synthetic performance index. Bounds-checked, throttled, pausable. |
| `SLT.sol`          | ~110  | ERC-20 + ERC-4626-style read-only metadata. Non-redeemable.               |
| `MintContract.sol` | ~140  | Accepts USDC/USDT, mints SLT at current index, forwards stable to Treasury Safe. |
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

- `OpenZeppelin/openzeppelin-contracts` (v5.x)
- `smartcontractkit/chainlink-brownie-contracts`
- `foundry-rs/forge-std`

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
slither . --filter-paths "lib/|test/" --exclude-informational
```

## Deployment (Fuji testnet)

1. Deploy a Gnosis Safe via [safe.global](https://safe.global) on Fuji. Add 5 signers, set threshold to 3.
2. Copy `.env.example` to `.env` and fill in:
   - `DEPLOYER_PRIVATE_KEY`
   - `TREASURY_SAFE_ADDRESS`
   - `USDC_ADDRESS`, `USDT_ADDRESS` (Fuji or mainnet)
   - `INDEX_INITIAL=1000000000000000000` (1.0 in 1e18)
   - `MIN_MINT_AMOUNT`, `MAX_MINT_AMOUNT`
3. Run the deploy script:

```sh
forge script script/Deploy.s.sol --rpc-url fuji --broadcast --verify
```

4. Post-deploy, execute these via Safe transaction:
   - `SLT.grantRole(MINTER_ROLE, MintContract)`
   - `MintContract.setStablecoinAccepted(USDC, true)`
   - `MintContract.setStablecoinAccepted(USDT, true)`
   - `IndexOracle.grantRole(ORACLE_UPDATER_ROLE, ChainlinkAdapter)` then `revokeRole` from deployer

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
script/
  Deploy.s.sol
docs/
  ARCHITECTURE.md
.github/workflows/ci.yml
foundry.toml
remappings.txt
.env.example
```

## Audit Pipeline

1. **Internal review** — peer review by Blockxell engineering + 1 external Solidity reviewer.
2. **Halborn private audit** — ~2 weeks. Threat model + spec doc + repo handed off.
3. **Halborn fix loop** — findings → PRs → re-audit.
4. **Code4rena public contest** — 7 days, award pool $20-30K USDC.
5. **Final fix review** — Halborn re-validates Code4rena fixes.
6. **Mainnet deploy**.

## License

Business Source License 1.1 (BUSL-1.1). Converts to MIT after the change date specified in
each file header. Contact `altan@blockxell.com` for commercial licensing inquiries before
the change date.

## Contact

- Engineering: `altan@blockxell.com`
- Security disclosures: see [`SECURITY.md`](SECURITY.md) (TBD, before mainnet)
