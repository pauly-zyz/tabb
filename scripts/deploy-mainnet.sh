#!/usr/bin/env bash
# Robinhood Chain mainnet (4663) deploy of Phase 1 + frontend address sync.
# Requires in .env: ROBINHOOD_MAINNET_RPC_URL, MAINNET_DEPLOYER_PRIVATE_KEY, TABB_OWNER (optional: TABB_GUARDIAN,
# TABB_TREASURY, TABB_PAYEE_CURATOR, TABB_SEED_USDG). The deployer needs ETH for gas and TABB_SEED_USDG USDG (default 10).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORGE="${FORGE:-forge}"; CAST="${CAST:-cast}"
set -a; . "$ROOT/.env"; set +a
RPC="${ROBINHOOD_MAINNET_RPC_URL:?set ROBINHOOD_MAINNET_RPC_URL}"
: "${MAINNET_DEPLOYER_PRIVATE_KEY:?}" "${TABB_OWNER:?set TABB_OWNER (the wallet that will own the protocol)}"
U=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
[ "$("$CAST" chain-id --rpc-url "$RPC")" = 4663 ] || { echo "RPC is not Robinhood Chain mainnet"; exit 1; }
D=$("$CAST" wallet address "$MAINNET_DEPLOYER_PRIVATE_KEY")
ETH=$("$CAST" balance "$D" --rpc-url "$RPC"); USDG=$("$CAST" call $U "balanceOf(address)(uint256)" "$D" --rpc-url "$RPC" | awk '{print $1}')
echo "deployer $D  eth_wei=$ETH  usdg=$USDG  owner=$TABB_OWNER"
[ "$ETH" -ge 1000000000000000 ] || { echo "deployer needs >= 0.001 ETH"; exit 1; }
[ "$USDG" -ge "${TABB_SEED_USDG:-10000000}" ] || { echo "deployer needs seed USDG"; exit 1; }

cd "$ROOT/contracts"
"$FORGE" script script/DeployMainnet.s.sol --rpc-url "$RPC" --broadcast --slow
MGR=$(python3 -c "import json;print(json.load(open('deployments/4663.json'))['agentCreditManager'])")
[ "$("$CAST" codesize "$MGR" --rpc-url "$RPC")" -gt 0 ] || { echo "no code at manager $MGR"; exit 1; }
[ "$("$CAST" call "$MGR" "pendingOwner()(address)" --rpc-url "$RPC")" = "$("$CAST" to-check-sum-address "$TABB_OWNER")" ] \
  || { echo "pendingOwner mismatch"; exit 1; }

cd "$ROOT"
node scripts/sync-addresses.mjs 4663
cd web && npx tsc --noEmit && npm run build >/dev/null
echo "MAINNET DEPLOYED: AgentCreditManager $MGR (owner must accept ownership at /admin)"
