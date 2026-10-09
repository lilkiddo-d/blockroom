import type { Address } from "viem";

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
  deployer?: Address;
  guardian?: Address;
  keeper?: Address;
  proposer?: Address;
  treasury?: Address;
};
