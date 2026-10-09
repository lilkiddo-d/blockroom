"use client";
import { useEffect, useMemo, useState } from "react";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import type { Address } from "viem";
import { STOCKS, type StockToken } from "@blockroom/config/chains";
import { midpointPoolAbi } from "@blockroom/config/abis";
import { CHAIN_ID, DEPLOYMENT, KEEPER_URL } from "@/lib/config";
import { approveArgs, useMarketOpen, useMid, useNow, useTokenState, useTx } from "@/lib/hooks";
import { fmtShares, fmtUsd, parseShares, parseUsd } from "@/lib/format";
import { fromStored, hashOrder, loadOrders, randomSalt, saveOrders, toStored, type StoredOrder } from "@/lib/midpoint";
import { KV, RequireDeployment, Segmented, StockPicker, TxStatus } from "@/components/common";

const STATUS = ["—", "Committed", "Revealed", "Cancelled", "Forfeited"];

export default function MidpointPage() {
  return (
    <>
      <h1>Midpoint cross</h1>
      <p className="sub">
        Hidden orders that only ever execute at the oracle midpoint, in periodic batches during US market hours.
        Orders are committed as hashes and revealed only to settle; nobody can see your side or size while the batch
        is open.
      </p>
      <RequireDeployment>
        <Midpoint />
      </RequireDeployment>
    </>
  );
}

function Midpoint() {
  const d = DEPLOYMENT!;
  const { address } = useAccount();
  const now = useNow(1000);
  const [stock, setStock] = useState<StockToken>(STOCKS[0]);
  const mid = useMid(stock.address);
  const open = useMarketOpen();
  const windows = useReadContract({
    address: d.MidpointPool,
    abi: midpointPoolAbi,
    functionName: "currentWindows",
    query: { refetchInterval: 5_000 },
  });
  const params = useReadContracts({
    contracts: [
      { address: d.MidpointPool, abi: midpointPoolAbi, functionName: "commitBond" },
      { address: d.MidpointPool, abi: midpointPoolAbi, functionName: "feeBps" },
    ],
  });
  const commitBond = (params.data?.[0]?.result as bigint | undefined) ?? 0n;
  const feeBps = Number((params.data?.[1]?.result as number | bigint | undefined) ?? 0);

  const [cid, commitEnd] = windows.data ?? [0n, 0n, 0n, 0n];
  const secsLeft = Math.max(0, Number(commitEnd) - Math.floor(now / 1000));

  return (
    <div className="grid grid-side">
      <div className="stack">
        <div className="panel stack">
          <h2>Batch</h2>
          <KV k="Market" v={open.data ? <span className="buy">open</span> : <span className="sell">closed</span>} />
          <KV k="Current batch" v={`#${cid.toString()}`} />
          <KV k="Commit window closes in" v={`${Math.floor(secsLeft / 60)}m ${secsLeft % 60}s`} />
          <KV k="Commit bond" v={`${fmtUsd(commitBond)} USDG`} />
          <KV k="Fee" v={`${feeBps} bps`} />
          <KV k={`${stock.symbol} oracle mid`} v={mid.data ? `$${fmtUsd(mid.data, 6, 4)}` : "…"} />
        </div>
        <Ledger stock={stock} />
      </div>
      <div className="stack">
        <OrderEntry stock={stock} setStock={setStock} commitBond={commitBond} marketOpen={!!open.data} />
        {address && <MyOrders trader={address} />}
      </div>
    </div>
  );
}

function Ledger({ stock }: { stock: StockToken }) {
  const d = DEPLOYMENT!;
  const { address } = useAccount();
  const [token, setToken] = useState<"usdg" | "stock">("usdg");
  const [amt, setAmt] = useState("");
  const tokenAddr: Address = token === "usdg" ? d.USDG : stock.address;
  const wallet = useTokenState(tokenAddr, d.MidpointPool);
  const bals = useReadContracts({
    contracts: [
      { address: d.MidpointPool, abi: midpointPoolAbi, functionName: "freeBalance", args: [address!, d.USDG] },
      { address: d.MidpointPool, abi: midpointPoolAbi, functionName: "freeBalance", args: [address!, stock.address] },
    ],
    query: { enabled: !!address, refetchInterval: 6_000 },
  });
  const amount = token === "usdg" ? parseUsd(amt) : parseShares(amt);
  const tx = useTx();
  const refresh = () => (wallet.refetch(), void bals.refetch());

  return (
    <div className="panel stack">
      <h2>Pool balance</h2>
      <p className="small muted">
        Fund your pool balance ahead of time — deposits are not linked to orders, so they don&apos;t reveal intent.
      </p>
      <KV k="USDG available" v={fmtUsd((bals.data?.[0]?.result as bigint) ?? 0n)} />
      <KV k={`${stock.symbol} available`} v={fmtShares((bals.data?.[1]?.result as bigint) ?? 0n)} />
      <Segmented value={token} onChange={setToken} options={[{ value: "usdg", label: "USDG" }, { value: "stock", label: stock.symbol }]} />
      <input placeholder="Amount" value={amt} onChange={(e) => setAmt(e.target.value)} />
      <div className="row">
        {wallet.allowance !== undefined && amount && wallet.allowance < amount ? (
          <button className="btn" onClick={async () => (await tx.send(approveArgs(tokenAddr, d.MidpointPool)), refresh())}>
            Approve
          </button>
        ) : (
          <button
            className="btn"
            disabled={!amount}
            onClick={async () => (await tx.send({ address: d.MidpointPool, abi: midpointPoolAbi, functionName: "deposit", args: [tokenAddr, amount!] }), refresh())}
          >
            Deposit
          </button>
        )}
        <button
          className="btn ghost"
          disabled={!amount}
          onClick={async () => (await tx.send({ address: d.MidpointPool, abi: midpointPoolAbi, functionName: "withdraw", args: [tokenAddr, amount!] }), refresh())}
        >
          Withdraw
        </button>
      </div>
      <TxStatus tx={tx} />
    </div>
  );
}

