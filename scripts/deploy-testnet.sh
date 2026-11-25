#!/usr/bin/env bash
# Deploy Tabb (Phase 1 + 2, with mocks) to Robinhood Chain testnet (46630) and wire the frontend.
# Requires .env with ROBINHOOD_TESTNET_RPC_URL and a funded DEPLOYER_PRIVATE_KEY (testnet only).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORGE="${FORGE:-forge}"; CAST="${CAST:-cast}"
set -a; . "$ROOT/.env"; set +a
export DEPLOY_MOCKS="${DEPLOY_MOCKS:-true}" DEPLOY_YIELD="${DEPLOY_YIELD:-true}"
RPC="$ROBINHOOD_TESTNET_RPC_URL"
[ "$($CAST chain-id --rpc-url "$RPC")" = "46630" ] || { echo "RPC is not Robinhood testnet (46630)"; exit 1; }
DEPLOYER=$($CAST wallet address --private-key "$DEPLOYER_PRIVATE_KEY")
echo "deployer $DEPLOYER balance $($CAST balance "$DEPLOYER" --ether --rpc-url "$RPC") ETH"
cd "$ROOT/contracts"
"$FORGE" script script/DeployTestnet.s.sol --rpc-url "$RPC" --broadcast --slow
MGR=$(python3 -c "import json;print(json.load(open('deployments/46630.json'))['agentCreditManager'])")
[ "$($CAST code "$MGR" --rpc-url "$RPC")" != "0x" ] || { echo "manager has no code on-chain"; exit 1; }
cd "$ROOT" && node scripts/sync-addresses.mjs 46630 --mocks
cd "$ROOT/web" && npx tsc --noEmit && npm run build >/dev/null && echo "web build OK"
echo "DEPLOYED: AgentCreditManager $MGR"
