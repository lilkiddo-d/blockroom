"use client";
import { useReadContracts } from "wagmi";
import { STOCKS } from "@blockroom/config/chains";
import { priceGuardAbi, settlementAbi } from "@blockroom/config/abis";
import { CHAIN, DEPLOYMENT, explorerAddress } from "@/lib/config";
import { fmtUsd } from "@/lib/format";
import { KV } from "./common";

export function HomeStats() {
  const d = DEPLOYMENT;
  const mids = useReadContracts({
    contracts: d
      ? STOCKS.map((s) => ({ address: d.PriceGuard, abi: priceGuardAbi, functionName: "getMid", args: [s.address, d.USDG] }) as const)
      : [],
    query: { enabled: !!d, refetchInterval: 15_000 },
  });
  const params = useReadContracts({
    contracts: d
      ? [
          { address: d.Settlement, abi: settlementAbi, functionName: "feeBps" },
          { address: d.PriceGuard, abi: priceGuardAbi, functionName: "defaultBandBps" },
        ]
      : [],
    query: { enabled: !!d },
  });
  if (!d) return <div className="notice">No deployment configured for this network yet.</div>;
  return (
    <div className="grid grid-2">
      <div className="panel">
        <h2>Oracle mids (USDG)</h2>
        <table>
          <tbody>
            {STOCKS.map((s, i) => {
              const r = mids.data?.[i];
              return (
                <tr key={s.symbol}>
                  <td>{s.symbol}</td>
                  <td className="muted" style={{ fontFamily: "var(--sans)" }}>{s.name}</td>
                  <td style={{ textAlign: "right" }}>{r?.status === "success" ? `$${fmtUsd(r.result as bigint)}` : r ? "stale" : "…"}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <div className="panel">
        <h2>Protocol</h2>
        <KV k="Network" v={CHAIN.name} />
        <KV k="RFQ fee" v={params.data?.[0]?.result !== undefined ? `${params.data[0].result} bps` : "…"} />
        <KV k="Price guard band" v={params.data?.[1]?.result !== undefined ? `±${params.data[1].result} bps` : "…"} />
        <KV k="Admin" v="48h Timelock" />
        <KV k="Settlement" v={explorerAddress(d.Settlement) ? <a href={explorerAddress(d.Settlement)} target="_blank" rel="noreferrer">{d.Settlement.slice(0, 10)}…</a> : d.Settlement} />
      </div>
    </div>
  );
}
