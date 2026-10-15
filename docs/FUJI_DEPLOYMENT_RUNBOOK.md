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

## Fuji deployment — v1.1-audit (15 Oct 2026)

`forge script script/DeployFuji.s.sol:DeployFuji --rpc-url $FUJI_RPC_URL --broadcast --slow` · deployer/test-treasury `0x471D1427e78ffF8fF7abEb17229387B5Bf459B47` · chain 43113

| Contract | Address |
|---|---|
| IndexOracle | `0x3318F2110395ea9Ec812c75F0885C77dB1bE0b75` |
| SLT | `0x4CE787CA936a633041e6611bff22440B26C57017` |
| MintContract | `0xD166A3b96E7921A53cD7f40F9A381db89d132C80` |
| tUSDC (mock, 6 dec) | `0x3712BEeFb7aeB5b9c3DE2e3B722b8cE24afF4FF8` |
| tUSDT (mock, 6 dec) | `0xC6a25aef4eEBb140baa6632E461a1c8503edcA69` |

Lock sequence executed inside the deploy script: `lockMinterRole(MintContract)` + `lockBurnSource()`. Post-deploy state read back: `minterRoleLocked=true · minterCount=1 · burnSourceLocked=true · authorizedBurnSource(treasury)=true · TREASURY_SAFE_DELAY=86400 · STALENESS_SLACK=14400`.

### E2E (same day, `cast send`, all against the addresses above)

| Step | Result | Tx |
|---|---|---|
| mint 1,000 tUSDC → 1,000 SLT at index 1.0 | ok | `0x0ddc7d0a50071029d93e671c283dfa977578f06d3f19e627ec0948cd0fab5f92` |
| `pause()` → `transfer` reverts `EnforcedPause` → `unpause()` → transfer ok | ok | `0xa20ed06d…`, `0xb78fdb92…`, `0xfcdfc844…` |
| `updateIndex(1.01e18)` 10 min after deploy | reverts `IndexOracle_TooSoon` (20h throttle, expected); `isFresh()=true` | — |
| M-02: `setMinUpdateInterval(21h)` with grace=1d | reverts `IndexOracle_InvalidConfig` | — |
| M-01: `setBurnSource(0xdead,true)` after lock | reverts `SLT_BurnSourceLocked` | — |
| M-01: `adminBurn(0xdead,1)` (holder) | reverts `SLT_BurnSourceNotAuthorized` | — |
| M-01: `adminBurn(treasury,1)` | ok (reconciliation path intact) | `0xc28dcddef07c93eebcca6b35db329cfd010f8727b99e8f58be05e102f30061dd` |
| H-01/L-04: `grantRole(MINTER_ROLE,0xdead)` after lock | reverts `AccessControlUnauthorizedAccount` | — |
| M-03: `setTreasurySafe(0xA5)` → pending set, `treasurySafe` unchanged → `executeTreasurySafe()` early reverts `TreasurySafeDelayNotElapsed` → `cancelTreasurySafe()` clears | ok | `0x7221706e…`, `0x63b9b864…` |
| M-03 follow-up: `setTreasurySafe(treasury)` re-proposed; executable at unix `1792171116` (16 Oct 2026 17:18 UTC) | pending | `0x7f71e53ea63bb600f823867b928ca6580b8bbfec1a305a44129527a215e87252` |

Pending for 16 Oct (time-gated on-chain, cannot be forced): `updateIndex` after 20h (≥ unix `1792156613`), `executeTreasurySafe()` after 24h (≥ `1792171116`).

Dashboard app (`/projects/blockxell/lidya/app`) still points at the Jul-2026 Fuji deployment; switching it needs a `.env.local` address update + `next build` + pm2 restart (not done in this round).
