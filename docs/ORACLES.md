# Oracles, market data and known gaps

## What is used

- **Chainlink Data Feeds** on Robinhood Chain. Chainlink is named as the official oracle in Robinhood's docs. Addresses come from Chainlink's directory: https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood (raw JSON snapshot in `docs/sources/`).
- **Stock feeds** ("Robinhood <SYM> / USD") use 8 decimals, a 24h heartbeat, a 0.5% deviation threshold, and `us_equities_24/5` market hours. Robinhood documents that these feeds already include the ERC-8056 corporate-action multiplier, so the price is per raw token.
- **USDG / USD** is used to convert USD prices into USDG and to enforce a 1% peg bound.

`OracleAdapter.getMid(base, quote)` returns `baseUSD / quoteUSD`, scaled to quote-token decimals: USDG units per one whole stock token.

## Checks

- answer > 0
- `updatedAt` is non-zero and not in the future
- `answeredInRound ≥ roundId`
- age ≤ `maxStaleness` (25h)
- optional secondary feed with a deviation bound
- quote-token peg bound
- optional sequencer-uptime feed with a grace period

## Gaps and how to close them

1. **No L2 sequencer-uptime feed** is published for Robinhood Chain. The adapter supports one: once Chainlink lists it, call `OracleAdapter.setSequencerUptimeFeed(feed, grace)` through the Timelock.
2. **Data Feeds are not a bid/ask mid.** They publish one aggregated price. Chainlink **Data Streams** are live on Robinhood Chain and include bid/ask/mid. To use a true mid:
   - deploy an `IOracleAdapter` that verifies Data Streams reports (pull-based: the keeper or taker supplies the signed report);
   - point `PriceGuard.setOracle(newAdapter)` at it through the Timelock.

   Every consumer (Settlement, MidpointPool, relay, app) reads the mid through PriceGuard, so nothing else changes.
3. **Lag:** with deviation-triggered updates, the on-chain price can trail the market by up to about 0.5%. The RFQ guard band (1%) is deliberately wider than that.
4. **Weekends and holidays:** the stock feeds keep a 24h heartbeat 24/5, so prices go stale beyond 25h over weekends. RFQ fills then revert (no stale pricing), and midpoint batches can't run anyway because the market is closed.

## Other environment findings (from the fork rehearsal)

- `0x2cAC…DaD1`, listed as "L2 Multicall" in Robinhood's protocol-contracts page, does **not** implement Multicall3 `aggregate3`. The app uses the canonical Multicall3 at `0xcA11bde05977b3631167028862bE2a173976CA11`, which is deployed and was checked on 4663.
- **EIP-7702 delegations are live** on this chain (many well-known EOAs carry `0xef0100…` code). Settlement accepts a maker's ECDSA signature before falling back to ERC-1271.
- `block.number` inside the EVM is an L1 block number (Arbitrum stack). The deploy script records the L2 block from `eth_blockNumber` for indexers.
- The public RPC is not an archive node and keeps very little history. Local forks must warm their cache immediately (`scripts/fork.sh` does this); use an archive RPC for long fork sessions.
- The Blockscout API sits behind a Cloudflare bot challenge from some networks. See DEPLOY.md for verification fallbacks.
