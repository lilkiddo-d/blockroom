/**
 * Batch keeper for MidpointPool.
 *  1. Indexes `Committed` events, tracks open batches per asset.
 *  2. Optional delegated reveals: traders may POST their order preimage to /reveal; the keeper reveals it at the
 *     start of the reveal window (revealMany). Preimages are held in memory only, never logged.
 *  3. Settles every batch once its reveal window closes (settlement is permissionless; late batches void and
 *     release locks, so the keeper also settles stragglers).
 *  4. Seeds exchange holidays from config/market-holidays.json (requires CALENDAR_ROLE).
 *
 *   SIGNER=keystore KEYSTORE_ACCOUNT=blockroom-keeper pnpm keeper
 */
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { encodeAbiParameters, keccak256, type Address, type Hex } from "viem";
import { orderRevealAbi, type OrderReveal } from "@blockroom/config";
import { marketClockAbi, midpointPoolAbi } from "@blockroom/config/abis";
import { chainFor, env, envNum, loadDeployment, loadDotEnv, log, makePublicClient, repoRoot } from "../lib/env.js";
import { loadSigner } from "../lib/signer.js";
import { BatchBook, revealFromWire, type WireReveal } from "./book.js";

loadDotEnv();
const chainId = Number(env("CHAIN_ID", "4663"));
const rpcUrl = env("RPC_URL", env("ROBINHOOD_RPC_URL", "https://rpc.mainnet.chain.robinhood.com"));
const pollMs = envNum("KEEPER_POLL_MS", 10_000);
const revealPort = envNum("KEEPER_REVEAL_PORT", 8788);
const LOG_CHUNK = 5_000n;
const dep = loadDeployment(chainId);
const client = makePublicClient(chainId, rpcUrl);
const signer = await loadSigner(chainFor(chainId), rpcUrl);
const chain = chainFor(chainId);
const book = new BatchBook();
let fromBlock = BigInt(dep.deployedAtBlock);

async function write(functionName: "settle" | "revealMany", args: readonly unknown[]) {
  const hash = await signer.wallet.writeContract({
    account: signer.account,
    chain,
    address: dep.MidpointPool,
    abi: midpointPoolAbi,
    functionName,
    args: args as never,
  });
  const r = await client.waitForTransactionReceipt({ hash });
  return r.status;
}

async function indexCommits() {
  const head = await client.getBlockNumber();
  while (fromBlock <= head) {
    const to = fromBlock + LOG_CHUNK - 1n > head ? head : fromBlock + LOG_CHUNK - 1n;
    const logs = await client.getContractEvents({
      address: dep.MidpointPool,
      abi: midpointPoolAbi,
      eventName: "Committed",
      fromBlock,
      toBlock: to,
    });
    for (const l of logs) {
      const { asset, batchId, commitment } = l.args as { asset: Address; batchId: bigint; commitment: Hex };
      book.addCommit(asset, batchId, commitment);
    }
    fromBlock = to + 1n;
  }
}

async function tick() {
  await indexCommits();
  // Batch windows are defined in chain time (block.timestamp), so judge them by the latest block, not the wall clock.
  const now = (await client.getBlock()).timestamp;
  for (const b of book.open()) {
    const info = await client.readContract({
      address: dep.MidpointPool,
      abi: midpointPoolAbi,
      functionName: "batchInfo",
      args: [b.asset, b.batchId],
    });
    if (info.settled) {
      book.markSettled(b.asset, b.batchId);
      continue;
    }
    // delegated reveals at the start of the reveal window
    if (now >= info.commitEnd && now < info.revealEnd) {
      const pending = book.takeReveals(b.asset, b.batchId);
      if (pending.length) {
        const status = await write("revealMany", [pending]).catch((e) => (log("keeper", "revealMany failed", { e: String(e) }), "failed"));
        log("keeper", "revealMany", { asset: b.asset, batchId: b.batchId, n: pending.length, status });
      }
    }
    if (now >= info.revealEnd) {
      const status = await write("settle", [b.asset, b.batchId]).catch((e) => (log("keeper", "settle failed", { e: String(e) }), "failed"));
      log("keeper", "settle", { asset: b.asset, batchId: b.batchId, status });
      if (status === "success") book.markSettled(b.asset, b.batchId);
    }
  }
}

