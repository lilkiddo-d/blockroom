import { describe, expect, it, beforeEach } from "vitest";
import { getAddress, type Address, type Hex } from "viem";
import { MakerSide, toWire, type Quote, type ServerMsg } from "@blockroom/config";
import { RelayCore, type RelayDeps } from "./core.js";

const BASE = getAddress("0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9");
const USDG = getAddress("0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168");
const MAKER = getAddress("0x00000000000000000000000000000000000000aa");
const OTHER = getAddress("0x00000000000000000000000000000000000000bb");
const RFQ = ("0x" + "11".repeat(32)) as Hex;
const MID = 340_000_000n;
const GOOD_SIG = "0x01" as Hex;

let now = 1_000_000;
function deps(over: Partial<RelayDeps> = {}): RelayDeps {
  return {
    chainId: 4663,
    settlement: getAddress("0x0000000000000000000000000000000000000001"),
    relayId: "test",
    rfqTtlMs: 15_000,
    maxQuoteTtlSec: 300,
    requireRegistered: true,
    now: () => now,
    isSupportedPair: (b, q) => b === BASE && q === USDG,
    verifyMessage: async ({ signature }) => signature === GOOD_SIG,
    verifyTypedData: async ({ signature }) => signature === GOOD_SIG,
    canQuote: async (m: Address) => m === MAKER,
    getMid: async () => ({ mid: MID, bandBps: 100 }),
    ...over,
  };
}

function client(core: RelayCore) {
  const inbox: ServerMsg[] = [];
  const conn = core.connect((m) => inbox.push(m));
  return { conn, inbox, send: (m: unknown) => core.handle(conn, JSON.stringify(m)) };
}

function quote(over: Partial<Quote> = {}): Quote {
  return {
    rfqId: RFQ,
    maker: MAKER,
    taker: "0x0000000000000000000000000000000000000000",
    baseToken: BASE,
    quoteToken: USDG,
    side: MakerSide.MakerSells,
    tif: 0,
    price: 340_500_000n,
    size: 10n * 10n ** 18n,
    minFill: 0n,
    nonce: 1n,
    expiry: BigInt(Math.floor(now / 1000) + 60),
    ...over,
  };
}

async function authedMaker(core: RelayCore, address = MAKER) {
  const m = client(core);
  await m.send({ type: "hello", role: "maker", address });
  await m.send({ type: "auth", address, signature: GOOD_SIG });
  return m;
}

