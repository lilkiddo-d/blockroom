import { getAddress, type Address, type Hex } from "viem";
import type { OrderReveal } from "@blockroom/config";

export type WireReveal = Omit<OrderReveal, "batchId" | "size" | "minFill" | "limitPrice"> & {
  batchId: string;
  size: string;
  minFill: string;
  limitPrice: string;
};

export function revealFromWire(w: WireReveal): OrderReveal {
  return {
    trader: getAddress(w.trader),
    asset: getAddress(w.asset),
    batchId: BigInt(w.batchId),
    side: Number(w.side),
    tif: Number(w.tif),
    size: BigInt(w.size),
    minFill: BigInt(w.minFill),
    limitPrice: BigInt(w.limitPrice),
    salt: w.salt as Hex,
  };
}

type Batch = { asset: Address; batchId: bigint; commits: Set<Hex>; reveals: OrderReveal[]; settled: boolean };

/** In-memory index of midpoint batches the keeper is responsible for. Bounded by on-chain batch caps. */
export class BatchBook {
  private batches = new Map<string, Batch>();

  private key(asset: Address, batchId: bigint) {
    return `${asset.toLowerCase()}:${batchId}`;
  }

  private get(asset: Address, batchId: bigint): Batch {
    const k = this.key(asset, batchId);
    let b = this.batches.get(k);
    if (!b) {
      b = { asset: getAddress(asset), batchId, commits: new Set(), reveals: [], settled: false };
      this.batches.set(k, b);
    }
    return b;
  }

  addCommit(asset: Address, batchId: bigint, commitment: Hex) {
    this.get(asset, batchId).commits.add(commitment);
  }

  addReveal(asset: Address, batchId: bigint, r: OrderReveal) {
    const b = this.get(asset, batchId);
    if (b.settled) throw new Error("batch already settled");
    if (b.reveals.some((x) => x.salt === r.salt && x.trader === r.trader)) return;
    if (b.reveals.length >= 64) throw new Error("batch reveal queue full");
    b.reveals.push(r);
  }

  takeReveals(asset: Address, batchId: bigint): OrderReveal[] {
    const b = this.get(asset, batchId);
    const out = b.reveals;
    b.reveals = [];
    return out;
  }

  markSettled(asset: Address, batchId: bigint) {
    const b = this.get(asset, batchId);
    b.settled = true;
    b.reveals = [];
  }

  open(): Batch[] {
    return [...this.batches.values()].filter((b) => !b.settled);
  }
}
