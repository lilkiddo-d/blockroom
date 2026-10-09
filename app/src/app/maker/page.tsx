"use client";
import { useEffect, useRef, useState } from "react";
import { useAccount, useReadContract, useReadContracts, useSignMessage, useSignTypedData } from "wagmi";
import { zeroAddress, type Address } from "viem";
import { STOCKS } from "@blockroom/config/chains";
import { MakerSide, TimeInForce, quoteDomain, quoteTypes, toWire, type Quote, type RfqRequest, type ServerMsg } from "@blockroom/config";
import { makerRegistryAbi, settlementAbi } from "@blockroom/config/abis";
import { CHAIN_ID, DEPLOYMENT, PROJECT_TOKEN, RELAY_URLS, TOKEN_FEATURES } from "@/lib/config";
import { approveArgs, useNow, useTokenState, useTx } from "@/lib/hooks";
import { fmtShares, fmtUsd, parseShares, parseUsd, shortAddr } from "@/lib/format";
import { KV, RequireDeployment, TxStatus } from "@/components/common";

export default function MakerPage() {
  return (
    <>
      <h1>Maker console</h1>
      <p className="sub">
        Post a bond, answer RFQs with signed firm quotes, and manage your outstanding quotes. Failing to honour a
        signed quote before it expires is slashed from your bond and paid to the taker.
      </p>
      <RequireDeployment>
        <Console />
      </RequireDeployment>
    </>
  );
}

type MakerInfo = {
  registered: boolean;
  suspended: boolean;
  defaults: number;
  unlockTime: bigint;
  stableBond: bigint;
  projectBond: bigint;
  pendingStable: bigint;
  pendingProject: bigint;
};

function Console() {
  const d = DEPLOYMENT!;
  const { address } = useAccount();
  const reads = useReadContracts({
    contracts: [
      { address: d.MakerRegistry, abi: makerRegistryAbi, functionName: "makerInfo", args: [address ?? zeroAddress] },
      { address: d.MakerRegistry, abi: makerRegistryAbi, functionName: "canQuote", args: [address ?? zeroAddress] },
      { address: d.MakerRegistry, abi: makerRegistryAbi, functionName: "minBond" },
      { address: d.MakerRegistry, abi: makerRegistryAbi, functionName: "slashableValue", args: [address ?? zeroAddress] },
      { address: d.MakerRegistry, abi: makerRegistryAbi, functionName: "unbondingPeriod" },
      { address: d.Settlement, abi: settlementAbi, functionName: "minNonce", args: [address ?? zeroAddress] },
      { address: d.Settlement, abi: settlementAbi, functionName: "slashBps" },
    ],
    query: { enabled: !!address, refetchInterval: 8_000 },
  });
  const info = reads.data?.[0]?.result as MakerInfo | undefined;
  const canQuote = reads.data?.[1]?.result as boolean | undefined;
  const minBond = (reads.data?.[2]?.result as bigint | undefined) ?? 0n;
  const slashable = (reads.data?.[3]?.result as bigint | undefined) ?? 0n;
  const unbonding = Number((reads.data?.[4]?.result as bigint | undefined) ?? 0n);
  const minNonce = (reads.data?.[5]?.result as bigint | undefined) ?? 0n;
  const slashBps = Number(reads.data?.[6]?.result ?? 0);
  const refresh = () => void reads.refetch();

  if (!address) return <div className="panel empty">Connect a wallet to manage your maker account.</div>;

  return (
    <div className="grid grid-side">
      <div className="stack">
        <div className="panel stack">
          <h2>Status</h2>
          <KV
            k="Eligible to quote"
            v={canQuote ? <span className="badge ok">yes</span> : <span className="badge bad">{info?.registered ? (info.suspended ? "suspended" : "bond too low") : "not registered"}</span>}
          />
          <KV k="Active bond" v={`${fmtUsd(info?.stableBond ?? 0n)} USDG`} />
          {TOKEN_FEATURES && <KV k="Project-token bond" v={fmtShares(info?.projectBond ?? 0n)} />}
          <KV k="Slashable (incl. pending)" v={`${fmtUsd(slashable)} USDG`} />
          <KV k="Minimum bond" v={`${fmtUsd(minBond)} USDG`} />
          <KV k="Slash on default" v={`${slashBps / 100}% of notional`} />
          <KV k="Defaults" v={info?.defaults ?? 0} />
          {info && (info.pendingStable > 0n || info.pendingProject > 0n) && (
            <KV k="Unbonding" v={`${fmtUsd(info.pendingStable)} USDG until ${new Date(Number(info.unlockTime) * 1000).toLocaleString()}`} />
          )}
        </div>
        <BondPanel info={info} unbonding={unbonding} refresh={refresh} />
        <NoncePanel minNonce={minNonce} refresh={refresh} />
      </div>
      <ManualQuoting eligible={!!canQuote} maker={address} />
    </div>
  );
}

