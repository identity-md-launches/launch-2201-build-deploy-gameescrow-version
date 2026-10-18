// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {GameEscrow} from "../src/GameEscrow.sol";
import {TestToken} from "./helpers/TestToken.sol";
import {EscrowTestBase} from "./helpers/EscrowTestBase.sol";

contract GameEscrowAdversarialTest is EscrowTestBase {
    function test_FalseReturningTokenCannotOpenAndRollbackFreesId() public {
        imd.setTransferMode(true, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd)));
        escrow.open(MATCH_ID, address(imd), 1 ether, GAME);
        assertEq(_match(MATCH_ID).playerA, address(0));
        assertEq(imd.balanceOf(alice), INITIAL_BALANCE);
        assertEq(imd.allowance(alice, address(escrow)), INITIAL_BALANCE);
        imd.setTransferMode(false, false);
        _open(MATCH_ID, imd, 1 ether);
    }

    function test_FalseReturningTokenCannotJoinAndStateRollsBack() public {
        _open(MATCH_ID, imd, 1 ether);
        imd.setTransferMode(true, false);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd)));
        escrow.join(MATCH_ID);
        assertEq(_match(MATCH_ID).playerB, address(0));
        assertEq(_match(MATCH_ID).joinedAt, 0);
        assertEq(imd.balanceOf(address(escrow)), 1 ether);
        assertEq(imd.balanceOf(bob), INITIAL_BALANCE);
        imd.setTransferMode(false, false);
        _join(MATCH_ID);
    }

    function test_ExactDepositRejectsBothUnderAndOverCreditOnOpenAndJoin() public {
        for (uint256 i; i < 2; ++i) {
            imd.setDepositDelta(i == 0 ? 1 : 0, i == 0 ? 0 : 1);
            vm.prank(alice);
            vm.expectRevert(GameEscrow.IncorrectDeposit.selector);
            escrow.open(MATCH_ID, address(imd), 1 ether, GAME);
            assertEq(_match(MATCH_ID).playerA, address(0));
            assertEq(imd.balanceOf(alice), INITIAL_BALANCE);
            assertEq(imd.balanceOf(address(escrow)), 0);
        }
        imd.setDepositDelta(0, 0);
        _open(MATCH_ID, imd, 1 ether);
        for (uint256 i; i < 2; ++i) {
            imd.setDepositDelta(i == 0 ? 1 : 0, i == 0 ? 0 : 1);
            vm.prank(bob);
            vm.expectRevert(GameEscrow.IncorrectDeposit.selector);
            escrow.join(MATCH_ID);
            assertEq(_match(MATCH_ID).playerB, address(0));
            assertEq(imd.balanceOf(bob), INITIAL_BALANCE);
            assertEq(imd.balanceOf(address(escrow)), 1 ether);
        }
        imd.setDepositDelta(0, 0);
        _join(MATCH_ID);
    }

    function test_NoReturnTokenSupportedOnDepositSettlementAndRefund() public {
        imd.setTransferMode(false, true);
        _joined(MATCH_ID, imd, 1 ether);
        _settle(MATCH_ID, alice, false);
        assertEq(imd.balanceOf(alice), INITIAL_BALANCE + 0.9 ether);
        assertEq(imd.balanceOf(escrow.FEE_RECIPIENT()), 0.1 ether);
        _joined(OTHER_ID, imd, 2 ether);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        escrow.refund(OTHER_ID);
        assertEq(imd.balanceOf(address(escrow)), 0);
    }

    function test_FailedFeeTransferRollsBackWinnerPaymentAndSignatureConsumption() public {
        _joined(MATCH_ID, imd, 1 ether);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signature(MATCH_ID, alice, false, deadline);
        imd.setBlockedRecipient(escrow.FEE_RECIPIENT());
        vm.expectRevert(TestToken.BlockedRecipient.selector);
        escrow.settle(MATCH_ID, alice, false, deadline, sig);
        _assertJoinedFundsIntact();
        imd.setBlockedRecipient(address(0));
        escrow.settle(MATCH_ID, alice, false, deadline, sig);
        _assertClosed(MATCH_ID);
        assertEq(imd.balanceOf(address(escrow)), 0);
    }

    function test_FalseReturningPayoutRollsBackSettlement() public {
        _joined(MATCH_ID, imd, 1 ether);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signature(MATCH_ID, alice, false, deadline);
        imd.setTransferMode(true, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd)));
        escrow.settle(MATCH_ID, alice, false, deadline, sig);
        _assertJoinedFundsIntact();
        imd.setTransferMode(false, false);
        escrow.settle(MATCH_ID, alice, false, deadline, sig);
    }

    function test_FailedSecondDrawTransferRollsBackFirstRefund() public {
        _joined(MATCH_ID, imd, 1 ether);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signature(MATCH_ID, address(0), true, deadline);
        imd.setBlockedRecipient(bob);
        vm.expectRevert(TestToken.BlockedRecipient.selector);
        escrow.settle(MATCH_ID, address(0), true, deadline, sig);
        _assertJoinedFundsIntact();
        imd.setBlockedRecipient(address(0));
        escrow.settle(MATCH_ID, address(0), true, deadline, sig);
        assertEq(imd.balanceOf(alice), INITIAL_BALANCE);
        assertEq(imd.balanceOf(bob), INITIAL_BALANCE);
    }

    function test_FailedSecondTimeoutRefundRollsBackFirstRefund() public {
        _joined(MATCH_ID, imd, 1 ether);
        imd.setBlockedRecipient(bob);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.expectRevert(TestToken.BlockedRecipient.selector);
        escrow.refund(MATCH_ID);
        _assertJoinedFundsIntact();
        imd.setBlockedRecipient(address(0));
        escrow.refund(MATCH_ID);
        assertEq(imd.balanceOf(alice), INITIAL_BALANCE);
        assertEq(imd.balanceOf(bob), INITIAL_BALANCE);
    }

    function test_FailedCancelTransferRollsBackAndCanRetry() public {
        _open(MATCH_ID, imd, 1 ether);
        imd.setBlockedRecipient(alice);
        vm.prank(alice);
        vm.expectRevert(TestToken.BlockedRecipient.selector);
        escrow.cancel(MATCH_ID);
        assertFalse(_match(MATCH_ID).settled);
        assertEq(imd.balanceOf(address(escrow)), 1 ether);
        imd.setBlockedRecipient(address(0));
        vm.prank(alice);
        escrow.cancel(MATCH_ID);
        assertEq(imd.balanceOf(alice), INITIAL_BALANCE);
    }

    function test_OneFailedMatchDoesNotBlockUnrelatedMatches() public {
        _joined(MATCH_ID, imd, 1 ether);
        vm.prank(alice);
        escrow.open(OTHER_ID, address(imd), 2 ether, GAME);
        vm.prank(carol);
        escrow.join(OTHER_ID);
        imd.setBlockedRecipient(bob);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signature(MATCH_ID, bob, false, deadline);
        vm.expectRevert(TestToken.BlockedRecipient.selector);
        escrow.settle(MATCH_ID, bob, false, deadline, sig);
        _settle(OTHER_ID, carol, false);
        _assertClosed(OTHER_ID);
        assertFalse(_match(MATCH_ID).settled);
        assertEq(imd.balanceOf(address(escrow)), 2 ether);
    }

    function test_ReentrancyOnOpenCannotJoinBeforeDepositCompletes() public {
        imd.setHook(address(escrow), abi.encodeCall(GameEscrow.join, (MATCH_ID)));
        _open(MATCH_ID, imd, 1 ether);
        _assertHookBlocked();
        assertEq(_match(MATCH_ID).playerB, address(0));
        assertEq(imd.balanceOf(address(escrow)), 1 ether);
    }

    function test_ReentrancyOnJoinCannotSettleBeforeDepositCompletes() public {
        _open(MATCH_ID, imd, 1 ether);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signature(MATCH_ID, bob, false, deadline);
        imd.setHook(address(escrow), abi.encodeCall(GameEscrow.settle, (MATCH_ID, bob, false, deadline, sig)));
        _join(MATCH_ID);
        _assertHookBlocked();
        assertFalse(_match(MATCH_ID).settled);
        assertEq(imd.balanceOf(address(escrow)), 2 ether);
    }

    function test_ReentrancyOnSettlementCannotSettleTwice() public {
        _joined(MATCH_ID, imd, 1 ether);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signature(MATCH_ID, alice, false, deadline);
        imd.setHook(address(escrow), abi.encodeCall(GameEscrow.settle, (MATCH_ID, alice, false, deadline, sig)));
        escrow.settle(MATCH_ID, alice, false, deadline, sig);
        _assertHookBlocked();
        assertEq(imd.balanceOf(alice), INITIAL_BALANCE + 0.9 ether);
        assertEq(imd.balanceOf(escrow.FEE_RECIPIENT()), 0.1 ether);
    }

    function test_ReentrancyOnRefundCannotRefundTwice() public {
        _joined(MATCH_ID, imd, 1 ether);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        imd.setHook(address(escrow), abi.encodeCall(GameEscrow.refund, (MATCH_ID)));
        escrow.refund(MATCH_ID);
        _assertHookBlocked();
        assertEq(imd.balanceOf(alice), INITIAL_BALANCE);
        assertEq(imd.balanceOf(bob), INITIAL_BALANCE);
    }

    function test_ReentrancyOnCancelCannotCancelTwice() public {
        _open(MATCH_ID, imd, 1 ether);
        imd.setHook(address(escrow), abi.encodeCall(GameEscrow.cancel, (MATCH_ID)));
        vm.prank(alice);
        escrow.cancel(MATCH_ID);
        _assertHookBlocked();
        assertEq(imd.balanceOf(alice), INITIAL_BALANCE);
    }

    function test_ReentrancyAcrossMatchesIsBlockedDuringDeposit() public {
        _open(OTHER_ID, imd, 2 ether);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        imd.setHook(address(escrow), abi.encodeCall(GameEscrow.refund, (OTHER_ID)));
        _open(MATCH_ID, imd, 1 ether);
        _assertHookBlocked();
        assertFalse(_match(OTHER_ID).settled);
        assertEq(imd.balanceOf(address(escrow)), 3 ether);
        escrow.refund(OTHER_ID);
        assertEq(imd.balanceOf(address(escrow)), 1 ether);
    }

    function _assertHookBlocked() private view {
        assertFalse(imd.hookSucceeded());
        assertEq(imd.hookResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }

    function _assertJoinedFundsIntact() private view {
        assertFalse(_match(MATCH_ID).settled);
        assertEq(imd.balanceOf(address(escrow)), 2 ether);
        assertEq(imd.balanceOf(alice), INITIAL_BALANCE - 1 ether);
        assertEq(imd.balanceOf(bob), INITIAL_BALANCE - 1 ether);
        assertEq(imd.balanceOf(escrow.FEE_RECIPIENT()), 0);
    }
}
