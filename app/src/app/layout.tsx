import type { Metadata } from "next";
import Link from "next/link";
import type { ReactNode } from "react";
import "./globals.css";
import { Providers } from "./providers";
import { Nav } from "@/components/Nav";

export const metadata: Metadata = {
  title: "Blockroom — block trading desk",
  description: "RFQ and midpoint crossing for large blocks of tokenized stocks.",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>
          <Nav />
          <main className="container">{children}</main>
          <footer className="footer">
            <span>Blockroom is non-custodial software. Trading tokenized equities involves substantial risk.</span>
            <Link href="/risk">Risk disclosure</Link>
          </footer>
        </Providers>
      </body>
    </html>
  );
}
