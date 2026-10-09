# Threat model

Scope: `contracts/src/*`, the RFQ relay, the keeper, the market-maker bot and the web app. Assets at risk are taker and maker funds in transit, maker bonds, midpoint pool balances, staked project tokens, and protocol fees.

## Actors and trust

| Actor | Trust | Can do |
|---|---|---|
| Taker | untrusted | fill any signed quote addressed to them (or open quotes) |
| Maker | untrusted, bonded | sign quotes; bond can be slashed |
| Relay operator | untrusted | see RFQs, drop or delay messages. Cannot forge quotes or touch funds |
| Keeper | untrusted (permissionless role) | reveal delegated orders, call `settle`, push holidays (with `CALENDAR_ROLE`) |
| Guardian | semi-trusted, fast | pause/unpause, force-close the clock, suspend makers. Cannot move funds or change parameters |
| Timelock (admin) | trusted, slow (≥48h) | change parameters and modules, set the project token once, enable compliance |
| Compliance operator | semi-trusted | edit the allowlist (only matters if compliance is enabled) |
| Oracle (Chainlink) | trusted with bounds | supplies the mid; staleness, peg and deviation checks bound the damage |

## Top risks

### 1. Quote replay
*Threat:* a signed quote is filled twice, on another chain or deployment, or for more than its size.

*Mitigations:*
- The EIP-712 domain binds `chainId` and the `Settlement` address.
- `filled[digest]` caps cumulative fills at `size`.
- The nonce bitmap burns the quote when it is fully filled, on IOC/FOK, or on default.
- `minNonce` gives makers a bulk cancel, and `expiry ≤ now + maxQuoteTtl` (5 min) bounds every quote's lifetime.

*Evidence:* the invariant `invariant_neverOverfilled` held over 8,192 random calls with real fills (`test_handlerExercisesFills`); `testFuzz_neverOverfill`; `test_revert_replayFullFill`; `test_revert_sameNonceDifferentQuote`; `test_hashQuote_matchesExplicitEip712`.

### 2. Last-look abuse by makers
*Threat:* a maker signs a quote, watches the market, and reneges by moving inventory, revoking approval or withdrawing its bond when the fill arrives.

*Mitigations:*
- Before any transfer, Settlement checks both legs (balance + allowance). If the maker can't deliver, the quote is burned and the maker's bond is slashed `slashBps` (1%) of notional, paid to the taker. Reneging always costs money.
- The taker leg is checked first and must pass, so a taker without funds can't force slashes.
- Withdrawals unbond for 3 days (longer than any quote's lifetime) and stay slashable while pending. Pending bond also still counts toward eligibility, so a withdrawal can't be used to get a fill reverted.
- The guardian can suspend repeat offenders, and `defaults` is tracked per maker.
- The price guard reverts out-of-band fills without a slash. That protects makers from stale picks, but it can't be used to escape a fair in-band fill.

*Residual risk:* the slash is capped at the maker's slashable bond. For very large blocks, takers should prefer makers whose bond is large relative to size (bond and defaults are shown in the maker console and on-chain).

### 3. Relay censorship and manipulation
*Threat:* the relay drops RFQs or quotes, favours certain makers, or front-runs.

*Mitigations:*
- The relay is a convenience, not a custodian. It can't forge quotes (EIP-712, verified both in the browser and on-chain) or settle (takers call `Settlement.fill` from their own wallet).
- RFQs are fanned out to every authenticated maker; there is no selective routing in the reference relay.
- The app connects to multiple relays (`NEXT_PUBLIC_RELAY_URLS`) and merges the quote streams. Anyone can run a relay.
- Takers can compare the on-chain maker set (MakerRegistry events) with who responded.
- The designated-taker field (`quote.taker`) stops other parties from sniping a quote meant for the requester.

*Residual risk:* a single-relay deployment is a liveness single point of failure. Run at least two independent relays.

### 4. Information leakage from midpoint orders
*Threat:* other participants learn side, size or price intent and trade ahead.

*Mitigations:*
- Orders are committed as hashes; side, size and limit stay hidden until the commit window closes, and no new commits for that batch are possible after it closes.
- Funds sit in an internal ledger that is funded independently of orders, so deposits don't map one-to-one to orders.
- Delegated reveal hands the preimage to the keeper only after committing, and the keeper reveals at the start of the reveal window.
- Every execution in a batch prints at a single oracle mid read once at settlement, so there is no price to front-run inside the batch.
- Two-way RFQs hide the taker's direction from makers.

*Residual leakage (documented, by design):*
- The asset of each commitment and the commitment count per batch are public.
- Revealed orders are public before settlement (a 2-minute window).
- Ledger deposits and withdrawals are public.
- The settler picks the moment within the 10-minute settle window, which gives some timing optionality over the mid. The limit price bounds the downside, and batches void after the window.

### 5. Oracle failure or manipulation
*Mitigations:*
- Positive answer, `updatedAt` neither in the future nor older than 25h, and `answeredInRound ≥ roundId`.
- An optional secondary feed with a deviation bound, and a USDG/USD peg check (1%).
- Optional sequencer-uptime feed: none is published for this chain yet; see docs/ORACLES.md.
- The midpoint pool voids batches when the oracle reverts.
- The oracle is swappable via `PriceGuard.setOracle` (Timelock).

*Residual risk:* Chainlink stock feeds update on 0.5% deviation or a 24h heartbeat, so the "mid" can lag the live market by up to about 0.5%. The guard band (1%) is wider than that.

### 6. Smart-contract risks
- Reentrancy: `nonReentrant` on every external state-changing entry point, strict checks-effects-interactions in `Settlement.fill` (no state writes after token calls), and Settlement never holds funds.
- Unbounded loops: none. Batch size is capped at 64, reward tokens at 4, tiers at 4, and allowlist and override batches are capped.
- Token assumptions: allowlisted tokens must be standard ERC-20s (no fee-on-transfer or rebasing). Robinhood stock tokens use an ERC-8056 UI multiplier, not rebasing; USDG is standard. MakerRegistry and the pool measure balance deltas on deposit.
- Signature malleability: OpenZeppelin `ECDSA.tryRecover` rejects high-s values.
- EIP-7702 delegated EOAs are accepted via ECDSA; pure contract wallets via ERC-1271 (`test_eip7702DelegatedMaker_ecdsaAccepted`). This was found in the fork run: Robinhood Chain has live 7702 delegations.
- Admin: 48h Timelock (floor enforced even for `updateDelay`), and the deployer renounces every admin role in the same script.
- Slither: 0 High and 0 Medium after fixes. Low findings are timestamp comparisons, which are intentional for expiries and market hours.

### 7. Off-chain key handling
- No private key is created, stored or printed by any code in this repo.
- Deploys sign with a Foundry keystore. The bot and keeper use a keystore (decrypted in memory, password from a file or TTY) or an external RPC signer (Clef/web3signer).
- The keeper holds only `CALENDAR_ROLE`, which can shorten sessions but never extend them.

### 8. Compliance and regional access
- `ComplianceRegistry` is wired into every user entry point and is OFF by default. When enabled, it gates RFQ take/make, maker registration, midpoint use and staking by allowlist.
- The optional frontend geoblock (`GEOBLOCK_COUNTRIES`) only gates the hosted UI. The contracts remain public.
