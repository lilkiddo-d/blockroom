// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./utils/BaseTest.sol";
import {MidpointPool} from "../src/MidpointPool.sol";
import {BlockroomBase} from "../src/base/BlockroomBase.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Vm} from "forge-std/Vm.sol";

contract MidpointPoolTest is BaseTest {
    address alice = makeAddr("alice"); // buyer
    address bob = makeAddr("bob"); // seller
    address carol = makeAddr("carol");
    uint64 id;

    function setUp() public override {
        super.setUp();
        id = pool.currentBatchId();
        _fund(alice);
        _fund(bob);
        _fund(carol);
    }

    function _fund(address u) internal {
        usdg.mint(u, 10_000_000e6);
        aapl.mint(u, 10_000e18);
        vm.startPrank(u);
        usdg.approve(address(pool), type(uint256).max);
        aapl.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdg), 1_000_000e6);
        pool.deposit(address(aapl), 1_000e18);
        vm.stopPrank();
    }

    function _order(address trader, uint8 side, uint128 size, uint128 minFill, uint128 limit, bytes32 salt)
        internal
        view
        returns (MidpointPool.OrderReveal memory r)
    {
        r = MidpointPool.OrderReveal({
            trader: trader,
            asset: address(aapl),
            batchId: id,
            side: side,
            tif: 0,
            size: size,
            minFill: minFill,
            limitPrice: limit,
            salt: salt
        });
    }

    function _commit(MidpointPool.OrderReveal memory r) internal returns (bytes32 c) {
        c = pool.hashOrder(r);
        vm.prank(r.trader);
        pool.commit(r.asset, c);
    }

    function _toReveal() internal {
        vm.warp((uint256(id) + 1) * 300);
    }

    function _toSettle() internal {
        vm.warp((uint256(id) + 1) * 300 + 120);
    }

    // ------------------------------------------------------------------ basic

    function test_fullCross_atMid() public {
        MidpointPool.OrderReveal memory b = _order(alice, 0, 10e18, 0, 345e6, "a");
        MidpointPool.OrderReveal memory s = _order(bob, 1, 10e18, 0, 0, "b");
        _commit(b);
        _commit(s);
        // bond locked
        assertEq(pool.freeBalance(alice, address(usdg)), 1_000_000e6 - 1e6);
        _toReveal();
        pool.reveal(b);
        pool.reveal(s);
        _toSettle();
        aaplFeed.set(341e8);
        pool.settle(address(aapl), id);

        uint256 notional = 3_410e6;
        uint256 fee = (notional * 5) / 10_000;
        assertEq(pool.freeBalance(alice, address(aapl)), 1_010e18);
        assertEq(pool.freeBalance(alice, address(usdg)), 1_000_000e6 - notional - fee);
        assertEq(pool.freeBalance(bob, address(aapl)), 990e18);
        assertEq(pool.freeBalance(bob, address(usdg)), 1_000_000e6 + notional - fee);
        assertEq(usdg.balanceOf(address(fc)), 2 * fee);
        MidpointPool.Batch memory bi = pool.batchInfo(address(aapl), id);
        assertTrue(bi.settled);
        assertEq(bi.mid, 341e6);
        assertEq(bi.matchedBase, 10e18);
    }

    function test_partialCross_proRataFifo() public {
        _commit(_order(alice, 0, 10e18, 0, 400e6, "a1"));
        _commit(_order(carol, 0, 10e18, 0, 400e6, "c1"));
        _commit(_order(bob, 1, 15e18, 0, 0, "b1"));
        _toReveal();
        pool.reveal(_order(alice, 0, 10e18, 0, 400e6, "a1"));
        pool.reveal(_order(carol, 0, 10e18, 0, 400e6, "c1"));
        pool.reveal(_order(bob, 1, 15e18, 0, 0, "b1"));
        _toSettle();
        pool.settle(address(aapl), id);
        assertEq(pool.freeBalance(alice, address(aapl)), 1_010e18); // FIFO: alice first, full
        assertEq(pool.freeBalance(carol, address(aapl)), 1_005e18); // carol gets the rest
        assertEq(pool.freeBalance(bob, address(aapl)), 985e18);
        // carol's unused lock fully returned
        uint256 notional = 5 * MID;
        uint256 fee = (notional * 5) / 10_000;
        assertEq(pool.freeBalance(carol, address(usdg)), 1_000_000e6 - notional - fee);
    }

    function test_limitPrices_excludeOrders() public {
        _commit(_order(alice, 0, 10e18, 0, 339e6, "a")); // buy limit below mid -> excluded
        _commit(_order(bob, 1, 10e18, 0, 341e6, "b")); // sell limit above mid -> excluded
        _toReveal();
        pool.reveal(_order(alice, 0, 10e18, 0, 339e6, "a"));
        pool.reveal(_order(bob, 1, 10e18, 0, 341e6, "b"));
        _toSettle();
        pool.settle(address(aapl), id);
        assertEq(pool.batchInfo(address(aapl), id).matchedBase, 0);
        assertEq(pool.freeBalance(alice, address(usdg)), 1_000_000e6);
        assertEq(pool.freeBalance(bob, address(aapl)), 1_000e18);
    }

    function test_minFill_skipsSmallCounterparty() public {
        _commit(_order(alice, 0, 10e18, 8e18, 400e6, "a")); // needs >= 8 per execution
        _commit(_order(bob, 1, 5e18, 0, 0, "b"));
        _commit(_order(carol, 1, 10e18, 0, 0, "c"));
        _toReveal();
        pool.reveal(_order(alice, 0, 10e18, 8e18, 400e6, "a"));
        pool.reveal(_order(bob, 1, 5e18, 0, 0, "b"));
        pool.reveal(_order(carol, 1, 10e18, 0, 0, "c"));
        _toSettle();
        pool.settle(address(aapl), id);
        assertEq(pool.freeBalance(bob, address(aapl)), 1_000e18, "bob skipped (5 < 8)");
        assertEq(pool.freeBalance(carol, address(aapl)), 990e18, "carol filled 10");
        assertEq(pool.freeBalance(alice, address(aapl)), 1_010e18);
    }

    function test_minFill_buySkippedWhenSmallerRemaining() public {
        _commit(_order(alice, 0, 4e18, 0, 400e6, "a"));
        _commit(_order(bob, 1, 10e18, 6e18, 0, "b")); // bob needs >= 6
        _commit(_order(carol, 0, 8e18, 0, 400e6, "c"));
        _toReveal();
        pool.reveal(_order(alice, 0, 4e18, 0, 400e6, "a"));
        pool.reveal(_order(bob, 1, 10e18, 6e18, 0, "b"));
        pool.reveal(_order(carol, 0, 8e18, 0, 400e6, "c"));
        _toSettle();
        pool.settle(address(aapl), id);
        assertEq(pool.freeBalance(alice, address(aapl)), 1_000e18, "alice skipped");
        assertEq(pool.freeBalance(carol, address(aapl)), 1_008e18);
        assertEq(pool.freeBalance(bob, address(aapl)), 992e18);
    }

    function test_FOK() public {
        MidpointPool.OrderReveal memory a = _order(alice, 0, 10e18, 0, 400e6, "a");
        a.tif = 1;
        _commit(a);
        _commit(_order(bob, 1, 6e18, 0, 0, "b"));
        _commit(_order(carol, 1, 6e18, 0, 0, "c"));
        _toReveal();
        pool.reveal(a);
        pool.reveal(_order(bob, 1, 6e18, 0, 0, "b"));
        pool.reveal(_order(carol, 1, 6e18, 0, 0, "c"));
        _toSettle();
        pool.settle(address(aapl), id);
        assertEq(pool.batchInfo(address(aapl), id).matchedBase, 0, "FOK not satisfiable by one counterparty");
        assertEq(pool.orderAt(address(aapl), id, 0).minFill, 10e18);
    }

    function test_unrevealed_forfeitsBond() public {
        _commit(_order(alice, 0, 10e18, 0, 400e6, "a"));
        _toSettle();
        pool.settle(address(aapl), id);
        assertEq(pool.freeBalance(alice, address(usdg)), 1_000_000e6 - 1e6);
        assertEq(fc.treasuryAccrued(address(usdg)), 1e6);
        assertEq(uint8(pool.orderAt(address(aapl), id, 0).status), uint8(MidpointPool.Status.Forfeited));
    }

    function test_cancelCommit() public {
        bytes32 c = _commit(_order(alice, 0, 10e18, 0, 400e6, "a"));
        vm.prank(bob);
        vm.expectRevert(MidpointPool.NotTrader.selector);
        pool.cancelCommit(c);
        vm.prank(alice);
        pool.cancelCommit(c);
        assertEq(pool.freeBalance(alice, address(usdg)), 1_000_000e6);
        vm.prank(alice);
        vm.expectRevert(MidpointPool.InvalidOrder.selector);
        pool.cancelCommit(c);
        vm.expectRevert(MidpointPool.UnknownCommitment.selector);
        pool.cancelCommit(bytes32(uint256(1)));
        _toReveal();
        vm.expectRevert(MidpointPool.InvalidOrder.selector);
        pool.reveal(_order(alice, 0, 10e18, 0, 400e6, "a"));
    }

    function test_cancelCommit_afterWindow_reverts() public {
        bytes32 c = _commit(_order(alice, 0, 10e18, 0, 400e6, "a"));
        _toReveal();
        vm.prank(alice);
        vm.expectRevert(MidpointPool.NotCommitPhase.selector);
        pool.cancelCommit(c);
    }

    // ------------------------------------------------------------ void paths

    function test_void_marketClosedAtSettle() public {
        _commit(_order(alice, 0, 10e18, 0, 400e6, "a"));
        _commit(_order(bob, 1, 10e18, 0, 0, "b"));
        _commit(_order(carol, 1, 1e18, 0, 0, "c")); // never revealed -> refunded on void
        _toReveal();
        pool.reveal(_order(alice, 0, 10e18, 0, 400e6, "a"));
        pool.reveal(_order(bob, 1, 10e18, 0, 0, "b"));
        _toSettle();
        vm.prank(guardian);
        clock.setForceClosed(true);
        pool.settle(address(aapl), id);
        assertTrue(pool.batchInfo(address(aapl), id).voided);
        assertEq(pool.freeBalance(alice, address(usdg)), 1_000_000e6);
        assertEq(pool.freeBalance(bob, address(aapl)), 1_000e18);
        assertEq(pool.freeBalance(carol, address(usdg)), 1_000_000e6);
    }

    function test_void_staleOracle() public {
        _commit(_order(alice, 0, 10e18, 0, 400e6, "a"));
        _toReveal();
        pool.reveal(_order(alice, 0, 10e18, 0, 400e6, "a"));
        _toSettle();
        aaplFeed.setWithTime(340e8, block.timestamp - 3 days);
        pool.settle(address(aapl), id);
        assertTrue(pool.batchInfo(address(aapl), id).voided);
    }

    function test_void_afterDeadline() public {
        _commit(_order(alice, 0, 10e18, 0, 400e6, "a"));
        _toReveal();
        pool.reveal(_order(alice, 0, 10e18, 0, 400e6, "a"));
        vm.warp((uint256(id) + 1) * 300 + 120 + 601);
        aaplFeed.set(340e8);
        pool.settle(address(aapl), id);
        assertTrue(pool.batchInfo(address(aapl), id).voided);
    }

    function test_void_paused_andWithdrawStillWorks() public {
        _commit(_order(alice, 0, 10e18, 0, 400e6, "a"));
        _toReveal();
        pool.reveal(_order(alice, 0, 10e18, 0, 400e6, "a"));
        _toSettle();
        vm.prank(guardian);
        pool.pause();
        pool.settle(address(aapl), id);
        assertTrue(pool.batchInfo(address(aapl), id).voided);
        vm.prank(alice);
        pool.withdraw(address(usdg), 1_000_000e6);
        assertEq(usdg.balanceOf(alice), 10_000_000e6);
    }

    // ------------------------------------------------------------ phase guards

    function test_phaseGuards() public {
        MidpointPool.OrderReveal memory a = _order(alice, 0, 10e18, 0, 400e6, "a");
        _commit(a);
        vm.expectRevert(MidpointPool.NotRevealPhase.selector);
        pool.reveal(a);
        vm.expectRevert(MidpointPool.NotSettleable.selector);
        pool.settle(address(aapl), id);
        vm.expectRevert(MidpointPool.NotSettleable.selector);
        pool.settle(address(aapl), id + 5);
        _toReveal();
        // a commit during batch `id`'s reveal phase lands in the NEXT batch
        vm.prank(bob);
        pool.commit(address(aapl), keccak256("next"));
        (, , uint64 batchOfLate,) = pool.commitInfo(keccak256("next"));
        assertEq(batchOfLate, id + 1);
        _toSettle();
        pool.settle(address(aapl), id);
        vm.expectRevert(MidpointPool.AlreadySettled.selector);
        pool.settle(address(aapl), id);
        vm.expectRevert(MidpointPool.NotRevealPhase.selector);
        pool.reveal(a);
    }

    function test_commitValidation() public {
        vm.prank(alice);
        vm.expectRevert(MidpointPool.AssetNotAllowed.selector);
        pool.commit(address(proj), bytes32(uint256(1)));

        bytes32 c = _commit(_order(alice, 0, 10e18, 0, 400e6, "a"));
        vm.prank(bob);
        vm.expectRevert(MidpointPool.DuplicateCommitment.selector);
        pool.commit(address(aapl), c);

        address poor = makeAddr("poor");
        vm.prank(poor);
        vm.expectRevert(MidpointPool.InsufficientBalance.selector);
        pool.commit(address(aapl), bytes32(uint256(2)));

        for (uint256 i = 1; i < 8; ++i) {
            vm.prank(alice);
            pool.commit(address(aapl), bytes32(i + 100));
        }
        vm.prank(alice);
        vm.expectRevert(MidpointPool.TooManyCommits.selector);
        pool.commit(address(aapl), bytes32(uint256(200)));
    }

    function test_batchFull() public {
        vm.prank(admin);
        pool.setParams(
            MidpointPool.Params({
                batchDuration: 300,
                revealWindow: 120,
                settleWindow: 600,
                feeBps: 5,
                maxOrdersPerBatch: 2,
                maxCommitsPerTrader: 8,
                commitBond: 1e6
            })
        );
        vm.startPrank(alice);
        pool.commit(address(aapl), bytes32(uint256(1)));
        pool.commit(address(aapl), bytes32(uint256(2)));
        vm.expectRevert(MidpointPool.BatchFull.selector);
        pool.commit(address(aapl), bytes32(uint256(3)));
        vm.stopPrank();
    }

    function test_marketClosed_noCommits() public {
        vm.warp(1_791_644_400); // Saturday
        vm.prank(alice);
        vm.expectRevert(MidpointPool.MarketClosed.selector);
        pool.commit(address(aapl), bytes32(uint256(1)));
    }

    function test_revealValidation() public {
        MidpointPool.OrderReveal memory bad = _order(alice, 2, 10e18, 0, 400e6, "x");
        _commit(bad);
        MidpointPool.OrderReveal memory noLimit = _order(alice, 0, 10e18, 0, 0, "y");
        _commit(noLimit);
        MidpointPool.OrderReveal memory tooBig = _order(alice, 0, 10e18, 0, type(uint128).max, "z");
        _commit(tooBig);
        MidpointPool.OrderReveal memory sellTooBig = _order(bob, 1, 5_000e18, 0, 0, "w");
        _commit(sellTooBig);
        _toReveal();
        vm.expectRevert(MidpointPool.InvalidOrder.selector);
        pool.reveal(bad);
        vm.expectRevert(MidpointPool.InvalidOrder.selector);
        pool.reveal(noLimit);
        vm.expectRevert(MidpointPool.InsufficientBalance.selector);
        pool.reveal(tooBig);
        vm.expectRevert(MidpointPool.InsufficientBalance.selector);
        pool.reveal(sellTooBig);
        MidpointPool.OrderReveal memory unknown = _order(alice, 0, 1e18, 0, 400e6, "nope");
        vm.expectRevert(MidpointPool.UnknownCommitment.selector);
        pool.reveal(unknown);
    }

    function test_revealMany_byKeeper() public {
        MidpointPool.OrderReveal[] memory rs = new MidpointPool.OrderReveal[](2);
        rs[0] = _order(alice, 0, 10e18, 0, 400e6, "a");
        rs[1] = _order(bob, 1, 10e18, 0, 0, "b");
        _commit(rs[0]);
        _commit(rs[1]);
        _toReveal();
        vm.prank(makeAddr("keeper"));
        pool.revealMany(rs);
        _toSettle();
        vm.prank(makeAddr("keeper"));
        pool.settle(address(aapl), id);
        assertEq(pool.batchInfo(address(aapl), id).matchedBase, 10e18);
    }

    function test_deposit_withdraw_validation() public {
        vm.startPrank(alice);
        vm.expectRevert(MidpointPool.TokenNotAllowed.selector);
        pool.deposit(address(proj), 1);
        vm.expectRevert(MidpointPool.ZeroAmount.selector);
        pool.deposit(address(usdg), 0);
        vm.expectRevert(MidpointPool.ZeroAmount.selector);
        pool.withdraw(address(usdg), 0);
        vm.expectRevert(MidpointPool.InsufficientBalance.selector);
        pool.withdraw(address(usdg), 2_000_000e6);
        vm.stopPrank();
        vm.prank(guardian);
        pool.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pool.deposit(address(usdg), 1);
    }

    function test_compliance() public {
        vm.prank(admin);
        compliance.setEnabled(true);
        vm.prank(alice);
        vm.expectRevert();
        pool.commit(address(aapl), bytes32(uint256(1)));
        vm.prank(alice);
        vm.expectRevert();
        pool.deposit(address(usdg), 1);
    }

    function test_admin() public {
        vm.startPrank(admin);
        MidpointPool.Params memory p = MidpointPool.Params({
            batchDuration: 10,
            revealWindow: 120,
            settleWindow: 600,
            feeBps: 5,
            maxOrdersPerBatch: 64,
            maxCommitsPerTrader: 8,
            commitBond: 1e6
        });
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        pool.setParams(p);
        p.batchDuration = 300;
        p.maxOrdersPerBatch = 65;
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        pool.setParams(p);
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        pool.setAsset(address(usdg), true, 6);
        vm.expectRevert(BlockroomBase.ZeroAddress.selector);
        pool.setAsset(address(0), true, 6);
        vm.expectRevert(BlockroomBase.ZeroAddress.selector);
        pool.setModules(address(0), address(clock), address(fc), address(hooks));
        pool.setModules(address(guard), address(clock), address(fc), address(hooks));
        vm.stopPrank();
        (uint64 cid, uint64 ce, uint64 re, uint64 sb) = pool.currentWindows();
        assertEq(cid, id);
        assertEq(ce, (id + 1) * 300);
        assertEq(re, ce + 120);
        assertEq(sb, re + 600);
    }

    // ------------------------------------------------------------------- fuzz

    /// @dev Every execution in a batch prints at the oracle mid; value is conserved.
    function testFuzz_matchesAtMid(uint128[6] memory sizes, uint8 sideBits, uint256 oracle) public {
        oracle = bound(oracle, 50e8, 2_000e8);
        address[3] memory traders = [alice, bob, carol];
        MidpointPool.OrderReveal[] memory rs = new MidpointPool.OrderReveal[](6);
        for (uint256 i; i < 6; ++i) {
            uint128 sz = uint128(bound(sizes[i], 1e15, 100e18));
            uint8 side = uint8((sideBits >> i) & 1);
            rs[i] = _order(traders[i % 3], side, sz, 0, side == 0 ? 3_000e6 : 0, bytes32(i));
            _commit(rs[i]);
        }
        uint256 totalUsdg = usdg.balanceOf(address(pool));
        uint256 totalAapl = aapl.balanceOf(address(pool));
        _toReveal();
        pool.revealMany(rs);
        _toSettle();
        aaplFeed.set(int256(oracle));
        vm.recordLogs();
        pool.settle(address(aapl), id);
        uint256 mid = oracle / 100;
        assertEq(pool.batchInfo(address(aapl), id).mid, mid);

        // every Matched event prints exactly at the oracle mid
        bytes32 sig = keccak256("Matched(address,uint64,address,address,uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            (,, uint256 q, uint256 notional, uint256 px) =
                abi.decode(logs[i].data, (address, address, uint256, uint256, uint256));
            assertEq(px, mid, "execution not at mid");
            assertEq(notional, (q * mid) / 1e18);
        }
        uint256 sumBuy;
        uint256 sumSell;
        for (uint256 i; i < 6; ++i) {
            MidpointPool.Order memory o = pool.orderAt(address(aapl), id, i);
            if (o.side == 0) sumBuy += o.filled;
            else sumSell += o.filled;
            assertEq(o.locked, 0, "all locks released");
        }
        uint256 matched = pool.batchInfo(address(aapl), id).matchedBase;
        assertEq(sumBuy, matched);
        assertEq(sumSell, matched);
        // value conservation: pool holds exactly user balances + nothing else (fees left)
        uint256 ledgerUsdg;
        uint256 ledgerAapl;
        for (uint256 i; i < 3; ++i) {
            ledgerUsdg += pool.freeBalance(traders[i], address(usdg));
            ledgerAapl += pool.freeBalance(traders[i], address(aapl));
        }
        assertEq(ledgerAapl, totalAapl);
        assertEq(usdg.balanceOf(address(pool)), ledgerUsdg);
        assertLe(ledgerUsdg, totalUsdg);
    }
}
