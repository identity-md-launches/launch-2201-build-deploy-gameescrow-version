// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GameEscrow} from "../src/GameEscrow.sol";
import {TestToken} from "./helpers/TestToken.sol";
import {EscrowTestBase} from "./helpers/EscrowTestBase.sol";

/// @dev An independent state machine predicts both success and failure and maintains its own ledger.
contract EscrowHandler is Test {
    uint256 public constant MATCH_COUNT = 16;
    uint256 private constant SIGNER_KEY = 0xA11CE512;
    uint256 private constant WRONG_KEY = 0xB0B512;
    uint256 private constant START_BALANCE = 10_000_000_000 ether;
    bytes32 private constant GAME = bytes32("chess");

    struct ExpectedMatch {
        uint256 tokenIndex;
        uint256 stake;
        address a;
        address b;
        uint256 opened;
        uint256 joined;
        uint8 phase; // 0 unused, 1 open, 2 joined, 3 terminal
    }

    GameEscrow private immutable escrow;
    address private immutable admin;
    address private immutable feeRecipient;
    address[3] private players;
    TestToken[2] private tokens;
    ExpectedMatch[16] private model;
    uint256[2] private minimum;
    uint256[2] private maximum;
    uint256[2] private caps;
    bool private isPaused;
    mapping(address token => mapping(address account => uint256 balance)) private expected;
    mapping(address token => mapping(address account => uint256 allowance)) private allowance;

    constructor(GameEscrow target, address a, address b, address c) {
        escrow = target;
        admin = target.owner();
        feeRecipient = target.FEE_RECIPIENT();
        players = [a, b, c];
        tokens = [TestToken(target.IMD()), TestToken(target.SHIFT())];
        minimum = [uint256(0.5 ether), uint256(10_000 ether)];
        maximum = [uint256(1_000 ether), uint256(50_000_000 ether)];
        caps = [uint256(10_000 ether), uint256(1_000_000_000 ether)];
        for (uint256 t; t < 2; ++t) {
            for (uint256 p; p < 3; ++p) {
                expected[address(tokens[t])][players[p]] = START_BALANCE;
                allowance[address(tokens[t])][players[p]] = START_BALANCE;
            }
        }
    }

    function open(uint256 idSeed, uint256 tokenSeed, uint256 amountSeed, uint256 actorSeed) public {
        uint256 id = idSeed % MATCH_COUNT;
        uint256 t = tokenSeed % 2;
        uint256 amount = bound(amountSeed, minimum[t], maximum[t]);
        if (amountSeed % 5 == 0) amount = maximum[t] + 1;
        address actor = players[actorSeed % 3];
        address token = address(tokens[t]);
        bool allowed = model[id].phase == 0 && !isPaused && amount >= minimum[t] && amount <= maximum[t]
            && expected[token][actor] >= amount && allowance[token][actor] >= amount;
        vm.prank(actor);
        (bool ok,) = address(escrow).call(abi.encodeCall(GameEscrow.open, (bytes32(id), token, amount, GAME)));
        assertEq(ok, allowed, "open success differs from model");
        if (ok) {
            model[id] = ExpectedMatch(t, amount, actor, address(0), vm.getBlockTimestamp(), 0, 1);
            _deposit(token, actor, amount);
        }
    }

    function join(uint256 idSeed, uint256 actorSeed) public {
        uint256 id = idSeed % MATCH_COUNT;
        ExpectedMatch storage m = model[id];
        address actor = players[actorSeed % 3];
        address token = address(tokens[m.tokenIndex]);
        bool allowed = m.phase == 1 && !isPaused && actor != m.a && vm.getBlockTimestamp() < m.opened + 1 hours
            && expected[token][actor] >= m.stake && allowance[token][actor] >= m.stake;
        vm.prank(actor);
        (bool ok,) = address(escrow).call(abi.encodeCall(GameEscrow.join, (bytes32(id))));
        assertEq(ok, allowed, "join success differs from model");
        if (ok) {
            m.b = actor;
            m.joined = vm.getBlockTimestamp();
            m.phase = 2;
            _deposit(token, actor, m.stake);
        }
    }

    function settle(uint256 idSeed, uint256 winnerSeed, bool draw, bool expired, bool wrongSigner) public {
        uint256 id = idSeed % MATCH_COUNT;
        ExpectedMatch storage m = model[id];
        address winner = winnerSeed % 4 == 3 ? address(this) : players[winnerSeed % 3];
        uint256 deadline = expired ? vm.getBlockTimestamp() - 1 : vm.getBlockTimestamp() + 1 hours;
        bool allowed = m.phase == 2 && vm.getBlockTimestamp() < m.joined + 24 hours && !expired && !wrongSigner
            && (draw || winner == m.a || winner == m.b);
        bytes memory signature = _signature(bytes32(id), winner, draw, deadline, wrongSigner);
        (bool ok,) =
            address(escrow).call(abi.encodeCall(GameEscrow.settle, (bytes32(id), winner, draw, deadline, signature)));
        assertEq(ok, allowed, "settle success differs from model");
        if (ok) {
            m.phase = 3;
            address token = address(tokens[m.tokenIndex]);
            if (draw) {
                _pay(token, m.a, m.stake);
                _pay(token, m.b, m.stake);
            } else {
                uint256 pot = m.stake * 2;
                uint256 fee = pot / 20;
                _pay(token, winner, pot - fee);
                _pay(token, feeRecipient, fee);
            }
        }
    }

    function cancel(uint256 idSeed, uint256 actorSeed) public {
        uint256 id = idSeed % MATCH_COUNT;
        ExpectedMatch storage m = model[id];
        address actor = players[actorSeed % 3];
        bool allowed = m.phase == 1 && m.a == actor;
        vm.prank(actor);
        (bool ok,) = address(escrow).call(abi.encodeCall(GameEscrow.cancel, (bytes32(id))));
        assertEq(ok, allowed, "cancel success differs from model");
        if (ok) {
            m.phase = 3;
            _pay(address(tokens[m.tokenIndex]), m.a, m.stake);
        }
    }

    function refund(uint256 idSeed) public {
        uint256 id = idSeed % MATCH_COUNT;
        ExpectedMatch storage m = model[id];
        bool allowed = (m.phase == 1 && vm.getBlockTimestamp() >= m.opened + 1 hours)
            || (m.phase == 2 && vm.getBlockTimestamp() >= m.joined + 24 hours);
        (bool ok,) = address(escrow).call(abi.encodeCall(GameEscrow.refund, (bytes32(id))));
        assertEq(ok, allowed, "refund success differs from model");
        if (ok) {
            bool joined = m.phase == 2;
            m.phase = 3;
            _pay(address(tokens[m.tokenIndex]), m.a, m.stake);
            if (joined) _pay(address(tokens[m.tokenIndex]), m.b, m.stake);
        }
    }

    function advanceTime(uint256 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 36 hours));
    }

    function setLimits(uint256 tokenSeed, uint256 minSeed, uint256 maxSeed) external {
        uint256 t = tokenSeed % 2;
        uint256 min = bound(minSeed, 0, caps[t] + 1);
        uint256 max = bound(maxSeed, 0, caps[t] + 1);
        bool allowed = min <= max && max <= caps[t];
        vm.prank(admin);
        (bool ok,) = address(escrow).call(abi.encodeCall(GameEscrow.setLimits, (address(tokens[t]), min, max)));
        assertEq(ok, allowed, "limits success differs from model");
        if (ok) {
            minimum[t] = min;
            maximum[t] = max;
        }
    }

    function setPaused(bool desired) external {
        vm.prank(admin);
        (bool ok,) = address(escrow)
            .call(desired ? abi.encodeCall(GameEscrow.pause, ()) : abi.encodeCall(GameEscrow.unpause, ()));
        assertEq(ok, desired != isPaused, "pause success differs from model");
        if (ok) isPaused = desired;
    }

    function assertModel() external view {
        assertEq(escrow.paused(), isPaused);
        uint256[2] memory liabilities;
        for (uint256 id; id < MATCH_COUNT; ++id) {
            ExpectedMatch memory m = model[id];
            (
                address token,
                uint256 stake,
                bytes32 game,
                address a,
                address b,
                uint256 opened,
                uint256 joined,
                bool closed
            ) = escrow.matches(bytes32(id));
            assertEq(token, m.phase == 0 ? address(0) : address(tokens[m.tokenIndex]));
            assertEq(stake, m.stake);
            assertEq(game, m.phase == 0 ? bytes32(0) : GAME);
            assertEq(a, m.a);
            assertEq(b, m.b);
            assertEq(opened, m.opened);
            assertEq(joined, m.joined);
            assertEq(closed, m.phase == 3);
            if (m.phase == 1) liabilities[m.tokenIndex] += m.stake;
            else if (m.phase == 2) liabilities[m.tokenIndex] += m.stake * 2;
        }
        for (uint256 t; t < 2; ++t) {
            address token = address(tokens[t]);
            (uint256 min, uint256 max) = escrow.limits(token);
            assertEq(min, minimum[t]);
            assertEq(max, maximum[t]);
            assertLe(max, caps[t]);
            uint256 total = tokens[t].balanceOf(address(escrow)) + tokens[t].balanceOf(feeRecipient);
            assertEq(tokens[t].balanceOf(address(escrow)), liabilities[t], "escrow is not fully backed");
            assertEq(tokens[t].balanceOf(address(escrow)), expected[token][address(escrow)]);
            assertEq(tokens[t].balanceOf(feeRecipient), expected[token][feeRecipient]);
            for (uint256 p; p < 3; ++p) {
                uint256 balance = tokens[t].balanceOf(players[p]);
                assertEq(balance, expected[token][players[p]], "player ledger mismatch");
                assertEq(tokens[t].allowance(players[p], address(escrow)), allowance[token][players[p]]);
                total += balance;
            }
            assertEq(total, 3 * START_BALANCE, "tokens lost or created");
        }
    }

    function drainAfterTimeout() external {
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        for (uint256 id; id < MATCH_COUNT; ++id) {
            if (model[id].phase == 1 || model[id].phase == 2) refund(id);
        }
        assertEq(tokens[0].balanceOf(address(escrow)), 0, "IMD funds stuck");
        assertEq(tokens[1].balanceOf(address(escrow)), 0, "SHIFT funds stuck");
    }

    function _deposit(address token, address actor, uint256 amount) private {
        expected[token][actor] -= amount;
        allowance[token][actor] -= amount;
        expected[token][address(escrow)] += amount;
    }

    function _pay(address token, address recipient, uint256 amount) private {
        expected[token][address(escrow)] -= amount;
        expected[token][recipient] += amount;
    }

    function _signature(bytes32 id, address winner, bool draw, uint256 deadline, bool wrongSigner)
        private
        view
        returns (bytes memory)
    {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("NightshiftGames"),
                keccak256("2"),
                block.chainid,
                address(escrow)
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
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(wrongSigner ? WRONG_KEY : SIGNER_KEY, keccak256(abi.encodePacked(hex"1901", domain, result)));
        return abi.encodePacked(r, s, v);
    }
}

contract GameEscrowInvariantTest is EscrowTestBase {
    EscrowHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new EscrowHandler(escrow, alice, bob, carol);
        // Begin with open and joined matches of each token to exercise all transitions immediately.
        handler.open(0, 0, 1 ether + 1, 0);
        handler.open(1, 1, 10_000 ether + 1, 1);
        handler.open(2, 0, 2 ether + 1, 1);
        handler.join(2, 2);
        handler.open(3, 1, 20_000 ether + 1, 2);
        handler.join(3, 0);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.open.selector;
        selectors[1] = handler.join.selector;
        selectors[2] = handler.settle.selector;
        selectors[3] = handler.cancel.selector;
        selectors[4] = handler.refund.selector;
        selectors[5] = handler.advanceTime.selector;
        selectors[6] = handler.setLimits.selector;
        selectors[7] = handler.setPaused.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_EveryBalanceAndMatchAgreesWithIndependentModel() public view {
        handler.assertModel();
    }

    function afterInvariant() public {
        handler.drainAfterTimeout();
        handler.assertModel();
    }
}
