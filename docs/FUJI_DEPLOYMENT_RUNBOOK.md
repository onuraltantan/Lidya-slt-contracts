# Fuji Testnet Deployment Runbook

**Hedef**: SLT V1 kontratlarını Avalanche Fuji testnet'e (chain ID 43113) deploy etmek, dashboard'a (`178.104.43.146:3000`) bağlamak.

**Süre**: ~30 dakika.

**Risk**: Sıfır finansal risk. Fuji = oyuncak para, gerçek değer yok.

---

## Adım 1 — MetaMask'ta Disposable Hesap Oluştur

1. MetaMask'ı aç → sağ üstteki hesap dropdown → "Add account or hardware wallet" → "Add a new account"
2. Yeni hesabı "**Fuji Deployer**" gibi isimlendir
3. Bu hesabın **mainnet'inde sıfır asset bulunmalı**. Sadece Fuji deployment için kullanacağız.

**Neden**: Deploy script private key'e ihtiyaç duyacak. Mainnet asset'i olan bir wallet'ın key'ini hiçbir yere yazmamalısın. Disposable Fuji wallet'ın key'i sızsa bile zarar yok.

---

## Adım 2 — Fuji Network'ünü MetaMask'a Ekle

MetaMask "Add network" → Manual:

```
Network Name:     Avalanche Fuji Testnet
RPC URL:          https://api.avax-test.network/ext/bc/C/rpc
Chain ID:         43113
Currency Symbol:  AVAX
Block Explorer:   https://testnet.snowtrace.io
```

---

## Adım 3 — Test AVAX Al (Faucet)

1. https://core.app/tools/testnet-faucet/?subnet=c&token=c
2. Cüzdan adresini yapıştır (Fuji Deployer hesabının adresi — `0x...`)
3. "Request 2 AVAX" → onay → wallet'a düşmesini bekle (~30 saniye)

Deploy için ~0.5 AVAX yeterli, 2 AVAX bolca güvenlik payı.

---

## Adım 4 — Snowtrace API Key Al (Verify İçin)

1. https://routescan.io/ → sağ üstte sign up (email + password)
2. Login → API tab → "Create API key" → kopyala

Bu API key sayesinde deploy ettiğimiz kontratlar Snowtrace'te otomatik verify olur (kaynak kodu görünür hale gelir).

---

## Adım 5 — Private Key'i Hazırla (Disposable Wallet)

MetaMask'ta Fuji Deployer hesabı seçili → menü (üç nokta) → "Account details" → "Show private key" → şifreni gir → **64 karakterlik hex string** (`0x` ile başlayabilir veya başlamayabilir).

**ÖNEMLİ:**
- Bu key'i **sadece ve sadece** kendi makinendeki `.env` dosyasına yapıştır.
- **ASLA** chat'e, mesaja, e-postaya, Slack'e, Notion'a yazma.
- Deploy bittikten sonra MetaMask'tan bu hesabı silebilirsin (ya da sadece hiç kullanmaman yeterli).

---

## Adım 6 — Deploy Yöntemini Seç

İki seçenek var. **Opsiyon A önerilen** çünkü dashboard zaten VPS'te ve adresler doğrudan dashboard'a entegre edilecek.

### Opsiyon A — VPS üzerinden deploy (önerilen)

**Avantaj**: private key VPS'te kalır (senin kontrolünde), ben SSH üzerinden deploy script'ini tetiklerim, sonuç adresleri dashboard'la aynı makinede olur.

**Akış**:
1. Sen SSH ile VPS'e bağlan
2. Repo'yu VPS'e çek
3. `.env` dosyasını sen doldur (private key + Snowtrace key — ikisi de senin elinden VPS dosyasına)
4. Bana "VPS'te `.env` hazır" de
5. Ben Foundry'i kurup `forge script DeployFuji` çalıştırırım
6. Adresleri dashboard'a entegre ederiz

### Opsiyon B — Senin laptop'unda deploy

**Avantaj**: hiçbir şey VPS'e değmez.
**Dezavantaj**: laptop'una Foundry kurman gerekiyor (bir defalık), komut satırından çalıştırma.

Bu yolu tercih edersen ayrıca step-by-step talimat veririm.

---

