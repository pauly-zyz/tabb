#!/usr/bin/env bash
# Dry-run of the Elysium deploy (self-hosted ERC-8004 registry + Tabb with USDC) and a Phase 1 flow on a local anvil
# fork of Elysium (99901). Uses the REAL USDC; nothing is broadcast to Elysium.
#   anvil --fork-url https://rpc.elysium.kinetiq.xyz --port 8547 &
#   scripts/fork-elysium-check.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORGE="${FORGE:-forge}"; CAST="${CAST:-cast}"
F="${FORK_RPC:-http://127.0.0.1:8547}"
U=0xb47c4C8F73F009CC0C0d3f92B388d13E293F0B65 # USDC on Elysium
WHALE="${USDC_WHALE:-0xe2e105d3f7209a9da11f83ccf3e7398a753823f1}"
DEPLOYER_PK=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d # anvil public key #1
DEPLOYER=$("$CAST" wallet address $DEPLOYER_PK)
OWNER=0x90F79bf6EB2c4f870365E785982E1f101E93b906 # anvil public account #3 (impersonated)
# fresh address: well-known anvil accounts carry EIP-7702 delegations on Elysium and reject ERC-721 safeMint
AGENT_OWNER=0x1000000000000000000000000000000000000A61
LENDER=0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
PAYEE=0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
[ "$("$CAST" chain-id --rpc-url $F)" = 99901 ] || { echo "not an Elysium fork"; exit 1; }

LOG=$(mktemp)
rpc() { "$CAST" rpc --rpc-url $F "$@" >/dev/null; }
send() { local from=$1; shift; "$CAST" send --rpc-url $F --unlocked --from "$from" "$@" > "$LOG" 2>&1; grep -q "status *1 (success)" "$LOG" || { echo "tx failed: $*"; cat "$LOG" | tail -5; exit 1; }; }
for a in $WHALE $DEPLOYER $OWNER $AGENT_OWNER $LENDER; do rpc anvil_impersonateAccount $a; rpc anvil_setBalance $a 0x8AC7230489E80000; done
send $WHALE $U "transfer(address,uint256)" $DEPLOYER 10000000
send $WHALE $U "transfer(address,uint256)" $AGENT_OWNER 500000000
send $WHALE $U "transfer(address,uint256)" $LENDER 5000000000

cd "$ROOT/contracts"
ELYSIUM_DEPLOYER_PRIVATE_KEY=$DEPLOYER_PK TABB_OWNER=$OWNER \
  "$FORGE" script script/DeployElysium.s.sol --rpc-url $F --broadcast --slow >/dev/null
J=deployments/99901.json
get() { python3 -c "import json;print(json.load(open('$J'))['$1'])"; }
POOL=$(get pool); MGR=$(get agentCreditManager); VAULT=$(get stakeVault); PAYEES=$(get payeeRegistry)
REG=$(get identityRegistry)
echo "deployed manager=$MGR pool=$POOL registry=$REG"
[ "$("$CAST" call $REG "owner()(address)" --rpc-url $F)" = "$OWNER" ] || { echo "registry owner wrong"; exit 1; }
[ "$("$CAST" call $REG "ownerOf(uint256)(address)" 0 --rpc-url $F)" = "$OWNER" ] || { echo "agent 0 not reserved"; exit 1; }
echo "self-hosted ERC-8004 registry owned by owner, agent #0 reserved"

for c in $POOL $(get riskConfig) $VAULT $(get creditScore) $PAYEES $MGR; do
  [ "$("$CAST" call $c "pendingOwner()(address)" --rpc-url $F)" = "$OWNER" ] || { echo "pendingOwner wrong on $c"; exit 1; }
  send $OWNER $c "acceptOwnership()"
  [ "$("$CAST" call $c "owner()(address)" --rpc-url $F)" = "$OWNER" ] || { echo "owner wrong on $c"; exit 1; }
done
echo "ownership accepted by owner on 6 contracts"

send $OWNER $PAYEES "setPayee(address,bool,string)" $PAYEE true "Fork test provider"
send $LENDER $U "approve(address,uint256)" $POOL 5000000000
send $LENDER $POOL "deposit(uint256,address)" 5000000000 $LENDER
echo "lender deposited 5000 USDC, pool totalAssets=$("$CAST" call $POOL "totalAssets()(uint256)" --rpc-url $F)"

send $AGENT_OWNER $REG "register(string)" "ipfs://fork-test-agent"
AGENT=1
[ "$("$CAST" call $REG "ownerOf(uint256)(address)" $AGENT --rpc-url $F)" = "$AGENT_OWNER" ] || { echo "agent registration failed"; exit 1; }
echo "registered agent #$AGENT"
send $AGENT_OWNER $U "approve(address,uint256)" $VAULT 300000000
send $AGENT_OWNER $VAULT "stake(uint256,uint256)" $AGENT 300000000
send $AGENT_OWNER $MGR "openTab(uint256,address,address)" $AGENT $AGENT_OWNER $AGENT_OWNER
AVAIL=$("$CAST" call $MGR "availableCredit(uint256)(uint256)" $AGENT --rpc-url $F | awk '{print $1}')
echo "agent #$AGENT (owner $AGENT_OWNER) opened a tab, available credit=$AVAIL"
send $AGENT_OWNER $MGR "draw(uint256,uint256)" $AGENT $AVAIL
echo "drew availableCredit ($AVAIL) into the PolicyAccount, debt=$("$CAST" call $MGR "debtOf(uint256)(uint256)" $AGENT --rpc-url $F)"
send $AGENT_OWNER $U "approve(address,uint256)" $MGR 200000000
send $AGENT_OWNER $MGR "repay(uint256,uint256)" $AGENT 200000000
DEBT=$("$CAST" call $MGR "debtOf(uint256)(uint256)" $AGENT --rpc-url $F | awk '{print $1}')
[ "$DEBT" = 0 ] || { echo "debt not cleared: $DEBT"; exit 1; }
echo "repaid in full, debt=0"
echo "FORK CHECK OK"
