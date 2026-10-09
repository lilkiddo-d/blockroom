"use client";
import type { ReactNode } from "react";
import { STOCKS, type StockToken } from "@blockroom/config/chains";
import { CHAIN, CHAIN_ID, DEPLOYMENT } from "@/lib/config";
import type { TxState } from "@/lib/hooks";
import { explorerTx } from "@/lib/config";

export function StockPicker({ value, onChange }: { value: StockToken; onChange: (s: StockToken) => void }) {
  return (
    <label>
      Instrument
      <select value={value.symbol} onChange={(e) => onChange(STOCKS.find((s) => s.symbol === e.target.value)!)}>
        {STOCKS.map((s) => (
          <option key={s.symbol} value={s.symbol}>
            {s.symbol} — {s.name}
          </option>
        ))}
      </select>
    </label>
  );
}

export function Segmented<T extends string>({
  value,
  options,
  onChange,
}: {
  value: T;
  options: { value: T; label: string; tone?: "buy" | "sell" }[];
  onChange: (v: T) => void;
}) {
  return (
    <div className="seg" role="radiogroup">
      {options.map((o) => (
        <button
          key={o.value}
          type="button"
          role="radio"
          aria-checked={value === o.value}
          className={`${value === o.value ? "on" : ""} ${o.tone ?? ""}`}
          onClick={() => onChange(o.value)}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

export function TxStatus({ tx }: { tx: TxState }) {
  if (tx.status === "idle") return null;
  const link = tx.hash ? explorerTx(tx.hash) : undefined;
  const cls = tx.status === "error" ? "notice err" : tx.status === "success" ? "notice ok" : "notice";
  const label =
    tx.status === "signing" ? "Confirm in your wallet…" : tx.status === "pending" ? "Waiting for confirmation…" : tx.status === "success" ? "Confirmed" : `Failed: ${tx.error}`;
  return (
    <div className={cls}>
      {label}{" "}
      {tx.hash && (link ? <a href={link} target="_blank" rel="noreferrer">view tx</a> : <span className="mono small">{tx.hash.slice(0, 18)}…</span>)}
    </div>
  );
}

export function RequireDeployment({ children }: { children: ReactNode }) {
  if (!DEPLOYMENT) {
    return (
      <div className="notice">
        No Blockroom deployment found for chain {CHAIN_ID} ({CHAIN.name}). Run the deploy script (see DEPLOY.md) — it
        writes <span className="mono">app/src/generated/deployments/{CHAIN_ID}.json</span>.
      </div>
    );
  }
  return <>{children}</>;
}

export function KV({ k, v }: { k: ReactNode; v: ReactNode }) {
  return (
    <div className="kv">
      <span>{k}</span>
      <span className="num">{v}</span>
    </div>
  );
}
