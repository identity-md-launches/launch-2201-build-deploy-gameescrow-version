// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {GameEscrow} from "../src/GameEscrow.sol";
import {TestToken} from "./helpers/TestToken.sol";
import {EscrowTestBase} from "./helpers/EscrowTestBase.sol";

contract FactoryHarness {
    function deploy(address initialSigner) external returns (GameEscrow) {
        return new GameEscrow(initialSigner);
    }

    function deployDeterministic(address initialSigner, bytes32 salt) external returns (GameEscrow) {
        return new GameEscrow{salt: salt}(initialSigner);
    }
}

contract GameEscrowAdminTest is EscrowTestBase {
    function test_InitialConfigurationAndConstructorEvents() public {
        vm.expectEmit(true, true, false, true);
        emit SignerSet(address(0), OWNER);
        vm.expectEmit(true, false, false, true);
        emit LimitsSet(address(imd), 0.5 ether, 1_000 ether);
        vm.expectEmit(true, false, false, true);
        emit LimitsSet(address(shift), 10_000 ether, 50_000_000 ether);
        GameEscrow fresh = new GameEscrow(OWNER);
        assertEq(fresh.owner(), OWNER);
        assertEq(fresh.signer(), OWNER);
        assertEq(fresh.IMD(), 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
        assertEq(fresh.SHIFT(), 0xE5e58E53d0Bb204Aa62c995A6c8CC8a48e60C3AC);
        assertEq(fresh.FEE_RECIPIENT(), 0x1119d5Df2f046bC2d3c0F6279EF2E9cE49422d44);
        assertEq(fresh.FEE_BPS(), 500);
        assertEq(fresh.BPS_DENOMINATOR(), 10_000);
        assertEq(fresh.IMD_HARD_CAP(), 10_000 ether);
        assertEq(fresh.SHIFT_HARD_CAP(), 1_000_000_000 ether);
        assertEq(fresh.JOIN_TIMEOUT(), 1 hours);
        assertEq(fresh.SETTLE_TIMEOUT(), 24 hours);
        assertFalse(fresh.paused());
        _assertLimits(fresh, address(imd), 0.5 ether, 1_000 ether);
        _assertLimits(fresh, address(shift), 10_000 ether, 50_000_000 ether);
    }

    function test_FactoryAndCreate2DeploymentOnEmptyChainKeepRequestedOwner() public {
        vm.etch(address(imd), "");
        vm.etch(address(shift), "");
        FactoryHarness factory = new FactoryHarness();
        GameEscrow created = factory.deploy(OWNER);
        assertEq(created.owner(), OWNER);
        assertEq(created.signer(), OWNER);
        assertNotEq(created.owner(), address(factory));
        bytes32 salt = keccak256("GameEscrow launch rehearsal");
        bytes memory init = abi.encodePacked(type(GameEscrow).creationCode, abi.encode(OWNER));
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(factory), salt, keccak256(init))))));
        GameEscrow deterministic = factory.deployDeterministic(OWNER, salt);
        assertEq(address(deterministic), predicted);
        assertEq(deterministic.owner(), OWNER);
        assertEq(deterministic.signer(), OWNER);
        assertLe(init.length, 49_152);
        assertLe(address(deterministic).code.length, 24_576);
        // External contracts are checked only when first used, never during construction.
        vm.expectRevert();
        created.open(MATCH_ID, address(imd), 1 ether, GAME);
    }

    function test_RuntimeHasNoForbiddenOpcodesAndFitsDeploymentLimit() public view {
        bytes memory code = address(escrow).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    function test_ZeroSignerRejectedAtConstructionAndRotation() public {
        vm.expectRevert(GameEscrow.InvalidSigner.selector);
        new GameEscrow(address(0));
        vm.prank(OWNER);
        vm.expectRevert(GameEscrow.InvalidSigner.selector);
        escrow.setSigner(address(0));
        assertEq(escrow.signer(), resultSigner);
    }

    function test_UnsupportedTokenRejectedForOpenAndLimits() public {
        vm.expectRevert(GameEscrow.UnsupportedToken.selector);
        escrow.open(MATCH_ID, address(0), 1 ether, GAME);
        vm.expectRevert(GameEscrow.UnsupportedToken.selector);
        escrow.open(MATCH_ID, carol, 1 ether, GAME);
        vm.prank(OWNER);
        vm.expectRevert(GameEscrow.UnsupportedToken.selector);
        escrow.setLimits(carol, 1, 2);
        _assertLimits(escrow, carol, 0, 0);
    }

    function test_SetLimitsAtHardCapsAndRefuseAboveOrReversed() public {
        for (uint256 t; t < 2; ++t) {
            address token = t == 0 ? address(imd) : address(shift);
            uint256 cap = t == 0 ? escrow.IMD_HARD_CAP() : escrow.SHIFT_HARD_CAP();
            vm.expectEmit(true, false, false, true, address(escrow));
            emit LimitsSet(token, cap, cap);
            vm.prank(OWNER);
            escrow.setLimits(token, cap, cap);
            _assertLimits(escrow, token, cap, cap);
            vm.startPrank(OWNER);
            vm.expectRevert(GameEscrow.InvalidLimits.selector);
            escrow.setLimits(token, 1, cap + 1);
            vm.expectRevert(GameEscrow.InvalidLimits.selector);
            escrow.setLimits(token, cap + 1, cap);
            vm.expectRevert(GameEscrow.InvalidLimits.selector);
            escrow.setLimits(token, 2, 1);
            vm.expectRevert(GameEscrow.InvalidLimits.selector);
            escrow.setLimits(token, 0, type(uint256).max);
            vm.stopPrank();
            _assertLimits(escrow, token, cap, cap);
        }
    }

    function test_LimitChangesNeverAlterAnExistingMatchOrBlockJoin() public {
        for (uint256 t; t < 2; ++t) {
            TestToken token = t == 0 ? imd : shift;
            bytes32 id = bytes32(t);
            (uint256 min, uint256 max) = escrow.limits(address(token));
            _open(id, token, max);
            vm.prank(OWNER);
            escrow.setLimits(address(token), min, min);
            _join(id);
            assertEq(_match(id).stake, max);
            assertEq(token.balanceOf(address(escrow)), 2 * max);
            _settle(id, alice, false);
            assertEq(token.balanceOf(escrow.FEE_RECIPIENT()), 2 * max / 20);
            vm.prank(alice);
            vm.expectRevert(GameEscrow.StakeOutOfBounds.selector);
            escrow.open(keccak256(abi.encode(id)), address(token), max, GAME);
        }
        _open(OTHER_ID, imd, 0.5 ether);
        vm.prank(OWNER);
        escrow.setLimits(address(imd), 10 ether, 100 ether);
        _join(OTHER_ID);
        _settle(OTHER_ID, bob, true);
    }

    function test_ZeroMinimumIsAnExplicitOwnerChoiceWithinSpecifiedBounds() public {
        vm.prank(OWNER);
        escrow.setLimits(address(imd), 0, 1 ether);
        _joined(MATCH_ID, imd, 0);
        _settle(MATCH_ID, alice, false);
        _assertClosed(MATCH_ID);
        assertEq(imd.balanceOf(address(escrow)), 0);
        assertEq(imd.balanceOf(alice), INITIAL_BALANCE);
        assertEq(imd.balanceOf(bob), INITIAL_BALANCE);
    }

    function test_PauseBlocksOpenAndJoinAndEmitsEvents() public {
        _open(MATCH_ID, imd, 1 ether);
        vm.expectEmit(false, false, false, true, address(escrow));
        emit Paused(OWNER);
        vm.prank(OWNER);
        escrow.pause();
        assertTrue(escrow.paused());
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.open(OTHER_ID, address(imd), 1 ether, GAME);
        vm.prank(bob);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.join(MATCH_ID);
        vm.prank(OWNER);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.pause();
        vm.expectEmit(false, false, false, true, address(escrow));
        emit Unpaused(OWNER);
        vm.prank(OWNER);
        escrow.unpause();
        assertFalse(escrow.paused());
        _join(MATCH_ID);
        _open(OTHER_ID, shift, 10_000 ether);
        vm.prank(OWNER);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        escrow.unpause();
    }

    function test_PauseAllowsSettlementDrawBothRefundsCancelAndAdminChanges() public {
        bytes32 drawId = bytes32("draw");
        bytes32 refundJoinedId = bytes32("refund joined");
        bytes32 refundOpenId = bytes32("refund open");
        _joined(MATCH_ID, imd, 1 ether);
        _joined(drawId, shift, 10_000 ether);
        _joined(refundJoinedId, imd, 1 ether);
        _open(refundOpenId, shift, 10_000 ether);
        _open(OTHER_ID, imd, 1 ether);
        vm.prank(OWNER);
        escrow.pause();
        _settle(MATCH_ID, bob, false);
        _settle(drawId, address(0), true);
        vm.prank(alice);
        escrow.cancel(OTHER_ID);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        escrow.refund(refundJoinedId);
        escrow.refund(refundOpenId);
        vm.startPrank(OWNER);
        escrow.setLimits(address(imd), 2 ether, 3 ether);
        escrow.setSigner(OWNER);
        vm.stopPrank();
        assertTrue(escrow.paused());
        assertEq(imd.balanceOf(address(escrow)), 0);
        assertEq(shift.balanceOf(address(escrow)), 0);
    }

    function test_OwnerCannotWithdrawRedirectUpgradeOrTransferOwnership() public {
        _joined(MATCH_ID, imd, 1 ether);
        bytes[6] memory calls = [
            abi.encodeWithSignature("withdraw(address,uint256)", address(imd), 2 ether),
            abi.encodeWithSignature("rescueTokens(address,address,uint256)", address(imd), OWNER, 2 ether),
            abi.encodeWithSignature("setFeeRecipient(address)", OWNER),
            abi.encodeWithSignature("setFee(uint256)", 1_000),
            abi.encodeWithSignature("transferOwnership(address)", carol),
            abi.encodeWithSignature("upgradeTo(address)", carol)
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(OWNER);
            (bool success,) = address(escrow).call(calls[i]);
            assertFalse(success);
        }
        assertEq(escrow.owner(), OWNER);
        assertEq(imd.balanceOf(OWNER), 0);
        assertEq(imd.balanceOf(address(escrow)), 2 ether);
    }

    function test_DirectDonationDoesNotChangePotOrAllowSweep() public {
        vm.prank(carol);
        imd.transfer(address(escrow), 7 ether);
        _joined(MATCH_ID, imd, 1 ether);
        _settle(MATCH_ID, alice, false);
        assertEq(imd.balanceOf(alice), INITIAL_BALANCE + 0.9 ether);
        assertEq(imd.balanceOf(address(escrow)), 7 ether);
        assertEq(imd.balanceOf(escrow.FEE_RECIPIENT()), 0.1 ether);
    }

    function testFuzz_OnlyOwnerCanAdminister(address caller) public {
        vm.assume(caller != OWNER);
        vm.startPrank(caller);
        vm.expectRevert(GameEscrow.Unauthorized.selector);
        escrow.setSigner(caller);
        vm.expectRevert(GameEscrow.Unauthorized.selector);
        escrow.setLimits(address(imd), 1, 2);
        vm.expectRevert(GameEscrow.Unauthorized.selector);
        escrow.pause();
        vm.expectRevert(GameEscrow.Unauthorized.selector);
        escrow.unpause();
        vm.stopPrank();
        assertEq(escrow.signer(), resultSigner);
        assertFalse(escrow.paused());
        _assertLimits(escrow, address(imd), 0.5 ether, 1_000 ether);
    }

    function testFuzz_StakesOutsideInitialLimitsRefused(bool useShift, uint256 raw, bool above) public {
        address token = useShift ? address(shift) : address(imd);
        (uint256 min, uint256 max) = escrow.limits(token);
        uint256 stake = above ? bound(raw, max + 1, type(uint256).max) : bound(raw, 0, min - 1);
        vm.prank(alice);
        vm.expectRevert(GameEscrow.StakeOutOfBounds.selector);
        escrow.open(MATCH_ID, token, stake, GAME);
        assertEq(_match(MATCH_ID).playerA, address(0));
    }

    function testFuzz_SetLimitsAcceptsExactlyOrderedBoundsBelowCap(bool useShift, uint256 min, uint256 max) public {
        address token = useShift ? address(shift) : address(imd);
        uint256 cap = useShift ? escrow.SHIFT_HARD_CAP() : escrow.IMD_HARD_CAP();
        if (min > max || max > cap) {
            vm.prank(OWNER);
            vm.expectRevert(GameEscrow.InvalidLimits.selector);
            escrow.setLimits(token, min, max);
        } else {
            vm.prank(OWNER);
            escrow.setLimits(token, min, max);
            _assertLimits(escrow, token, min, max);
        }
    }

    function testFuzz_ConfiguredInclusiveBoundsUsedForFutureOpens(bool useShift, uint256 a, uint256 b) public {
        TestToken token = useShift ? shift : imd;
        uint256 cap = useShift ? escrow.SHIFT_HARD_CAP() : escrow.IMD_HARD_CAP();
        uint256 min = bound(a, 0, cap);
        uint256 max = bound(b, min, cap);
        vm.prank(OWNER);
        escrow.setLimits(address(token), min, max);
        _open(MATCH_ID, token, min);
        _open(OTHER_ID, token, max);
        assertEq(token.balanceOf(address(escrow)), min + max);
    }

    function _assertLimits(GameEscrow target, address token, uint256 expectedMin, uint256 expectedMax) private view {
        (uint256 min, uint256 max) = target.limits(token);
        assertEq(min, expectedMin);
        assertEq(max, expectedMax);
    }
}
