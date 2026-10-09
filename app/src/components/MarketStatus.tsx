"use client";
import { useMarketOpen, useNow } from "@/lib/hooks";

export function MarketStatus() {
  const { data: open, isError } = useMarketOpen();
  const now = useNow(30_000);
  const et = new Date(now).toLocaleTimeString("en-US", { timeZone: "America/New_York", hour: "2-digit", minute: "2-digit" });
  return (
    <span className="row small muted" title="US regular session per the on-chain MarketClock">
      <span className={`dot ${open ? "ok" : isError ? "" : "bad"}`} />
      {open === undefined ? "Market —" : open ? "Market open" : "Market closed"} · {et} ET
    </span>
  );
}
