/**
 * RFQ relay wire protocol (JSON over WebSocket). The relay is a dumb, verifiable message bus:
 * it can't forge quotes (EIP-712 signed by makers) and can't settle trades (takers fill on-chain directly).
 */
import type { Address, Hex } from "viem";
import type { WireQuote } from "./eip712";

/** Taker intent. "two-way" asks makers for both a bid and an offer so the taker's direction stays private. */
export type RfqSide = "buy" | "sell" | "two-way";

export type RfqRequest = {
  rfqId: Hex;
  baseToken: Address;
  quoteToken: Address;
  side: RfqSide;
  /** base units (18 dp for stock tokens), decimal string */
  size: string;
  /** optional: restrict quotes to this taker address (prevents quote sniping by others) */
  taker?: Address;
  /** unix ms after which makers should stop responding */
  deadline: number;
};

// ---------------------------------------------------------------- client -> relay

export type HelloMsg = { type: "hello"; role: "taker" | "maker"; address?: Address };
export type MakerAuthMsg = { type: "auth"; address: Address; signature: Hex };
export type RfqMsg = { type: "rfq"; rfq: Omit<RfqRequest, "deadline"> };
export type CancelRfqMsg = { type: "cancel"; rfqId: Hex };
export type QuoteMsg = { type: "quote"; quote: WireQuote; signature: Hex };
export type PingMsg = { type: "ping" };

export type ClientMsg = HelloMsg | MakerAuthMsg | RfqMsg | CancelRfqMsg | QuoteMsg | PingMsg;

// ---------------------------------------------------------------- relay -> client

export type ChallengeMsg = { type: "challenge"; message: string };
export type ReadyMsg = { type: "ready"; role: "taker" | "maker"; address?: Address; makers: number };
export type RfqBroadcastMsg = { type: "rfq"; rfq: RfqRequest };
export type RfqAckMsg = { type: "rfq_ack"; rfqId: Hex; deadline: number; makersNotified: number };
export type QuoteForwardMsg = {
  type: "quote";
  rfqId: Hex;
  quote: WireQuote;
  signature: Hex;
  /** mid observed by the relay (quote units per whole base token) and deviation in bps - informational only */
  mid: string;
  deviationBps: number;
  receivedAt: number;
};
export type RfqClosedMsg = { type: "rfq_closed"; rfqId: Hex; reason: "deadline" | "cancelled" };
export type ErrorMsg = { type: "error"; code: string; message: string; rfqId?: Hex };
export type PongMsg = { type: "pong"; t: number };

export type ServerMsg =
  | ChallengeMsg
  | ReadyMsg
  | RfqBroadcastMsg
  | RfqAckMsg
  | QuoteForwardMsg
  | RfqClosedMsg
  | ErrorMsg
  | PongMsg;

export function makerAuthMessage(address: Address, nonce: string, relayId: string): string {
  return `Blockroom relay login\nrelay: ${relayId}\naddress: ${address.toLowerCase()}\nnonce: ${nonce}`;
}
