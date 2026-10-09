// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {RobinhoodConfig} from "../../script/RobinhoodConfig.sol";
import {Settlement} from "../../src/Settlement.sol";
import {MidpointPool} from "../../src/MidpointPool.sol";
import {AggregatorV3Interface} from "../../src/interfaces/IBlockroom.sol";

interface IScaledUI {
    function uiMultiplier() external view returns (uint256);
}

/// @notice Fork tests against Robinhood Chain mainnet with the real USDG, stock tokens and Chainlink feeds.
///         Forks the latest block by default (the public RPC is not an archive node); set FORK_BLOCK with an archive
///         RPC (ROBINHOOD_RPC_URL) to pin. Tests that need the US session warp into it (see `_ensureSession`).
///         Set FORK_TESTS=false to skip when offline.
contract ForkTest is Test {
    bool internal enabled;

    Deploy.Deployed internal d;
    uint256 internal makerPk = 0xB10C;
    address internal maker;
    address internal taker = makeAddr("taker");

    function setUp() public {
        enabled = vm.envOr("FORK_TESTS", true);
        if (!enabled) return;
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blk);
        maker = vm.addr(makerPk);
        d = new Deploy().run();
    }

    modifier onlyFork() {
        if (!enabled) return;
        _;
    }

    function test_fork_canonicalAddresses() public view onlyFork {
        assertEq(block.chainid, 4663);
        assertEq(IERC20Metadata(RobinhoodConfig.USDG).symbol(), "USDG");
        assertEq(IERC20Metadata(RobinhoodConfig.USDG).decimals(), 6);
        assertEq(IERC20Metadata(RobinhoodConfig.WETH).decimals(), 18);
        RobinhoodConfig.Stock[] memory s = RobinhoodConfig.stocks();
        for (uint256 i; i < s.length; ++i) {
            assertEq(IERC20Metadata(s[i].token).symbol(), s[i].symbol);
            assertEq(IERC20Metadata(s[i].token).decimals(), 18);
            assertGt(IScaledUI(s[i].token).uiMultiplier(), 0);
            assertEq(AggregatorV3Interface(s[i].feed).decimals(), 8);
            (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(s[i].feed).latestRoundData();
            assertGt(answer, 0);
            assertLe(block.timestamp - updatedAt, 1 days + 1 hours);
            // every configured stock resolves to a sane USDG mid
            uint256 mid = d.guard.getMid(s[i].token, RobinhoodConfig.USDG);
            assertGt(mid, 1e6);
            assertLt(mid, 100_000e6);
        }
    }

    function test_fork_deployHandOff() public view onlyFork {
        assertTrue(d.settlement.hasRole(0x00, address(d.timelock)));
        assertEq(d.timelock.getMinDelay(), 48 hours);
        assertEq(d.hooks.projectToken(), address(0));
        assertFalse(d.compliance.enabled());
    }

    function test_fork_rfqFill_realTokens() public onlyFork {
        address aapl = RobinhoodConfig.stocks()[0].token;
        address usdg = RobinhoodConfig.USDG;
        deal(usdg, maker, 100_000e6);
        deal(aapl, maker, 100e18);
        deal(usdg, taker, 100_000e6);

        vm.startPrank(maker);
        d.registry.register();
        IERC20(usdg).approve(address(d.registry), 25_000e6);
        d.registry.depositBond(25_000e6);
        IERC20(aapl).approve(address(d.settlement), type(uint256).max);
        vm.stopPrank();

        uint256 mid = d.guard.getMid(aapl, usdg);
        Settlement.Quote memory q = Settlement.Quote({
            rfqId: keccak256("fork-rfq"),
            maker: maker,
            taker: taker,
            baseToken: aapl,
            quoteToken: usdg,
            side: 0,
            tif: 0,
            price: (mid * 10_020) / 10_000, // +20 bps
            size: 50e18,
            minFill: 10e18,
            nonce: 1,
            expiry: uint64(block.timestamp + 2 minutes)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, d.settlement.hashQuote(q));
        vm.startPrank(taker);
        IERC20(usdg).approve(address(d.settlement), type(uint256).max);
        (uint256 qa, uint256 fee, bool defaulted) = d.settlement.fill(q, abi.encodePacked(r, s, v), 50e18);
        vm.stopPrank();
        assertFalse(defaulted);
        assertEq(IERC20(aapl).balanceOf(taker), 50e18);
        assertEq(IERC20(usdg).balanceOf(taker), 100_000e6 - qa - fee);
        assertEq(IERC20(usdg).balanceOf(address(d.feeCollector)), fee);
    }

    function test_fork_rfqOutsideGuardRejected() public onlyFork {
        address nvda = RobinhoodConfig.stocks()[1].token;
        address usdg = RobinhoodConfig.USDG;
        uint256 mid = d.guard.getMid(nvda, usdg);
        vm.expectRevert();
        d.guard.checkPrice(nvda, usdg, (mid * 10_200) / 10_000);
    }

    /// @dev Warp to the next regular session if the fork block is outside it. If that jump exceeds the feeds'
    ///      staleness window (weekends), re-stamp each feed's CURRENT on-chain answer at the new time - simulating
    ///      the heartbeat updates that would occur in reality - so the oracle path stays fully exercised.
    function _ensureSession() internal {
        uint256 start = block.timestamp;
        for (uint256 i; i < 500 && !d.clock.isOpen(); ++i) {
            vm.warp(block.timestamp + 15 minutes);
        }
        assertTrue(d.clock.isOpen(), "no session found within ~5 days");
        if (block.timestamp - start < 12 hours) return;
        RobinhoodConfig.Stock[] memory s = RobinhoodConfig.stocks();
        for (uint256 i; i <= s.length; ++i) {
            address feed = i == s.length ? RobinhoodConfig.FEED_USDG_USD : s[i].feed;
            (uint80 id, int256 ans,,, uint80 air) = AggregatorV3Interface(feed).latestRoundData();
            vm.mockCall(
                feed,
                abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
                abi.encode(id, ans, block.timestamp, block.timestamp, air)
            );
        }
    }

    function test_fork_midpointBatch_realOracle() public onlyFork {
        _ensureSession();
        address tsla = RobinhoodConfig.stocks()[2].token;
        address usdg = RobinhoodConfig.USDG;
        address buyer = makeAddr("buyer");
        address seller = makeAddr("seller");
        deal(usdg, buyer, 1_000_000e6);
        deal(tsla, seller, 1_000e18);
        vm.startPrank(buyer);
        IERC20(usdg).approve(address(d.pool), type(uint256).max);
        d.pool.deposit(usdg, 1_000_000e6);
        vm.stopPrank();
        vm.startPrank(seller);
        IERC20(tsla).approve(address(d.pool), type(uint256).max);
        IERC20(usdg).approve(address(d.pool), type(uint256).max);
        d.pool.deposit(tsla, 1_000e18);
        vm.stopPrank();
        deal(usdg, seller, 10e6);
        vm.prank(seller);
        d.pool.deposit(usdg, 10e6); // commit bond

        uint256 mid = d.guard.getMid(tsla, usdg);
        uint64 id = d.pool.currentBatchId();
        MidpointPool.OrderReveal memory b = MidpointPool.OrderReveal(
            buyer, tsla, id, 0, 0, 100e18, 0, uint128((mid * 101) / 100), bytes32("b")
        );
        MidpointPool.OrderReveal memory s =
            MidpointPool.OrderReveal(seller, tsla, id, 1, 0, 100e18, 0, 0, bytes32("s"));
        bytes32 cb = d.pool.hashOrder(b);
        bytes32 cs = d.pool.hashOrder(s);
        vm.prank(buyer);
        d.pool.commit(tsla, cb);
        vm.prank(seller);
        d.pool.commit(tsla, cs);
        MidpointPool.Batch memory bi = d.pool.batchInfo(tsla, id);
        vm.warp(bi.commitEnd);
        d.pool.reveal(b);
        d.pool.reveal(s);
        vm.warp(bi.revealEnd);
        mid = d.guard.getMid(tsla, usdg);
        d.pool.settle(tsla, id);
        bi = d.pool.batchInfo(tsla, id);
        assertFalse(bi.voided);
        assertEq(bi.mid, mid, "printed at oracle mid");
        assertEq(bi.matchedBase, 100e18);
        assertEq(d.pool.freeBalance(buyer, tsla), 100e18);
    }
}
