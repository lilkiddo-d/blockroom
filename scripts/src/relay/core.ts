/**
 * RFQ relay core: transport-agnostic, deterministic, unit-tested (relay.test.ts).
 *
 * Trust model - the relay is a convenience, not a trusted party:
 *  - It cannot forge quotes: every quote is EIP-712 signed by the maker and verified here AND on-chain.
 *  - It cannot settle or move funds: takers call Settlement.fill directly from their wallet.
 *  - Censorship resistance: RFQs are fanned out to ALL authenticated makers (no selective routing), every
 *    accepted quote is forwarded unmodified, anyone can run a relay (the app accepts several relay URLs), and
 *    takers can verify the maker set on-chain (MakerRegistry) against who responded.
 *  - Information leakage: makers only learn the side if the taker chooses; "two-way" RFQs request both a bid
 *    and an offer. Quotes are only forwarded to the requesting taker connection.
 */
import { randomBytes } from "node:crypto";
import { getAddress, isAddress, isHex, type Address, type Hex } from "viem";
import {
  fromWire,
  makerAuthMessage,
  MakerSide,
  quoteDomain,
  quoteTypes,
  type ClientMsg,
  type Quote,
  type RfqRequest,
  type ServerMsg,
} from "@blockroom/config";

export type Conn = {
  id: string;
  send: (m: ServerMsg) => void;
  role?: "taker" | "maker";
  address?: Address;
  challenge?: string;
  authed: boolean;
  /** token bucket for rate limiting */
  tokens: number;
  lastRefill: number;
};

export type RelayDeps = {
  chainId: number;
  settlement: Address;
  /** EIP-712 / EIP-191 verification (ERC-1271 aware when backed by a public client) */
  verifyTypedData: (args: { address: Address; quote: Quote; signature: Hex }) => Promise<boolean>;
  verifyMessage: (args: { address: Address; message: string; signature: Hex }) => Promise<boolean>;
  /** MakerRegistry.canQuote */
  canQuote: (maker: Address) => Promise<boolean>;
  /** PriceGuard.getMid + bandBps (quote units per whole base token) */
  getMid: (base: Address, quote: Address) => Promise<{ mid: bigint; bandBps: number }>;
  isSupportedPair: (base: Address, quote: Address) => boolean;
  now: () => number;
  rfqTtlMs: number;
  maxQuoteTtlSec: number;
  requireRegistered: boolean;
  relayId: string;
};

type OpenRfq = { rfq: RfqRequest; takerConn: string; timer?: ReturnType<typeof setTimeout>; quotes: number };

const RATE_CAPACITY = 40;
const RATE_PER_SEC = 10;
const MAX_QUOTES_PER_RFQ = 200;

export class RelayCore {
  private conns = new Map<string, Conn>();
  private rfqs = new Map<Hex, OpenRfq>();
  constructor(private deps: RelayDeps) {}

  // ------------------------------------------------------------ connections

  connect(send: (m: ServerMsg) => void): Conn {
    const c: Conn = {
      id: randomBytes(8).toString("hex"),
      send,
      authed: false,
      tokens: RATE_CAPACITY,
      lastRefill: this.deps.now(),
    };
    this.conns.set(c.id, c);
    return c;
  }

  disconnect(c: Conn) {
    this.conns.delete(c.id);
    for (const [id, o] of this.rfqs) if (o.takerConn === c.id) this.closeRfq(id, "cancelled");
  }

  makerCount(): number {
    let n = 0;
    for (const c of this.conns.values()) if (c.role === "maker" && c.authed) n++;
    return n;
  }

  openRfqCount(): number {
    return this.rfqs.size;
  }

  // ---------------------------------------------------------------- inbound

  async handle(c: Conn, raw: string): Promise<void> {
    if (!this.take(c)) return c.send({ type: "error", code: "rate_limited", message: "slow down" });
    let msg: ClientMsg;
    try {
      msg = JSON.parse(raw) as ClientMsg;
    } catch {
      return c.send({ type: "error", code: "bad_json", message: "invalid JSON" });
    }
    try {
      switch (msg.type) {
        case "ping":
          return c.send({ type: "pong", t: this.deps.now() });
        case "hello":
          return this.onHello(c, msg.role, msg.address);
        case "auth":
          return await this.onAuth(c, msg.address, msg.signature);
        case "rfq":
          return this.onRfq(c, msg.rfq);
        case "cancel":
          return this.onCancel(c, msg.rfqId);
        case "quote":
          return await this.onQuote(c, msg);
        default:
          return c.send({ type: "error", code: "unknown_type", message: "unknown message type" });
      }
    } catch (e) {
      c.send({ type: "error", code: "internal", message: (e as Error).message.slice(0, 200) });
    }
  }

