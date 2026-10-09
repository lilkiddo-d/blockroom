"use client";
import { encodeAbiParameters, keccak256, type Address, type Hex } from "viem";
import { orderRevealAbi, type OrderReveal } from "@blockroom/config";

/** Order preimages stay in this browser (localStorage) until revealed; they are never sent anywhere unless the
 *  user opts into delegated reveal via the keeper. */
const KEY = "blockroom.midpoint.orders.v1";

export type StoredOrder = {
  commitment: Hex;
  chainId: number;
  createdAt: number;
  reveal: Omit<OrderReveal, "batchId" | "size" | "minFill" | "limitPrice"> & {
    batchId: string;
    size: string;
    minFill: string;
    limitPrice: string;
  };
  delegated?: boolean;
};

export function hashOrder(r: OrderReveal): Hex {
  return keccak256(encodeAbiParameters(orderRevealAbi, [r]));
}

export function randomSalt(): Hex {
  const b = crypto.getRandomValues(new Uint8Array(32));
  return ("0x" + Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("")) as Hex;
}

export function toStored(r: OrderReveal, commitment: Hex, chainId: number): StoredOrder {
  return {
    commitment,
    chainId,
    createdAt: Date.now(),
    reveal: {
      ...r,
      batchId: r.batchId.toString(),
      size: r.size.toString(),
      minFill: r.minFill.toString(),
      limitPrice: r.limitPrice.toString(),
    },
  };
}

export function fromStored(s: StoredOrder): OrderReveal {
  return {
    ...s.reveal,
    trader: s.reveal.trader as Address,
    asset: s.reveal.asset as Address,
    batchId: BigInt(s.reveal.batchId),
    size: BigInt(s.reveal.size),
    minFill: BigInt(s.reveal.minFill),
    limitPrice: BigInt(s.reveal.limitPrice),
  };
}

export function loadOrders(): StoredOrder[] {
  if (typeof window === "undefined") return [];
  try {
    return JSON.parse(localStorage.getItem(KEY) ?? "[]") as StoredOrder[];
  } catch {
    return [];
  }
}

export function saveOrders(orders: StoredOrder[]) {
  try {
    localStorage.setItem(KEY, JSON.stringify(orders.slice(-200)));
  } catch {
    /* storage unavailable: orders live for this session only */
  }
}
