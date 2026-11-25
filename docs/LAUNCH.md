# Tabb — Checklist Peluncuran Publik

Status per 2026-11-25: **kode siap untuk audit dan peluncuran; contract mainnet belum di-deploy.**
Situs production (Vercel) sudah menargetkan Robinhood Chain mainnet (`4663`) dan menampilkan
"Not deployed on Robinhood Chain yet" dengan semua aksi dinonaktifkan sampai alamat mainnet diisi.

## Yang sudah diverifikasi

| Pemeriksaan | Hasil |
|---|---|
| `forge test` | 206/206 lulus (unit, fuzz, invariant, skenario Fase 1 + 2) |
| Coverage | total 91.6%; AgentCreditManager 99.7%, TabManager/Harvester/Liquidator 100% |
| Slither (medium/high) | 53 temuan, semua ditinjau: tidak ada bug yang bisa dieksploitasi (lihat SECURITY.md §5.1) |
| E2E lokal (anvil + Playwright, wallet injected) | Fase 1: faucet, deposit, buka tab, draw dengan risk ack, stake, revenue → auto-repay via splitter, risk monitor. Fase 2: buka tab vault-share, collateral, borrow, harvest, tab YT + mode market closed. Semua lulus |
| Build web production (`NEXT_PUBLIC_CHAIN_ID` default 4663) | Lulus; 6 halaman dimuat tanpa error JS |
| Testnet | Dilewati atas keputusan pemilik (tidak ada ETH testnet) |

## Langkah yang harus dilakukan tim (berurutan)

1. **Audit** contract di `contracts/src` (scope: SECURITY.md §1). Tag commit yang diaudit.
2. **Isi alamat eksternal** yang terverifikasi di `contracts/script/Config.s.sol` dan `config/addresses.ts`:
   USDG (cek `decimals() == 6`), ERC-8004 Identity Registry, feed Chainlink + sequencer uptime feed,
   vault USDG ERC-4626, token YT Clipt. Tidak ada alamat yang dikarang di repo ini.
3. **Deploy mainnet secara manual** oleh tim (script di repo sengaja menolak chain `4663`).
   Urutan dan parameter mengikuti `contracts/script/TabbDeployer.sol` (`_deployCore`, `_deployYieldCore`),
   termasuk seed deposit 1.000 USDG ke `0xdead` di kedua pool.
4. **Serahkan admin**: owner semua contract → `TimelockController` (delay ≥ 48 jam) di belakang multisig
   (Ownable2Step → `acceptOwnership`); guardian → multisig terpisah khusus pause.
5. **Tulis alamat ke frontend**: simpan hasil deploy sebagai `contracts/deployments/4663.json`
   (+ `4663.yield.json`) dengan format yang sama seperti `31337.json`, lalu:
   `node scripts/sync-addresses.mjs 4663` → commit → merge ke `main`.
6. **Env Vercel**: set `NEXT_PUBLIC_ROBINHOOD_RPC_URL` (RPC mainnet resmi) dan opsional
   `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID`. `NEXT_PUBLIC_CHAIN_ID` tidak perlu (default 4663).
7. **Keeper**: jalankan bot untuk `processRevenue`/`distribute`, `markDelinquent`, `markDefault`,
   `harvest`, `liquidate`.
8. **Monitoring & runbook**: utilisasi, tab lewat jatuh tempo, default, health factor, event pause.
9. **Bug bounty** dan review legal (Q-A17) sebelum membuka ke publik.

Setelah langkah 5–6, situs production langsung aktif di mainnet tanpa perubahan kode lain.