## Adım 7 — Deploy Sonrası: Dashboard'a Bağla

Deploy tamamlandığında script şu çıktıyı verecek:

```
NEXT_PUBLIC_CHAIN_ID=43113
NEXT_PUBLIC_SLT_ADDRESS=0x...
NEXT_PUBLIC_MINT_CONTRACT_ADDRESS=0x...
NEXT_PUBLIC_INDEX_ORACLE_ADDRESS=0x...
NEXT_PUBLIC_USDC_ADDRESS=0x...
NEXT_PUBLIC_USDT_ADDRESS=0x...
```

Bunlar dashboard'un `.env.local` dosyasına yazılacak. Sonra:

```sh
pm2 restart lidya-slt
```

Dashboard'un Mint sayfası artık deploy ettiğimiz kontratlara çağrı yapıyor olacak.

---

## Adım 8 — Smoke Test (Sen Yapacaksın)

Deploy bittikten sonra:

1. http://178.104.43.146:3000/ aç
2. MetaMask Fuji Deployer hesabıyla connect et
3. Mint sayfasına git
4. "Faucet 1000 tUSDC" butonuna bas (script deployer'a 10K tUSDC mint etti zaten, ek isterse buton ekleriz)
5. tUSDC seç → 1000 yaz → Approve → Mint
6. SLT bakiyen 1000 olmalı (index 1.0'da $1000 = 1000 SLT)
7. Snowtrace'e gidip mint event'ini gör (`testnet.snowtrace.io/address/<MintContract>`)

Bir şey ters giderse paste et bana, debug ederiz.

---

## Adım 9 — Index Update Test

Strategy performance'ı taklit etmek için elle index güncellemesi:

```
oracle.updateIndex(1010000000000000000)  // %1 yukarı, index 1.01'e
```

Bu deployer (sen) tarafından yapılacak. Ben CLI komutunu hazırlarım, sen MetaMask'tan onaylarsın. Mainnet'te bu Chainlink adapter olacak, Fuji'de manuel.

---

## Sonraki Adımlar (Fuji Sonrası)

Fuji'de smoke test geçince:
- Tag `v1.1-audit` → audit paketi (scope brief + NDA) → Halborn / Zealynx / Cantina RFQ
- Dış audit + fix-verification turu
- Mainnet deploy (gerçek 3-of-5 Treasury Safe ile)

---

## Hızlı Referans — Fuji Bilgi Kartı

| Item | Value |
|---|---|
| Chain ID | 43113 |
| RPC | https://api.avax-test.network/ext/bc/C/rpc |
| Explorer | https://testnet.snowtrace.io |
| Faucet | https://core.app/tools/testnet-faucet/ |
| API key portal | https://routescan.io/ |

---

## Fuji deployment — v1.1-audit (15 Oct 2026, redeployed 20:30 TRT after burnSourceCount change)

`forge script script/DeployFuji.s.sol:DeployFuji --rpc-url $FUJI_RPC_URL --broadcast --slow` · deployer/test-treasury `0x471D1427e78ffF8fF7abEb17229387B5Bf459B47` · chain 43113 · code = tag `v1.1-audit`

| Contract | Address |
|---|---|
| IndexOracle | `0x46C1656080A8cae36bC97471a89ad1D22A7E752B` |
| SLT | `0xD994732ED7638994134AB78EA10925c9da67F7Ff` |
| MintContract | `0x85DEe5De22b10B5164B41806C4C69274864Dd8dF` |
| tUSDC (mock, 6 dec) | `0x2E64D8b911E849CeF5693bf5E1EC6c91d265294F` |
| tUSDT (mock, 6 dec) | `0x28A62Bdda14b5686692B3d9696D20a5f2646809B` |

(An earlier same-day deployment at SLT `0x4CE787CA…`, MintContract `0xD166A3b9…`, IndexOracle `0x3318F211…` predates `burnSourceCount` and is superseded.)

Lock sequence executed inside the deploy script: `lockMinterRole(MintContract)` + `lockBurnSource()`. Post-deploy state read back: `minterRoleLocked=true · minterCount=1 · burnSourceLocked=true · burnSourceCount=1 · authorizedBurnSource(treasury)=true · TREASURY_SAFE_DELAY=86400 · STALENESS_SLACK=14400`.

### E2E (same day, `cast send`, all against the addresses above)

| Step | Result | Tx |
|---|---|---|
| mint 1,000 tUSDC → 1,000 SLT at index 1.0; tUSDC lands in treasury | ok | `0x2b976a1d0d08ede4c15f5d7c8b9e00de473f9f7d25d2aed93612644803caff1a` |
| `pause()` → `transfer` reverts `EnforcedPause` → `unpause()` → transfer ok | ok | `0x5778604e…`, `0x2ac1ac3e…`, `0x1ca33319…` |
| `updateIndex(1.01e18)` minutes after deploy | reverts `IndexOracle_TooSoon` (20h throttle, expected); `isFresh()=true` | — |
| M-02: `setMinUpdateInterval(21h)` with grace=1d | reverts `IndexOracle_InvalidConfig` | — |
| M-01: `setBurnSource(0xdead,true)` after lock | reverts `SLT_BurnSourceLocked` | — |
| M-01: `adminBurn(0xdead,1)` (holder) | reverts `SLT_BurnSourceNotAuthorized` | — |
| M-01: `adminBurn(treasury,1)` | ok (reconciliation path intact) | `0xa88a12da3005a637381df3beceaf70b6f66af620ba5518ce06a04ec0409327ad` |
| H-01/L-04: `grantRole(MINTER_ROLE,0xdead)` after lock | reverts `AccessControlUnauthorizedAccount` | — |
| M-03: `setTreasurySafe(0xA5)` → pending set, `treasurySafe` unchanged → `executeTreasurySafe()` early reverts `TreasurySafeDelayNotElapsed` → `cancelTreasurySafe()` clears | ok | `0xb831baec…`, `0x286b1a0c…` |
| M-03 follow-up: `setTreasurySafe(treasury)` re-proposed; executable at unix `1792171830` (16 Oct 2026 17:30 UTC) | pending | `0x555d8b54694f867c24912bbe2bff7d872c9698ce941d9fc073efa639f5f4f2b8` |

Pending for 16 Oct (time-gated on-chain, cannot be forced): `updateIndex` after 20h (≥ unix `1792157342`, 13:29 UTC), `executeTreasurySafe()` after 24h (≥ `1792171830`, 17:30 UTC).

### 16 Oct follow-up

Executed 16 Oct 2026 ~17:41 UTC (unix 1792172486+) from deployer `0x471D…9B47`, tag `v1.1-audit` (c6bdfda).

| Step | Action | Tx / Result |
|------|--------|-------------|
| 1a | `updateIndex(1.01e18)` on IndexOracle (87,144 s since last update ≥ 72,000 s) | `0xc0b92637ff7b0d0338834b7e7e88d109de840f609f48b29869e8507a88da068e` — block 59564311, status 1 |
| 1b | Read-back | `pricePerShare()` = 1.01e18 · `isFresh()` = true · `lastUpdateTimestamp()` = 1792172515 |
| 1c | Immediate `updateIndex(1.02e18)` | reverted `IndexOracle_TooSoon(uint256,uint256)` (selector `0x4624ed56`) — throttle enforced |
| 1d | Immediate `updateIndex(1.07e18)` (+5.9 %) | reverted `IndexOracle_TooSoon` — throttle check (L177) precedes bounds check (L184), so `IndexOracle_OutOfBounds` cannot be observed on-chain inside the 20h window; bounds path covered by forge tests |
| 2a | `executeTreasurySafe()` on MintContract (now ≥ 1792171830) | `0xb215a973fd1a985a1f7c49c1ddfe07c12b3e150a8d71eaedce6d83122aeee852` — block 59564342, status 1 |
| 2b | Read-back | `treasurySafe()` = `0x471D1427e78ffF8fF7abEb17229387B5Bf459B47` · `pendingTreasurySafe()` = `0x0` · `pendingTreasurySafeExecutableAt()` = 0 |

Fuji v1.1-audit E2E complete. Next oracle update window opens at unix 1792244515 (17 Oct ~13:41 UTC).

Dashboard app (`/projects/blockxell/lidya/app`) still points at the Jul-2026 Fuji deployment; switching it needs a `.env.local` address update + `next build` + pm2 restart (not done in this round).
