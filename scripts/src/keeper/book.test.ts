import { describe, expect, it } from "vitest";
import type { Hex } from "viem";
import { BatchBook, revealFromWire } from "./book.js";

const A = "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9";
const T = "0x00000000000000000000000000000000000000aa";

describe("BatchBook", () => {
  it("tracks commits, queues reveals once, and drops settled batches", () => {
    const b = new BatchBook();
    b.addCommit(A, 7n, ("0x" + "01".repeat(32)) as Hex);
    expect(b.open()).toHaveLength(1);
    const r = revealFromWire({
      trader: T,
      asset: A,
      batchId: "7",
      side: 0,
      tif: 0,
      size: "1",
      minFill: "0",
      limitPrice: "2",
      salt: ("0x" + "02".repeat(32)) as Hex,
    });
    b.addReveal(A, 7n, r);
    b.addReveal(A, 7n, r);
    expect(b.takeReveals(A, 7n)).toHaveLength(1);
    expect(b.takeReveals(A, 7n)).toHaveLength(0);
    b.markSettled(A, 7n);
    expect(b.open()).toHaveLength(0);
    expect(() => b.addReveal(A, 7n, r)).toThrow();
  });
});
