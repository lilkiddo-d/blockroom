"use client";
/**
 * Multi-relay RFQ client. The taker connects to every configured relay at once and merges quote streams, so
 * no single relay can censor makers or the taker. Quotes are verified locally (EIP-712) before display.
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { verifyTypedData, type Address, type Hex } from "viem";
import { fromWire, quoteDomain, quoteTypes, type Quote, type RfqSide, type ServerMsg } from "@blockroom/config";
import { CHAIN_ID, DEPLOYMENT, RELAY_URLS } from "./config";

export type LiveQuote = {
  key: string;
  relay: string;
  quote: Quote;
  signature: Hex;
  mid: bigint;
  deviationBps: number;
  receivedAt: number;
  verified: boolean;
};

export type RelayStatus = { url: string; state: "connecting" | "open" | "closed"; makers: number };

export function useRfqRelays() {
  const sockets = useRef(new Map<string, WebSocket>());
  const [status, setStatus] = useState<RelayStatus[]>(RELAY_URLS.map((url) => ({ url, state: "connecting", makers: 0 })));
  const [quotes, setQuotes] = useState<LiveQuote[]>([]);
  const [activeRfq, setActiveRfq] = useState<{ rfqId: Hex; deadline: number } | null>(null);
  const [errors, setErrors] = useState<string[]>([]);
  const activeRef = useRef<Hex | null>(null);

  const setRelay = (url: string, patch: Partial<RelayStatus>) =>
    setStatus((s) => s.map((r) => (r.url === url ? { ...r, ...patch } : r)));

  useEffect(() => {
    let cancelled = false;
    const connect = (url: string) => {
      if (cancelled) return;
      let ws: WebSocket;
      try {
        ws = new WebSocket(url);
      } catch {
        setRelay(url, { state: "closed" });
        return;
      }
      sockets.current.set(url, ws);
      ws.onopen = () => {
        setRelay(url, { state: "open" });
        ws.send(JSON.stringify({ type: "hello", role: "taker" }));
      };
      ws.onclose = () => {
        setRelay(url, { state: "closed" });
        if (!cancelled) setTimeout(() => connect(url), 4000);
      };
      ws.onmessage = async (ev) => {
        const msg = JSON.parse(String(ev.data)) as ServerMsg;
        if (msg.type === "ready") setRelay(url, { makers: msg.makers });
        else if (msg.type === "rfq_ack") setRelay(url, { makers: msg.makersNotified });
        else if (msg.type === "error") setErrors((e) => [`${url}: ${msg.message}`, ...e].slice(0, 5));
        else if (msg.type === "quote" && msg.rfqId === activeRef.current && DEPLOYMENT) {
          const q = fromWire(msg.quote);
          let verified = false;
          try {
            verified = await verifyTypedData({
              address: q.maker,
              domain: quoteDomain(CHAIN_ID, DEPLOYMENT.Settlement),
              types: quoteTypes,
              primaryType: "Quote",
              message: q,
              signature: msg.signature,
            });
          } catch {
            verified = false; // smart-contract makers (ERC-1271) are verified on-chain at fill time
          }
          const key = `${q.maker}-${q.nonce}`;
          setQuotes((qs) =>
            qs.some((x) => x.key === key)
              ? qs
              : [
                  ...qs,
                  {
                    key,
                    relay: url,
                    quote: q,
                    signature: msg.signature,
                    mid: BigInt(msg.mid),
                    deviationBps: msg.deviationBps,
                    receivedAt: Date.now(),
                    verified,
                  },
                ],
          );
        }
      };
    };
    RELAY_URLS.forEach(connect);
    const all = sockets.current;
    return () => {
      cancelled = true;
      all.forEach((ws) => ws.close());
      all.clear();
    };
  }, []);

  const requestQuote = useCallback(
    (args: { baseToken: Address; quoteToken: Address; side: RfqSide; size: bigint; taker?: Address }) => {
      const bytes = crypto.getRandomValues(new Uint8Array(32));
      const rfqId = ("0x" + Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("")) as Hex;
      activeRef.current = rfqId;
      setQuotes([]);
      setErrors([]);
      setActiveRfq({ rfqId, deadline: Date.now() + 15_000 });
      const msg = JSON.stringify({
        type: "rfq",
        rfq: { rfqId, baseToken: args.baseToken, quoteToken: args.quoteToken, side: args.side, size: args.size.toString(), taker: args.taker },
      });
      sockets.current.forEach((ws) => ws.readyState === WebSocket.OPEN && ws.send(msg));
      return rfqId;
    },
    [],
  );

  const cancel = useCallback(() => {
    const id = activeRef.current;
    if (!id) return;
    sockets.current.forEach((ws) => ws.readyState === WebSocket.OPEN && ws.send(JSON.stringify({ type: "cancel", rfqId: id })));
    activeRef.current = null;
    setActiveRfq(null);
  }, []);

  return { status, quotes, activeRfq, errors, requestQuote, cancel };
}