type Holiday = { date: string; etDay: number; closeMinute: number; name: string };
async function seedHolidays() {
  const file = join(repoRoot, "config", "market-holidays.json");
  const { holidays } = JSON.parse(readFileSync(file, "utf8")) as { holidays: Holiday[] };
  const role = await client.readContract({ address: dep.MarketClock, abi: marketClockAbi, functionName: "CALENDAR_ROLE" });
  const hasRole = await client.readContract({
    address: dep.MarketClock,
    abi: marketClockAbi,
    functionName: "hasRole",
    args: [role, signer.address],
  });
  if (!hasRole) return log("keeper", "no CALENDAR_ROLE - skipping holiday sync");
  const missing: Holiday[] = [];
  for (const h of holidays) {
    const cur = await client.readContract({
      address: dep.MarketClock,
      abi: marketClockAbi,
      functionName: "sessionOverride",
      args: [BigInt(h.etDay)],
    });
    if (Number(cur) !== h.closeMinute) missing.push(h);
  }
  if (!missing.length) return log("keeper", "holiday calendar in sync", { n: holidays.length });
  const hash = await signer.wallet.writeContract({
    account: signer.account,
    chain,
    address: dep.MarketClock,
    abi: marketClockAbi,
    functionName: "setSessionOverrides",
    args: [missing.map((h) => BigInt(h.etDay)), missing.map((h) => h.closeMinute)],
  });
  await client.waitForTransactionReceipt({ hash });
  log("keeper", "holidays pushed", { n: missing.length });
}

// ---- delegated reveal endpoint
createServer((req, res) => {
  const cors = { "access-control-allow-origin": "*", "access-control-allow-headers": "content-type" };
  if (req.method === "OPTIONS") return res.writeHead(204, cors).end();
  if (req.url === "/health") {
    res.writeHead(200, { "content-type": "application/json", ...cors });
    return res.end(JSON.stringify({ ok: true, openBatches: book.open().length }));
  }
  if (req.method !== "POST" || req.url !== "/reveal") return res.writeHead(404, cors).end();
  let body = "";
  req.on("data", (c) => {
    body += c;
    if (body.length > 8_192) req.destroy();
  });
  req.on("end", async () => {
    try {
      const r: OrderReveal = revealFromWire(JSON.parse(body) as WireReveal);
      const commitment = keccak256(encodeAbiParameters(orderRevealAbi, [r]));
      const [trader] = await client.readContract({
        address: dep.MidpointPool,
        abi: midpointPoolAbi,
        functionName: "commitInfo",
        args: [commitment],
      });
      if (trader.toLowerCase() !== r.trader.toLowerCase()) throw new Error("unknown commitment");
      book.addReveal(r.asset, r.batchId, r);
      res.writeHead(202, { "content-type": "application/json", ...cors });
      res.end(JSON.stringify({ accepted: true, commitment }));
    } catch (e) {
      res.writeHead(400, { "content-type": "application/json", ...cors });
      res.end(JSON.stringify({ accepted: false, error: (e as Error).message }));
    }
  });
}).listen(revealPort, () => log("keeper", "reveal endpoint listening", { port: revealPort }));

log("keeper", "starting", { keeper: signer.address, chainId, pool: dep.MidpointPool });
await seedHolidays().catch((e) => log("keeper", "holiday sync failed", { e: String(e) }));
for (;;) {
  await tick().catch((e) => log("keeper", "tick failed", { e: String(e) }));
  await new Promise((r) => setTimeout(r, pollMs));
}
