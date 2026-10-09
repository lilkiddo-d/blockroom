import { MakerSide } from "@blockroom/config";

/**
 * Reference market-maker pricing: quote mid +/- spread, capped by notional and inventory.
 * Pure functions so they can be unit tested.
 */
export function quotePrice(mid: bigint, side: MakerSide, spreadBps: number): bigint {
  const s = BigInt(Math.round(spreadBps));
  // maker sells -> ask above mid (round up); maker buys -> bid below mid (round down)
  return side === MakerSide.MakerSells ? (mid * (10_000n + s) + 9_999n) / 10_000n : (mid * (10_000n - s)) / 10_000n;
}

export function quoteSize(args: {
  requested: bigint;
  side: MakerSide;
  price: bigint;
  baseUnit: bigint;
  baseInventory: bigint;
  quoteInventory: bigint;
  maxNotional: bigint;
}): bigint {
  const { requested, side, price, baseUnit, baseInventory, quoteInventory, maxNotional } = args;
  let size = requested;
  const maxByNotional = (maxNotional * baseUnit) / price;
  if (size > maxByNotional) size = maxByNotional;
  if (side === MakerSide.MakerSells) {
    if (size > baseInventory) size = baseInventory;
  } else {
    const maxByCash = (quoteInventory * baseUnit) / price;
    if (size > maxByCash) size = maxByCash;
  }
  return size > 0n ? size : 0n;
}

/** Unique, monotonically increasing nonces (bitmap-friendly: consecutive values share words). */
export function nonceFactory(seed = BigInt(Date.now()) * 1_000n) {
  let n = seed;
  return () => n++;
}
