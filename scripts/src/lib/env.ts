import { readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, http, type Address, type Chain } from "viem";
import { blockroomFork, robinhoodChain, FORK_CHAIN_ID, ROBINHOOD_CHAIN_ID } from "@blockroom/config/chains";

export const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");

/** Minimal .env loader (no dependency): KEY=VALUE lines, existing process.env wins. */
export function loadDotEnv(file = join(repoRoot, ".env")) {
  if (!existsSync(file)) return;
  for (const line of readFileSync(file, "utf8").split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (!m || line.trim().startsWith("#")) continue;
    if (process.env[m[1]] === undefined) process.env[m[1]] = m[2].replace(/^['"]|['"]$/g, "");
  }
}

export function env(name: string, fallback?: string): string {
  const v = process.env[name] ?? fallback;
  if (v === undefined || v === "") throw new Error(`missing env ${name}`);
  return v;
}

export function envNum(name: string, fallback: number): number {
  const v = process.env[name];
  return v === undefined || v === "" ? fallback : Number(v);
}

export type Deployment = {
  chainId: number;
  deployedAtBlock: number;
  Timelock: Address;
  OracleAdapter: Address;
  PriceGuard: Address;
  MarketClock: Address;
  ComplianceRegistry: Address;
  ProjectTokenHooks: Address;
  FeeCollector: Address;
  MakerRegistry: Address;
  Settlement: Address;
  MidpointPool: Address;
  USDG: Address;
};

export function loadDeployment(chainId: number): Deployment {
  const file = join(repoRoot, "contracts", "deployments", `${chainId}.json`);
  if (!existsSync(file)) {
    throw new Error(`no deployment record at ${file} - run script/Deploy.s.sol (see DEPLOY.md)`);
  }
  return JSON.parse(readFileSync(file, "utf8")) as Deployment;
}

export function chainFor(chainId: number): Chain {
  if (chainId === ROBINHOOD_CHAIN_ID) return robinhoodChain;
  if (chainId === FORK_CHAIN_ID) return blockroomFork;
  throw new Error(`unsupported chain ${chainId}`);
}

export function makePublicClient(chainId: number, rpcUrl: string) {
  return createPublicClient({ chain: chainFor(chainId), transport: http(rpcUrl) });
}

export function log(scope: string, msg: string, extra?: Record<string, unknown>) {
  const line = { t: new Date().toISOString(), scope, msg, ...(extra ?? {}) };
  console.log(JSON.stringify(line, (_k, v) => (typeof v === "bigint" ? v.toString() : v)));
}
