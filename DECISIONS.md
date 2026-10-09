# Decisions log

One line of reasoning per decision. Newest decisions are appended at the bottom of each section.

## Chain, tokens, oracle

- **Chain = Robinhood Chain mainnet, chain id 4663, ETH gas, Blockscout explorer.** Taken from docs.robinhood.com/chain/connecting and checked with `cast chain-id`.
- **Stock-token addresses come from Robinhood's asset registry (`api.robinhood.com/rhj/assets`).** That is the live source behind the "Stock Tokens & Tokenized ETFs" table on docs.robinhood.com/chain/contracts. A raw snapshot is in `docs/sources/`.
- **USDG (6 dp) is the only quote/bond stablecoin.** The docs list it as the chain's settlement stablecoin, and it is the only stablecoin with a Robinhood-listed address and a Chainlink feed.
- **Chainlink Data Feeds are the oracle.** Robinhood's docs name Chainlink the official oracle, and feed addresses come from Chainlink's directory JSON for `robinhood-mainnet`.
- **Supported universe = 11 names (AAPL, NVDA, TSLA, MSFT, GOOGL, AMZN, META, SPY, QQQ, AMD, COIN).** These have both a canonical token and a Chainlink feed. Adding more takes one Timelock call per contract.
- **"Mid" = the Chainlink aggregated price, with a swappable adapter.** Data Feeds publish one consensus price, not a bid/ask. A Data Streams adapter that returns a true mid can replace it via `PriceGuard.setOracle` (see docs/ORACLES.md).
- **Sequencer-uptime check is optional and off.** Chainlink publishes no uptime feed for Robinhood Chain. The adapter supports one as soon as it exists (documented gap).
- **Feed staleness limit = 25h** (24h heartbeat + 1h buffer). The feeds update 24/5 on 0.5% deviation, and the heartbeat bounds how stale the price can get.
- **USDG peg tolerance = 1%.** The mid is converted through the USDG/USD feed, and a de-peg beyond 1% halts pricing instead of mispricing every trade.
- **Prices are in quote units per one whole base token.** This matches the feed semantics, since Chainlink stock feeds already include the ERC-8056 UI multiplier.
- **viem uses the canonical Multicall3 (`0xcA11bde0…`), not the docs' "L2 Multicall" (`0x2cAC…`).** The docs' contract has no `aggregate3`, so every batched frontend read reverted against it (found in the fork run).
- **EVM target = Cancun.** `ArbSys.arbOSVersion()` returns 116, which is ArbOS 61 and supports Cancun opcodes.

## Protocol design

- **Price guard band = ±100 bps.** It must exceed the feed's 0.5% deviation threshold plus a normal spread. It is per-asset configurable with a hard cap of 10%.
- **Out-of-band quote = revert, no slash.** This protects makers from stale quotes being picked off and protects takers from off-market prices.
- **Quote replay protection uses an EIP-712 domain, a per-quote `filled` cap and a Permit2-style nonce bitmap plus `minNonce`.** Makers get O(1) single or bulk cancels, and replay is impossible across chains, deployments and fills.
- **Anti last-look: both legs are pre-checked (balance + allowance) before any transfer.** An undeliverable maker means a slash and a burned quote. An undeliverable taker means a revert, so makers can't be griefed into slashes.
- **Slash = 1% of notional, capped at the maker's slashable bond, paid 100% to the taker.** Compensation goes to the harmed party, and the cap keeps the bond the maximum loss.
- **Max quote TTL = 5 minutes, maker unbonding = 3 days.** Unbonding must outlast every quote the maker signed. Pending withdrawals stay slashable and still count for eligibility, so a withdrawal can't be used to escape a fill.
- **Settlement never custodies funds: transfers go directly maker↔taker.** This is fewer transfers and a smaller attack surface. It requires standard ERC-20s; stock tokens and USDG qualify.
- **Maker signatures: ECDSA first, ERC-1271 only as a fallback for contract wallets.** OpenZeppelin's `SignatureChecker` skips ECDSA for any address with code, which rejects EIP-7702 "smart EOAs". These are live on Robinhood Chain; the fork run hit it. A pure contract has no key, so ECDSA can't recover to it.
- **Partial fills, min fill and time in force are signed into the quote.** GTD allows multiple fills ≥ minFill until expiry. IOC allows one fill and cancels the rest. FOK requires exactly the full size.
- **The final remainder below `minFill` can be filled.** Otherwise a GTD quote could be left with an unfillable dust remainder.
- **Midpoint uses per-asset batches: 5 min commit, 2 min reveal, 10 min settle window.** Per-asset batches keep loops bounded (≤64 orders), and short windows limit the settler's timing optionality.
- **Midpoint matching is FIFO by commit order with a two-pointer walk, all executions at one mid read.** It runs in O(n), is deterministic, and makes "always at oracle mid" a structural property.
- **`minFill` in the pool is a per-execution minimum acceptable quantity, applied as `min(minFill, remaining)`.** This is how real dark pools define MAQ, and it keeps the walk single-pass and terminating.
- **Pool FOK = `minFill = size`, so a single counterparty must take the whole order.** It reuses MAQ semantics without backtracking.
- **Buys must carry a limit price, sells may omit one.** Buys must lock enough quote at reveal (size × limit plus max fee). Sells lock base, so they don't need a price.
- **Funds sit in an internal pool ledger, deposited separately from orders.** A same-transaction deposit would reveal side and size, while a standing balance does not.
- **Commit bond = 5 USDG, forfeited if unrevealed and refunded on reveal or void.** This is anti-spam for the bounded commit slots.
- **Anyone can reveal with the preimage; the keeper offers delegated reveal.** Traders can stay offline, and the keeper only learns the order after the commit window closes.
- **Batches void (refund and unlock everything) if paused, the market is closed, the oracle is unhealthy or the deadline passed.** Funds can never get stuck, and no match happens without a valid mid.
- **Pool withdrawals work while paused.** A pause must never trap user funds.
- **The market clock computes US DST fully on-chain; holidays and early closes are pushed by `CALENDAR_ROLE` and can only shorten sessions.** This needs no oracle for time, and a compromised calendar key can at worst halt matching.
- **The RFQ desk is not gated by market hours, only by oracle freshness.** The stock feeds are 24/5, and the price guard already refuses stale prices.