  private onHello(c: Conn, role: "taker" | "maker", address?: Address) {
    if (role !== "taker" && role !== "maker") return c.send({ type: "error", code: "bad_role", message: "role" });
    c.role = role;
    if (role === "taker") {
      c.authed = true;
      if (address && isAddress(address)) c.address = getAddress(address);
      return c.send({ type: "ready", role, address: c.address, makers: this.makerCount() });
    }
    if (!address || !isAddress(address)) return c.send({ type: "error", code: "bad_address", message: "address" });
    c.address = getAddress(address);
    c.challenge = makerAuthMessage(c.address, randomBytes(16).toString("hex"), this.deps.relayId);
    c.send({ type: "challenge", message: c.challenge });
  }

  private async onAuth(c: Conn, address: Address, signature: Hex) {
    if (c.role !== "maker" || !c.challenge || !c.address || getAddress(address) !== c.address) {
      return c.send({ type: "error", code: "auth_state", message: "send hello first" });
    }
    const ok = await this.deps.verifyMessage({ address: c.address, message: c.challenge, signature });
    if (!ok) return c.send({ type: "error", code: "auth_failed", message: "bad signature" });
    if (this.deps.requireRegistered && !(await this.deps.canQuote(c.address))) {
      return c.send({ type: "error", code: "not_registered", message: "maker not bonded in MakerRegistry" });
    }
    c.authed = true;
    c.challenge = undefined;
    c.send({ type: "ready", role: "maker", address: c.address, makers: this.makerCount() });
  }

  private onRfq(c: Conn, r: Omit<RfqRequest, "deadline">) {
    if (c.role !== "taker") return c.send({ type: "error", code: "not_taker", message: "hello as taker first" });
    if (!isHex(r.rfqId, { strict: true }) || r.rfqId.length !== 66) {
      return c.send({ type: "error", code: "bad_rfq", message: "rfqId must be bytes32" });
    }
    if (this.rfqs.has(r.rfqId)) return c.send({ type: "error", code: "dup_rfq", message: "duplicate rfqId" });
    if (!isAddress(r.baseToken) || !isAddress(r.quoteToken) || !this.deps.isSupportedPair(r.baseToken, r.quoteToken)) {
      return c.send({ type: "error", code: "bad_pair", message: "unsupported pair", rfqId: r.rfqId });
    }
    if (!["buy", "sell", "two-way"].includes(r.side)) {
      return c.send({ type: "error", code: "bad_side", message: "side", rfqId: r.rfqId });
    }
    let size: bigint;
    try {
      size = BigInt(r.size);
    } catch {
      return c.send({ type: "error", code: "bad_size", message: "size", rfqId: r.rfqId });
    }
    if (size <= 0n) return c.send({ type: "error", code: "bad_size", message: "size", rfqId: r.rfqId });
    if (r.taker !== undefined && !isAddress(r.taker)) {
      return c.send({ type: "error", code: "bad_taker", message: "taker", rfqId: r.rfqId });
    }

    const rfq: RfqRequest = {
      rfqId: r.rfqId,
      baseToken: getAddress(r.baseToken),
      quoteToken: getAddress(r.quoteToken),
      side: r.side,
      size: size.toString(),
      taker: r.taker ? getAddress(r.taker) : undefined,
      deadline: this.deps.now() + this.deps.rfqTtlMs,
    };
    const open: OpenRfq = { rfq, takerConn: c.id, quotes: 0 };
    open.timer = setTimeout(() => this.closeRfq(rfq.rfqId, "deadline"), this.deps.rfqTtlMs);
    (open.timer as { unref?: () => void }).unref?.();
    this.rfqs.set(rfq.rfqId, open);

    let notified = 0;
    for (const m of this.conns.values()) {
      if (m.role === "maker" && m.authed && m.id !== c.id) {
        m.send({ type: "rfq", rfq });
        notified++;
      }
    }
    c.send({ type: "rfq_ack", rfqId: rfq.rfqId, deadline: rfq.deadline, makersNotified: notified });
  }