function BondPanel({ info, unbonding, refresh }: { info?: MakerInfo; unbonding: number; refresh: () => void }) {
  const d = DEPLOYMENT!;
  const [amt, setAmt] = useState("");
  const [projAmt, setProjAmt] = useState("");
  const usdg = useTokenState(d.USDG, d.MakerRegistry);
  const proj = useTokenState(PROJECT_TOKEN, d.MakerRegistry);
  const tx = useTx();
  const amount = parseUsd(amt);
  const projAmount = parseShares(projAmt);
  const now = useNow(5000);
  const run = async (p: Parameters<typeof tx.send>[0]) => (await tx.send(p), refresh(), usdg.refetch(), proj.refetch());

  if (!info?.registered) {
    return (
      <div className="panel stack">
        <h2>Register</h2>
        <p className="small muted">Registration is free; you become eligible to quote once your bond reaches the minimum.</p>
        <button className="btn" onClick={() => run({ address: d.MakerRegistry, abi: makerRegistryAbi, functionName: "register" })}>
          Register as maker
        </button>
        <TxStatus tx={tx} />
      </div>
    );
  }
  const unlocked = info.unlockTime > 0n && now / 1000 >= Number(info.unlockTime);
  return (
    <div className="panel stack">
      <h2>Bond</h2>
      <span className="small muted">Wallet: {fmtUsd(usdg.balance ?? 0n)} USDG</span>
      <input placeholder="USDG amount" value={amt} onChange={(e) => setAmt(e.target.value)} />
      <div className="row">
        {usdg.allowance !== undefined && amount && usdg.allowance < amount ? (
          <button className="btn" onClick={() => run(approveArgs(d.USDG, d.MakerRegistry))}>Approve USDG</button>
        ) : (
          <button className="btn" disabled={!amount} onClick={() => run({ address: d.MakerRegistry, abi: makerRegistryAbi, functionName: "depositBond", args: [amount!] })}>
            Deposit
          </button>
        )}
        <button className="btn ghost" disabled={!amount} onClick={() => run({ address: d.MakerRegistry, abi: makerRegistryAbi, functionName: "requestWithdrawal", args: [amount!, 0n] })}>
          Request withdrawal
        </button>
      </div>
      {TOKEN_FEATURES && PROJECT_TOKEN && (
        <>
          <input placeholder="Project token amount" value={projAmt} onChange={(e) => setProjAmt(e.target.value)} />
          <div className="row">
            {proj.allowance !== undefined && projAmount && proj.allowance < projAmount ? (
              <button className="btn" onClick={() => run(approveArgs(PROJECT_TOKEN!, d.MakerRegistry))}>Approve token</button>
            ) : (
              <button className="btn" disabled={!projAmount} onClick={() => run({ address: d.MakerRegistry, abi: makerRegistryAbi, functionName: "depositProjectBond", args: [projAmount!] })}>
                Bond project token
              </button>
            )}
            <button className="btn ghost" disabled={!projAmount} onClick={() => run({ address: d.MakerRegistry, abi: makerRegistryAbi, functionName: "requestWithdrawal", args: [0n, projAmount!] })}>
              Unbond token
            </button>
          </div>
        </>
      )}
      {(info.pendingStable > 0n || info.pendingProject > 0n) && (
        <div className="row">
          <button className="btn" disabled={!unlocked} onClick={() => run({ address: d.MakerRegistry, abi: makerRegistryAbi, functionName: "completeWithdrawal" })}>
            Complete withdrawal
          </button>
          <button className="btn ghost" onClick={() => run({ address: d.MakerRegistry, abi: makerRegistryAbi, functionName: "cancelWithdrawal" })}>
            Cancel withdrawal
          </button>
        </div>
      )}
      <p className="small muted">
        Withdrawals unbond for {Math.round(unbonding / 3600)}h and remain slashable until completed, so open quotes stay backed.
      </p>
      <TxStatus tx={tx} />
    </div>
  );
}

