# Tabb — Peluncuran Mainnet

Status per 2026-11-25:

- Fase 1 (kredit AI agent) siap di-deploy ke Robinhood Chain mainnet (`4663`).
- Review keamanan internal selesai (`docs/AUDIT.md`), dan deploy sudah diuji di fork mainnet.
- Fase 2 (kredit yield) belum di mainnet. Alasannya, alamat feed harga Chainlink, sequencer feed, vault USDG ERC-4626, dan YT Clipt di mainnet belum ada yang terverifikasi.

## Yang sudah diverifikasi

| Pemeriksaan | Hasil |
|---|---|
| Alamat eksternal | USDG `0x5fc5…d168` ("Global Dollar", 6 desimal) dan ERC-8004 IdentityRegistry `0x8004A169…a432`, keduanya dicek on-chain |
| `forge test` | 206/206 lulus |
| Slither | 53 temuan medium/high sudah ditriase, tidak ada yang bisa dieksploitasi |
| Review internal | Tidak ada temuan critical, high, atau medium. Ada 2 low dan 3 info, lihat AUDIT.md |
| Fork mainnet (`scripts/fork-mainnet-check.sh`) | Deploy asli, serah ownership, deposit lender, lalu agent ERC-8004 asli melakukan stake → buka tab → draw → lunas |
| UI `/admin` di fork | Terima ownership 6 contract, tambah payee, pause/unpause |
| E2E lokal (anvil) | Alur Fase 1 dan Fase 2 lulus |
| Biaya gas deploy | 22 transaksi, ~15,3 juta gas, ≈ 0,0005 ETH pada 0,03 gwei |

## Prasyarat deploy

1. **Wallet deployer** (kunci panas, hanya untuk deploy dan wiring): `0x67c123Df6bec1214C1d44FffaAD0D86F9f493beD`.
   Harus berisi minimal **0,002 ETH** di Robinhood Chain mainnet dan **10 USDG** untuk seed deposit.
2. **`TABB_OWNER`**, yaitu wallet milik pemilik protokol. Wallet ini menjadi owner, guardian, treasury, dan curator.
   Pemilik harus menekan "Accept ownership" untuk 6 contract di halaman `/admin` situs.

## Deploy

```bash
echo "TABB_OWNER=0x..." >> .env
```

```bash
FORGE=~/.foundry/bin/forge CAST=~/.foundry/bin/cast scripts/deploy-mainnet.sh
```

Script ini mengecek chain dan saldo, men-deploy, lalu memverifikasi `pendingOwner`. Setelah itu ia menulis
`contracts/deployments/4663.json`, menjalankan `scripts/sync-addresses.mjs 4663`, dan mem-build web.
Hasilnya di-commit lalu di-merge ke `main`. Vercel production otomatis memakai alamat mainnet.

## Setelah deploy (pemilik)

1. Buka `/admin`, lalu terima ownership pada keenam contract.
2. Tambahkan payee yang sudah dikurasi (penyedia compute, API, atau data). Tanpa payee, agent tidak bisa membelanjakan pinjaman.
3. Opsional: set `NEXT_PUBLIC_ROBINHOOD_RPC_URL` di Vercel ke RPC provider. RPC publik punya rate limit.
4. Jalankan keeper untuk `distribute`, `markDelinquent`, dan `markDefault`. Ketiganya bisa dipanggil siapa saja.
5. Setelah protokol aktif, disarankan memindahkan ownership ke `TimelockController` yang dikendalikan multisig. Audit eksternal dan bug bounty juga disarankan sebelum menaikkan limit.
