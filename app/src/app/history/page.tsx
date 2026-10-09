"use client";
import { useEffect, useState } from "react";
import { useAccount, usePublicClient } from "wagmi";
import type { Address, Hash } from "viem";
import { STOCKS } from "@blockroom/config/chains";
import { midpointPoolAbi, settlementAbi } from "@blockroom/config/abis";
import { DEPLOYMENT, explorerTx } from "@/lib/config";
import { fmtShares, fmtUsd } from "@/lib/format";
import { RequireDeployment } from "@/components/common";

type Row = {
  kind: "RFQ" | "Midpoint" | "Default";
  block: bigint;
  tx: Hash;
  role: string;
  symbol: string;
  side: "BUY" | "SELL" | "—";
  base: bigint;
  quote: bigint;
  price: bigint;
  mid: bigint;
};

const LOOKBACK = 500_000n;
const CHUNK = 50_000n;

export default function HistoryPage() {
  return (
    <>
      <h1>Trade history</h1>
      <p className="sub">Your RFQ fills, maker defaults and midpoint executions, read directly from chain events.</p>
      <RequireDeployment>
        <History />
      </RequireDeployment>
    </>
  );
}

const sym = (a: string) => STOCKS.find((s) => s.address.toLowerCase() === a.toLowerCase())?.symbol ?? "?";

function History() {
  const d = DEPLOYMENT!;
  const { address } = useAccount();
  const client = usePublicClient();
  const [rows, setRows] = useState<Row[] | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (!address || !client) return;
    let cancelled = false;
    (async () => {
      try {
        const head = await client.getBlockNumber();
        const start = BigInt(d.deployedAtBlock) > head - LOOKBACK ? BigInt(d.deployedAtBlock) : head - LOOKBACK;
        const me = address.toLowerCase();
        const out: Row[] = [];
        for (let from = start; from <= head; from += CHUNK) {
          const to = from + CHUNK - 1n > head ? head : from + CHUNK - 1n;
          const [fills, defaults, matches] = await Promise.all([
            client.getContractEvents({ address: d.Settlement, abi: settlementAbi, eventName: "QuoteFilled", fromBlock: from, toBlock: to }),
            client.getContractEvents({ address: d.Settlement, abi: settlementAbi, eventName: "QuoteDefaulted", fromBlock: from, toBlock: to }),
            client.getContractEvents({ address: d.MidpointPool, abi: midpointPoolAbi, eventName: "Matched", fromBlock: from, toBlock: to }),
          ]);
          for (const l of fills) {
            const a = l.args;
            const isTaker = a.taker!.toLowerCase() === me;
            const isMaker = a.maker!.toLowerCase() === me;
            if (!isTaker && !isMaker) continue;
            const takerBuys = a.side === 0;
            const buys = isTaker ? takerBuys : !takerBuys;
            out.push({
              kind: "RFQ",
              block: l.blockNumber,
              tx: l.transactionHash,
              role: isTaker ? "taker" : "maker",
              symbol: sym(a.baseToken!),
              side: buys ? "BUY" : "SELL",
              base: a.baseAmount!,
              quote: a.quoteAmount!,
              price: (a.quoteAmount! * 10n ** 18n) / a.baseAmount!,
              mid: a.mid!,
            });
          }
          for (const l of defaults) {
            const a = l.args;
            if (a.taker!.toLowerCase() !== me && a.maker!.toLowerCase() !== me) continue;
            out.push({ kind: "Default", block: l.blockNumber, tx: l.transactionHash, role: a.taker!.toLowerCase() === me ? "taker (compensated)" : "maker (slashed)", symbol: "—", side: "—", base: 0n, quote: a.penalty!, price: 0n, mid: 0n });
          }
          for (const l of matches) {
            const a = l.args;
            const isBuyer = a.buyer!.toLowerCase() === me;
            if (!isBuyer && a.seller!.toLowerCase() !== me) continue;
            out.push({
              kind: "Midpoint",
              block: l.blockNumber,
              tx: l.transactionHash,
              role: isBuyer ? "buyer" : "seller",
              symbol: sym(a.asset as Address),
              side: isBuyer ? "BUY" : "SELL",
              base: a.baseAmount!,
              quote: a.quoteAmount!,
              price: a.mid!,
              mid: a.mid!,
            });
          }
          if (cancelled) return;
        }
        setRows(out.sort((x, y) => Number(y.block - x.block)));
      } catch (e) {
        setErr((e as Error).message.slice(0, 200));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [address, client, d]);

  if (!address) return <div className="panel empty">Connect a wallet to see your trades.</div>;
  if (err) return <div className="notice err">{err}</div>;
  if (!rows) return <div className="panel empty">Scanning events…</div>;
  if (!rows.length) return <div className="panel empty">No trades yet.</div>;
  return (
    <div className="panel">
      <table>
        <thead>
          <tr>
            <th>Block</th>
            <th>Venue</th>
            <th>Role</th>
            <th>Side</th>
            <th>Size</th>
            <th>Price</th>
            <th>Mid</th>
            <th>Notional / penalty</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={`${r.tx}-${r.kind}-${r.role}-${r.base}`}>
              <td>{r.block.toString()}</td>
              <td>{r.kind}</td>
              <td>{r.role}</td>
              <td className={r.side === "BUY" ? "buy" : r.side === "SELL" ? "sell" : ""}>
                {r.side} {r.symbol !== "—" ? r.symbol : ""}
              </td>
              <td>{r.base ? fmtShares(r.base) : "—"}</td>
              <td>{r.price ? `$${fmtUsd(r.price, 6, 4)}` : "—"}</td>
              <td>{r.mid ? `$${fmtUsd(r.mid, 6, 4)}` : "—"}</td>
              <td>${fmtUsd(r.quote)}</td>
              <td>{explorerTx(r.tx) ? <a href={explorerTx(r.tx)} target="_blank" rel="noreferrer">tx</a> : <span className="mono small">{r.tx.slice(0, 10)}</span>}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