function NoncePanel({ minNonce, refresh }: { minNonce: bigint; refresh: () => void }) {
  const d = DEPLOYMENT!;
  const [nonce, setNonce] = useState("");
  const tx = useTx();
  return (
    <div className="panel stack">
      <h2>Cancel quotes</h2>
      <KV k="Min valid nonce" v={minNonce.toString()} />
      <div className="row">
        <input placeholder="nonce" value={nonce} onChange={(e) => setNonce(e.target.value)} style={{ flex: 1 }} />
        <button className="btn ghost" disabled={!/^\d+$/.test(nonce)} onClick={async () => (await tx.send({ address: d.Settlement, abi: settlementAbi, functionName: "invalidateNonce", args: [BigInt(nonce)] }), refresh())}>
          Cancel one
        </button>
      </div>
      <button
        className="btn danger"
        onClick={async () => (await tx.send({ address: d.Settlement, abi: settlementAbi, functionName: "setMinNonce", args: [BigInt(Date.now()) * 1000n] }), refresh())}
      >
        Cancel ALL outstanding quotes
      </button>
      <TxStatus tx={tx} />
    </div>
  );
}

/** Manual RFQ responder: authenticates to the relay with a wallet signature and signs quotes in-wallet. */
function ManualQuoting({ eligible, maker }: { eligible: boolean; maker: Address }) {
  const d = DEPLOYMENT!;
  const [state, setState] = useState<"idle" | "connecting" | "ready" | "error">("idle");
  const [rfqs, setRfqs] = useState<RfqRequest[]>([]);
  const [err, setErr] = useState<string | null>(null);
  const ws = useRef<WebSocket | null>(null);
  const { signMessageAsync } = useSignMessage();
  const { signTypedDataAsync } = useSignTypedData();
  const now = useNow(1000);
  const ttl = useReadContract({ address: d.Settlement, abi: settlementAbi, functionName: "maxQuoteTtl" });

  useEffect(() => () => ws.current?.close(), []);

  function connect() {
    setState("connecting");
    const s = new WebSocket(RELAY_URLS[0]);
    ws.current = s;
    s.onopen = () => s.send(JSON.stringify({ type: "hello", role: "maker", address: maker }));
    s.onclose = () => setState("idle");
    s.onmessage = async (ev) => {
      const m = JSON.parse(String(ev.data)) as ServerMsg;
      if (m.type === "challenge") {
        try {
          const signature = await signMessageAsync({ message: m.message });
          s.send(JSON.stringify({ type: "auth", address: maker, signature }));
        } catch {
          setState("error");
          s.close();
        }
      } else if (m.type === "ready") setState("ready");
      else if (m.type === "rfq") setRfqs((r) => [m.rfq, ...r].slice(0, 20));
      else if (m.type === "error") setErr(m.message);
    };
  }

  async function respond(rfq: RfqRequest, side: MakerSide, priceStr: string, sizeStr: string) {
    const price = parseUsd(priceStr);
    const size = parseShares(sizeStr);
    if (!price || !size || !ws.current) return;
    const q: Quote = {
      rfqId: rfq.rfqId,
      maker,
      taker: rfq.taker ?? zeroAddress,
      baseToken: rfq.baseToken,
      quoteToken: rfq.quoteToken,
      side,
      tif: TimeInForce.GTD,
      price,
      size,
      minFill: 0n,
      nonce: BigInt(Date.now()) * 1000n + BigInt(Math.floor(Math.random() * 1000)),
      expiry: BigInt(Math.floor(Date.now() / 1000) + Math.min(60, Number(ttl.data ?? 60))),
    };
    const signature = await signTypedDataAsync({ domain: quoteDomain(CHAIN_ID, d.Settlement), types: quoteTypes, primaryType: "Quote", message: q });
    ws.current.send(JSON.stringify({ type: "quote", quote: toWire(q), signature }));
  }

  return (
    <div className="panel stack">
      <div className="spread">
        <h2>Live RFQs</h2>
        {state === "ready" ? <span className="badge ok">connected</span> : (
          <button className="btn small" disabled={!eligible || state === "connecting"} onClick={connect}>
            {eligible ? "Connect to relay" : "Bond to quote"}
          </button>
        )}
      </div>
      <p className="small muted">
        For automated quoting run the reference bot (<span className="mono">pnpm mm-bot</span>). Here you can answer
        RFQs by hand; each quote is signed in your wallet (EIP-712) and is firm until expiry.
      </p>
      {err && <div className="notice err">{err}</div>}
      {rfqs.filter((r) => r.deadline > now).length === 0 ? (
        <div className="empty">{state === "ready" ? "Waiting for requests…" : "Not connected."}</div>
      ) : (
        rfqs.filter((r) => r.deadline > now).map((r) => <RfqRow key={r.rfqId} rfq={r} now={now} onQuote={respond} />)
      )}
    </div>
  );
}

