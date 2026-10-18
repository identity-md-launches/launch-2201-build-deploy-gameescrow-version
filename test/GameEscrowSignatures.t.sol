// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {GameEscrow} from "../src/GameEscrow.sol";
import {EscrowTestBase} from "./helpers/EscrowTestBase.sol";

contract GameEscrowSignaturesTest is EscrowTestBase {
    function setUp() public override {
        super.setUp();
        _joined(MATCH_ID, imd, 1 ether);
    }

    function test_DomainAndDigestMatchIndependentEIP712Encoding() public view {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("NightshiftGames"),
                keccak256("2"),
                uint256(1),
                address(escrow)
            )
        );
        assertEq(escrow.DOMAIN_SEPARATOR(), domain);
        assertEq(
            escrow.hashResult(MATCH_ID, alice, false, vm.getBlockTimestamp()),
            _digest(address(escrow), 1, MATCH_ID, alice, false, vm.getBlockTimestamp())
        );
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = escrow.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(name, "NightshiftGames");
        assertEq(version, "2");
        assertEq(chainId, 1);
        assertEq(verifyingContract, address(escrow));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
    }

    function test_WrongSignerRejected() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signDigest(OTHER_KEY, _digest(address(escrow), 1, MATCH_ID, alice, false, deadline));
        vm.expectRevert(GameEscrow.InvalidSignature.selector);
        escrow.settle(MATCH_ID, alice, false, deadline, sig);
        _assertUnchanged();
    }

    function test_ExpiredSignatureRejectedAndExactDeadlineAccepted() public {
        uint256 deadline = vm.getBlockTimestamp() + 60;
        bytes memory sig = _signature(MATCH_ID, alice, false, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(GameEscrow.SignatureExpired.selector);
        escrow.settle(MATCH_ID, alice, false, deadline, sig);
        _assertUnchanged();
        // A different result can still be accepted exactly at its own deadline.
        uint256 newDeadline = vm.getBlockTimestamp();
        escrow.settle(MATCH_ID, alice, false, newDeadline, _signature(MATCH_ID, alice, false, newDeadline));
        _assertClosed(MATCH_ID);
    }

    function test_WrongContractDomainRejected() public {
        GameEscrow other = new GameEscrow(resultSigner);
        uint256 deadline = vm.getBlockTimestamp() + 60;
        bytes memory sig = _signDigest(SIGNER_KEY, _digest(address(other), 1, MATCH_ID, alice, false, deadline));
        vm.expectRevert(GameEscrow.InvalidSignature.selector);
        escrow.settle(MATCH_ID, alice, false, deadline, sig);
        _assertUnchanged();
    }

    function test_WrongChainDomainRejected() public {
        uint256 deadline = vm.getBlockTimestamp() + 60;
        bytes memory sig = _signDigest(SIGNER_KEY, _digest(address(escrow), 10, MATCH_ID, alice, false, deadline));
        vm.expectRevert(GameEscrow.InvalidSignature.selector);
        escrow.settle(MATCH_ID, alice, false, deadline, sig);
        _assertUnchanged();
    }

    function test_ChangingChainIdInvalidatesOldDomainAndAcceptsNewDomain() public {
        uint256 deadline = vm.getBlockTimestamp() + 60;
        bytes32 oldDomain = escrow.DOMAIN_SEPARATOR();
        bytes memory oldSig = _signature(MATCH_ID, alice, false, deadline);
        vm.chainId(31337);
        assertNotEq(escrow.DOMAIN_SEPARATOR(), oldDomain);
        vm.expectRevert(GameEscrow.InvalidSignature.selector);
        escrow.settle(MATCH_ID, alice, false, deadline, oldSig);
        escrow.settle(MATCH_ID, alice, false, deadline, _signature(MATCH_ID, alice, false, deadline));
    }

    function test_WrongNameOrVersionRejected() public {
        uint256 deadline = vm.getBlockTimestamp() + 60;
        for (uint256 i; i < 2; ++i) {
            bytes32 domain = keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    i == 0 ? keccak256("PinballEscrow") : keccak256("NightshiftGames"),
                    i == 0 ? keccak256("2") : keccak256("1"),
                    uint256(1),
                    address(escrow)
                )
            );
            bytes32 result = keccak256(abi.encode(escrow.RESULT_TYPEHASH(), MATCH_ID, alice, false, deadline));
            bytes memory sig = _signDigest(SIGNER_KEY, keccak256(abi.encodePacked(hex"1901", domain, result)));
            vm.expectRevert(GameEscrow.InvalidSignature.selector);
            escrow.settle(MATCH_ID, alice, false, deadline, sig);
        }
    }

    function test_PersonalSignSignatureRejected() public {
        uint256 deadline = vm.getBlockTimestamp() + 60;
        bytes32 digest = _digest(address(escrow), 1, MATCH_ID, alice, false, deadline);
        bytes32 personalDigest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        bytes memory sig = _signDigest(SIGNER_KEY, personalDigest);
        vm.expectRevert(GameEscrow.InvalidSignature.selector);
        escrow.settle(MATCH_ID, alice, false, deadline, sig);
    }

    function test_EveryResultFieldIsSigned() public {
        _joined(OTHER_ID, imd, 1 ether);
        uint256 deadline = vm.getBlockTimestamp() + 60;
        bytes memory sig = _signature(MATCH_ID, alice, false, deadline);
        vm.expectRevert(GameEscrow.InvalidSignature.selector);
        escrow.settle(OTHER_ID, alice, false, deadline, sig);
        vm.expectRevert(GameEscrow.InvalidSignature.selector);
        escrow.settle(MATCH_ID, bob, false, deadline, sig);
        vm.expectRevert(GameEscrow.InvalidSignature.selector);
        escrow.settle(MATCH_ID, alice, true, deadline, sig);
        vm.expectRevert(GameEscrow.InvalidSignature.selector);
        escrow.settle(MATCH_ID, alice, false, deadline + 1, sig);
        assertFalse(_match(MATCH_ID).settled);
        assertFalse(_match(OTHER_ID).settled);
        assertEq(imd.balanceOf(address(escrow)), 4 ether);
    }

    function test_WinnerMustBeAPlayerUnlessDraw() public {
        uint256 deadline = vm.getBlockTimestamp() + 60;
        bytes memory sig = _signature(MATCH_ID, carol, false, deadline);
        vm.expectRevert(GameEscrow.InvalidWinner.selector);
        escrow.settle(MATCH_ID, carol, false, deadline, sig);
        bytes memory zeroSig = _signature(MATCH_ID, address(0), false, deadline);
        vm.expectRevert(GameEscrow.InvalidWinner.selector);
        escrow.settle(MATCH_ID, address(0), false, deadline, zeroSig);
        _assertUnchanged();
    }

    function test_ReplayAndConflictingResultBothRejectedAfterSettlement() public {
        uint256 deadline = vm.getBlockTimestamp() + 60;
        bytes memory sig = _signature(MATCH_ID, alice, false, deadline);
        bytes memory conflictingSig = _signature(MATCH_ID, bob, false, deadline);
        escrow.settle(MATCH_ID, alice, false, deadline, sig);
        vm.expectRevert(GameEscrow.MatchClosed.selector);
        escrow.settle(MATCH_ID, alice, false, deadline, sig);
        vm.expectRevert(GameEscrow.MatchClosed.selector);
        escrow.settle(MATCH_ID, bob, false, deadline, conflictingSig);
        assertEq(imd.balanceOf(address(escrow)), 0);
        assertEq(imd.balanceOf(escrow.FEE_RECIPIENT()), 0.1 ether);
    }

    function test_SignerRotationInvalidatesPendingSignature() public {
        uint256 deadline = vm.getBlockTimestamp() + 60;
        bytes memory oldSig = _signature(MATCH_ID, alice, false, deadline);
        address newSigner = vm.addr(OTHER_KEY);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit SignerSet(resultSigner, newSigner);
        vm.prank(OWNER);
        escrow.setSigner(newSigner);
        vm.expectRevert(GameEscrow.InvalidSignature.selector);
        escrow.settle(MATCH_ID, alice, false, deadline, oldSig);
        bytes memory newSig = _signDigest(OTHER_KEY, _digest(address(escrow), 1, MATCH_ID, alice, false, deadline));
        escrow.settle(MATCH_ID, alice, false, deadline, newSig);
    }

    function test_HighSMalleableSignatureRejected() public {
        uint256 deadline = vm.getBlockTimestamp() + 60;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(SIGNER_KEY, _digest(address(escrow), 1, MATCH_ID, alice, false, deadline));
        uint256 order = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(order - uint256(s));
        bytes memory sig = abi.encodePacked(r, highS, v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        escrow.settle(MATCH_ID, alice, false, deadline, sig);
        _assertUnchanged();
    }

    function test_MalformedAndZeroRecoverySignaturesRejected() public {
        uint256 deadline = vm.getBlockTimestamp() + 60;
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, uint256(0)));
        escrow.settle(MATCH_ID, alice, false, deadline, "");
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, uint256(64)));
        escrow.settle(MATCH_ID, alice, false, deadline, new bytes(64));
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        escrow.settle(MATCH_ID, alice, false, deadline, new bytes(65));
        _assertUnchanged();
    }

    function test_InvalidVRejected() public {
        uint256 deadline = vm.getBlockTimestamp() + 60;
        (, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, _digest(address(escrow), 1, MATCH_ID, alice, false, deadline));
        bytes memory sig = abi.encodePacked(r, s, uint8(1));
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        escrow.settle(MATCH_ID, alice, false, deadline, sig);
    }

    function testFuzz_AnyNonPlayerWinnerRejected(address winner) public {
        vm.assume(winner != alice && winner != bob);
        uint256 deadline = vm.getBlockTimestamp() + 60;
        bytes memory sig = _signature(MATCH_ID, winner, false, deadline);
        vm.expectRevert(GameEscrow.InvalidWinner.selector);
        escrow.settle(MATCH_ID, winner, false, deadline, sig);
        _assertUnchanged();
    }

    function _assertUnchanged() private view {
        assertFalse(_match(MATCH_ID).settled);
        assertEq(imd.balanceOf(address(escrow)), 2 ether);
        assertEq(imd.balanceOf(alice), INITIAL_BALANCE - 1 ether);
        assertEq(imd.balanceOf(bob), INITIAL_BALANCE - 1 ether);
        assertEq(imd.balanceOf(escrow.FEE_RECIPIENT()), 0);
    }
}
