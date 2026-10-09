// Stub for @coinbase/cdp-sdk, which @base-org/account imports only for its server-side "subscription owner
// wallet" feature (and which in turn pulls optional x402 payment packages). Blockroom never uses it.
export class CdpClient {
  constructor() {
    throw new Error("CdpClient is not available in Blockroom");
  }
}
export default {};
