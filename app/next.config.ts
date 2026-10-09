import type { NextConfig } from "next";

// @base-org/account (via RainbowKit's Base wallet connector) imports @coinbase/cdp-sdk for a server-side
// subscription feature that drags in optional x402 packages. Blockroom never uses it, so it resolves to a stub.
const OPTIONAL_STUBS = ["@coinbase/cdp-sdk"];
const stub = "./src/lib/empty-module.js";

const nextConfig: NextConfig = {
  turbopack: {
    resolveAlias: Object.fromEntries(OPTIONAL_STUBS.map((m) => [m, stub])),
  },
  webpack: (config) => {
    config.resolve.alias = { ...config.resolve.alias, ...Object.fromEntries(OPTIONAL_STUBS.map((m) => [m, false])) };
    return config;
  },
  reactStrictMode: true,
  transpilePackages: ["@blockroom/config"],
  poweredByHeader: false,
  async headers() {
    return [
      {
        source: "/(.*)",
        headers: [
          { key: "X-Frame-Options", value: "DENY" },
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
          { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=()" },
        ],
      },
    ];
  },
};

export default nextConfig;