function OrderEntry({
  stock,
  setStock,
  commitBond,
  marketOpen,
}: {
  stock: StockToken;
  setStock: (s: StockToken) => void;
  commitBond: bigint;
  marketOpen: boolean;
}) {
  const d = DEPLOYMENT!;
  const { address } = useAccount();
  const [side, setSide] = useState<"buy" | "sell">("buy");
  const [tif, setTif] = useState<"ioc" | "fok">("ioc");
  const [size, setSize] = useState("1000");
  const [minFill, setMinFill] = useState("");
  const [limit, setLimit] = useState("");
  const [delegate, setDelegate] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const tx = useTx();
  const batch = useReadContract({ address: d.MidpointPool, abi: midpointPoolAbi, functionName: "currentBatchId", query: { refetchInterval: 5_000 } });

  async function commit() {
    const sz = parseShares(size);
    const lim = limit ? parseUsd(limit) : 0n;
    if (!address || !sz || batch.data === undefined) return;
    if (side === "buy" && !lim) return setMsg("Buy orders need a limit price (max price you accept at mid).");
    const reveal = {
      trader: address,
      asset: stock.address,
      batchId: batch.data,
      side: side === "buy" ? 0 : 1,
      tif: tif === "ioc" ? 0 : 1,
      size: sz,
      minFill: parseShares(minFill) ?? 0n,
      limitPrice: lim ?? 0n,
      salt: randomSalt(),
    };
    const commitment = hashOrder(reveal);
    // persist the preimage BEFORE sending, so it can't be lost
    const stored = toStored(reveal, commitment, CHAIN_ID);
    saveOrders([...loadOrders(), stored]);
    const receipt = await tx.send({ address: d.MidpointPool, abi: midpointPoolAbi, functionName: "commit", args: [stock.address, commitment] });
    if (!receipt) return;
    setMsg(`Committed to batch #${batch.data}. Reveal after the commit window closes.`);
    if (delegate && KEEPER_URL) {
      const res = await fetch(`${KEEPER_URL}/reveal`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(stored.reveal),
      }).catch(() => undefined);
      const ok = res?.status === 202;
      saveOrders(loadOrders().map((o) => (o.commitment === commitment ? { ...o, delegated: ok } : o)));
      setMsg(ok ? "Committed; the keeper will reveal for you at the start of the reveal window." : "Committed, but the keeper did not accept the reveal — reveal it yourself.");
    }
    window.dispatchEvent(new Event("blockroom-orders"));
  }

  return (
    <div className="panel stack">
      <h2>New hidden order</h2>
      <div className="grid grid-2">
        <StockPicker value={stock} onChange={setStock} />
        <label>
          Side
          <Segmented value={side} onChange={setSide} options={[{ value: "buy", label: "Buy", tone: "buy" }, { value: "sell", label: "Sell", tone: "sell" }]} />
        </label>
        <label>
          Size (shares)
          <input value={size} onChange={(e) => setSize(e.target.value)} />
        </label>
        <label>
          Minimum fill per execution (optional)
          <input value={minFill} onChange={(e) => setMinFill(e.target.value)} placeholder="0" />
        </label>
        <label>
          {side === "buy" ? "Limit — max mid you accept (USDG)" : "Limit — min mid you accept (optional)"}
          <input value={limit} onChange={(e) => setLimit(e.target.value)} placeholder={side === "buy" ? "required" : "any"} />
        </label>
        <label>
          Time in force
          <Segmented value={tif} onChange={setTif} options={[{ value: "ioc", label: "IOC (this batch)" }, { value: "fok", label: "FOK (all or none)" }]} />
        </label>
      </div>
      {KEEPER_URL && (
        <label className="row" style={{ flexDirection: "row" }}>
          <input type="checkbox" checked={delegate} onChange={(e) => setDelegate(e.target.checked)} /> Let the keeper
          reveal for me (shares the order details with the keeper once the commit window closes)
        </label>
      )}
      <p className="small muted">
        Committing locks a {fmtUsd(commitBond)} USDG bond from your pool balance, refunded on reveal and forfeited if you
        never reveal. Buys lock size × limit (+ max fee) at reveal; unused funds are released at settlement.
      </p>
      <button className="btn" disabled={!address || !marketOpen || tx.status === "pending"} onClick={commit}>
        {marketOpen ? "Commit order" : "Market closed"}
      </button>
      <TxStatus tx={tx} />
      {msg && <div className="notice">{msg}</div>}
    </div>
  );
}

