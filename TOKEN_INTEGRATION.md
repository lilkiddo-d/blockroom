# $BLKR project-token integration

Blockroom **does not deploy any ERC-20**. $BLKR launches separately on a launchpad. The protocol is fully functional without it, and every token feature stays dormant until governance switches it on.

## How it is wired

`ProjectTokenHooks` is the single switchboard. `MakerRegistry`, `FeeCollector`, `Settlement` and `MidpointPool` read the token address and parameters from it, so one Timelock action activates everything consistently.

| Feature | Contract | Behaviour before the token is set | After |
|---|---|---|---|
| Bond in $BLKR | `MakerRegistry.depositProjectBond` | reverts `TokenDisabled` | accepted; counts as `amount × bondValuePerToken / 1e18` USDG of bond. Slashed only after the maker's USDG bond is exhausted |
| Staking → fee share | `FeeCollector.stake / requestUnstake / claim` | `stake` reverts | stakers receive `stakerShareBps` (default 30%) of every USDG fee; the rest goes to the treasury |
| Taker fee discounts | `ProjectTokenHooks.feeDiscountBps` → `Settlement._fee`, `MidpointPool._fee` | 0 | tier discount based on **staked** balance (not wallet balance), with a 7-day unstake cooldown so tiers can't be flash-borrowed |

`setProjectToken(address)` is **one-shot** and **admin-only**; after deployment the admin is the 48h Timelock.

## Turning it on

Prerequisites:
- the token is deployed and has code;
- you have decided `bondValuePerToken` — USDG units (6 dp) credited per 1e18 token units. Use a conservative haircut: for example, if $BLKR trades at $0.40, use `200000` ($0.20, a 50% haircut). `0` means project-token bonds count for nothing.

Step 1 schedules this batch on the Timelock: `setProjectToken`, `setBondValuePerToken`, and the default tiers (≥10k staked = 10% off, ≥100k = 25% off, ≥1M = 50% off).

```bash
cd contracts && forge script script/SetProjectToken.s.sol --sig "schedule(address,uint256)" <TOKEN> <BOND_VALUE_PER_TOKEN> --rpc-url https://rpc.mainnet.chain.robinhood.com --account blockroom-deployer --broadcast
```

Step 2, at least 48 hours later, executes it with exactly the same arguments:

```bash
cd contracts && forge script script/SetProjectToken.s.sol --sig "execute(address,uint256)" <TOKEN> <BOND_VALUE_PER_TOKEN> --rpc-url https://rpc.mainnet.chain.robinhood.com --account blockroom-deployer --broadcast
```

The signing account must be the Timelock proposer and executor (`BLOCKROOM_PROPOSER` / `BLOCKROOM_EXECUTOR` at deploy time; the deployer by default). If that is a multisig, submit the same `scheduleBatch` / `executeBatch` calldata through it instead.

Step 3, frontend: set `NEXT_PUBLIC_PROJECT_TOKEN=<TOKEN>` in Vercel and redeploy. When it is empty, the Stake page, project-token bonding and discount UI are hidden. If it is set before step 2 executes, the Stake page shows "pending Timelock".

## Safety notes

- The project token can never be a fee *reward* token, so principal and rewards are never mixed.
- `bondValuePerToken` and the tiers can be changed later, but only through the Timelock.
- Token features change no settlement prices; they only affect bond accounting, fee splits and discounts (discounts are capped at 50%).
- Tests use a mock ERC-20 only (`contracts/test/utils/Mocks.sol`).
