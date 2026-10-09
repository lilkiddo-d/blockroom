"use client";
import { connectorsForWallets } from "@rainbow-me/rainbowkit";
import {
  coinbaseWallet,
  injectedWallet,
  metaMaskWallet,
  rainbowWallet,
  walletConnectWallet,
} from "@rainbow-me/rainbowkit/wallets";
import { createConfig, http } from "wagmi";
import type { Chain } from "viem";
import { CHAIN, RPC_URL, WALLETCONNECT_PROJECT_ID } from "./config";

const projectId = WALLETCONNECT_PROJECT_ID || "blockroom-injected-only";

const connectors = connectorsForWallets(
  [
    {
      groupName: "Wallets",
      wallets: WALLETCONNECT_PROJECT_ID
        ? [injectedWallet, metaMaskWallet, rainbowWallet, coinbaseWallet, walletConnectWallet]
        : [injectedWallet, coinbaseWallet],
    },
  ],
  { appName: "Blockroom", projectId },
);

const chain: Chain = CHAIN;

export const wagmiConfig = createConfig({
  chains: [chain],
  connectors,
  transports: { [chain.id]: http(RPC_URL) },
  ssr: true,
});
