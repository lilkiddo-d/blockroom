# Blockroom

An RFQ desk and midpoint dark pool for **block trades of tokenized stocks on Robinhood Chain**. Large traders can trade size without moving the public price.

- **RFQ.** A taker asks for a price on size through an off-chain relay. Bonded market makers answer with EIP-712-signed firm quotes. The taker picks one and settles atomically on-chain. Settlement rejects quotes more than ±1% from the oracle mid, and a maker who fails to honour a signed quote is slashed and the taker compensated.
- **Midpoint cross.** Hidden orders (commit → reveal) match in 5-minute batches, only during US market hours, always at the oracle mid.
- **Partial fills, min fill and time in force** (GTD / IOC / FOK) on both venues.
- **Admin** is a 48h Timelock; a guardian can only pause.
- **Optional allowlist hook** (off by default), optional frontend geoblock, and a risk disclosure page.
- **$BLKR project-token hooks** for maker bonds, fee sharing and fee tiers, off until governance enables them. No token is deployed here.

## Repo

```
contracts/   Foundry · Solidity 0.8.28 · OpenZeppelin v5.4
  src/       Settlement, MakerRegistry, MidpointPool, PriceGuard, MarketClock, OracleAdapter,
             FeeCollector, ProjectTokenHooks, ComplianceRegistry, BlockroomTimelock
  script/    Deploy.s.sol (deploy + wire + Timelock hand-off + verify), SetProjectToken.s.sol
  test/      unit, fuzz, invariant (test/invariant), live-mainnet fork tests (test/fork)
app/         Next.js 16 · wagmi 2 · viem · RainbowKit — RFQ, midpoint, maker console, history, stake, risk
scripts/     RFQ relay (WebSocket), reference market-maker bot, batch keeper, e2e smoke tests, fork.sh
config/      chains.ts (sourced addresses), EIP-712 types, relay protocol, generated ABIs
docs/        ORACLES.md, sources/ (raw snapshots of the official address lists)
```

## Quick start

```bash
pnpm install
```
```bash
cd contracts && forge test
```
```bash
pnpm --filter @blockroom/scripts test
```
```bash
pnpm build
```

Run the full local stack against a mainnet fork with `bash scripts/fork.sh`, then follow "Local rehearsal" in [DEPLOY.md](DEPLOY.md).

## Status

| Check | Result |
|---|---|
| Foundry tests (unit, fuzz, invariant) | 134 passing, plus 5 fork tests against live Robinhood Chain |
| Invariants | a quote never fills beyond its size · no fill outside the price guard · midpoint executions always at the oracle mid · pool solvency · Settlement never holds funds |
| Line coverage (core contracts) | 100% on every core contract |
| Slither | 0 High, 0 Medium |
| Local mainnet fork | full deploy ✓, relay + bot RFQ round trip ✓, keeper-revealed midpoint batch ✓, frontend ✓ |
| Mainnet dry run | ✓ (24.2M gas) |

## Docs

- [DEPLOY.md](DEPLOY.md) — exact commands for mainnet, hosting, verification
- [DECISIONS.md](DECISIONS.md) — every design choice with one line of reasoning
- [THREAT_MODEL.md](THREAT_MODEL.md) — actors, risks, mitigations, residual risk
- [TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md) — how $BLKR plugs in later
- [docs/ORACLES.md](docs/ORACLES.md) — feeds, checks, known gaps and chain quirks

Blockroom is independent software and is not affiliated with Robinhood.
