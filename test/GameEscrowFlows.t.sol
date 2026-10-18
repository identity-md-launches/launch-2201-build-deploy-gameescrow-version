// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GameEscrow} from "../src/GameEscrow.sol";
import {EscrowTestBase} from "./helpers/EscrowTestBase.sol";
import {TestToken} from "./helpers/TestToken.sol";

contract GameEscrowFlowsTest is EscrowTestBase {
    function test_BothTokensAtMinimumMiddleAndMaximum() public {
        for (uint256 t; t < 2; ++t) {
            TestToken token = t == 0 ? imd : shift;
            (uint256 min, uint256 max) = escrow.limits(address(token));
            uint256[3] memory stakes = [min, (min + max) / 2 + 7, max];
            for (uint256 i; i < stakes.length; ++i) {
                bytes32 id = keccak256(abi.encode(t, i));
                uint256 stake = stakes[i];
                uint256 balanceA = token.balanceOf(alice);
                uint256 balanceB = token.balanceOf(bob);
                uint256 balanceFee = token.balanceOf(escrow.FEE_RECIPIENT());
                vm.expectEmit(true, true, true, true, address(escrow));
                emit Opened(id, address(token), stake, GAME, alice);
                _open(id, token, stake);
                GameEscrow.Match memory m = _match(id);
                assertEq(m.token, address(token));
                assertEq(m.stake, stake);
                assertEq(m.game, GAME);
                assertEq(m.playerA, alice);
                assertEq(m.playerB, address(0));
                assertEq(m.openedAt, vm.getBlockTimestamp());
                assertEq(m.joinedAt, 0);
                assertFalse(m.settled);
                assertEq(token.balanceOf(address(escrow)), stake);

                vm.warp(vm.getBlockTimestamp() + 12);
                vm.expectEmit(true, true, false, true, address(escrow));
                emit Joined(id, bob);
                _join(id);
                assertEq(_match(id).playerB, bob);
                assertEq(_match(id).joinedAt, vm.getBlockTimestamp());
                assertEq(token.balanceOf(address(escrow)), stake * 2);

                uint256 fee = stake * 2 / 20;
                vm.expectEmit(true, true, false, true, address(escrow));
                emit Settled(id, alice, false, stake * 2 - fee, fee);
                _settle(id, alice, false);
                assertEq(token.balanceOf(alice), balanceA + stake - fee);
                assertEq(token.balanceOf(bob), balanceB - stake);
                assertEq(token.balanceOf(escrow.FEE_RECIPIENT()), balanceFee + fee);
                assertEq(token.balanceOf(address(escrow)), 0);
                _assertClosed(id);
            }
        }
    }

    function test_DrawBothTokensRefundsFullStakeAndNoFee() public {
        for (uint256 t; t < 2; ++t) {
            TestToken token = t == 0 ? imd : shift;
            uint256 stake = t == 0 ? 13 ether + 7 : 12_345 ether + 7;
            bytes32 id = bytes32(t);
            _joined(id, token, stake);
            vm.expectEmit(true, true, false, true, address(escrow));
            emit Settled(id, carol, true, stake, 0);
            _settle(id, carol, true);
            assertEq(token.balanceOf(alice), INITIAL_BALANCE);
            assertEq(token.balanceOf(bob), INITIAL_BALANCE);
            assertEq(token.balanceOf(escrow.FEE_RECIPIENT()), 0);
            assertEq(token.balanceOf(address(escrow)), 0);
            _assertClosed(id);
        }
    }

    function test_DrawMayUseZeroWinner() public {
        _joined(MATCH_ID, imd, 1 ether);
        _settle(MATCH_ID, address(0), true);
        assertEq(imd.balanceOf(alice), INITIAL_BALANCE);
        assertEq(imd.balanceOf(bob), INITIAL_BALANCE);
    }

    function test_UnjoinedRefundAtExactHourBothTokensByAnyone() public {
        for (uint256 t; t < 2; ++t) {
            TestToken token = t == 0 ? imd : shift;
            (uint256 stake,) = escrow.limits(address(token));
            bytes32 id = bytes32(t);
            _open(id, token, stake);
            vm.warp(_match(id).openedAt + 1 hours - 1);
            vm.expectRevert(GameEscrow.RefundTooEarly.selector);
            escrow.refund(id);
            vm.warp(vm.getBlockTimestamp() + 1);
            vm.expectEmit(true, false, false, true, address(escrow));
            emit Refunded(id);
            vm.prank(carol);
            escrow.refund(id);
            _assertClosed(id);
            assertEq(token.balanceOf(alice), INITIAL_BALANCE);
            assertEq(token.balanceOf(address(escrow)), 0);
            assertEq(token.balanceOf(escrow.FEE_RECIPIENT()), 0);
            vm.expectRevert(GameEscrow.MatchClosed.selector);
            escrow.refund(id);
        }
    }

    function test_JoinedRefund24HoursAfterJoinBothTokens() public {
        for (uint256 t; t < 2; ++t) {
            TestToken token = t == 0 ? imd : shift;
            (uint256 stake,) = escrow.limits(address(token));
            bytes32 id = bytes32(t);
            _open(id, token, stake);
            vm.warp(vm.getBlockTimestamp() + 1 hours - 1);
            _join(id);
            vm.warp(_match(id).openedAt + 24 hours);
            vm.expectRevert(GameEscrow.RefundTooEarly.selector);
            escrow.refund(id);
            vm.warp(_match(id).joinedAt + 24 hours - 1);
            vm.expectRevert(GameEscrow.RefundTooEarly.selector);
            escrow.refund(id);
            vm.warp(vm.getBlockTimestamp() + 1);
            vm.expectEmit(true, false, false, true, address(escrow));
            emit Refunded(id);
            vm.prank(carol);
            escrow.refund(id);
            _assertClosed(id);
            assertEq(token.balanceOf(alice), INITIAL_BALANCE);
            assertEq(token.balanceOf(bob), INITIAL_BALANCE);
            assertEq(token.balanceOf(address(escrow)), 0);
            assertEq(token.balanceOf(escrow.FEE_RECIPIENT()), 0);
        }
    }

    function test_CancelImmediatelyBothTokensAndOnlyOnce() public {
        for (uint256 t; t < 2; ++t) {
            TestToken token = t == 0 ? imd : shift;
            (uint256 stake,) = escrow.limits(address(token));
            bytes32 id = bytes32(t);
            _open(id, token, stake);
            vm.expectEmit(true, false, false, true, address(escrow));
            emit Cancelled(id);
            vm.prank(alice);
            escrow.cancel(id);
            _assertClosed(id);
            assertEq(token.balanceOf(alice), INITIAL_BALANCE);
            assertEq(token.balanceOf(address(escrow)), 0);
            vm.prank(alice);
            vm.expectRevert(GameEscrow.MatchClosed.selector);
            escrow.cancel(id);
        }
    }

    function test_CancelAfterOpenTimeoutStillWorks() public {
        _open(MATCH_ID, imd, 1 ether);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(alice);
        escrow.cancel(MATCH_ID);
        assertEq(imd.balanceOf(alice), INITIAL_BALANCE);
    }

    function test_CancelByOtherPlayerOrOwnerRefusedAndJoinedCannotCancel() public {
        _open(MATCH_ID, imd, 1 ether);
        vm.prank(bob);
        vm.expectRevert(GameEscrow.Unauthorized.selector);
        escrow.cancel(MATCH_ID);
        vm.prank(OWNER);
        vm.expectRevert(GameEscrow.Unauthorized.selector);
        escrow.cancel(MATCH_ID);
        _join(MATCH_ID);
        vm.prank(alice);
        vm.expectRevert(GameEscrow.AlreadyJoined.selector);
        escrow.cancel(MATCH_ID);
        assertEq(imd.balanceOf(address(escrow)), 2 ether);
    }

    function test_JoinOwnMatchAndThirdPlayerRefused() public {
        _open(MATCH_ID, imd, 1 ether);
        vm.prank(alice);
        vm.expectRevert(GameEscrow.CannotJoinOwnMatch.selector);
        escrow.join(MATCH_ID);
        _join(MATCH_ID);
        vm.prank(carol);
        vm.expectRevert(GameEscrow.AlreadyJoined.selector);
        escrow.join(MATCH_ID);
        assertEq(imd.balanceOf(address(escrow)), 2 ether);
    }

    function test_JoinAtDeadlineRefusedAndRefundWorks() public {
        _open(MATCH_ID, imd, 1 ether);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(bob);
        vm.expectRevert(GameEscrow.JoinWindowClosed.selector);
        escrow.join(MATCH_ID);
        escrow.refund(MATCH_ID);
    }

    function test_SettleAtTimeoutRefusedAndRefundWorks() public {
        _joined(MATCH_ID, imd, 1 ether);
        uint256 deadline = vm.getBlockTimestamp() + 2 days;
        bytes memory sig = _signature(MATCH_ID, alice, false, deadline);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.expectRevert(GameEscrow.SettleWindowClosed.selector);
        escrow.settle(MATCH_ID, alice, false, deadline, sig);
        escrow.refund(MATCH_ID);
        assertEq(imd.balanceOf(alice), INITIAL_BALANCE);
        assertEq(imd.balanceOf(bob), INITIAL_BALANCE);
    }

    function test_SettleJustBeforeTimeoutWorks() public {
        _joined(MATCH_ID, imd, 1 ether);
        vm.warp(vm.getBlockTimestamp() + 24 hours - 1);
        _settle(MATCH_ID, bob, false);
        assertEq(imd.balanceOf(bob), INITIAL_BALANCE + 0.9 ether);
    }

    function test_UnknownMatchRefusedByAllLifecycleMethods() public {
        vm.expectRevert(GameEscrow.MatchNotFound.selector);
        escrow.join(MATCH_ID);
        vm.expectRevert(GameEscrow.MatchNotFound.selector);
        escrow.cancel(MATCH_ID);
        vm.expectRevert(GameEscrow.MatchNotFound.selector);
        escrow.refund(MATCH_ID);
        vm.expectRevert(GameEscrow.MatchNotFound.selector);
        escrow.settle(MATCH_ID, alice, false, vm.getBlockTimestamp(), "");
    }

    function test_UnjoinedCannotSettle() public {
        _open(MATCH_ID, imd, 1 ether);
        vm.expectRevert(GameEscrow.NotJoined.selector);
        escrow.settle(MATCH_ID, alice, false, vm.getBlockTimestamp(), "");
    }

    function test_MatchIdAndLabelMayBeZeroButIdNeverReused() public {
        vm.prank(alice);
        escrow.open(bytes32(0), address(imd), 1 ether, bytes32(0));
        vm.prank(bob);
        vm.expectRevert(GameEscrow.MatchAlreadyExists.selector);
        escrow.open(bytes32(0), address(shift), 10_000 ether, bytes32("chess"));
        vm.prank(alice);
        escrow.cancel(bytes32(0));
        vm.prank(alice);
        vm.expectRevert(GameEscrow.MatchAlreadyExists.selector);
        escrow.open(bytes32(0), address(imd), 1 ether, GAME);
    }

    function test_InsufficientAllowanceOrBalanceCannotOpenOrJoin() public {
        vm.prank(alice);
        imd.approve(address(escrow), 1 ether - 1);
        vm.prank(alice);
        vm.expectRevert();
        escrow.open(MATCH_ID, address(imd), 1 ether, GAME);
        assertEq(_match(MATCH_ID).playerA, address(0));
        vm.prank(alice);
        imd.approve(address(escrow), 1 ether);
        _open(MATCH_ID, imd, 1 ether);
        vm.startPrank(bob);
        imd.approve(address(escrow), 1 ether - 1);
        vm.expectRevert();
        escrow.join(MATCH_ID);
        imd.approve(address(escrow), 1 ether);
        imd.transfer(carol, INITIAL_BALANCE - 1 ether + 1);
        vm.expectRevert();
        escrow.join(MATCH_ID);
        vm.stopPrank();
        assertEq(_match(MATCH_ID).playerB, address(0));
        assertEq(_match(MATCH_ID).joinedAt, 0);
        assertEq(imd.balanceOf(address(escrow)), 1 ether);
    }

    function test_JoinAlwaysTakesStoredAmountAndToken() public {
        _open(MATCH_ID, imd, 3 ether + 9);
        vm.prank(bob);
        shift.approve(address(escrow), 3 ether + 9);
        _join(MATCH_ID);
        assertEq(imd.balanceOf(bob), INITIAL_BALANCE - 3 ether - 9);
        assertEq(shift.balanceOf(bob), INITIAL_BALANCE);
        assertEq(imd.allowance(bob, address(escrow)), INITIAL_BALANCE - 3 ether - 9);
    }

    function test_TerminalMatchesRejectEverySubsequentAction() public {
        for (uint256 outcome; outcome < 4; ++outcome) {
            bytes32 id = bytes32(outcome);
            _open(id, imd, 1 ether);
            if (outcome == 0) {
                vm.prank(alice);
                escrow.cancel(id);
            } else if (outcome == 1) {
                vm.warp(vm.getBlockTimestamp() + 1 hours);
                escrow.refund(id);
            } else {
                _join(id);
                if (outcome == 2) {
                    _settle(id, alice, false);
                } else {
                    vm.warp(vm.getBlockTimestamp() + 24 hours);
                    escrow.refund(id);
                }
            }
            vm.expectRevert(GameEscrow.MatchClosed.selector);
            escrow.join(id);
            vm.expectRevert(GameEscrow.MatchClosed.selector);
            escrow.cancel(id);
            vm.expectRevert(GameEscrow.MatchClosed.selector);
            escrow.refund(id);
            vm.expectRevert(GameEscrow.MatchClosed.selector);
            escrow.settle(id, alice, false, vm.getBlockTimestamp(), "");
            vm.expectRevert(GameEscrow.MatchAlreadyExists.selector);
            escrow.open(id, address(imd), 1 ether, GAME);
        }
    }

    function test_ConcurrentMatchesKeepTokensAndPotsSeparate() public {
        _joined(MATCH_ID, imd, 2 ether);
        _joined(OTHER_ID, shift, 20_000 ether);
        _open(bytes32("third"), imd, 3 ether);
        _settle(MATCH_ID, bob, false);
        assertEq(imd.balanceOf(address(escrow)), 3 ether);
        assertEq(shift.balanceOf(address(escrow)), 40_000 ether);
        _settle(OTHER_ID, alice, true);
        assertEq(shift.balanceOf(address(escrow)), 0);
        vm.prank(alice);
        escrow.cancel(bytes32("third"));
        assertEq(imd.balanceOf(address(escrow)), 0);
    }

    function testFuzz_AnyStakeConservesPotAndRoundsFeeDown(bool useShift, uint256 rawStake, bool bWins) public {
        TestToken token = useShift ? shift : imd;
        uint256 cap = useShift ? escrow.SHIFT_HARD_CAP() : escrow.IMD_HARD_CAP();
        vm.prank(OWNER);
        escrow.setLimits(address(token), 1, cap);
        uint256 stake = bound(rawStake, 1, cap);
        _joined(MATCH_ID, token, stake);
        address winner = bWins ? bob : alice;
        _settle(MATCH_ID, winner, false);
        uint256 fee = (stake * 2 * 5) / 100;
        uint256 payout = stake * 2 - fee;
        assertEq(token.balanceOf(winner), INITIAL_BALANCE - stake + payout);
        assertEq(token.balanceOf(bWins ? alice : bob), INITIAL_BALANCE - stake);
        assertEq(token.balanceOf(escrow.FEE_RECIPIENT()), fee);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(payout + fee, stake * 2);
        assertLt(stake * 2 * 5 - fee * 100, 100);
    }

    function testFuzz_DrawAlwaysRefundsBothExactly(bool useShift, uint256 rawStake) public {
        TestToken token = useShift ? shift : imd;
        (uint256 min, uint256 max) = escrow.limits(address(token));
        uint256 stake = bound(rawStake, min, max);
        _joined(MATCH_ID, token, stake);
        _settle(MATCH_ID, bob, true);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE);
        assertEq(token.balanceOf(escrow.FEE_RECIPIENT()), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
    }
}
