import Link from "next/link";
import { HomeStats } from "@/components/HomeStats";

export default function Home() {
  return (
    <div className="stack" style={{ gap: 24 }}>
      <div>
        <h1 style={{ fontSize: 30 }}>Trade size without moving the price.</h1>
        <p className="sub" style={{ maxWidth: 720 }}>
          Blockroom is a block-trading desk for tokenized stocks. Request firm quotes from bonded market makers, or rest
          hidden orders that only cross at the oracle midpoint. Everything settles atomically on-chain.
        </p>
      </div>
      <div className="grid grid-3">
        <Link href="/rfq" className="panel stack" style={{ color: "inherit" }}>
          <h2>Request for quote →</h2>
          <span className="muted">
            Competing signed quotes stream in from bonded makers. Settlement rejects any quote too far from the oracle mid.
          </span>
        </Link>
        <Link href="/midpoint" className="panel stack" style={{ color: "inherit" }}>
          <h2>Midpoint cross →</h2>
          <span className="muted">
            Commit hidden orders; batches match only at the oracle mid during market hours. Reveal happens only to settle.
          </span>
        </Link>
        <Link href="/maker" className="panel stack" style={{ color: "inherit" }}>
          <h2>Make markets →</h2>
          <span className="muted">Post a bond, answer RFQs, and earn spread. Reneging on a signed quote is slashed.</span>
        </Link>
      </div>
      <HomeStats />
    </div>
  );
}
