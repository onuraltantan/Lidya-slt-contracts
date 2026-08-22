# SLT Contracts — Pre-Audit Review Brief
**Version under review: v1.1-prereview (v1.0-audit + four applied changes, see §4) · 22 Aug 2026**
**Prepared for: independent preview ahead of formal audit (Zealynx / Cantina)**
**Status: compiles clean (solc 0.8.24, 0 errors / 0 warnings) · full Foundry suite green (109/109 incl. invariants) · Slither clean on project contracts (see SECURITY_CHECK_22Aug2026.md).**

## 1. What this is

SLT (Synthetic Liquidity Token) is a **non-redeemable, index-based ERC-20** on Avalanche C-Chain. Investors mint SLT by paying USDT at the current index value; the USDT settles atomically into a treasury Safe. The token's value tracks a published index (initial 1.0, net of fees). There is **no redemption of any kind** — holders exit only by selling on the secondary market. This is deliberate and is the legal cornerstone of the design: BVI counsel's regulatory analysis rests on the absence of any ongoing claim by holders against the issuer.

**Scope:** `src/SLT.sol`, `src/MintContract.sol`, `src/IndexOracle.sol`, plus interfaces. Solidity 0.8.24, OpenZeppelin v5, Foundry. v1.0 deployed and passing on Fuji testnet.

## 2. Structural context you need before reading code

- **Single issuer entity.** Blockxell Issuance Limited (BVI) is both issuer and treasury — it owns the Treasury Safe and the fiat account, and invests **for its own account**. It never holds client assets and owes holders nothing.
- **Burn is NOT redemption.** The only supply-reduction flow: on net capital exit, the treasury buys SLT on the secondary market **at market price, at its own discretion** (typically from the market maker's inventory), moves it to its own address, and burns it. No holder can trigger a burn; no price is promised; nothing is paid to a holder by the issuer.
- **Supply logic:** performance → index moves, supply unchanged · capital in → mint · capital out → discretionary buyback + burn. Supply only ever increases via fully-collateralised mints.
- **No peg.** Market price may deviate from the index; no mechanism or commitment closes the gap. The affiliated market maker quotes AROUND fair value with real spread and real inventory risk — never a standing NAV bid.

Anything in the code that would create a holder claim, a redemption path, a transfer restriction, or an upgrade path is a **critical finding** — the design forbids all four.

## 3. What we believe is sound (please try to break it)

- Non-redeemability: no redeem/withdraw/burn-for-stable path anywhere; `adminBurn` pays nothing.
- Immutability: no proxy, no upgrade hooks; oracle reference is `immutable`.
- Free transfer: no whitelist/denylist/freeze/forced transfer.
- Atomic mint settlement: `safeTransferFrom(msg.sender → treasurySafe)` then `slt.mint`, `nonReentrant`, oracle freshness required (`isFresh()`), per-tx bounds $1k–$5M.
- Oracle: ±5% per-update bound (hard ceiling), min update interval 20h (hard floor), 1-day staleness grace, guardian pause.
- Decimal handling USDT(6) ↔ SLT(18).
- MINTER_ROLE granted only post-deploy, only to MintContract, then lockable forever.

## 4. Changes applied in v1.1 (validate these)

Nothing has been sent to auditors yet. Four changes were identified in our internal review and are **applied in this version** — please challenge both the findings and the implementations:

| # | Finding (v1.0 code) | Applied change (v1.1) |
|---|---|---|
| 1 | `SLT.adminBurn(from, amount)`: BURNER_ROLE could burn **any holder's** balance — contradicted "issuer cannot touch holder balances" | `authorizedBurnSource` allowlist added; `adminBurn` reverts with `SLT_BurnSourceNotAuthorized` unless `from` is listed. List managed by DEFAULT_ADMIN via `setBurnSource()`. Trade-off accepted: no forced recovery of mis-sent mints. |
| 2 | DEFAULT_ADMIN could `grantRole(MINTER_ROLE, x)` → a compromised Treasury Safe could self-grant mint | `lockMinterRole()` added: one-way, sets MINTER_ROLE's role-admin to the never-granted `MINTER_ADMIN_LOCK` sentinel (which is its own admin). Deployment sequence: deploy → grant MINTER to MintContract → lock. Trade-off accepted: MintContract can never be replaced without a token redeploy. |
| 3 | Docs said "±5%/day" but the bound was **per update**; admin could set interval to 1 min and bound to 20% | Hard limits tightened: `maxChangeBps` ceiling 2000→**500** (default = ceiling), `minUpdateInterval` floor 1 min→**20 hours** (default 1h→20h, range [20h, 1d]), `gracePeriod` floor 1h→**1 day** (so routine cadence never trips staleness). Documented ±5%-per-daily-update is now a code guarantee. |
| 4 | Token name in code was "Synthetic **Liquid** Token"; all documents say "Synthetic **Liquidity** Token" (immutable post-deploy) | Name fixed to "Synthetic Liquidity Token". |

Additional non-code notes (documentation-side, already tracked): pause does NOT cover `adminBurn` (deliberate — reconciliation must work while paused; docs will be corrected); minting is fully permissionless on-chain (no KYC in contract — eligibility lives at issuer/UI level; a voluntary AML programme is being designed with counsel).

Also worth checking: `setTreasurySafe` redirects all future deposits with a single role (DEFAULT_ADMIN) — it is on our list of functions to bind to multisig quorum at the policy layer (Fireblocks), not in code. Tell us if you disagree.

## 5. Whitepaper claims vs code — the alignment matrix

| WP claim | Code reality | Status |
|---|---|---|
| Non-redeemable, no holder claim | Confirmed in code | OK |
| Immutable, non-upgradeable | Confirmed | OK |
| Unrestricted transfer | Confirmed | OK |
| Atomic settlement to treasury Safe | Confirmed | OK |
| "Issuer cannot touch holder balances" | Enforced via burn-source allowlist | fixed in v1.1 (change 1) |
| "Compromised multisig cannot bypass mint flow" | Enforced via lockMinterRole() post-deploy step | fixed in v1.1 (change 2) — verify the lock sequence |
| "±5% per day" index bound | Hard limits: 500 bps ceiling, 20h interval floor | fixed in v1.1 (change 3) |
| "Pause covers transfers, mints, burns" | Burns NOT pausable (deliberate) | docs will change, not code |
| Eligibility controls at mint entry | UI/entity level only; contract is permissionless | disclosed; AML programme in design |

## 6. What we want from you

1. Adversarial pass on §3 — especially any hidden redemption-like path or holder claim.
2. Review the four applied changes (§4) — sound implementation? Better alternative? Any new attack surface introduced (e.g. burn-source list management, the lock sentinel)?
3. Anything the formal auditors (Zealynx/Cantina) would flag that we can fix cheaply now.
4. Test coverage gaps worth closing pre-audit (suite is green at 109/109 incl. invariants; new v1.1 paths are covered but breadth/depth suggestions welcome).

Planned pipeline after your pass: optional second static scanner → formal audit (Zealynx/Cantina) from this v1.1 baseline.

Contact: Onur Altan Tan — Blockxell.
