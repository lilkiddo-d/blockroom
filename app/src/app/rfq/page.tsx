"use client";
import { useMemo, useState } from "react";
import { useAccount, useReadContract } from "wagmi";
import { decodeEventLog, zeroAddress } from "viem";
import { STOCKS, type StockToken } from "@blockroom/config/chains";
import { MakerSide, type RfqSide } from "@blockroom/config";
import { settlementAbi } from "@blockroom/config/abis";
import { DEPLOYMENT } from "@/lib/config";
import { approveArgs, useMid, useNow, useTokenState, useTx } from "@/lib/hooks";
import { useRfqRelays, type LiveQuote } from "@/lib/relay";
import { bpsVsMid, fmtShares, fmtUsd, notional, parseShares, shortAddr } from "@/lib/format";
import { KV, RequireDeployment, Segmented, StockPicker, TxStatus } from "@/components/common";

export default function RfqPage() {
  return (
    <>
      <h1>Request for quote</h1>
      <p className="sub">
        Ask every registered market maker for a firm, signed price on size. Pick the best one and settle atomically
        on-chain. Quotes more than the guard band away from the oracle mid can't settle.
      </p>
      <RequireDeployment>
        <Rfq />
      </RequireDeployment>
    </>
  );
}

function Rfq() {
  const { address } = useAccount();
  const [stock, setStock] = useState<StockToken>(STOCKS[0]);
  const [side, setSide] = useState<RfqSide>("buy");
  const [sizeStr, setSizeStr] = useState("100");
  const [designated, setDesignated] = useState(true);
  const [selected, setSelected] = useState<LiveQuote | null>(null);
  const relay = useRfqRelays();
  const mid = useMid(stock.address);
  const now = useNow(500);
  const size = parseShares(sizeStr);

  const sorted = useMemo(() => {
    const live = relay.quotes.filter((q) => Number(q.quote.expiry) * 1000 > now);
    // best first: lowest ask for takers buying, highest bid for takers selling
    return [...live].sort((a, b) => {
      if (a.quote.side !== b.quote.side) return a.quote.side - b.quote.side;
      return a.quote.side === MakerSide.MakerSells ? Number(a.quote.price - b.quote.price) : Number(b.quote.price - a.quote.price);
    });
  }, [relay.quotes, now]);

  const bestKeys = useMemo(() => {
    const s = new Set<string>();
    const ask = sorted.find((q) => q.quote.side === MakerSide.MakerSells);
    const bid = sorted.find((q) => q.quote.side === MakerSide.MakerBuys);
    if (ask) s.add(ask.key);
    if (bid) s.add(bid.key);
    return s;
  }, [sorted]);

  const openRelays = relay.status.filter((r) => r.state === "open").length;
  const remainingMs = relay.activeRfq ? Math.max(0, relay.activeRfq.deadline - now) : 0;

  return (
    <div className="grid grid-side">
      <div className="stack">
        <div className="panel stack">
          <h2>New request</h2>
          <StockPicker value={stock} onChange={(s) => (setStock(s), setSelected(null))} />
          <label>
            Side
            <Segmented
              value={side}
              onChange={setSide}
              options={[
                { value: "buy", label: "Buy", tone: "buy" },
                { value: "sell", label: "Sell", tone: "sell" },
                { value: "two-way", label: "Two-way (private)" },
              ]}
            />
          </label>
          {side === "two-way" && (
            <p className="small muted">
              Makers quote both a bid and an offer, so they can&apos;t tell which way you trade.
            </p>
          )}
          <label>
            Size (shares)
            <input value={sizeStr} onChange={(e) => setSizeStr(e.target.value)} inputMode="decimal" />
          </label>
          <label className="row" style={{ flexDirection: "row", alignItems: "center" }}>
            <input type="checkbox" checked={designated} onChange={(e) => setDesignated(e.target.checked)} /> Only
            fillable by my address
          </label>
          <KV k="Oracle mid" v={mid.data ? `$${fmtUsd(mid.data)}` : mid.isError ? "unavailable" : "…"} />
          <KV k="Indicative notional" v={mid.data && size ? `$${fmtUsd(notional(size, mid.data))}` : "—"} />
          <button
            className="btn"
            disabled={!size || openRelays === 0 || (designated && !address)}
            onClick={() => {
              setSelected(null);
              relay.requestQuote({
                baseToken: stock.address,
                quoteToken: DEPLOYMENT!.USDG,
                side,
                size: size!,
                taker: designated ? address : undefined,
              });
            }}
          >
            Request quotes
          </button>
          {relay.activeRfq && (
            <div className="spread small">
              <span className="muted">Collecting quotes… {(remainingMs / 1000).toFixed(0)}s</span>
              <button className="btn ghost small" onClick={relay.cancel}>
                Stop
              </button>
            </div>
          )}
        </div>
        <div className="panel stack small">
          <h2>Relays</h2>
          {relay.status.map((r) => (
            <div key={r.url} className="spread">
              <span className="row">
                <span className={`dot ${r.state === "open" ? "ok" : "bad"}`} />
                <span className="mono">{r.url}</span>
              </span>
              <span className="muted">{r.makers} makers</span>
            </div>
          ))}
          {relay.errors.map((e, i) => (
            <span key={i} className="warn">
              {e}
            </span>
          ))}
        </div>
      </div>

      <div className="stack">
        <div className="panel">
          <div className="spread">
            <h2>Quotes</h2>
            <span className="small muted">{sorted.length} live</span>
          </div>
          {sorted.length === 0 ? (
            <div className="empty">{relay.activeRfq ? "Waiting for makers…" : "Request a quote to see competing prices stream in."}</div>
          ) : (
            <table>
              <thead>
                <tr>
                  <th>Maker</th>
                  <th>You</th>
                  <th>Price</th>
                  <th>vs mid</th>
                  <th>Size</th>
                  <th>Expires</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {sorted.map((q) => {
                  const takerBuys = q.quote.side === MakerSide.MakerSells;
                  const dev = bpsVsMid(q.quote.price, mid.data ?? q.mid);
                  const good = takerBuys ? dev <= 0 : dev >= 0;
                  return (
                    <tr
                      key={q.key}
                      className={`clickable ${bestKeys.has(q.key) ? "best" : ""}`}
                      onClick={() => setSelected(q)}
                    >
                      <td>
                        {shortAddr(q.quote.maker)}{" "}
                        {q.verified ? <span className="badge ok">signed</span> : <span className="badge warn">1271</span>}
                      </td>
                      <td className={takerBuys ? "buy" : "sell"}>{takerBuys ? "BUY" : "SELL"}</td>
                      <td>${fmtUsd(q.quote.price, 6, 4)}</td>
                      <td className={good ? "buy" : "sell"}>
                        {dev > 0 ? "+" : ""}
                        {dev.toFixed(1)} bps
                      </td>
                      <td>{fmtShares(q.quote.size)}</td>
                      <td>{Math.max(0, Math.floor(Number(q.quote.expiry) - now / 1000))}s</td>
                      <td>
                        <button className="btn small">Select</button>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          )}
        </div>
        {selected && <Confirm q={selected} requested={size} onDone={() => setSelected(null)} />}
      </div>
    </div>
  );
}

function Confirm({ q, requested, onDone }: { q: LiveQuote; requested?: bigint; onDone: () => void }) {
  const { address } = useAccount();
  const d = DEPLOYMENT!;
  const takerBuys = q.quote.side === MakerSide.MakerSells;
  const mid = useMid(q.quote.baseToken);
  const [amtStr, setAmtStr] = useState(fmtShares(requested && requested < q.quote.size ? requested : q.quote.size, 18).replace(/,/g, ""));
  const amount = parseShares(amtStr);
  const quoteAmt = amount ? (takerBuys ? (amount * q.quote.price + 10n ** 18n - 1n) / 10n ** 18n : notional(amount, q.quote.price)) : 0n;
  const fee = useReadContract({
    address: d.Settlement,
    abi: settlementAbi,
    functionName: "quoteFee",
    args: address ? [address, quoteAmt] : undefined,
    query: { enabled: !!address && quoteAmt > 0n },
  });
  const payToken = takerBuys ? d.USDG : q.quote.baseToken;
  const pay = useTokenState(payToken, d.Settlement);
  const needed = takerBuys ? quoteAmt + (fee.data ?? 0n) : amount ?? 0n;
  const approveTx = useTx();
  const fillTx = useTx();
  const [outcome, setOutcome] = useState<string | null>(null);
  const dev = bpsVsMid(q.quote.price, mid.data ?? q.mid);
  const remainingSec = Number(q.quote.expiry) - Math.floor(Date.now() / 1000);
  const wrongTaker = q.quote.taker !== zeroAddress && q.quote.taker.toLowerCase() !== address?.toLowerCase();

  async function fill() {
    const receipt = await fillTx.send({
      address: d.Settlement,
      abi: settlementAbi,
      functionName: "fill",
      args: [q.quote, q.signature, amount!],
    });
    if (!receipt) return;
    for (const log of receipt.logs) {
      try {
        const ev = decodeEventLog({ abi: settlementAbi, data: log.data, topics: log.topics });
        if (ev.eventName === "QuoteDefaulted") {
          setOutcome(`Maker failed to deliver. Your funds were returned and you received $${fmtUsd(ev.args.penalty)} from the maker's bond.`);
        } else if (ev.eventName === "QuoteFilled") {
          setOutcome(`Filled ${fmtShares(ev.args.baseAmount)} ${symbolOf(q.quote.baseToken)} at $${fmtUsd(q.quote.price, 6, 4)} (fee $${fmtUsd(ev.args.fee)}).`);
        }
      } catch {
        /* other contracts' logs */
      }
    }
    pay.refetch();
  }

  return (
    <div className="panel stack">
      <div className="spread">
        <h2>Confirm {takerBuys ? "purchase" : "sale"}</h2>
        <button className="btn ghost small" onClick={onDone}>
          Close
        </button>
      </div>
      <div className="grid grid-2">
        <div>
          <KV k="Maker" v={shortAddr(q.quote.maker)} />
          <KV k="Price" v={`$${fmtUsd(q.quote.price, 6, 4)}`} />
          <KV k="Oracle mid" v={mid.data ? `$${fmtUsd(mid.data, 6, 4)}` : "…"} />
          <KV k="Price vs mid" v={<span className={(takerBuys ? dev <= 0 : dev >= 0) ? "buy" : "sell"}>{dev.toFixed(1)} bps</span>} />
          <KV k="Quote expires in" v={`${Math.max(0, remainingSec)}s`} />
        </div>
        <div>
          <label>
            Fill amount (max {fmtShares(q.quote.size)}{q.quote.minFill > 0n ? `, min ${fmtShares(q.quote.minFill)}` : ""})
            <input value={amtStr} onChange={(e) => setAmtStr(e.target.value)} />
          </label>
          <KV k="Notional" v={`$${fmtUsd(quoteAmt)}`} />
          <KV k="Protocol fee" v={fee.data !== undefined ? `$${fmtUsd(fee.data)}` : "—"} />
          <KV k={takerBuys ? "You pay" : "You receive"} v={`$${fmtUsd(takerBuys ? quoteAmt + (fee.data ?? 0n) : quoteAmt - (fee.data ?? 0n))}`} />
        </div>
      </div>
      {wrongTaker && <div className="notice err">This quote is reserved for a different taker address.</div>}
      {pay.balance !== undefined && pay.balance < needed && (
        <div className="notice err">Insufficient {takerBuys ? "USDG" : symbolOf(q.quote.baseToken)} balance.</div>
      )}
      <div className="row">
        {pay.allowance !== undefined && pay.allowance < needed ? (
          <button className="btn" disabled={approveTx.status === "pending"} onClick={async () => (await approveTx.send(approveArgs(payToken, d.Settlement)), pay.refetch())}>
            Approve {takerBuys ? "USDG" : symbolOf(q.quote.baseToken)}
          </button>
        ) : (
          <button
            className="btn"
            disabled={!amount || !address || wrongTaker || remainingSec <= 0 || fillTx.status === "pending" || fillTx.status === "signing"}
            onClick={fill}
          >
            Settle on-chain
          </button>
        )}
      </div>
      <TxStatus tx={approveTx} />
      <TxStatus tx={fillTx} />
      {outcome && <div className="notice ok">{outcome}</div>}
    </div>
  );
}

function symbolOf(addr: string) {
  return STOCKS.find((s) => s.address.toLowerCase() === addr.toLowerCase())?.symbol ?? "token";
}
