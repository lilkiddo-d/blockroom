/** EIP-712 definitions shared by the relay, the market-maker bot and the app. Mirrors Settlement.sol. */
import type { Address, Hex } from "viem";

export const QUOTE_DOMAIN_NAME = "Blockroom Settlement";
export const QUOTE_DOMAIN_VERSION = "1";

export const quoteTypes = {
  Quote: [
    { name: "rfqId", type: "bytes32" },
    { name: "maker", type: "address" },
    { name: "taker", type: "address" },
    { name: "baseToken", type: "address" },
    { name: "quoteToken", type: "address" },
    { name: "side", type: "uint8" },
    { name: "tif", type: "uint8" },
    { name: "price", type: "uint256" },
    { name: "size", type: "uint256" },
    { name: "minFill", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "expiry", type: "uint64" },
  ],
} as const;

/** Side from the MAKER's perspective (as signed). */
export enum MakerSide {
  MakerSells = 0, // taker buys
  MakerBuys = 1, // taker sells
}

export enum TimeInForce {
  GTD = 0,
  IOC = 1,
  FOK = 2,
}

export type Quote = {
  rfqId: Hex;
  maker: Address;
  taker: Address;
  baseToken: Address;
  quoteToken: Address;
  side: number;
  tif: number;
  price: bigint;
  size: bigint;
  minFill: bigint;
  nonce: bigint;
  expiry: bigint;
};

export function quoteDomain(chainId: number, settlement: Address) {
  return {
    name: QUOTE_DOMAIN_NAME,
    version: QUOTE_DOMAIN_VERSION,
    chainId,
    verifyingContract: settlement,
  } as const;
}

/** JSON-safe quote (bigints as decimal strings) used on the wire. */
export type WireQuote = {
  [K in keyof Quote]: Quote[K] extends bigint ? string : Quote[K];
};

export function toWire(q: Quote): WireQuote {
  return {
    ...q,
    price: q.price.toString(),
    size: q.size.toString(),
    minFill: q.minFill.toString(),
    nonce: q.nonce.toString(),
    expiry: q.expiry.toString(),
  };
}

export function fromWire(w: WireQuote): Quote {
  return {
    ...w,
    price: BigInt(w.price),
    size: BigInt(w.size),
    minFill: BigInt(w.minFill),
    nonce: BigInt(w.nonce),
    expiry: BigInt(w.expiry),
  };
}

/** Midpoint commitment preimage - mirrors MidpointPool.OrderReveal (abi.encode of the struct). */
export const orderRevealAbi = [
  {
    type: "tuple",
    components: [
      { name: "trader", type: "address" },
      { name: "asset", type: "address" },
      { name: "batchId", type: "uint64" },
      { name: "side", type: "uint8" },
      { name: "tif", type: "uint8" },
      { name: "size", type: "uint128" },
      { name: "minFill", type: "uint128" },
      { name: "limitPrice", type: "uint128" },
      { name: "salt", type: "bytes32" },
    ],
  },
] as const;

export type OrderReveal = {
  trader: Address;
  asset: Address;
  batchId: bigint;
  side: number; // 0 buy, 1 sell
  tif: number; // 0 IOC, 1 FOK
  size: bigint;
  minFill: bigint;
  limitPrice: bigint;
  salt: Hex;
};
