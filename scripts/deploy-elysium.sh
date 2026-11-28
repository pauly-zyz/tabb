#!/usr/bin/env bash
# Elysium (Kinetiq, 99901) deploy: self-hosted ERC-8004 IdentityRegistry + Tabb Phase 1 with USDC, then frontend sync.
# Requires in .env: ELYSIUM_RPC_URL, ELYSIUM_DEPLOYER_PRIVATE_KEY, TABB_OWNER (optional: TABB_GUARDIAN, TABB_TREASURY,
# TABB_PAYEE_CURATOR, TABB_SEED_USDG). The deployer needs HYPE for gas and TABB_SEED_USDG USDC (default 10).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORGE="${FORGE:-forge}"; CAST="${CAST:-cast}"
set -a; . "$ROOT/.env"; set +a
RPC="${ELYSIUM_RPC_URL:-https://rpc.elysium.kinetiq.xyz}"
: "${ELYSIUM_DEPLOYER_PRIVATE_KEY:?}" "${TABB_OWNER:?set TABB_OWNER (the wallet that will own the protocol)}"
U=0xb47c4C8F73F009CC0C0d3f92B388d13E293F0B65 # USDC
[ "$("$CAST" chain-id --rpc-url "$RPC")" = 99901 ] || { echo "RPC is not Elysium"; exit 1; }
D=$("$CAST" wallet address "$ELYSIUM_DEPLOYER_PRIVATE_KEY")
ETH=$("$CAST" balance "$D" --rpc-url "$RPC"); USDG=$("$CAST" call $U "balanceOf(address)(uint256)" "$D" --rpc-url "$RPC" | awk '{print $1}')
echo "deployer $D  hype_wei=$ETH  usdc=$USDG  owner=$TABB_OWNER"
[ "$ETH" -ge 10000000000000000 ] || { echo "deployer needs >= 0.01 HYPE"; exit 1; }
[ "$USDG" -ge "${TABB_SEED_USDG:-10000000}" ] || { echo "deployer needs seed USDC"; exit 1; }

cd "$ROOT/contracts"
"$FORGE" script script/DeployElysium.s.sol --rpc-url "$RPC" --broadcast --slow
MGR=$(python3 -c "import json;print(json.load(open('deployments/99901.json'))['agentCreditManager'])")
[ "$("$CAST" codesize "$MGR" --rpc-url "$RPC")" -gt 0 ] || { echo "no code at manager $MGR"; exit 1; }
[ "$("$CAST" call "$MGR" "pendingOwner()(address)" --rpc-url "$RPC")" = "$("$CAST" to-check-sum-address "$TABB_OWNER")" ] \
  || { echo "pendingOwner mismatch"; exit 1; }

cd "$ROOT"
node scripts/sync-addresses.mjs 99901 --stable USDC --self-registry
cd web && npx tsc --noEmit && npm run build >/dev/null
REG=$(python3 -c "import json;print(json.load(open('$ROOT/contracts/deployments/99901.json'))['identityRegistry'])")
echo "ELYSIUM DEPLOYED: AgentCreditManager $MGR, ERC-8004 registry $REG (accept ownership at /admin on Elysium)"
