"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { TOKEN_FEATURES } from "@/lib/config";
import { MarketStatus } from "./MarketStatus";

const LINKS = [
  { href: "/rfq", label: "Request quote" },
  { href: "/midpoint", label: "Midpoint" },
  { href: "/maker", label: "Maker console" },
  { href: "/history", label: "History" },
  ...(TOKEN_FEATURES ? [{ href: "/stake", label: "Stake" }] : []),
  { href: "/risk", label: "Risk" },
];

export function Nav() {
  const path = usePathname();
  return (
    <nav className="nav">
      <Link href="/" className="brand">
        <span className="brand-mark" aria-hidden /> Blockroom
      </Link>
      <div className="nav-links">
        {LINKS.map((l) => (
          <Link key={l.href} href={l.href} className={path?.startsWith(l.href) ? "active" : ""}>
            {l.label}
          </Link>
        ))}
      </div>
      <MarketStatus />
      <ConnectButton chainStatus="icon" showBalance={false} accountStatus="address" />
    </nav>
  );
}
