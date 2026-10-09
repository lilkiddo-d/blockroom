import { NextResponse, type NextRequest } from "next/server";

/**
 * Optional frontend geoblock (OFF unless GEOBLOCK_COUNTRIES is set, e.g. "US,CU,IR,KP,SY").
 * Uses the edge geo header set by Vercel (x-vercel-ip-country) or Cloudflare (cf-ipcountry).
 * This only gates the hosted UI; on-chain gating is the ComplianceRegistry hook.
 */
const BLOCKED = new Set(
  (process.env.GEOBLOCK_COUNTRIES ?? "")
    .split(",")
    .map((s) => s.trim().toUpperCase())
    .filter(Boolean),
);

export function proxy(req: NextRequest) {
  if (BLOCKED.size === 0) return NextResponse.next();
  const country = (req.headers.get("x-vercel-ip-country") ?? req.headers.get("cf-ipcountry") ?? "").toUpperCase();
  if (country && BLOCKED.has(country) && !req.nextUrl.pathname.startsWith("/blocked") && !req.nextUrl.pathname.startsWith("/risk")) {
    const url = req.nextUrl.clone();
    url.pathname = "/blocked";
    return NextResponse.redirect(url);
  }
  return NextResponse.next();
}

export const config = { matcher: ["/((?!_next/|favicon.ico).*)"] };
