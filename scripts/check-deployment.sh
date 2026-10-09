#!/usr/bin/env bash
# Read-only post-deploy checks. Usage: bash scripts/check-deployment.sh <chainId> <rpcUrl>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHAIN="${1:-4663}"
R="${2:-https://rpc.mainnet.chain.robinhood.com}"
D="${ROOT}/contracts/deployments/${CHAIN}.json"
get() { node -e "console.log(require(process.argv[1])[process.argv[2]])" "$D" "$1"; }
ADMIN=0x0000000000000000000000000000000000000000000000000000000000000000
TL=$(get Timelock); DEPLOYER=$(get deployer)
echo "chain id:                 $(cast chain-id --rpc-url "$R") (expected ${CHAIN})"
for c in OracleAdapter PriceGuard MarketClock ComplianceRegistry ProjectTokenHooks FeeCollector MakerRegistry Settlement MidpointPool; do
  a=$(get $c)
  printf "%-20s timelock admin=%s deployer admin=%s\n" "$c" \
    "$(cast call "$a" 'hasRole(bytes32,address)(bool)' $ADMIN "$TL" --rpc-url "$R")" \
    "$(cast call "$a" 'hasRole(bytes32,address)(bool)' $ADMIN "$DEPLOYER" --rpc-url "$R")"
done
echo "compliance enabled:       $(cast call "$(get ComplianceRegistry)" 'enabled()(bool)' --rpc-url "$R")"
echo "timelock min delay (s):   $(cast call "$TL" 'getMinDelay()(uint256)' --rpc-url "$R")"
echo "project token:            $(cast call "$(get ProjectTokenHooks)" 'projectToken()(address)' --rpc-url "$R")"
echo "AAPL mid (USDG, 6 dp):    $(cast call "$(get PriceGuard)" 'getMid(address,address)(uint256)' 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9 "$(get USDG)" --rpc-url "$R" 2>&1 | head -1)"
echo "market open now:          $(cast call "$(get MarketClock)" 'isOpen()(bool)' --rpc-url "$R")"
