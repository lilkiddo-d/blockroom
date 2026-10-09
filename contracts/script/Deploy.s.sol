// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {BlockroomTimelock} from "../src/BlockroomTimelock.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {MarketClock} from "../src/MarketClock.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {ProjectTokenHooks} from "../src/ProjectTokenHooks.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {MakerRegistry} from "../src/MakerRegistry.sol";
import {Settlement} from "../src/Settlement.sol";
import {MidpointPool} from "../src/MidpointPool.sol";
import {RobinhoodConfig} from "./RobinhoodConfig.sol";

/// @title Deploy
/// @notice One-shot deploy + wire + hand-off for Blockroom on Robinhood Chain (4663) or a local anvil fork of it
///         (run anvil with `--chain-id 31337` so fork deployments never collide with mainnet records).
///
///  Signing: only via a Foundry keystore (`--account blockroom-deployer`). No key ever touches this script.
///
///  Optional env (all default to the deployer unless noted):
///    BLOCKROOM_GUARDIAN      pause/unpause + maker suspension
///    BLOCKROOM_KEEPER        holiday calendar role (the `blockroom-keeper` keystore address)
///    BLOCKROOM_PROPOSER      timelock proposer/canceller (use a multisig in production)
///    BLOCKROOM_EXECUTOR      timelock executor (default: proposer)
///    BLOCKROOM_COMPLIANCE_OP allowlist operator
///    BLOCKROOM_TREASURY      fee treasury (default: the Timelock)
contract Deploy is Script {
    struct Holiday {
        uint256 closeMinute;
        string date;
        uint256 etDay;
        string name;
    }

    struct Roles {
        address deployer;
        address guardian;
        address keeper;
        address proposer;
        address executor;
        address complianceOp;
        address treasury;
    }

    struct Deployed {
        BlockroomTimelock timelock;
        OracleAdapter oracle;
        PriceGuard guard;
        MarketClock clock;
        ComplianceRegistry compliance;
        ProjectTokenHooks hooks;
        FeeCollector feeCollector;
        MakerRegistry registry;
        Settlement settlement;
        MidpointPool pool;
    }

    // ---- protocol parameters (see DECISIONS.md)
    uint256 internal constant TIMELOCK_DELAY = 48 hours;
    uint16 internal constant GUARD_BAND_BPS = 100; // 1% (Chainlink stock-feed deviation threshold is 0.5%)
    uint32 internal constant FEED_STALENESS = 1 days + 1 hours; // 24h heartbeat + buffer
    uint16 internal constant USDG_PEG_TOLERANCE_BPS = 100; // 1%
    uint16 internal constant RFQ_FEE_BPS = 5;
    uint16 internal constant SLASH_BPS = 100; // 1% of notional to the taker on default
    uint32 internal constant MAX_QUOTE_TTL = 5 minutes;
    uint256 internal constant MIN_MAKER_BOND = 25_000e6; // 25k USDG
    uint64 internal constant UNBONDING = 3 days;
    uint64 internal constant UNSTAKE_COOLDOWN = 7 days;
    uint256 internal constant STAKER_SHARE_BPS = 3_000;

    function run() external returns (Deployed memory d) {
        require(block.chainid == RobinhoodConfig.CHAIN_ID || block.chainid == 31337, "unsupported chain");
        require(RobinhoodConfig.USDG.code.length > 0, "USDG missing: run against Robinhood Chain or a fork of it");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        Roles memory r = _roles(deployer);

        address[] memory proposers = new address[](1);
        proposers[0] = r.proposer;
        address[] memory executors = new address[](1);
        executors[0] = r.executor;
        d.timelock = new BlockroomTimelock(TIMELOCK_DELAY, proposers, executors);
        if (r.treasury == address(0)) r.treasury = address(d.timelock);

        _deployCore(d, r);
        _configure(d, r);
        _handOff(d, r);
        vm.stopBroadcast();

        _verifyHandOff(d, r);
        _write(d, r);
    }

    // ------------------------------------------------------------------ steps

    function _roles(address deployer) internal view returns (Roles memory r) {
        r.deployer = deployer;
        r.guardian = vm.envOr("BLOCKROOM_GUARDIAN", deployer);
        r.keeper = vm.envOr("BLOCKROOM_KEEPER", deployer);
        r.proposer = vm.envOr("BLOCKROOM_PROPOSER", deployer);
        r.executor = vm.envOr("BLOCKROOM_EXECUTOR", r.proposer);
        r.complianceOp = vm.envOr("BLOCKROOM_COMPLIANCE_OP", deployer);
        r.treasury = vm.envOr("BLOCKROOM_TREASURY", address(0));
    }

    function _deployCore(Deployed memory d, Roles memory r) internal {
        address me = r.deployer;
        d.oracle = new OracleAdapter(me, r.guardian);
        d.guard = new PriceGuard(me, r.guardian, address(d.oracle), GUARD_BAND_BPS);
        d.clock = new MarketClock(me, r.guardian, me); // deployer seeds the holiday calendar, then hands to keeper
        d.compliance = new ComplianceRegistry(me, r.complianceOp);
        d.hooks = new ProjectTokenHooks(me, 0, STAKER_SHARE_BPS); // project-token bond value unset until governance prices it
        d.feeCollector = new FeeCollector(me, r.guardian, address(d.hooks), r.treasury, UNSTAKE_COOLDOWN);
        d.registry = new MakerRegistry(me, r.guardian, RobinhoodConfig.USDG, address(d.hooks), MIN_MAKER_BOND, UNBONDING);
        d.settlement = new Settlement(
            me,
            r.guardian,
            address(d.registry),
            address(d.guard),
            address(d.feeCollector),
            address(d.hooks),
            RFQ_FEE_BPS,
            SLASH_BPS,
            MAX_QUOTE_TTL
        );
        d.pool = new MidpointPool(
            me,
            r.guardian,
            RobinhoodConfig.USDG,
            address(d.guard),
            address(d.clock),
            address(d.feeCollector),
            address(d.hooks),
            MidpointPool.Params({
                batchDuration: 300,
                revealWindow: 120,
                settleWindow: 600,
                feeBps: 5,
                maxOrdersPerBatch: 64,
                maxCommitsPerTrader: 4,
                commitBond: 5e6
            })
        );
    }

    function _configure(Deployed memory d, Roles memory r) internal {
        // Oracle feeds
        d.oracle.setFeed(
            RobinhoodConfig.USDG,
            RobinhoodConfig.FEED_USDG_USD,
            address(0),
            FEED_STALENESS,
            0,
            USDG_PEG_TOLERANCE_BPS,
            IERC20Metadata(RobinhoodConfig.USDG).decimals(),
            true
        );
        RobinhoodConfig.Stock[] memory stocks = RobinhoodConfig.stocks();
        for (uint256 i; i < stocks.length; ++i) {
            uint8 dec = IERC20Metadata(stocks[i].token).decimals();
            d.oracle.setFeed(stocks[i].token, stocks[i].feed, address(0), FEED_STALENESS, 0, 0, dec, false);
            d.settlement.setBaseToken(stocks[i].token, true, dec);
            d.pool.setAsset(stocks[i].token, true, dec);
        }
        d.settlement.setQuoteToken(RobinhoodConfig.USDG, true);

        // Wiring
        d.hooks.setStakingSource(address(d.feeCollector));
        d.feeCollector.addRewardToken(RobinhoodConfig.USDG);
        d.feeCollector.grantRole(d.feeCollector.NOTIFIER_ROLE(), address(d.settlement));
        d.feeCollector.grantRole(d.feeCollector.NOTIFIER_ROLE(), address(d.pool));
        d.registry.grantRole(d.registry.SLASHER_ROLE(), address(d.settlement));

        // Compliance hook wired everywhere but OFF (ComplianceRegistry.enabled == false)
        d.settlement.setCompliance(address(d.compliance));
        d.pool.setCompliance(address(d.compliance));
        d.registry.setCompliance(address(d.compliance));
        d.feeCollector.setCompliance(address(d.compliance));

        // Seed the exchange-holiday calendar, then hand the calendar role to the keeper
        _seedHolidays(d.clock);
        bytes32 cal = d.clock.CALENDAR_ROLE();
        if (r.keeper != r.deployer) {
            d.clock.grantRole(cal, r.keeper);
            d.clock.renounceRole(cal, r.deployer);
        }
    }

    function _seedHolidays(MarketClock clock) internal {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/../config/market-holidays.json"));
        Holiday[] memory hs = abi.decode(vm.parseJson(json, ".holidays"), (Holiday[]));
        uint256 n = hs.length;
        uint256[] memory days_ = new uint256[](n);
        uint16[] memory closes = new uint16[](n);
        for (uint256 i; i < n; ++i) {
            days_[i] = hs[i].etDay;
            closes[i] = uint16(hs[i].closeMinute);
        }
        if (n > 0) clock.setSessionOverrides(days_, closes);
    }

    /// @dev Grant DEFAULT_ADMIN_ROLE to the Timelock and renounce it from the deployer on every contract.
    function _handOff(Deployed memory d, Roles memory r) internal {
        AccessControl[9] memory acs = _acs(d);
        address tl = address(d.timelock);
        for (uint256 i; i < acs.length; ++i) {
            bytes32 adminRole = acs[i].DEFAULT_ADMIN_ROLE();
            acs[i].grantRole(adminRole, tl);
            acs[i].renounceRole(adminRole, r.deployer);
        }
    }

    function _verifyHandOff(Deployed memory d, Roles memory r) internal view {
        AccessControl[9] memory acs = _acs(d);
        for (uint256 i; i < acs.length; ++i) {
            require(acs[i].hasRole(0x00, address(d.timelock)), "timelock not admin");
            require(!acs[i].hasRole(0x00, r.deployer), "deployer still admin");
        }
        require(d.timelock.getMinDelay() >= 48 hours, "delay");
        require(d.hooks.projectToken() == address(0), "project token must be unset");
        require(!d.compliance.enabled(), "compliance must default off");
    }

    /// @dev On Arbitrum-stack chains `block.number` inside the EVM is an L1 block number, and the script's local
    ///      EVM has no ArbSys precompile. Off-chain indexers (keeper, history) need the L2 block number, so ask the
    ///      node directly. Read during the simulation pass (i.e. before broadcast) minus a margin, so it is a safe
    ///      lower bound for log scans.
    function _l2BlockNumber() internal returns (uint256) {
        try vm.rpc("eth_blockNumber", "[]") returns (bytes memory raw) {
            uint256 n = 0;
            for (uint256 i; i < raw.length; ++i) {
                n = (n << 8) | uint8(raw[i]);
            }
            return n > 1_000 ? n - 1_000 : 0;
        } catch {
            return block.number;
        }
    }

    function _acs(Deployed memory d) internal pure returns (AccessControl[9] memory) {
        return [
            AccessControl(address(d.oracle)),
            AccessControl(address(d.guard)),
            AccessControl(address(d.clock)),
            AccessControl(address(d.compliance)),
            AccessControl(address(d.hooks)),
            AccessControl(address(d.feeCollector)),
            AccessControl(address(d.registry)),
            AccessControl(address(d.settlement)),
            AccessControl(address(d.pool))
        ];
    }

    // ----------------------------------------------------------------- output

    function _write(Deployed memory d, Roles memory r) internal {
        string memory o = "deployment";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeUint(o, "deployedAtBlock", _l2BlockNumber());
        vm.serializeAddress(o, "Timelock", address(d.timelock));
        vm.serializeAddress(o, "OracleAdapter", address(d.oracle));
        vm.serializeAddress(o, "PriceGuard", address(d.guard));
        vm.serializeAddress(o, "MarketClock", address(d.clock));
        vm.serializeAddress(o, "ComplianceRegistry", address(d.compliance));
        vm.serializeAddress(o, "ProjectTokenHooks", address(d.hooks));
        vm.serializeAddress(o, "FeeCollector", address(d.feeCollector));
        vm.serializeAddress(o, "MakerRegistry", address(d.registry));
        vm.serializeAddress(o, "Settlement", address(d.settlement));
        vm.serializeAddress(o, "MidpointPool", address(d.pool));
        vm.serializeAddress(o, "USDG", RobinhoodConfig.USDG);
        vm.serializeAddress(o, "guardian", r.guardian);
        vm.serializeAddress(o, "keeper", r.keeper);
        vm.serializeAddress(o, "proposer", r.proposer);
        vm.serializeAddress(o, "treasury", r.treasury);
        string memory json = vm.serializeAddress(o, "deployer", r.deployer);

        if (vm.isContext(VmSafe.ForgeContext.TestGroup)) return; // fork tests: never touch deployment records
        bool dryRun = vm.isContext(VmSafe.ForgeContext.ScriptDryRun);
        string memory id = vm.toString(block.chainid);
        string memory root = vm.projectRoot();
        if (dryRun) {
            vm.writeJson(json, string.concat(root, "/deployments/", id, ".dryrun.json"));
            console2.log("DRY RUN - simulated addresses written to deployments/%s.dryrun.json", id);
        } else {
            vm.writeJson(json, string.concat(root, "/deployments/", id, ".json"));
            vm.writeJson(json, string.concat(root, "/../app/src/generated/deployments/", id, ".json"));
            console2.log("Deployment written to deployments/%s.json and app/src/generated/deployments/", id);
        }
        console2.log("Settlement   ", address(d.settlement));
        console2.log("MidpointPool ", address(d.pool));
        console2.log("Timelock     ", address(d.timelock));
    }
}