## Governance and security

- **Admin = OpenZeppelin `TimelockController` with a 48h floor enforced in `getMinDelay()`.** The delay can be raised but never lowered below 48h, even by governance.
- **The guardian can only pause/unpause, force-close the clock and suspend makers.** It is a fast circuit breaker with no ability to move funds or change economics.
- **The deployer is the default proposer/executor; production should set `BLOCKROOM_PROPOSER` to a multisig.** The script is unattended, and DEPLOY.md recommends the multisig.
- **The treasury defaults to the Timelock.** Protocol revenue is then only movable through governance.
- **Fee sweeps to the treasury are permissionless.** No privileged key is needed to route revenue to the fixed treasury address.
- **Compliance hook is wired into every entry point and disabled by default (`enabled = false`).** It can be switched on via the Timelock without a redeploy. Allowlist edits use a separate `COMPLIANCE_ROLE`.
- **No upgradeable proxies.** Immutable contracts plus swappable modules (oracle, price guard, compliance, fee collector) give flexibility without proxy risk.
- **Slither: all High and Medium findings fixed or justified inline.** The remaining annotated false positives are the signed-order `transferFrom(maker, …)` (the core RFQ pattern) and the calendar modulo arithmetic.
- **Line endings are normalized to LF.** CRLF files skewed Slither's source mapping on Windows.
- **Foundry `dynamic_test_linking = false`.** With it on, `expectRevert` + `new` silently ended tests early, which made some assertions vacuous.

## Project token ($BLKR)

- **One switchboard (`ProjectTokenHooks`) owns the token address; every consumer reads from it.** A single one-shot Timelock call (`setProjectToken`) activates every feature consistently.
- **Bond value per token starts at 0.** Project-token bonds count for nothing until governance sets a haircut ratio, which stops an illiquid token from replacing real collateral.
- **Fee discounts are based on staked balance with a 7-day unstake cooldown, not wallet balance.** Wallet balances can be flash-borrowed to game discount tiers.
- **Stakers get 30% of fees in reward tokens (USDG); the project token can never be a reward token.** This keeps principal and rewards separate in the accounting.
- **A mock ERC-20 is used only in tests (`test/utils/Mocks.sol`).** The project ships no token contract.

## Off-chain and frontend

- **The relay is a stateless WebSocket fan-out that verifies EIP-712 and EIP-191 and gives an advisory guard check.** It can't forge or settle anything, and the app connects to several relays and merges their quotes.
- **"Two-way" RFQs exist so takers can hide their direction.** This directly mitigates information leakage to makers.
- **Maker relay auth uses a challenge signature plus an on-chain `canQuote` check.** Only bonded makers can see order flow.
- **Bot and keeper signing: Foundry keystore (decrypted in memory) or an RPC signer (anvil, Clef, web3signer).** No key is ever created, stored or printed by this code.
- **Frontend: Next.js 16, React 19, wagmi 2, RainbowKit 2.** RainbowKit 2.x requires wagmi 2, so wagmi 3 isn't used.
- **Wallets: injected/Coinbase always, WalletConnect wallets only when `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` is set.** The build works with no third-party IDs configured.
- **The geoblock is a Next.js middleware on Vercel/Cloudflare geo headers, off unless `GEOBLOCK_COUNTRIES` is set.** It is optional as specified, and on-chain gating is the ComplianceRegistry.
- **Midpoint order preimages live in browser localStorage and are saved before the commit transaction.** Nothing leaks to a server, and a failed commit never loses a preimage.
- **The local fork is re-labelled chain id 31337.** Deployment records for the fork and mainnet can never collide.
- **Fork tests fork the latest block.** The public RPC is not an archive node. Tests warp into the next US session and re-stamp feeds only if the warp crosses a weekend.
- **The keeper judges batch windows by chain time (latest block timestamp), not the wall clock.** The on-chain windows follow `block.timestamp`.
- **`deployedAtBlock` is the L2 block number from `eth_blockNumber`, minus a 1,000-block margin.** On Arbitrum-stack chains `block.number` is an L1 number, which would point indexers at the wrong range.
- **Local forks use `--hardfork cancun --gas-limit 30000000` and warm their cache immediately.** The public RPC isn't an archive node, Prague's EIP-2935 read needs archive state, and the forked Arbitrum gas limit (about 1.1e15) breaks gas estimation.
- **Coinbase CDP SDK is stubbed in the app bundle.** RainbowKit's Base Account connector imports it only for a server-side subscription feature that pulls in uninstalled optional x402 packages and breaks the build.
- **Next 16 `proxy.ts` replaces `middleware.ts` for the geoblock.** `middleware` is deprecated in Next 16.
- **Branding: the wordmark is "Blockroom" with no Robinhood name or logo.** The chain is named only where factually required (network selector, docs).