describe("RelayCore", () => {
  let core: RelayCore;
  beforeEach(() => {
    now = 1_000_000;
    core = new RelayCore(deps());
  });

  it("authenticates registered makers with a signed challenge", async () => {
    const m = client(core);
    await m.send({ type: "hello", role: "maker", address: MAKER });
    expect(m.inbox[0].type).toBe("challenge");
    await m.send({ type: "auth", address: MAKER, signature: GOOD_SIG });
    expect(m.inbox.at(-1)).toMatchObject({ type: "ready", role: "maker" });
    expect(core.makerCount()).toBe(1);
  });

  it("rejects bad signatures and unregistered makers", async () => {
    const m = client(core);
    await m.send({ type: "hello", role: "maker", address: MAKER });
    await m.send({ type: "auth", address: MAKER, signature: "0x02" });
    expect(m.inbox.at(-1)).toMatchObject({ type: "error", code: "auth_failed" });
    const o = client(core);
    await o.send({ type: "hello", role: "maker", address: OTHER });
    await o.send({ type: "auth", address: OTHER, signature: GOOD_SIG });
    expect(o.inbox.at(-1)).toMatchObject({ type: "error", code: "not_registered" });
    expect(core.makerCount()).toBe(0);
  });

  it("fans an RFQ out to every maker and streams valid quotes back to the taker only", async () => {
    const m1 = await authedMaker(core);
    const t = client(core);
    const spectator = client(core);
    await spectator.send({ type: "hello", role: "taker" });
    await t.send({ type: "hello", role: "taker" });
    await t.send({ type: "rfq", rfq: { rfqId: RFQ, baseToken: BASE, quoteToken: USDG, side: "buy", size: "10000000000000000000" } });
    expect(t.inbox.at(-1)).toMatchObject({ type: "rfq_ack", makersNotified: 1 });
    expect(m1.inbox.at(-1)).toMatchObject({ type: "rfq" });

    await m1.send({ type: "quote", quote: toWire(quote()), signature: GOOD_SIG });
    const fwd = t.inbox.at(-1) as Extract<ServerMsg, { type: "quote" }>;
    expect(fwd.type).toBe("quote");
    expect(fwd.mid).toBe(MID.toString());
    expect(fwd.deviationBps).toBe(14);
    expect(spectator.inbox.some((x) => x.type === "quote")).toBe(false);
  });

  it("rejects quotes that don't answer the RFQ, are unsigned, stale, or outside the guard", async () => {
    const m = await authedMaker(core);
    const t = client(core);
    await t.send({ type: "hello", role: "taker" });
    await t.send({ type: "rfq", rfq: { rfqId: RFQ, baseToken: BASE, quoteToken: USDG, side: "buy", size: "10000000000000000000" } });
    const cases: [Partial<Quote>, string, Hex?][] = [
      [{ side: MakerSide.MakerBuys }, "wrong_side"],
      [{ size: 11n * 10n ** 18n }, "bad_size"],
      [{ maker: OTHER }, "wrong_maker"],
      [{ expiry: BigInt(Math.floor(now / 1000) + 3600) }, "bad_expiry"],
      [{ expiry: BigInt(Math.floor(now / 1000) - 1) }, "bad_expiry"],
      [{ price: 350_000_000n }, "outside_guard"],
      [{ baseToken: USDG }, "wrong_pair"],
      [{}, "bad_signature", "0x02"],
    ];
    for (const [over, code, sig] of cases) {
      await m.send({ type: "quote", quote: toWire(quote(over)), signature: sig ?? GOOD_SIG });
      expect(m.inbox.at(-1)).toMatchObject({ type: "error", code });
    }
    expect(t.inbox.filter((x) => x.type === "quote")).toHaveLength(0);
  });

  it("two-way RFQs accept both sides so the taker's direction stays private", async () => {
    const m = await authedMaker(core);
    const t = client(core);
    await t.send({ type: "hello", role: "taker" });
    await t.send({ type: "rfq", rfq: { rfqId: RFQ, baseToken: BASE, quoteToken: USDG, side: "two-way", size: "10000000000000000000" } });
    await m.send({ type: "quote", quote: toWire(quote({ side: 0 })), signature: GOOD_SIG });
    await m.send({ type: "quote", quote: toWire(quote({ side: 1, price: 339_500_000n, nonce: 2n })), signature: GOOD_SIG });
    expect(t.inbox.filter((x) => x.type === "quote")).toHaveLength(2);
  });

  it("enforces the designated taker", async () => {
    const m = await authedMaker(core);
    const t = client(core);
    await t.send({ type: "hello", role: "taker" });
    await t.send({ type: "rfq", rfq: { rfqId: RFQ, baseToken: BASE, quoteToken: USDG, side: "buy", size: "1", taker: OTHER } });
    await m.send({ type: "quote", quote: toWire(quote({ size: 1n })), signature: GOOD_SIG });
    expect(m.inbox.at(-1)).toMatchObject({ code: "wrong_taker" });
  });

  it("validates RFQs and closes them on cancel/disconnect", async () => {
    const t = client(core);
    await t.send({ type: "rfq", rfq: { rfqId: RFQ } });
    expect(t.inbox.at(-1)).toMatchObject({ code: "not_taker" });
    await t.send({ type: "hello", role: "taker" });
    await t.send({ type: "rfq", rfq: { rfqId: "0x12", baseToken: BASE, quoteToken: USDG, side: "buy", size: "1" } });
    expect(t.inbox.at(-1)).toMatchObject({ code: "bad_rfq" });
    await t.send({ type: "rfq", rfq: { rfqId: RFQ, baseToken: USDG, quoteToken: USDG, side: "buy", size: "1" } });
    expect(t.inbox.at(-1)).toMatchObject({ code: "bad_pair" });
    await t.send({ type: "rfq", rfq: { rfqId: RFQ, baseToken: BASE, quoteToken: USDG, side: "buy", size: "0" } });
    expect(t.inbox.at(-1)).toMatchObject({ code: "bad_size" });
    await t.send({ type: "rfq", rfq: { rfqId: RFQ, baseToken: BASE, quoteToken: USDG, side: "buy", size: "5" } });
    expect(core.openRfqCount()).toBe(1);
    await t.send({ type: "rfq", rfq: { rfqId: RFQ, baseToken: BASE, quoteToken: USDG, side: "buy", size: "5" } });
    expect(t.inbox.at(-1)).toMatchObject({ code: "dup_rfq" });
    await t.send({ type: "cancel", rfqId: RFQ });
    expect(t.inbox.at(-1)).toMatchObject({ type: "rfq_closed", reason: "cancelled" });
    expect(core.openRfqCount()).toBe(0);
  });

  it("rate limits floods", async () => {
    const t = client(core);
    for (let i = 0; i < 60; i++) await t.send({ type: "ping" });
    expect(t.inbox.some((x) => x.type === "error" && x.code === "rate_limited")).toBe(true);
  });
});
