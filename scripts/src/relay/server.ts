/**
 * Blockroom RFQ relay - WebSocket service.
 *   pnpm relay                         (reads .env; CHAIN_ID + RPC_URL select the deployment)
 *   GET /health -> {"ok":true,...}     (for Railway / Fly.io health checks)
 */
import { createServer } from "node:http";
import { WebSocketServer, type WebSocket } from "ws";
import { getAddress, type Address } from "viem";
import { STOCKS, quoteDomain, quoteTypes, type ServerMsg } from "@blockroom/config";
import { makerRegistryAbi, priceGuardAbi, settlementAbi } from "@blockroom/config/abis";
import { env, envNum, loadDeployment, loadDotEnv, log, makePublicClient } from "../lib/env.js";
import { RelayCore } from "./core.js";

loadDotEnv();
const chainId = Number(env("CHAIN_ID", "4663"));
const rpcUrl = env("RPC_URL", env("ROBINHOOD_RPC_URL", "https://rpc.mainnet.chain.robinhood.com"));
const port = envNum("PORT", envNum("RELAY_PORT", 8787));
const dep = loadDeployment(chainId);
const client = makePublicClient(chainId, rpcUrl);

const maxQuoteTtlSec = Number(
  await client.readContract({ address: dep.Settlement, abi: settlementAbi, functionName: "maxQuoteTtl" }),
);
const supportedBases = new Set(STOCKS.map((s) => s.address.toLowerCase()));
const midCache = new Map<string, { at: number; mid: bigint; bandBps: number }>();

const core = new RelayCore({
  chainId,
  settlement: dep.Settlement,
  relayId: process.env.RELAY_ID ?? `blockroom-${chainId}`,
  rfqTtlMs: envNum("RELAY_RFQ_TTL_MS", 15_000),
  maxQuoteTtlSec,
  requireRegistered: (process.env.RELAY_REQUIRE_REGISTERED_MAKERS ?? "true") !== "false",
  now: () => Date.now(),
  isSupportedPair: (b, q) =>
    supportedBases.has(b.toLowerCase()) && getAddress(q) === getAddress(dep.USDG),
  verifyMessage: ({ address, message, signature }) => client.verifyMessage({ address, message, signature }),
  verifyTypedData: ({ address, quote, signature }) =>
    client.verifyTypedData({
      address,
      domain: quoteDomain(chainId, dep.Settlement),
      types: quoteTypes,
      primaryType: "Quote",
      message: quote,
      signature,
    }),
  canQuote: (maker: Address) =>
    client.readContract({ address: dep.MakerRegistry, abi: makerRegistryAbi, functionName: "canQuote", args: [maker] }),
  getMid: async (base, quote) => {
    const key = `${base}-${quote}`;
    const hit = midCache.get(key);
    if (hit && Date.now() - hit.at < 2_000) return hit;
    const [mid, band] = await Promise.all([
      client.readContract({ address: dep.PriceGuard, abi: priceGuardAbi, functionName: "getMid", args: [base, quote] }),
      client.readContract({ address: dep.PriceGuard, abi: priceGuardAbi, functionName: "bandBps", args: [base] }),
    ]);
    const v = { at: Date.now(), mid, bandBps: Number(band) };
    midCache.set(key, v);
    return v;
  },
});

const http = createServer((req, res) => {
  if (req.url === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true, chainId, makers: core.makerCount(), openRfqs: core.openRfqCount() }));
    return;
  }
  res.writeHead(404).end();
});

const wss = new WebSocketServer({ server: http, maxPayload: 16 * 1024 });
wss.on("connection", (ws: WebSocket, req) => {
  const send = (m: ServerMsg) => ws.readyState === ws.OPEN && ws.send(JSON.stringify(m));
  const conn = core.connect(send);
  log("relay", "connect", { id: conn.id, ip: req.socket.remoteAddress });
  let alive = true;
  ws.on("pong", () => (alive = true));
  const hb = setInterval(() => {
    if (!alive) return ws.terminate();
    alive = false;
    ws.ping();
  }, 30_000);
  ws.on("message", (data) => void core.handle(conn, data.toString()));
  ws.on("close", () => {
    clearInterval(hb);
    core.disconnect(conn);
    log("relay", "disconnect", { id: conn.id, role: conn.role, address: conn.address });
  });
});

http.listen(port, () => log("relay", "listening", { port, chainId, settlement: dep.Settlement }));
