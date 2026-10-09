import { getAddress, isAddress, type Address } from "viem";
import { blockroomFork, robinhoodChain, FORK_CHAIN_ID, ROBINHOOD_CHAIN_ID } from "@blockroom/config/chains";
import { DEPLOYMENTS } from "@/generated/deployments";
import type { Deployment } from "./deployments-type";

export const CHAIN_ID = Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? ROBINHOOD_CHAIN_ID);
export const CHAIN = CHAIN_ID === FORK_CHAIN_ID ? blockroomFork : robinhoodChain;
export const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL || CHAIN.rpcUrls.default.http[0];

export const RELAY_URLS = (process.env.NEXT_PUBLIC_RELAY_URLS ?? "ws://localhost:8787")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

export const KEEPER_URL = process.env.NEXT_PUBLIC_KEEPER_URL ?? "";
export const WALLETCONNECT_PROJECT_ID = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID ?? "";

/** $BLKR. Empty / invalid => every token feature is hidden. See TOKEN_INTEGRATION.md. */
const rawToken = (process.env.NEXT_PUBLIC_PROJECT_TOKEN ?? "").trim();
export const PROJECT_TOKEN: Address | undefined = isAddress(rawToken) ? getAddress(rawToken) : undefined;
export const TOKEN_FEATURES = PROJECT_TOKEN !== undefined;

export const DEPLOYMENT: Deployment | undefined = DEPLOYMENTS[String(CHAIN_ID)];
export const EXPLORER = CHAIN.blockExplorers?.default.url;

export function explorerTx(hash: string) {
  return EXPLORER ? `${EXPLORER}/tx/${hash}` : undefined;
}
export function explorerAddress(a: string) {
  return EXPLORER ? `${EXPLORER}/address/${a}` : undefined;
}
