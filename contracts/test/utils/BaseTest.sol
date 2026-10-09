// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OracleAdapter} from "../../src/OracleAdapter.sol";
import {PriceGuard} from "../../src/PriceGuard.sol";
import {MarketClock} from "../../src/MarketClock.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {ProjectTokenHooks} from "../../src/ProjectTokenHooks.sol";
import {FeeCollector} from "../../src/FeeCollector.sol";
import {MakerRegistry} from "../../src/MakerRegistry.sol";
import {Settlement} from "../../src/Settlement.sol";
import {MidpointPool} from "../../src/MidpointPool.sol";
import {MockERC20, MockAggregator} from "./Mocks.sol";

abstract contract BaseTest is Test {
    // Tuesday 2026-10-06 15:00 UTC = 11:00 EDT (market open)
    uint256 internal constant OPEN_TS = 1_791_298_800;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal calendar = makeAddr("calendar");
    address internal treasury = makeAddr("treasury");
    address internal complianceOp = makeAddr("complianceOp");
    address internal taker = makeAddr("taker");
    uint256 internal makerPk = 0xA11CE;
    address internal maker;

    MockERC20 internal usdg;
    MockERC20 internal aapl;
    MockERC20 internal proj; // TEST-ONLY project token mock
    MockAggregator internal aaplFeed;
    MockAggregator internal usdgFeed;

    OracleAdapter internal oracle;
    PriceGuard internal guard;
    MarketClock internal clock;
    ComplianceRegistry internal compliance;
    ProjectTokenHooks internal hooks;
    FeeCollector internal fc;
    MakerRegistry internal registry;
    Settlement internal settlement;
    MidpointPool internal pool;

    uint256 internal constant AAPL_USD = 340e8; // feed answer (8 dp)
    uint256 internal constant MID = 340e6; // USDG units per 1 AAPL
    uint256 internal constant MIN_BOND = 10_000e6;

    function setUp() public virtual {
        vm.warp(OPEN_TS);
        maker = vm.addr(makerPk);

        usdg = new MockERC20("Global Dollar", "USDG", 6);
        aapl = new MockERC20("Apple", "AAPL", 18);
        proj = new MockERC20("Blockroom", "BLKR", 18);
        aaplFeed = new MockAggregator(8, int256(AAPL_USD));
        usdgFeed = new MockAggregator(8, 1e8);

        vm.startPrank(admin);
        oracle = new OracleAdapter(admin, guardian);
        oracle.setFeed(address(aapl), address(aaplFeed), address(0), 1 days, 0, 0, 18, false);
        oracle.setFeed(address(usdg), address(usdgFeed), address(0), 1 days, 0, 200, 6, true);
        guard = new PriceGuard(admin, guardian, address(oracle), 100);
        clock = new MarketClock(admin, guardian, calendar);
        compliance = new ComplianceRegistry(admin, complianceOp);
        hooks = new ProjectTokenHooks(admin, 0.5e6, 3_000); // 1 BLKR = 0.5 USDG bond value, 30% to stakers
        fc = new FeeCollector(admin, guardian, address(hooks), treasury, 7 days);
        hooks.setStakingSource(address(fc));
        fc.addRewardToken(address(usdg));
        registry = new MakerRegistry(admin, guardian, address(usdg), address(hooks), MIN_BOND, 2 days);
        settlement = new Settlement(
            admin, guardian, address(registry), address(guard), address(fc), address(hooks), 5, 100, 10 minutes
        );
        settlement.setBaseToken(address(aapl), true, 18);
        settlement.setQuoteToken(address(usdg), true);
        settlement.setCompliance(address(compliance));
        registry.grantRole(registry.SLASHER_ROLE(), address(settlement));
        fc.grantRole(fc.NOTIFIER_ROLE(), address(settlement));
        registry.setCompliance(address(compliance));

        pool = new MidpointPool(
            admin,
            guardian,
            address(usdg),
            address(guard),
            address(clock),
            address(fc),
            address(hooks),
            MidpointPool.Params({
                batchDuration: 300,
                revealWindow: 120,
                settleWindow: 600,
                feeBps: 5,
                maxOrdersPerBatch: 64,
                maxCommitsPerTrader: 8,
                commitBond: 1e6
            })
        );
        pool.setAsset(address(aapl), true, 18);
        pool.setCompliance(address(compliance));
        fc.grantRole(fc.NOTIFIER_ROLE(), address(pool));
        vm.stopPrank();

        vm.label(address(usdg), "USDG");
        vm.label(address(aapl), "AAPL");
        vm.label(maker, "maker");
    }

    // ---------------------------------------------------------------- helpers

    function _registerMaker(address m, uint256 bond) internal {
        usdg.mint(m, bond);
        vm.startPrank(m);
        registry.register();
        usdg.approve(address(registry), bond);
        registry.depositBond(bond);
        vm.stopPrank();
    }

    function _quote(uint8 side, uint256 price, uint256 size, uint256 nonce)
        internal
        view
        returns (Settlement.Quote memory q)
    {
        q = Settlement.Quote({
            rfqId: keccak256(abi.encode("rfq", nonce)),
            maker: maker,
            taker: address(0),
            baseToken: address(aapl),
            quoteToken: address(usdg),
            side: side,
            tif: 0,
            price: price,
            size: size,
            minFill: 0,
            nonce: nonce,
            expiry: uint64(block.timestamp + 5 minutes)
        });
    }

    function _sign(uint256 pk, Settlement.Quote memory q) internal view returns (bytes memory) {
        bytes32 digest = settlement.hashQuote(q);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _fundAndApprove(MockERC20 t, address who, address spender, uint256 amount) internal {
        t.mint(who, amount);
        vm.prank(who);
        t.approve(spender, type(uint256).max);
    }
}