function RfqRow({ rfq, now, onQuote }: { rfq: RfqRequest; now: number; onQuote: (r: RfqRequest, s: MakerSide, p: string, sz: string) => void }) {
  const sym = STOCKS.find((s) => s.address.toLowerCase() === rfq.baseToken.toLowerCase())?.symbol ?? shortAddr(rfq.baseToken);
  const [bid, setBid] = useState("");
  const [ask, setAsk] = useState("");
  const [size, setSize] = useState(fmtShares(BigInt(rfq.size), 18).replace(/,/g, ""));
  return (
    <div className="panel stack" style={{ background: "var(--panel-2)" }}>
      <div className="spread">
        <span className="mono">
          {rfq.side.toUpperCase()} {fmtShares(BigInt(rfq.size))} {sym}
        </span>
        <span className="small muted">{Math.max(0, Math.floor((rfq.deadline - now) / 1000))}s</span>
      </div>
      <div className="row">
        <input style={{ width: 110 }} value={size} onChange={(e) => setSize(e.target.value)} placeholder="size" />
        {rfq.side !== "buy" && (
          <>
            <input style={{ width: 110 }} value={bid} onChange={(e) => setBid(e.target.value)} placeholder="bid" />
            <button className="btn small" onClick={() => onQuote(rfq, MakerSide.MakerBuys, bid, size)}>Send bid</button>
          </>
        )}
        {rfq.side !== "sell" && (
          <>
            <input style={{ width: 110 }} value={ask} onChange={(e) => setAsk(e.target.value)} placeholder="ask" />
            <button className="btn small" onClick={() => onQuote(rfq, MakerSide.MakerSells, ask, size)}>Send ask</button>
          </>
        )}
      </div>
    </div>
  );
}
