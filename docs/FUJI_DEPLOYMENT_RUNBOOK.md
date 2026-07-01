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
- Sprint 8 → Halborn audit handoff package
- Halborn audit (~2 hafta)
- Code4rena public contest (~7 gün)
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
