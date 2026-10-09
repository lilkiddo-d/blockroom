"use client";
import { useState } from "react";
import { notFound } from "next/navigation";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { zeroAddress } from "viem";
import { feeCollectorAbi, projectTokenHooksAbi } from "@blockroom/config/abis";
import { DEPLOYMENT, PROJECT_TOKEN, TOKEN_FEATURES } from "@/lib/config";
import { approveArgs, useNow, useTokenState, useTx } from "@/lib/hooks";
import { fmtShares, fmtUsd, parseShares } from "@/lib/format";
import { KV, RequireDeployment, TxStatus } from "@/components/common";

export default function StakePage() {
  if (!TOKEN_FEATURES) notFound();
  return (
    <>
      <h1>Stake</h1>
      <p className="sub">Stake the project token to share settlement fees and unlock taker fee discounts.</p>
      <RequireDeployment>
        <Stake />
      </RequireDeployment>
    </>
  );
}

function Stake() {
  const d = DEPLOYMENT!;
  const { address } = useAccount();
  const me = address ?? zeroAddress;
  const [amt, setAmt] = useState("");
  const amount = parseShares(amt);
  const tok = useTokenState(PROJECT_TOKEN, d.FeeCollector);
  const tx = useTx();
  const now = useNow(5000);
  const enabled = useReadContract({ address: d.ProjectTokenHooks, abi: projectTokenHooksAbi, functionName: "tokenEnabled" });
  const reads = useReadContracts({
    contracts: [
      { address: d.FeeCollector, abi: feeCollectorAbi, functionName: "stakedOf", args: [me] },
      { address: d.FeeCollector, abi: feeCollectorAbi, functionName: "unstaking", args: [me] },
      { address: d.FeeCollector, abi: feeCollectorAbi, functionName: "claimable", args: [me, d.USDG] },
      { address: d.FeeCollector, abi: feeCollectorAbi, functionName: "totalStaked" },
      { address: d.ProjectTokenHooks, abi: projectTokenHooksAbi, functionName: "feeDiscountBps", args: [me] },
      { address: d.ProjectTokenHooks, abi: projectTokenHooksAbi, functionName: "tiers" },
      { address: d.ProjectTokenHooks, abi: projectTokenHooksAbi, functionName: "stakerShareBps" },
    ],
    query: { refetchInterval: 8_000 },
  });
  const staked = (reads.data?.[0]?.result as bigint | undefined) ?? 0n;
  const unstaking = reads.data?.[1]?.result as readonly [bigint, bigint] | undefined;
  const claimable = (reads.data?.[2]?.result as bigint | undefined) ?? 0n;
  const total = (reads.data?.[3]?.result as bigint | undefined) ?? 0n;
  const discount = Number(reads.data?.[4]?.result ?? 0);
  const tiers = (reads.data?.[5]?.result as readonly { minStake: bigint; discountBps: number }[] | undefined) ?? [];
  const share = Number(reads.data?.[6]?.result ?? 0);
  const run = async (p: Parameters<typeof tx.send>[0]) => (await tx.send(p), void reads.refetch(), tok.refetch());

  if (enabled.data === false) {
    return <div className="notice">The project token has not been activated on-chain yet (pending Timelock).</div>;
  }
  return (
    <div className="grid grid-2">
      <div className="panel stack">
        <h2>Your stake</h2>
        <KV k="Wallet" v={fmtShares(tok.balance ?? 0n)} />
        <KV k="Staked" v={fmtShares(staked)} />
        <KV k="Share of pool" v={total ? `${((Number(staked) / Number(total)) * 100).toFixed(2)}%` : "—"} />
        <KV k="Claimable fees" v={`${fmtUsd(claimable)} USDG`} />
        <KV k="Your taker discount" v={`${discount / 100}%`} />
        <input placeholder="Amount" value={amt} onChange={(e) => setAmt(e.target.value)} />
        <div className="row">
          {tok.allowance !== undefined && amount && tok.allowance < amount ? (
            <button className="btn" onClick={() => run(approveArgs(PROJECT_TOKEN!, d.FeeCollector))}>Approve</button>
          ) : (
            <button className="btn" disabled={!amount} onClick={() => run({ address: d.FeeCollector, abi: feeCollectorAbi, functionName: "stake", args: [amount!] })}>
              Stake
            </button>
          )}
          <button className="btn ghost" disabled={!amount} onClick={() => run({ address: d.FeeCollector, abi: feeCollectorAbi, functionName: "requestUnstake", args: [amount!] })}>
            Unstake
          </button>
          <button className="btn ghost" disabled={!claimable} onClick={() => run({ address: d.FeeCollector, abi: feeCollectorAbi, functionName: "claim" })}>
            Claim
          </button>
        </div>
        {unstaking && unstaking[0] > 0n && (
          <div className="row">
            <span className="small muted">
              {fmtShares(unstaking[0])} unlocking {new Date(Number(unstaking[1]) * 1000).toLocaleString()}
            </span>
            <button className="btn small" disabled={now / 1000 < Number(unstaking[1])} onClick={() => run({ address: d.FeeCollector, abi: feeCollectorAbi, functionName: "withdrawUnstaked" })}>
              Withdraw
            </button>
          </div>
        )}
        <TxStatus tx={tx} />
      </div>
      <div className="panel stack">
        <h2>Program</h2>
        <KV k="Fee share to stakers" v={`${share / 100}%`} />
        <KV k="Total staked" v={fmtShares(total)} />
        {tiers.map((t, i) => (
          <KV key={i} k={`Tier ${i + 1}: ≥ ${fmtShares(t.minStake, 0)} staked`} v={`${t.discountBps / 100}% off taker fees`} />
        ))}
        <p className="small muted">Unstaking has a cooldown during which the stake earns nothing and gives no discount.</p>
      </div>
    </div>
  );
}