  private onCancel(c: Conn, rfqId: Hex) {
    const o = this.rfqs.get(rfqId);
    if (!o || o.takerConn !== c.id) return c.send({ type: "error", code: "unknown_rfq", message: "rfq", rfqId });
    this.closeRfq(rfqId, "cancelled");
  }

  private async onQuote(c: Conn, msg: Extract<ClientMsg, { type: "quote" }>) {
    if (c.role !== "maker" || !c.authed || !c.address) {
      return c.send({ type: "error", code: "not_maker", message: "authenticate as maker first" });
    }
    let q: Quote;
    try {
      q = fromWire(msg.quote);
    } catch {
      return c.send({ type: "error", code: "bad_quote", message: "malformed quote" });
    }
    const o = this.rfqs.get(q.rfqId);
    const reject = (code: string, message: string) => c.send({ type: "error", code, message, rfqId: q.rfqId });
    if (!o) return reject("rfq_closed", "rfq not open");
    if (o.quotes >= MAX_QUOTES_PER_RFQ) return reject("too_many_quotes", "quote cap reached");
    const r = o.rfq;

    // Quote must answer the RFQ exactly as asked.
    if (getAddress(q.maker) !== c.address) return reject("wrong_maker", "quote.maker must be your address");
    if (getAddress(q.baseToken) !== r.baseToken || getAddress(q.quoteToken) !== r.quoteToken) {
      return reject("wrong_pair", "pair mismatch");
    }
    const wantSide =
      r.side === "buy" ? [MakerSide.MakerSells] : r.side === "sell" ? [MakerSide.MakerBuys] : [0, 1];
    if (!wantSide.includes(q.side)) return reject("wrong_side", "side mismatch");
    if (q.size <= 0n || q.size > BigInt(r.size)) return reject("bad_size", "size must be in (0, rfq.size]");
    if (q.minFill > q.size || q.tif > 2) return reject("bad_quote", "minFill/tif");
    const nowSec = BigInt(Math.floor(this.deps.now() / 1000));
    if (q.expiry <= nowSec || q.expiry - nowSec > BigInt(this.deps.maxQuoteTtlSec)) {
      return reject("bad_expiry", "expiry outside (now, now+maxQuoteTtl]");
    }
    if (r.taker && getAddress(q.taker) !== r.taker) return reject("wrong_taker", "quote.taker must equal rfq.taker");

    const sigOk = await this.deps.verifyTypedData({ address: c.address, quote: q, signature: msg.signature });
    if (!sigOk) return reject("bad_signature", "EIP-712 signature invalid");

    // Advisory price-guard check (the binding check is on-chain).
    const { mid, bandBps } = await this.deps.getMid(q.baseToken, q.quoteToken);
    const diff = q.price > mid ? q.price - mid : mid - q.price;
    const deviationBps = mid === 0n ? 1e9 : Number((diff * 10_000n) / mid);
    if (deviationBps > bandBps) return reject("outside_guard", `price ${deviationBps}bps from mid > ${bandBps}`);

    const taker = this.conns.get(o.takerConn);
    if (!taker) return reject("rfq_closed", "taker gone");
    o.quotes++;
    taker.send({
      type: "quote",
      rfqId: q.rfqId,
      quote: msg.quote,
      signature: msg.signature,
      mid: mid.toString(),
      deviationBps,
      receivedAt: this.deps.now(),
    });
  }

  private closeRfq(rfqId: Hex, reason: "deadline" | "cancelled") {
    const o = this.rfqs.get(rfqId);
    if (!o) return;
    if (o.timer) clearTimeout(o.timer);
    this.rfqs.delete(rfqId);
    this.conns.get(o.takerConn)?.send({ type: "rfq_closed", rfqId, reason });
  }

  private take(c: Conn): boolean {
    const now = this.deps.now();
    c.tokens = Math.min(RATE_CAPACITY, c.tokens + ((now - c.lastRefill) / 1000) * RATE_PER_SEC);
    c.lastRefill = now;
    if (c.tokens < 1) return false;
    c.tokens -= 1;
    return true;
  }
}

export { quoteDomain, quoteTypes };
