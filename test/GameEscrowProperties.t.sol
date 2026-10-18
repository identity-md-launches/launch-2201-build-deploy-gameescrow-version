// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GameEscrow} from "src/GameEscrow.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {EscrowTestBase} from "./helpers/EscrowTestBase.sol";
import {TestToken} from "./helpers/TestToken.sol";

/// @dev Independent edge examples complement the state machine and the existing flow tests.
/// forge-config: default.fuzz.runs = 1000
contract GameEscrowPropertiesTest is EscrowTestBase {
    function test_FeeStepsAtSingleWeiBoundariesForBothTokens() public {
        // Each player stakes s, so the smallest nonzero fee occurs at s = 10 wei.
        // Explicit examples avoid copying the production arithmetic into the oracle.
        uint256[10] memory stakes = [uint256(1), 9, 10, 11, 19, 20, 21, 99, 100, 101];
        uint256[10] memory fees = [uint256(0), 0, 1, 1, 1, 2, 2, 9, 10, 10];
        uint256[10] memory payouts = [uint256(2), 18, 19, 21, 37, 38, 40, 189, 190, 192];
        for (uint256 t; t < 2; ++t) {
            TestToken token = t == 0 ? imd : shift;
            vm.prank(OWNER);
            escrow.setLimits(address(token), 1, 101);
            for (uint256 i; i < stakes.length; ++i) {
                bytes32 id = keccak256(abi.encode("fee step", t, i));
                _joined(id, token, stakes[i]);
                uint256 winnerBefore = token.balanceOf(bob);
                uint256 loserBefore = token.balanceOf(alice);
                uint256 feeBefore = token.balanceOf(escrow.FEE_RECIPIENT());
                vm.expectEmit(true, true, false, true, address(escrow));
                emit Settled(id, bob, false, payouts[i], fees[i]);
                _settle(id, bob, false);
                assertEq(token.balanceOf(bob) - winnerBefore, payouts[i]);
                assertEq(token.balanceOf(alice), loserBefore);
                assertEq(token.balanceOf(escrow.FEE_RECIPIENT()) - feeBefore, fees[i]);
                assertEq(token.balanceOf(address(escrow)), 0);
                _assertClosed(id);
            }
        }
    }

    function test_HardCapAndOneWeiBelowItSettleWithoutDustForBothTokens() public {
        for (uint256 t; t < 2; ++t) {
            TestToken token = t == 0 ? imd : shift;
            uint256 cap = t == 0 ? 10_000 ether : 1_000_000_000 ether;
            vm.prank(OWNER);
            escrow.setLimits(address(token), cap - 1, cap);
            for (uint256 delta; delta < 2; ++delta) {
                bytes32 id = keccak256(abi.encode("cap", t, delta));
                _joined(id, token, cap - delta);
                uint256 beforeA = token.balanceOf(alice);
                uint256 beforeFee = token.balanceOf(escrow.FEE_RECIPIENT());
                _settle(id, alice, false);
                assertEq(token.balanceOf(alice) - beforeA, cap / 10 * 19 - delta);
                assertEq(token.balanceOf(escrow.FEE_RECIPIENT()) - beforeFee, cap / 10 - delta);
                assertEq(token.balanceOf(address(escrow)), 0);
            }
        }
    }

    function test_InitialOutOfRangeEdgesLeaveBalancesAllowancesAndIdUntouched() public {
        for (uint256 t; t < 2; ++t) {
            TestToken token = t == 0 ? imd : shift;
            (uint256 min, uint256 max) = escrow.limits(address(token));
            uint256[4] memory amounts = [uint256(0), min - 1, max + 1, type(uint256).max];
            bytes32 id = bytes32(t);
            bytes memory unused = abi.encode(_match(id));
            for (uint256 i; i < amounts.length; ++i) {
                vm.prank(alice);
                vm.expectRevert(GameEscrow.StakeOutOfBounds.selector);
                escrow.open(id, address(token), amounts[i], GAME);
                assertEq(abi.encode(_match(id)), unused);
                assertEq(token.balanceOf(alice), INITIAL_BALANCE);
                assertEq(token.balanceOf(address(escrow)), 0);
                assertEq(token.allowance(alice, address(escrow)), INITIAL_BALANCE);
            }
            _open(id, token, min); // a rejected attempt must not consume the ID
        }
    }

    function test_ApprovalForOtherTokenCannotFundJoin() public {
        for (uint256 t; t < 2; ++t) {
            TestToken token = t == 0 ? imd : shift;
            TestToken wrongToken = t == 0 ? shift : imd;
            (uint256 stake,) = escrow.limits(address(token));
            bytes32 id = bytes32(t);
            _open(id, token, stake);
            bytes memory beforeMatch = abi.encode(_match(id));
            vm.startPrank(bob);
            token.approve(address(escrow), 0);
            wrongToken.approve(address(escrow), stake);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(escrow), 0, stake)
            );
            escrow.join(id);
            vm.stopPrank();
            assertEq(abi.encode(_match(id)), beforeMatch);
            assertEq(token.balanceOf(address(escrow)), stake);
            assertEq(token.balanceOf(bob), INITIAL_BALANCE);
            assertEq(wrongToken.balanceOf(bob), INITIAL_BALANCE);
            assertEq(wrongToken.allowance(bob, address(escrow)), stake);
            vm.prank(bob);
            token.approve(address(escrow), stake);
            _join(id);
            assertEq(token.allowance(bob, address(escrow)), 0);
            _settle(id, bob, true);
        }
    }

    function testFuzz_LimitChangesPreserveTermsThroughEveryExit(
        bool useShift,
        uint256 rawStake,
        uint256 newMinSeed,
        uint256 newMaxSeed,
        uint8 outcomeSeed,
        bytes32 game
    ) public {
        TestToken token = useShift ? shift : imd;
        (uint256 min, uint256 max) = escrow.limits(address(token));
        uint256 stake = bound(rawStake, min, max);
        uint256 outcome = outcomeSeed % 5; // cancel, win, draw, open refund, joined refund
        uint256 openedAt = vm.getBlockTimestamp();
        vm.prank(alice);
        escrow.open(MATCH_ID, address(token), stake, game);
        uint256 cap = useShift ? 1_000_000_000 ether : 10_000 ether;
        uint256 newMin = bound(newMinSeed, 0, cap);
        uint256 newMax = bound(newMaxSeed, newMin, cap);
        vm.prank(OWNER);
        escrow.setLimits(address(token), newMin, newMax);
        bool joined = outcome == 1 || outcome == 2 || outcome == 4;
        if (joined) {
            vm.warp(openedAt + 3599);
            _join(MATCH_ID);
        }
        // Both a zero ceiling and a pause must leave every existing exit usable.
        vm.startPrank(OWNER);
        escrow.setLimits(address(token), 0, 0);
        escrow.pause();
        vm.stopPrank();
        if (outcome == 0) {
            vm.prank(alice);
            escrow.cancel(MATCH_ID);
        } else if (outcome == 1 || outcome == 2) {
            _settle(MATCH_ID, bob, outcome == 2);
        } else {
            vm.warp(joined ? openedAt + 3599 + 24 hours : openedAt + 1 hours);
            vm.prank(carol);
            escrow.refund(MATCH_ID);
        }
        GameEscrow.Match memory m = _match(MATCH_ID);
        assertEq(m.token, address(token));
        assertEq(m.stake, stake);
        assertEq(m.game, game);
        assertEq(m.playerA, alice);
        assertEq(m.playerB, joined ? bob : address(0));
        assertEq(m.openedAt, openedAt);
        assertEq(m.joinedAt, joined ? openedAt + 3599 : 0);
        assertTrue(m.settled);
        assertEq(token.balanceOf(address(escrow)), 0);
        uint256 fee = outcome == 1 ? stake / 10 : 0;
        assertEq(token.balanceOf(escrow.FEE_RECIPIENT()), fee);
        assertEq(token.balanceOf(alice), outcome == 1 ? INITIAL_BALANCE - stake : INITIAL_BALANCE);
        assertEq(token.balanceOf(bob), outcome == 1 ? INITIAL_BALANCE + stake - fee : INITIAL_BALANCE);
        assertEq(token.balanceOf(carol), INITIAL_BALANCE);
    }

    function testFuzz_CancelAndJoinOrderingNeverPaysBothPaths(bool useShift, uint256 rawStake, bool cancelFirst)
        public
    {
        TestToken token = useShift ? shift : imd;
        (uint256 min, uint256 max) = escrow.limits(address(token));
        uint256 stake = bound(rawStake, min, max);
        _open(MATCH_ID, token, stake);
        if (cancelFirst) {
            vm.prank(alice);
            escrow.cancel(MATCH_ID);
            vm.prank(bob);
            vm.expectRevert(GameEscrow.MatchClosed.selector);
            escrow.join(MATCH_ID);
            assertEq(_match(MATCH_ID).playerB, address(0));
        } else {
            _join(MATCH_ID);
            vm.prank(alice);
            vm.expectRevert(GameEscrow.AlreadyJoined.selector);
            escrow.cancel(MATCH_ID);
            assertEq(token.balanceOf(address(escrow)), 2 * stake);
            _settle(MATCH_ID, carol, true);
        }
        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(token.balanceOf(escrow.FEE_RECIPIENT()), 0);
        _assertClosed(MATCH_ID);
    }

    function testFuzz_DonationCannotSubsidizeAnUnderfundedJoin(bool useShift, uint256 rawStake, uint256 rawDonation)
        public
    {
        TestToken token = useShift ? shift : imd;
        (uint256 min, uint256 max) = escrow.limits(address(token));
        uint256 stake = bound(rawStake, min, max);
        uint256 donation = bound(rawDonation, stake, stake * 10);
        _open(MATCH_ID, token, stake);
        vm.prank(carol);
        token.transfer(address(escrow), donation);
        vm.prank(bob);
        token.transfer(carol, INITIAL_BALANCE - stake + 1);
        bytes memory beforeMatch = abi.encode(_match(MATCH_ID));
        uint256 beforeAllowance = token.allowance(bob, address(escrow));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, stake - 1, stake));
        escrow.join(MATCH_ID);
        assertEq(abi.encode(_match(MATCH_ID)), beforeMatch);
        assertEq(token.balanceOf(address(escrow)), stake + donation);
        assertEq(token.balanceOf(bob), stake - 1);
        assertEq(token.allowance(bob, address(escrow)), beforeAllowance);
        vm.prank(carol);
        token.transfer(bob, 1);
        _join(MATCH_ID);
        assertEq(token.balanceOf(bob), 0);
        _settle(MATCH_ID, bob, false);
        assertEq(token.balanceOf(bob), stake * 2 - stake / 10);
        assertEq(token.balanceOf(escrow.FEE_RECIPIENT()), stake / 10);
        assertEq(token.balanceOf(address(escrow)), donation);
    }

    function testFuzz_ArbitraryMatchIdAndGameSurviveFullLifecycle(bytes32 id, bytes32 game, bool useShift) public {
        TestToken token = useShift ? shift : imd;
        (uint256 stake,) = escrow.limits(address(token));
        vm.prank(alice);
        escrow.open(id, address(token), stake, game);
        _join(id);
        _settle(id, bob, true);
        GameEscrow.Match memory m = _match(id);
        assertEq(m.game, game);
        assertEq(m.token, address(token));
        assertEq(m.stake, stake);
        assertEq(m.playerA, alice);
        assertEq(m.playerB, bob);
        assertTrue(m.settled);
        vm.prank(carol);
        vm.expectRevert(GameEscrow.MatchAlreadyExists.selector);
        escrow.open(id, address(token), stake, bytes32(~uint256(game)));
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    // vm.chainId in the runner accepts only the uint64 range.
    function testFuzz_DomainUsesChainIdAcrossRunnerRange(uint64 chainId, bool useShift) public {
        vm.chainId(chainId);
        TestToken token = useShift ? shift : imd;
        (uint256 stake,) = escrow.limits(address(token));
        _joined(MATCH_ID, token, stake);
        uint256 deadline = vm.getBlockTimestamp() + 60;
        bytes32 digest = _digest(address(escrow), chainId, MATCH_ID, bob, false, deadline);
        assertEq(escrow.hashResult(MATCH_ID, bob, false, deadline), digest);
        bytes memory wrongChain =
            _signDigest(SIGNER_KEY, _digest(address(escrow), chainId ^ 1, MATCH_ID, bob, false, deadline));
        vm.expectRevert(GameEscrow.InvalidSignature.selector);
        escrow.settle(MATCH_ID, bob, false, deadline, wrongChain);
        assertFalse(_match(MATCH_ID).settled);
        escrow.settle(MATCH_ID, bob, false, deadline, _signDigest(SIGNER_KEY, digest));
        _assertClosed(MATCH_ID);
        assertEq(token.balanceOf(address(escrow)), 0);
    }
}
