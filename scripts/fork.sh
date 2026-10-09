#!/usr/bin/env bash
# Local end-to-end environment: anvil fork of Robinhood Chain mainnet (re-labelled chain 31337), full Blockroom
# deploy via script/Deploy.s.sol, and dev balances for anvil's unlocked accounts #0 (taker) and #1 (maker).
#
#   bash scripts/fork.sh            # FORK_PORT=29463 by default
#
# Notes
# - Uses anvil's well-known UNLOCKED dev accounts by ADDRESS only (--unlocked). No private key is used or printed.
# - The public RPC is not an archive node and only keeps recent state, so the fork must warm up every slot it needs
#   right after starting. For long sessions use an archive RPC (e.g. Alchemy) via ROBINHOOD_RPC_URL.
# - --hardfork cancun avoids anvil's per-block EIP-2935 history-contract read, which needs archive state.
# - --gas-limit 30000000 replaces the forked Arbitrum block gas limit (~1.1e15), which breaks gas estimation.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${FORK_PORT:-29463}"
UPSTREAM="${ROBINHOOD_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
R="http://127.0.0.1:${PORT}"
TAKER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
MAKER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
AAPL=0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9

anvil --fork-url "$UPSTREAM" --chain-id 31337 --port "$PORT" --host 127.0.0.1 --hardfork cancun --gas-limit 30000000 \
  --retries 20 --timeout 90000 --fork-retry-backoff 1000 > "${ROOT}/.anvil.log" 2>&1 &
ANVIL_PID=$!
echo "anvil pid ${ANVIL_PID} on ${R}"
for _ in $(seq 1 40); do cast chain-id --rpc-url "$R" >/dev/null 2>&1 && break; sleep 1; done

slot() { # token account -> storage slot of balanceOf(account)
  (cd "${ROOT}/contracts" && forge script script/dev/FindBalanceSlot.s.sol --sig "run(address,address)" "$1" "$2" \
    --rpc-url "$R" 2>/dev/null | grep -oE '0x[0-9a-f]{64}' | tail -1)
}
fund() { # token account amount
  cast rpc anvil_setStorageAt "$1" "$(slot "$1" "$2")" "$(cast to-uint256 "$3")" --rpc-url "$R" >/dev/null
}

echo "== funding dev accounts"
for a in $TAKER $MAKER; do
  fund $USDG "$a" 10000000000000         # 10,000,000 USDG
  fund $AAPL "$a" 10000000000000000000000  # 10,000 AAPL
done

echo "== deploying Blockroom"
(cd "${ROOT}/contracts" && forge script script/Deploy.s.sol --rpc-url "$R" --unlocked --sender $TAKER --broadcast \
  2>&1 | grep -E "COMPLETE|Error" | grep -v etherscan)

D="${ROOT}/contracts/deployments/31337.json"
get() { node -e "console.log(require(process.argv[1])[process.argv[2]])" "$D" "$1"; }
REG=$(get MakerRegistry); SET=$(get Settlement); POOL=$(get MidpointPool)

echo "== registering + bonding dev maker, approvals"
send() { cast send "$@" --unlocked --rpc-url "$R" >/dev/null; }
send $REG "register()" --from $MAKER
send $USDG "approve(address,uint256)" $REG 25000000000 --from $MAKER
send $REG "depositBond(uint256)" 25000000000 --from $MAKER
for a in $TAKER $MAKER; do
  for t in $USDG $AAPL; do
    send $t "approve(address,uint256)" $SET 115792089237316195423570985008687907853269984665640564039457584007913129639935 --from $a
    send $t "approve(address,uint256)" $POOL 115792089237316195423570985008687907853269984665640564039457584007913129639935 --from $a
  done
done
echo "== warming fork cache (every feed via PriceGuard, Multicall3, stock balances)"
PG=$(get PriceGuard)
STOCKS=$(grep -oE 'address: "0x[0-9a-fA-F]{40}", decimals: 18' "${ROOT}/config/chains.ts" | grep -oE '0x[0-9a-fA-F]{40}')
for s in $STOCKS; do
  cast call $PG "getMid(address,address)(uint256)" "$s" $USDG --rpc-url "$R" >/dev/null || echo "  warn: mid unavailable for $s"
  for a in $TAKER $MAKER; do cast call "$s" "balanceOf(address)(uint256)" "$a" --rpc-url "$R" >/dev/null; done
done
cast call 0xcA11bde05977b3631167028862bE2a173976CA11 "getBlockNumber()(uint256)" --rpc-url "$R" >/dev/null
echo "maker canQuote: $(cast call $REG 'canQuote(address)(bool)' $MAKER --rpc-url $R)"
echo "AAPL mid (USDG): $(cast call $(get PriceGuard) 'getMid(address,address)(uint256)' $AAPL $USDG --rpc-url $R)"
echo "ready. RPC=${R}  (stop with: kill ${ANVIL_PID})"
wait $ANVIL_PID
