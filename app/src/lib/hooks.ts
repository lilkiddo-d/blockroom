"use client";
import { useCallback, useEffect, useState } from "react";
import { useAccount, usePublicClient, useReadContract, useWriteContract } from "wagmi";
import { erc20Abi, maxUint256, type Address, type Hash, type TransactionReceipt } from "viem";
import { marketClockAbi, priceGuardAbi } from "@blockroom/config/abis";
import { DEPLOYMENT, explorerTx } from "./config";

export type TxState = { status: "idle" | "signing" | "pending" | "success" | "error"; hash?: Hash; error?: string };

/** writeContract + wait for receipt with a simple status machine. */
export function useTx() {
  const { writeContractAsync } = useWriteContract();
  const client = usePublicClient();
  const [state, setState] = useState<TxState>({ status: "idle" });

  const send = useCallback(
    async (req: Parameters<typeof writeContractAsync>[0]): Promise<TransactionReceipt | undefined> => {
      try {
        setState({ status: "signing" });
        const hash = await writeContractAsync(req);
        setState({ status: "pending", hash });
        const receipt = await client!.waitForTransactionReceipt({ hash });
        setState({
          status: receipt.status === "success" ? "success" : "error",
          hash,
          error: receipt.status === "success" ? undefined : "transaction reverted",
        });
        return receipt;
      } catch (e) {
        const err = e as { shortMessage?: string; message?: string };
        setState({ status: "error", error: err.shortMessage ?? err.message ?? "failed" });
        return undefined;
      }
    },
    [writeContractAsync, client],
  );
  return { ...state, send, reset: () => setState({ status: "idle" }), link: state.hash ? explorerTx(state.hash) : undefined };
}

export function useMid(base?: Address) {
  return useReadContract({
    address: DEPLOYMENT?.PriceGuard,
    abi: priceGuardAbi,
    functionName: "getMid",
    args: base && DEPLOYMENT ? [base, DEPLOYMENT.USDG] : undefined,
    query: { enabled: !!base && !!DEPLOYMENT, refetchInterval: 5_000, retry: false },
  });
}

export function useMarketOpen() {
  return useReadContract({
    address: DEPLOYMENT?.MarketClock,
    abi: marketClockAbi,
    functionName: "isOpen",
    query: { enabled: !!DEPLOYMENT, refetchInterval: 30_000 },
  });
}

export function useTokenState(token?: Address, spender?: Address) {
  const { address } = useAccount();
  const balance = useReadContract({
    address: token,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!token && !!address, refetchInterval: 8_000 },
  });
  const allowance = useReadContract({
    address: token,
    abi: erc20Abi,
    functionName: "allowance",
    args: address && spender ? [address, spender] : undefined,
    query: { enabled: !!token && !!address && !!spender, refetchInterval: 8_000 },
  });
  return {
    balance: balance.data,
    allowance: allowance.data,
    refetch: () => {
      void balance.refetch();
      void allowance.refetch();
    },
  };
}

export function approveArgs(token: Address, spender: Address) {
  return { address: token, abi: erc20Abi, functionName: "approve" as const, args: [spender, maxUint256] as const };
}

export function useNow(intervalMs = 1000) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(id);
  }, [intervalMs]);
  return now;
}
