import { describe, expect, it } from "vitest";
import { MakerSide } from "@blockroom/config";
import { nonceFactory, quotePrice, quoteSize } from "./pricing.js";

describe("pricing", () => {
  it("quotes asks above and bids below mid", () => {
    expect(quotePrice(340_000_000n, MakerSide.MakerSells, 15)).toBe(340_510_000n);
    expect(quotePrice(340_000_000n, MakerSide.MakerBuys, 15)).toBe(339_490_000n);
  });

  it("caps size by notional and inventory", () => {
    const base = 10n ** 18n;
    const common = { baseUnit: base, price: 340_000_000n, quoteInventory: 1_000_000_000n, maxNotional: 3_400_000_000n };
    expect(quoteSize({ ...common, requested: 100n * base, side: MakerSide.MakerSells, baseInventory: 5n * base })).toBe(5n * base);
    expect(quoteSize({ ...common, requested: 100n * base, side: MakerSide.MakerSells, baseInventory: 50n * base })).toBe(10n * base);
    // 1,000 USDG of cash buys ~2.94 shares
    expect(quoteSize({ ...common, requested: 100n * base, side: MakerSide.MakerBuys, baseInventory: 0n })).toBe(
      (1_000_000_000n * base) / 340_000_000n,
    );
  });

  it("produces unique increasing nonces", () => {
    const n = nonceFactory(5n);
    expect([n(), n(), n()]).toEqual([5n, 6n, 7n]);
  });
});
