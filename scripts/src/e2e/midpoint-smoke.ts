/**
 * End-to-end midpoint smoke test (LOCAL FORK ONLY - uses anvil time travel):
 * two traders commit opposite hidden orders, hand their reveals to the keeper, and the keeper reveals + settles.
 *
 *   CHAIN_ID=31337 RPC_URL=http://127.0.0.1:29463 KEEPER_URL=http://127.0.0.1:8788 \
 *   BUYER=<anvil #0> SELLER=<anvil #1> pnpm --filter @blockroom/scripts smoke:midpoint
 */
import { createWalletClient, encodeAbiParameters, http, keccak256, parseUnits, type Address, type Hex } from "viem";
import { orderRevealAbi, stockBySymbol, type OrderReveal } from "@blockroom/config";
import { marketClockAbi, midpointPoolAbi } from "@blockroom/config/abis";
import { chainFor, env, loadDeployment, makePublicClient } from "../lib/env.js";

const chainId = Number(env("CHAIN_ID", "31337"));
if (chainId !== 31337) throw new Error("midpoint smoke uses anvil time travel - local fork only");
const rpcUrl = env("RPC_URL");
const keeperUrl = env("KEEPER_URL", "http://127.0.0.1:8788");
const buyer = env("BUYER") as Address;
const seller = env("SELLER") as Address;
const dep = loadDeployment(chainId);
const chain = chainFor(chainId);
const client = makePublicClient(chainId, rpcUrl);
const wallet = createWalletClient({ chain, transport: http(rpcUrl) });
const stock = stockBySymbol("TSLA")!;
const rpc = (method: string, params: unknown[]) =>
  client.request({ method: method as never, params: params as never });

async function send(from: Address, functionName: string, args: readonly unknown[]) {
  const hash = await wallet.writeContract({ account: from, chain, address: dep.MidpointPool, abi: midpointPoolAbi, functionName: functionName as never, args: args as never });
  const r = await client.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`${functionName} reverted`);
}
async function now() {
  return Number((await client.getBlock()).timestamp);
}
async function warpTo(ts: number) {
  const t = await now();
  if (ts > t) await rpc("evm_increaseTime", [ts - t]);
  await rpc("evm_mine", []);
}

// 1. move into the US regular session if needed
for (let i = 0; i < 400; i++) {
  if (await client.readContract({ address: dep.MarketClock, abi: marketClockAbi, functionName: "isOpen" })) break;
  await warpTo((await now()) + 15 * 60);
}
console.log("market open at", new Date((await now()) * 1000).toISOString());

// 2. fund pool ledgers (approvals were set by scripts/fork.sh)
await send(buyer, "deposit", [dep.USDG, parseUnits("200000", 6)]);
await send(seller, "deposit", [dep.USDG, parseUnits("100", 6)]); // commit bond
await send(seller, "deposit", [stock.address, parseUnits("100", 18)]);

// 3. commit opposite hidden orders
const batchId = await client.readContract({ address: dep.MidpointPool, abi: midpointPoolAbi, functionName: "currentBatchId" });
const salt = (s: string) => keccak256(new TextEncoder().encode(s + Date.now())) as Hex;
const orders: OrderReveal[] = [
  { trader: buyer, asset: stock.address, batchId, side: 0, tif: 0, size: parseUnits("40", 18), minFill: 0n, limitPrice: parseUnits("5000", 6), salt: salt("b") },
  { trader: seller, asset: stock.address, batchId, side: 1, tif: 0, size: parseUnits("25", 18), minFill: 0n, limitPrice: 0n, salt: salt("s") },
];
const slots: bigint[] = [];
for (const o of orders) {
  const commitment = keccak256(encodeAbiParameters(orderRevealAbi, [o]));
  await send(o.trader, "commit", [o.asset, commitment]);
  const [, , , index] = await client.readContract({ address: dep.MidpointPool, abi: midpointPoolAbi, functionName: "commitInfo", args: [commitment] });
  slots.push(BigInt(index));
}
console.log(`committed 2 orders to batch #${batchId}`);

// 4. delegate reveals to the keeper (only now, after committing)
for (const o of orders) {
  const res = await fetch(`${keeperUrl}/reveal`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(o, (_k, v) => (typeof v === "bigint" ? v.toString() : v)),
  });
  if (res.status !== 202) throw new Error(`keeper rejected reveal: ${await res.text()}`);
}
console.log("reveals delegated to keeper");

// 5. advance time; the keeper reveals during the reveal window and settles after it
const info = await client.readContract({ address: dep.MidpointPool, abi: midpointPoolAbi, functionName: "batchInfo", args: [stock.address, batchId] });
await warpTo(Number(info.commitEnd) + 1);
const waitFor = async (pred: () => Promise<boolean>, label: string) => {
  for (let i = 0; i < 60; i++) {
    if (await pred()) return;
    await new Promise((r) => setTimeout(r, 2000));
    await rpc("evm_mine", []);
  }
  throw new Error(`timeout waiting for ${label}`);
};
await waitFor(async () => {
  for (const idx of slots) {
    const o = await client.readContract({ address: dep.MidpointPool, abi: midpointPoolAbi, functionName: "orderAt", args: [stock.address, batchId, idx] });
    if (o.status !== 2) return false;
  }
  return true;
}, "keeper reveal");
console.log("keeper revealed both orders");
await warpTo(Number(info.revealEnd) + 1);
await waitFor(async () => (await client.readContract({ address: dep.MidpointPool, abi: midpointPoolAbi, functionName: "batchInfo", args: [stock.address, batchId] })).settled, "keeper settle");
const b = await client.readContract({ address: dep.MidpointPool, abi: midpointPoolAbi, functionName: "batchInfo", args: [stock.address, batchId] });
const buyerOrder = await client.readContract({ address: dep.MidpointPool, abi: midpointPoolAbi, functionName: "orderAt", args: [stock.address, batchId, slots[0]] });
const got = buyerOrder.filled;
console.log(`SETTLED voided=${b.voided} mid=${b.mid} matched=${b.matchedBase} buyerReceived=${got}`);
if (b.voided || b.matchedBase !== parseUnits("25", 18) || got !== parseUnits("25", 18)) throw new Error("unexpected batch outcome");
console.log("OK: 25 TSLA crossed at the oracle mid via keeper reveal + settle");
process.exit(0);
