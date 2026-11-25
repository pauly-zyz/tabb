#!/usr/bin/env bash
# Dry-run of the mainnet deploy + a Phase 1 smoke flow on a local anvil fork of Robinhood Chain mainnet.
# Uses the REAL USDG and the REAL ERC-8004 Identity Registry; nothing is broadcast to mainnet.
#   anvil --fork-url https://rpc.mainnet.chain.robinhood.com --port 8546 &
#   scripts/fork-mainnet-check.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORGE="${FORGE:-forge}"; CAST="${CAST:-cast}"
F="${FORK_RPC:-http://127.0.0.1:8546}"
U=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
REG=0x8004A169FB4a3325136EB29fA0ceB6D2e539a432
WHALE="${USDG_WHALE:-0x51c72848c68a965f66fa7a88855f9f7784502a7f}"
DEPLOYER_PK=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d # anvil public key #1
DEPLOYER=$("$CAST" wallet address $DEPLOYER_PK)
OWNER=0x90F79bf6EB2c4f870365E785982E1f101E93b906 # anvil public account #3 (impersonated)
AGENT=1
AGENT_OWNER=$("$CAST" call $REG "ownerOf(uint256)(address)" $AGENT --rpc-url $F)
LENDER=0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
PAYEE=0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
[ "$("$CAST" chain-id --rpc-url $F)" = 4663 ] || { echo "not a mainnet fork"; exit 1; }

rpc() { "$CAST" rpc --rpc-url $F "$@" >/dev/null; }
send() { local from=$1; shift; "$CAST" send --rpc-url $F --unlocked --from "$from" "$@" | grep -q "status *1 (success)" || { echo "tx failed: $*"; exit 1; }; }
for a in $WHALE $DEPLOYER $OWNER $AGENT_OWNER $LENDER; do rpc anvil_impersonateAccount $a; rpc anvil_setBalance $a 0x8AC7230489E80000; done
send $WHALE $U "transfer(address,uint256)" $DEPLOYER 10000000
send $WHALE $U "transfer(address,uint256)" $AGENT_OWNER 500000000
send $WHALE $U "transfer(address,uint256)" $LENDER 5000000000

cd "$ROOT/contracts"
MAINNET_DEPLOYER_PRIVATE_KEY=$DEPLOYER_PK TABB_OWNER=$OWNER \
  "$FORGE" script script/DeployMainnet.s.sol --rpc-url $F --broadcast --slow >/dev/null
J=deployments/4663.json
get() { python3 -c "import json;print(json.load(open('$J'))['$1'])"; }
POOL=$(get pool); MGR=$(get agentCreditManager); VAULT=$(get stakeVault); PAYEES=$(get payeeRegistry)
echo "deployed manager=$MGR pool=$POOL"

for c in $POOL $(get riskConfig) $VAULT $(get creditScore) $PAYEES $MGR; do
  [ "$("$CAST" call $c "pendingOwner()(address)" --rpc-url $F)" = "$OWNER" ] || { echo "pendingOwner wrong on $c"; exit 1; }
  send $OWNER $c "acceptOwnership()"
  [ "$("$CAST" call $c "owner()(address)" --rpc-url $F)" = "$OWNER" ] || { echo "owner wrong on $c"; exit 1; }
done
echo "ownership accepted by owner on 6 contracts"

send $OWNER $PAYEES "setPayee(address,bool,string)" $PAYEE true "Fork test provider"
send $LENDER $U "approve(address,uint256)" $POOL 5000000000
send $LENDER $POOL "deposit(uint256,address)" 5000000000 $LENDER
echo "lender deposited 5000 USDG, pool totalAssets=$("$CAST" call $POOL "totalAssets()(uint256)" --rpc-url $F)"

send $AGENT_OWNER $U "approve(address,uint256)" $VAULT 300000000
send $AGENT_OWNER $VAULT "stake(uint256,uint256)" $AGENT 300000000
send $AGENT_OWNER $MGR "openTab(uint256,address,address)" $AGENT $AGENT_OWNER $AGENT_OWNER
AVAIL=$("$CAST" call $MGR "availableCredit(uint256)(uint256)" $AGENT --rpc-url $F | awk '{print $1}')
echo "real ERC-8004 agent #$AGENT (owner $AGENT_OWNER) opened a tab, available credit=$AVAIL"
send $AGENT_OWNER $MGR "draw(uint256,uint256)" $AGENT $AVAIL
echo "drew availableCredit ($AVAIL) into the PolicyAccount, debt=$("$CAST" call $MGR "debtOf(uint256)(uint256)" $AGENT --rpc-url $F)"
send $AGENT_OWNER $U "approve(address,uint256)" $MGR 200000000
send $AGENT_OWNER $MGR "repay(uint256,uint256)" $AGENT 200000000
DEBT=$("$CAST" call $MGR "debtOf(uint256)(uint256)" $AGENT --rpc-url $F | awk '{print $1}')
[ "$DEBT" = 0 ] || { echo "debt not cleared: $DEBT"; exit 1; }
echo "repaid in full, debt=0"
echo "FORK CHECK OK"
