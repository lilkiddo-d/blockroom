# Deploying Blockroom to Robinhood Chain mainnet (chain id 4663)

No private key ever touches this repo. Every transaction is signed through a Foundry keystore.

## 0. Preflight (once)

- [ ] Foundry installed (`forge --version`), plus Node ≥ 20 and pnpm.
- [ ] Dependencies: `pnpm install`; contracts libraries are already vendored in `contracts/lib/`.
- [ ] Decide roles (all optional; each defaults to the deployer):
  - `BLOCKROOM_PROPOSER` — **strongly recommended: a multisig.** It proposes and cancels Timelock operations.
  - `BLOCKROOM_EXECUTOR` (default = proposer), `BLOCKROOM_GUARDIAN` (pause key), `BLOCKROOM_KEEPER` (the address of the `blockroom-keeper` keystore), `BLOCKROOM_COMPLIANCE_OP`, `BLOCKROOM_TREASURY` (default = Timelock).
- [ ] Fund the deployer with **≥ 0.01 ETH on Robinhood Chain**. The dry run estimated 24.2M gas ≈ 0.001 ETH at 0.02 gwei; the rest is headroom for L1 data costs and gas spikes.
- [ ] Optional: a dedicated RPC (e.g. Alchemy) — the public endpoint is rate-limited.

## 1. Import keys (interactive, never stored in this repo)

```bash
cast wallet import blockroom-deployer --interactive
```
```bash
cast wallet import blockroom-keeper --interactive
```

## 2. Dry run against mainnet (no broadcast)

```bash
cd contracts && forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --account blockroom-deployer --sender $(cast wallet address --account blockroom-deployer)
```

This must end with `SIMULATION COMPLETE`. It writes simulated addresses to `contracts/deployments/4663.dryrun.json` and never touches the real record.

## 3. Deploy + wire + hand admin to the 48h Timelock + verify (the one command)

```bash
cd contracts && forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --account blockroom-deployer --sender $(cast wallet address --account blockroom-deployer) --broadcast --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/ --slow
```

The script:
- deploys the Timelock, OracleAdapter, PriceGuard, MarketClock, ComplianceRegistry, ProjectTokenHooks, FeeCollector, MakerRegistry, Settlement and MidpointPool;
- configures 11 stock feeds and USDG, wires roles, seeds the NYSE holiday calendar, and grants admin to the Timelock while the deployer renounces it everywhere;
- asserts all of that before writing `contracts/deployments/4663.json` and `app/src/generated/deployments/4663.json`.

**If verification fails** (the Blockscout API sometimes shows a Cloudflare challenge to automated clients), the deployment is still complete. Re-run only the verification later from the broadcast record:

```bash
cd contracts && forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --account blockroom-deployer --sender $(cast wallet address --account blockroom-deployer) --resume --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
```

## 4. Post-deploy checks (read-only)

This reads `contracts/deployments/4663.json`. Expect:
- every contract shows `timelock admin=true deployer admin=false`;
- compliance enabled `false`;
- timelock min delay `172800`;
- project token `0x000…0`;
- a live AAPL mid (stale over weekends, which is expected).

```bash
bash scripts/check-deployment.sh 4663 https://rpc.mainnet.chain.robinhood.com
```

Then commit `contracts/deployments/4663.json` and `app/src/generated/deployments/4663.json` so the frontend build picks them up.

## 5. Later: enable the $BLKR project token (through the Timelock)

```bash
cd contracts && forge script script/SetProjectToken.s.sol --sig "schedule(address,uint256)" <TOKEN> <BOND_VALUE_PER_TOKEN> --rpc-url https://rpc.mainnet.chain.robinhood.com --account blockroom-deployer --broadcast
```

Wait ≥ 48 hours, then run the same command with `--sig "execute(address,uint256)"`. Details are in TOKEN_INTEGRATION.md.

## 6. Off-chain services

All three read `contracts/deployments/<CHAIN_ID>.json`, so deploy them from the repo after step 4 is committed.

### RFQ relay (Railway or Fly.io)
- Start command: `pnpm install && pnpm relay`
- Env: `CHAIN_ID=4663`, `RPC_URL=<rpc>`, `PORT` (set by the platform), optional `RELAY_ID`
- Health check: `GET /health` → `{"ok":true,...}`. Expose it over TLS (`wss://`).
- Fly.io: `fly launch --no-deploy`, set the internal port to 8787 (or `PORT`), `fly deploy`. Railway: new service from the repo, start command as above.
- Run **two or more independent relays** and list them all in `NEXT_PUBLIC_RELAY_URLS`.

### Keeper
- Holds `CALENDAR_ROLE` if you passed `BLOCKROOM_KEEPER`. It settles batches and serves delegated reveals.
- `SIGNER=keystore KEYSTORE_ACCOUNT=blockroom-keeper KEYSTORE_PASSWORD_FILE=/run/secrets/keystore_password CHAIN_ID=4663 RPC_URL=<rpc> pnpm keeper`
- Copy the keystore file (`~/.foundry/keystores/blockroom-keeper`) to the host as a secret, never into the repo.
- Expose port `KEEPER_REVEAL_PORT` (8788) over HTTPS and set `NEXT_PUBLIC_KEEPER_URL`.
- Keep a little ETH on the keeper for gas.

### Market makers
- Each maker registers and bonds in the app's Maker console, then runs `pnpm mm-bot` with its own keystore: `SIGNER=keystore KEYSTORE_ACCOUNT=<maker> RELAY_URL=wss://…`.

### Frontend (Vercel)
- Import the repo, set **Root Directory = `app`**; Vercel detects Next.js and the pnpm workspace.
- Env:
  - `NEXT_PUBLIC_CHAIN_ID=4663`
  - `NEXT_PUBLIC_RPC_URL=<rpc>`
  - `NEXT_PUBLIC_RELAY_URLS=wss://relay-1…,wss://relay-2…`
  - optional: `NEXT_PUBLIC_KEEPER_URL`, `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID`, `NEXT_PUBLIC_PROJECT_TOKEN` (empty = token features hidden), `GEOBLOCK_COUNTRIES` (e.g. `US,CU,IR,KP,SY`; empty = off)

## Local rehearsal (what was run before mainnet)

`bash scripts/fork.sh` starts an anvil fork of mainnet on port 29463 (re-labelled chain 31337), deploys with anvil's unlocked dev account (no keys), funds dev accounts, bonds a dev maker and warms the fork cache. Then:

```bash
CHAIN_ID=31337 RPC_URL=http://127.0.0.1:29463 pnpm relay
```
```bash
CHAIN_ID=31337 RPC_URL=http://127.0.0.1:29463 RELAY_URL=ws://127.0.0.1:8787 SIGNER=rpc SIGNER_ADDRESS=0x70997970C51812dc3A010C7d01b50e0d17dc79C8 pnpm mm-bot
```
```bash
CHAIN_ID=31337 RPC_URL=http://127.0.0.1:29463 RELAY_URL=ws://127.0.0.1:8787 SIGNER=rpc SIGNER_ADDRESS=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 pnpm --filter @blockroom/scripts smoke:rfq
```

The public RPC isn't an archive node, so use the fork soon after starting it, or set `ROBINHOOD_RPC_URL` to an archive endpoint.
