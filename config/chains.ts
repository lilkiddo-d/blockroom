/**
 * Robinhood Chain configuration for Blockroom.
 *
 * Every address below was taken from an official source on 2026-10-08 and is re-verified on-chain by
 * contracts/test/fork/Fork.t.sol (symbol, decimals, feed liveness). Raw snapshots: docs/sources/.
 *
 *  [chain]   https://docs.robinhood.com/chain/connecting            chain id, RPC, explorer, gas token
 *  [deploy]  https://docs.robinhood.com/chain/deploy-smart-contracts Blockscout verification flags
 *  [tokens]  https://docs.robinhood.com/chain/contracts              WETH + USDG (static) and stock tokens (live
 *            table rendered from https://api.robinhood.com/rhj/assets, the on-chain asset registry)
 *  [stocks]  https://docs.robinhood.com/chain/building-with-stock-tokens  ERC-20, 18 decimals, ERC-8056 uiMultiplier
 *  [oracle]  https://docs.robinhood.com/chain/oracles-and-price-feeds -> Chainlink is the official oracle
 *  [feeds]   https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood
 *            (raw JSON: https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json)
 *  [proto]   https://docs.robinhood.com/chain/protocol-contracts       Multicall, Permit2, bridge contracts
 *
 * Gaps (documented in docs/ORACLES.md): no Chainlink L2 sequencer-uptime feed is published for Robinhood
 * Chain, and Data Feeds expose a single aggregated price (not bid/ask). OracleAdapter is swappable for a
 * Data Streams adapter that returns a true mid.
 */
import { defineChain, type Address } from "viem";

export const ROBINHOOD_CHAIN_ID = 4663 as const;
export const FORK_CHAIN_ID = 31337 as const;

/** [chain] */
export const robinhoodChain = defineChain({
  id: ROBINHOOD_CHAIN_ID,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: ["https://rpc.mainnet.chain.robinhood.com"] },
  },
  blockExplorers: {
    default: { name: "Blockscout", url: "https://robinhoodchain.blockscout.com" },
  },
  contracts: {
    // Canonical Multicall3 (aggregate3), verified on-chain. NOTE: the "L2 Multicall" listed in [proto]
    // (0x2cAC...DaD1) is an older multicall WITHOUT aggregate3 - viem's batching reverts against it.
    multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" },
  },
});

/** Local anvil fork of Robinhood Chain mainnet (`pnpm fork`), re-labelled 31337 to keep records separate. */
export const blockroomFork = defineChain({
  id: FORK_CHAIN_ID,
  name: "Robinhood Chain (local fork)",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["http://127.0.0.1:8545"] } },
  contracts: {
    multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" },
  },
});

/** [deploy] */
export const verification = {
  verifier: "blockscout",
  verifierUrl: "https://robinhoodchain.blockscout.com/api/",
  source: "https://docs.robinhood.com/chain/deploy-smart-contracts",
} as const;

/** [proto] */
export const protocolContracts = {
  permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  /** Robinhood-listed "L2 Multicall" (no aggregate3). Use `multicall3` below for viem. */
  multicall: "0x2cAC2D899eCC914d704FeaAE33ac1bF36277DaD1",
  /** Canonical Multicall3, deployed on Robinhood Chain (checked with aggregate3 on 2026-10-09). */
  multicall3: "0xcA11bde05977b3631167028862bE2a173976CA11",
  l2GatewayRouter: "0x1E324B9316138CA9a73F960213621AD1aaf01B89",
} as const satisfies Record<string, Address>;

/** [tokens] */
export const USDG = {
  symbol: "USDG",
  name: "Global Dollar",
  address: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168" as Address,
  decimals: 6,
  /** [feeds] "USDG / USD", 8 dp, 24h heartbeat, 0.5% deviation */
  feed: "0x61B7e5650328764B076A108EFF5fa7282a1B9aD2" as Address,
} as const;

export const WETH = {
  symbol: "WETH",
  address: "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73" as Address,
  decimals: 18,
  /** [feeds] "ETH / USD" */
  feed: "0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9" as Address,
} as const;

export type StockToken = {
  symbol: string;
  name: string;
  address: Address;
  decimals: 18;
  /** [feeds] Chainlink "Robinhood <SYM> / USD": 8 dp, 24h heartbeat, 0.5% deviation, us_equities_24/5 */
  feed: Address;
};

/** [tokens] + [feeds]. Must match contracts/script/RobinhoodConfig.sol. */
export const STOCKS: readonly StockToken[] = [
  { symbol: "AAPL", name: "Apple", address: "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9", decimals: 18, feed: "0x6B22A786bAa607d76728168703a39Ea9C99f2cD0" },
  { symbol: "NVDA", name: "NVIDIA", address: "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC", decimals: 18, feed: "0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15" },
  { symbol: "TSLA", name: "Tesla", address: "0x322F0929c4625eD5bAd873c95208D54E1c003b2d", decimals: 18, feed: "0x4A1166a659A55625345e9515b32adECea5547C38" },
  { symbol: "MSFT", name: "Microsoft", address: "0xe93237C50D904957Cf27E7B1133b510C669c2e74", decimals: 18, feed: "0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E" },
  { symbol: "GOOGL", name: "Alphabet Class A", address: "0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3", decimals: 18, feed: "0xF6f373a037c30F0e5010d854385cA89185AE638b" },
  { symbol: "AMZN", name: "Amazon", address: "0x12f190a9F9d7D37a250758b26824B97CE941bF54", decimals: 18, feed: "0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C" },
  { symbol: "META", name: "Meta Platforms", address: "0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35", decimals: 18, feed: "0x7C38C00C30BEe9378381E7B6135d7283356D71b1" },
  { symbol: "SPY", name: "SPDR S&P 500 ETF Trust", address: "0x117cc2133c37B721F49dE2A7a74833232B3B4C0C", decimals: 18, feed: "0x319724394D3A0e3669269846abE664Cd621f9f6A" },
  { symbol: "QQQ", name: "Invesco QQQ", address: "0xD5f3879160bc7c32ebb4dC785F8a4F505888de68", decimals: 18, feed: "0x80901d846d5D7B030F26B480776EE3b29374C2ae" },
  { symbol: "AMD", name: "AMD", address: "0x86923f96303D656E4aa86D9d42D1e57ad2023fdC", decimals: 18, feed: "0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72" },
  { symbol: "COIN", name: "Coinbase", address: "0x6330D8C3178a418788dF01a47479c0ce7CCF450b", decimals: 18, feed: "0xA3a468A452940B7D6b69991207B508c609a98Ef2" },
] as const;

export function stockByAddress(address: string): StockToken | undefined {
  const a = address.toLowerCase();
  return STOCKS.find((s) => s.address.toLowerCase() === a);
}

export function stockBySymbol(symbol: string): StockToken | undefined {
  return STOCKS.find((s) => s.symbol === symbol.toUpperCase());
}

export const SUPPORTED_CHAIN_IDS = [ROBINHOOD_CHAIN_ID, FORK_CHAIN_ID] as const;
export type SupportedChainId = (typeof SUPPORTED_CHAIN_IDS)[number];
