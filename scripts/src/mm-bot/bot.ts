/**
 * Reference market-maker bot. Connects to the relay as a maker, prices RFQs at oracle mid +/- spread,
 * checks its own inventory and allowances, and answers with EIP-712 signed quotes.
 *
 *   SIGNER=keystore KEYSTORE_ACCOUNT=blockroom-maker pnpm mm-bot
 *   SIGNER=rpc SIGNER_ADDRESS=0x... RPC_URL=http://127.0.0.1:8545 CHAIN_ID=31337 pnpm mm-bot   (local fork)
 *
 * Prerequisites: the maker address is registered and bonded in MakerRegistry (Maker console in the app).
 */
import WebSocket from "ws";
import { erc20Abi, getAddress, maxUint256, zeroAddress, type Address, type Hex } from "viem";
import {
  MakerSide,
  STOCKS,
  TimeInForce,
  quoteDomain,
  quoteTypes,
  toWire,
  type Quote,
  type RfqRequest,
  type ServerMsg,
} from "@blockroom/config";
import { makerRegistryAbi, priceGuardAbi } from "@blockroom/config/abis";
import { chainFor, env, envNum, loadDeployment, loadDotEnv, log, makePublicClient } from "../lib/env.js";
import { loadSigner } from "../lib/signer.js";
import { nonceFactory, quotePrice, quoteSize } from "./pricing.js";

loadDotEnv();
const chainId = Number(env("CHAIN_ID", "4663"));
const rpcUrl = env("RPC_URL", env("ROBINHOOD_RPC_URL", "https://rpc.mainnet.chain.robinhood.com"));
const relayUrl = env("RELAY_URL", "ws://localhost:8787");
const spreadBps = envNum("MM_SPREAD_BPS", 15);
const ttlSec = envNum("MM_QUOTE_TTL_SEC", 60);
const dep = loadDeployment(chainId);
const client = makePublicClient(chainId, rpcUrl);
const signer = await loadSigner(chainFor(chainId), rpcUrl);
const maker = signer.address;
const quoteDecimals = 6;
const maxNotional = BigInt(envNum("MM_MAX_NOTIONAL_USDG", 250_000)) * 10n ** BigInt(quoteDecimals);
const nextNonce = nonceFactory();

async function ensureApprovals() {
  const tokens: Address[] = [dep.USDG, ...STOCKS.map((s) => s.address)];
  for (const token of tokens) {
    const allowance = await client.readContract({
      address: token,
      abi: erc20Abi,
      functionName: "allowance",
      args: [maker, dep.Settlement],
    });
    if (allowance > 10n ** 30n) continue;
    const hash = await signer.wallet.writeContract({
      account: signer.account,
      chain: chainFor(chainId),
      address: token,
      abi: erc20Abi,
      functionName: "approve",
      args: [dep.Settlement, maxUint256],
    });
    await client.waitForTransactionReceipt({ hash });
    log("mm", "approved", { token });
  }
}

async function buildQuotes(rfq: RfqRequest): Promise<Quote[]> {
  const sides =
    rfq.side === "buy" ? [MakerSide.MakerSells] : rfq.side === "sell" ? [MakerSide.MakerBuys] : [0, 1];
  const mid = await client.readContract({
    address: dep.PriceGuard,
    abi: priceGuardAbi,
    functionName: "getMid",
    args: [rfq.baseToken, rfq.quoteToken],
  });
  const [baseBal, quoteBal] = await Promise.all([
    client.readContract({ address: rfq.baseToken, abi: erc20Abi, functionName: "balanceOf", args: [maker] }),
    client.readContract({ address: rfq.quoteToken, abi: erc20Abi, functionName: "balanceOf", args: [maker] }),
  ]);
  const expiry = BigInt(Math.floor(Date.now() / 1000) + ttlSec);
  const out: Quote[] = [];
  for (const side of sides) {
    const price = quotePrice(mid, side, spreadBps);
    const size = quoteSize({
      requested: BigInt(rfq.size),
      side,
      price,
      baseUnit: 10n ** 18n,
      baseInventory: baseBal,
      quoteInventory: quoteBal,
      maxNotional,
    });
    if (size === 0n) continue;
    out.push({
      rfqId: rfq.rfqId,
      maker,
      taker: rfq.taker ?? zeroAddress,
      baseToken: rfq.baseToken,
      quoteToken: rfq.quoteToken,
      side,
      tif: TimeInForce.GTD,
      price,
      size,
      minFill: size / 10n,
      nonce: nextNonce(),
      expiry,
    });
  }
  return out;
}

function connect() {
  const ws = new WebSocket(relayUrl);
  const send = (m: unknown) => ws.send(JSON.stringify(m));
  ws.on("open", () => send({ type: "hello", role: "maker", address: maker }));
  ws.on("message", async (data) => {
    const msg = JSON.parse(data.toString()) as ServerMsg;
    try {
      if (msg.type === "challenge") {
        const signature = await signer.wallet.signMessage({ account: signer.account, message: msg.message });
        send({ type: "auth", address: maker, signature });
      } else if (msg.type === "ready") {
        log("mm", "authenticated", { maker, makers: msg.makers });
      } else if (msg.type === "rfq") {
        const quotes = await buildQuotes(msg.rfq);
        for (const q of quotes) {
          const signature: Hex = await signer.wallet.signTypedData({
            account: signer.account,
            domain: quoteDomain(chainId, dep.Settlement),
            types: quoteTypes,
            primaryType: "Quote",
            message: q,
          });
          send({ type: "quote", quote: toWire(q), signature });
          log("mm", "quoted", { rfqId: q.rfqId, side: q.side, price: q.price, size: q.size });
        }
      } else if (msg.type === "error") {
        log("mm", "relay error", { code: msg.code, message: msg.message });
      }
    } catch (e) {
      log("mm", "handler error", { error: (e as Error).message });
    }
  });
  ws.on("close", () => {
    log("mm", "disconnected; reconnecting in 3s");
    setTimeout(connect, 3_000);
  });
  ws.on("error", (e) => log("mm", "ws error", { error: e.message }));
}

const eligible = await client.readContract({
  address: dep.MakerRegistry,
  abi: makerRegistryAbi,
  functionName: "canQuote",
  args: [maker],
});
log("mm", "starting", { maker: getAddress(maker), eligible, relayUrl, spreadBps });
if (!eligible) log("mm", "WARNING: maker is not registered/bonded - relay will reject auth");
await ensureApprovals();
connect();
