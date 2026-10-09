import { formatUnits, parseUnits } from "viem";

export const USDG_DECIMALS = 6;
export const STOCK_DECIMALS = 18;

export function fmtUsd(v: bigint, decimals = USDG_DECIMALS, dp = 2): string {
  const n = Number(formatUnits(v, decimals));
  return n.toLocaleString("en-US", { minimumFractionDigits: dp, maximumFractionDigits: dp });
}

export function fmtShares(v: bigint, dp = 4): string {
  const n = Number(formatUnits(v, STOCK_DECIMALS));
  return n.toLocaleString("en-US", { maximumFractionDigits: dp });
}

export function parseShares(s: string): bigint | undefined {
  try {
    const v = parseUnits(s.trim() || "0", STOCK_DECIMALS);
    return v > 0n ? v : undefined;
  } catch {
    return undefined;
  }
}

export function parseUsd(s: string): bigint | undefined {
  try {
    const v = parseUnits(s.trim() || "0", USDG_DECIMALS);
    return v > 0n ? v : undefined;
  } catch {
    return undefined;
  }
}

/** signed deviation of price vs mid in bps (positive = above mid) */
export function bpsVsMid(price: bigint, mid: bigint): number {
  if (mid === 0n) return 0;
  return Number(((price - mid) * 100_000n) / mid) / 10;
}

export function shortAddr(a?: string) {
  return a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "";
}

export function notional(baseAmount: bigint, price: bigint): bigint {
  return (baseAmount * price) / 10n ** BigInt(STOCK_DECIMALS);
}
