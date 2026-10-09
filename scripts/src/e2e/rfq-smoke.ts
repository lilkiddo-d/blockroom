/**
 * End-to-end RFQ smoke test (local fork): taker -> relay -> maker bot -> signed quote -> Settlement.fill on-chain.
 *
 *   CHAIN_ID=31337 RPC_URL=http://127.0.0.1:29463 RELAY_URL=ws://127.0.0.1:8787 \
 *   SIGNER=rpc SIGNER_ADDRESS=<anvil dev account #0> pnpm --filter @blockroom/scripts smoke:rfq
 */
import WebSocket from "ws";
import { decodeEventLog, erc20Abi, parseUnits, verifyTypedData, type Hex } from "viem";
import { fromWire, quoteDomain, quoteTypes, stockBySymbol, type Quote, type ServerMsg } from "@blockroom/config";
import { settlementAbi } from "@blockroom/config/abis";
import { chainFor, env, loadDeployment, loadDotEnv, makePublicClient } from "../lib/env.js";
import { loadSigner } from "../lib/signer.js";

loadDotEnv();
const chainId = Number(env("CHAIN_ID", "31337"));
const rpcUrl = env("RPC_URL");
const dep = loadDeployment(chainId);
const client = makePublicClient(chainId, rpcUrl);
const signer = await loadSigner(chainFor(chainId), rpcUrl);
const aapl = stockBySymbol(process.env.SMOKE_SYMBOL ?? "AAPL")!;
const size = parseUnits(process.env.SMOKE_SIZE ?? "10", 18);
const rfqId = ("0x" + Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("hex")) as Hex;

const quotes: { q: Quote; sig: Hex; mid: bigint; dev: number }[] = [];
await new Promise<void>((resolve, reject) => {
  const ws = new WebSocket(env("RELAY_URL", "ws://127.0.0.1:8787"));
  const timer = setTimeout(() => (ws.close(), resolve()), 6_000);
  ws.on("open", () => ws.send(JSON.stringify({ type: "hello", role: "taker" })));
  ws.on("error", reject);
  ws.on("message", (raw) => {
    const m = JSON.parse(raw.toString()) as ServerMsg;
    if (m.type === "ready") {
      ws.send(JSON.stringify({ type: "rfq", rfq: { rfqId, baseToken: aapl.address, quoteToken: dep.USDG, side: "two-way", size: size.toString(), taker: signer.address } }));
    } else if (m.type === "rfq_ack") {
      console.log(`rfq ${rfqId.slice(0, 10)}… sent to ${m.makersNotified} maker(s)`);
    } else if (m.type === "quote") {
      quotes.push({ q: fromWire(m.quote), sig: m.signature, mid: BigInt(m.mid), dev: m.deviationBps });
      if (quotes.length >= 2) (clearTimeout(timer), ws.close(), resolve());
    } else if (m.type === "error") {
      console.log("relay error:", m.code, m.message);
    }
  });
});

if (!quotes.length) throw new Error("no quotes received");
for (const x of quotes) {
  console.log(`quote side=${x.q.side === 0 ? "ASK" : "BID"} price=${x.q.price} size=${x.q.size} vsMid=${x.dev}bps`);
}
const ask = quotes.find((x) => x.q.side === 0);
if (!ask) throw new Error("no ask received");

// verify off-chain exactly as the app does
const ok = await verifyTypedData({
  address: ask.q.maker,
  domain: quoteDomain(chainId, dep.Settlement),
  types: quoteTypes,
  primaryType: "Quote",
  message: ask.q,
  signature: ask.sig,
});
if (!ok) throw new Error("EIP-712 signature did not verify off-chain");

const before = await client.readContract({ address: aapl.address, abi: erc20Abi, functionName: "balanceOf", args: [signer.address] });
// simulate first so any revert surfaces with a decoded reason
await client.simulateContract({
  account: signer.address,
  address: dep.Settlement,
  abi: settlementAbi,
  functionName: "fill",
  args: [ask.q, ask.sig, ask.q.size],
});
const hash = await signer.wallet.writeContract({
  account: signer.account,
  chain: chainFor(chainId),
  address: dep.Settlement,
  abi: settlementAbi,
  functionName: "fill",
  args: [ask.q, ask.sig, ask.q.size],
});
const receipt = await client.waitForTransactionReceipt({ hash });
if (receipt.status !== "success") throw new Error(`fill reverted (tx ${hash}, gasUsed ${receipt.gasUsed})`);
let filled = false;
for (const l of receipt.logs) {
  try {
    const ev = decodeEventLog({ abi: settlementAbi, data: l.data, topics: l.topics });
    if (ev.eventName === "QuoteFilled") {
      filled = true;
      console.log(`FILLED base=${ev.args.baseAmount} quote=${ev.args.quoteAmount} fee=${ev.args.fee} mid=${ev.args.mid}`);
    }
  } catch {
    /* non-settlement log */
  }
}
const after = await client.readContract({ address: aapl.address, abi: erc20Abi, functionName: "balanceOf", args: [signer.address] });
if (!filled || after - before !== ask.q.size) throw new Error("fill not reflected in balances");
console.log(`OK: taker received ${after - before} ${aapl.symbol} units, gas used ${receipt.gasUsed}`);
process.exit(0);