function MyOrders({ trader }: { trader: Address }) {
  const d = DEPLOYMENT!;
  const [orders, setOrders] = useState<StoredOrder[]>([]);
  const now = useNow(2000);
  const tx = useTx();
  useEffect(() => {
    const load = () => setOrders(loadOrders().filter((o) => o.chainId === CHAIN_ID && o.reveal.trader.toLowerCase() === trader.toLowerCase()));
    load();
    window.addEventListener("blockroom-orders", load);
    return () => window.removeEventListener("blockroom-orders", load);
  }, [trader, tx.status]);

  const recent = useMemo(() => orders.slice(-12).reverse(), [orders]);
  const infos = useReadContracts({
    contracts: recent.flatMap((o) => [
      { address: d.MidpointPool, abi: midpointPoolAbi, functionName: "commitInfo", args: [o.commitment] } as const,
      { address: d.MidpointPool, abi: midpointPoolAbi, functionName: "batchInfo", args: [o.reveal.asset as Address, BigInt(o.reveal.batchId)] } as const,
    ]),
    query: { refetchInterval: 6_000 },
  });
  const orderAts = useReadContracts({
    contracts: recent.map((o, i) => {
      const ci = infos.data?.[i * 2]?.result as readonly [Address, Address, bigint, number] | undefined;
      return { address: d.MidpointPool, abi: midpointPoolAbi, functionName: "orderAt", args: [o.reveal.asset as Address, BigInt(o.reveal.batchId), BigInt(ci?.[3] ?? 0)] } as const;
    }),
    query: { enabled: !!infos.data, refetchInterval: 6_000 },
  });

  if (recent.length === 0) return <div className="panel empty">No midpoint orders from this browser yet.</div>;
  const t = Math.floor(now / 1000);

  return (
    <div className="panel">
      <h2>My orders (this browser)</h2>
      <table>
        <thead>
          <tr>
            <th>Batch</th>
            <th>Order</th>
            <th>Status</th>
            <th>Filled</th>
            <th>Batch mid</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {recent.map((o, i) => {
            const b = infos.data?.[i * 2 + 1]?.result as
              | { commitEnd: bigint; revealEnd: bigint; settled: boolean; voided: boolean; mid: bigint }
              | undefined;
            const ord = orderAts.data?.[i]?.result as { status: number; filled: bigint } | undefined;
            const st = ord?.status ?? 0;
            const sym = STOCKS.find((s) => s.address.toLowerCase() === o.reveal.asset.toLowerCase())?.symbol;
            const inReveal = b && t >= Number(b.commitEnd) && t < Number(b.revealEnd);
            const canSettle = b && !b.settled && t >= Number(b.revealEnd);
            const inCommit = b && t < Number(b.commitEnd);
            return (
              <tr key={o.commitment}>
                <td>#{o.reveal.batchId}</td>
                <td className={o.reveal.side === 0 ? "buy" : "sell"}>
                  {o.reveal.side === 0 ? "BUY" : "SELL"} {fmtShares(BigInt(o.reveal.size))} {sym}
                </td>
                <td>
                  {b?.voided ? "Voided" : STATUS[st]}
                  {o.delegated && st === 1 ? " (keeper)" : ""}
                </td>
                <td>{ord ? fmtShares(ord.filled) : "—"}</td>
                <td>{b?.settled && !b.voided ? `$${fmtUsd(b.mid, 6, 4)}` : "—"}</td>
                <td className="row">
                  {st === 1 && inReveal && (
                    <button className="btn small" onClick={() => tx.send({ address: d.MidpointPool, abi: midpointPoolAbi, functionName: "reveal", args: [fromStored(o)] })}>
                      Reveal
                    </button>
                  )}
                  {st === 1 && inCommit && (
                    <button className="btn ghost small" onClick={() => tx.send({ address: d.MidpointPool, abi: midpointPoolAbi, functionName: "cancelCommit", args: [o.commitment] })}>
                      Cancel
                    </button>
                  )}
                  {canSettle && (
                    <button className="btn ghost small" onClick={() => tx.send({ address: d.MidpointPool, abi: midpointPoolAbi, functionName: "settle", args: [o.reveal.asset as Address, BigInt(o.reveal.batchId)] })}>
                      Settle
                    </button>
                  )}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
      <TxStatus tx={tx} />
    </div>
  );
}
