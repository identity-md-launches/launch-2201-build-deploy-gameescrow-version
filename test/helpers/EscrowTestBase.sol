// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GameEscrow} from "../../src/GameEscrow.sol";
import {TestToken} from "./TestToken.sol";

abstract contract EscrowTestBase is Test {
    GameEscrow internal escrow;
    TestToken internal imd;
    TestToken internal shift;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal resultSigner;
    uint256 internal constant SIGNER_KEY = 0xA11CE512;
    uint256 internal constant OTHER_KEY = 0xB0B512;
    bytes32 internal constant MATCH_ID = keccak256("match-1");
    bytes32 internal constant OTHER_ID = keccak256("match-2");
    bytes32 internal constant GAME = bytes32("pinball");
    address internal constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    uint256 internal constant INITIAL_BALANCE = 10_000_000_000 ether;

    event Opened(bytes32 indexed matchId, address indexed token, uint256 stake, bytes32 game, address indexed playerA);
    event Joined(bytes32 indexed matchId, address indexed playerB);
    event Settled(bytes32 indexed matchId, address indexed winner, bool draw, uint256 payout, uint256 fee);
    event Refunded(bytes32 indexed matchId);
    event Cancelled(bytes32 indexed matchId);
    event SignerSet(address indexed previousSigner, address indexed newSigner);
    event LimitsSet(address indexed token, uint256 min, uint256 max);
    event Paused(address account);
    event Unpaused(address account);

    function setUp() public virtual {
        vm.warp(1_000_000);
        vm.chainId(1);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        resultSigner = vm.addr(SIGNER_KEY);
        escrow = new GameEscrow(OWNER);
        vm.prank(OWNER);
        escrow.setSigner(resultSigner);
        TestToken implementation = new TestToken();
        vm.etch(escrow.IMD(), address(implementation).code);
        vm.etch(escrow.SHIFT(), address(implementation).code);
        imd = TestToken(escrow.IMD());
        shift = TestToken(escrow.SHIFT());
        _fund(imd, alice);
        _fund(imd, bob);
        _fund(imd, carol);
        _fund(shift, alice);
        _fund(shift, bob);
        _fund(shift, carol);
    }

    function _fund(TestToken token, address player) internal {
        token.mint(player, INITIAL_BALANCE);
        vm.prank(player);
        token.approve(address(escrow), INITIAL_BALANCE);
    }

    function _open(bytes32 id, TestToken token, uint256 stake) internal {
        vm.prank(alice);
        escrow.open(id, address(token), stake, GAME);
    }

    function _join(bytes32 id) internal {
        vm.prank(bob);
        escrow.join(id);
    }

    function _joined(bytes32 id, TestToken token, uint256 stake) internal {
        _open(id, token, stake);
        _join(id);
    }

    // Construct the typed digest independently of the implementation's hashResult helper.
    function _digest(
        address verifyingContract,
        uint256 chainId,
        bytes32 id,
        address winner,
        bool draw,
        uint256 deadline
    ) internal pure returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("NightshiftGames"),
                keccak256("2"),
                chainId,
                verifyingContract
            )
        );
        bytes32 result = keccak256(
            abi.encode(
                keccak256("Result(bytes32 matchId,address winner,bool draw,uint256 deadline)"),
                id,
                winner,
                draw,
                deadline
            )
        );
        return keccak256(abi.encodePacked(hex"1901", domain, result));
    }

    function _signDigest(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signature(bytes32 id, address winner, bool draw, uint256 deadline) internal view returns (bytes memory) {
        return _signDigest(SIGNER_KEY, _digest(address(escrow), this.chainIdForTest(), id, winner, draw, deadline));
    }

    // An external read prevents optimizer caching across a test's vm.chainId mutation.
    function chainIdForTest() external view returns (uint256) {
        return block.chainid;
    }

    function _settle(bytes32 id, address winner, bool draw) internal {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signature(id, winner, draw, deadline);
        vm.prank(carol);
        escrow.settle(id, winner, draw, deadline, sig);
    }

    function _match(bytes32 id) internal view returns (GameEscrow.Match memory m) {
        (m.token, m.stake, m.game, m.playerA, m.playerB, m.openedAt, m.joinedAt, m.settled) = escrow.matches(id);
    }

    function _assertClosed(bytes32 id) internal view {
        assertTrue(_match(id).settled);
    }
}
