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
    bytes32[16] private matchIds;
    bytes32[] private archivedIds;
    mapping(bytes32 => bytes32) private archivedState;
    uint256 private nextId = MATCH_COUNT;
    uint256[2] private minimum;
    uint256[2] private maximum;
    uint256[2] private caps;
    uint256[2] private donations;
    uint256 private signerKey = SIGNER_KEY;
    bool private isPaused;
    // Successful calls, not just attempted selectors: used by the deterministic harness check.
    uint256[5] public successes; // open, join, settle, cancel, refund
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
        for (uint256 id; id < MATCH_COUNT; ++id) {
            matchIds[id] = bytes32(id);
        }
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
        _open(id, t, amount, actor);
    }

    function _open(uint256 id, uint256 t, uint256 amount, address actor) private {
        address token = address(tokens[t]);
        bool allowed = model[id].phase == 0 && !isPaused && amount >= minimum[t] && amount <= maximum[t]
            && expected[token][actor] >= amount && allowance[token][actor] >= amount;
        vm.prank(actor);
        (bool ok,) = address(escrow).call(abi.encodeCall(GameEscrow.open, (matchIds[id], token, amount, GAME)));
        assertEq(ok, allowed, "open success differs from model");
        if (ok) {
            model[id] = ExpectedMatch(t, amount, actor, address(0), vm.getBlockTimestamp(), 0, 1);
            _deposit(token, actor, amount);
            ++successes[0];
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
        (bool ok,) = address(escrow).call(abi.encodeCall(GameEscrow.join, (matchIds[id])));
        assertEq(ok, allowed, "join success differs from model");
        if (ok) {
            m.b = actor;
            m.joined = vm.getBlockTimestamp();
            m.phase = 2;
            _deposit(token, actor, m.stake);
            ++successes[1];
        }
    }

    function settle(uint256 idSeed, uint256 winnerSeed, bool draw, bool expired, bool wrongSigner) public {
        uint256 id = idSeed % MATCH_COUNT;
        ExpectedMatch storage m = model[id];
        address winner = winnerSeed % 4 == 3 ? address(this) : players[winnerSeed % 3];
        uint256 deadline = expired ? vm.getBlockTimestamp() - 1 : vm.getBlockTimestamp() + 1 hours;
        bool allowed = m.phase == 2 && vm.getBlockTimestamp() < m.joined + 24 hours && !expired && !wrongSigner
            && (draw || winner == m.a || winner == m.b);
        bytes memory signature = _signature(matchIds[id], winner, draw, deadline, wrongSigner);
        (bool ok,) =
            address(escrow).call(abi.encodeCall(GameEscrow.settle, (matchIds[id], winner, draw, deadline, signature)));
        assertEq(ok, allowed, "settle success differs from model");
        if (ok) {
            m.phase = 3;
            ++successes[2];
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
        (bool ok,) = address(escrow).call(abi.encodeCall(GameEscrow.cancel, (matchIds[id])));
        assertEq(ok, allowed, "cancel success differs from model");
        if (ok) {
            m.phase = 3;
            _pay(address(tokens[m.tokenIndex]), m.a, m.stake);
            ++successes[3];
        }
    }

    function refund(uint256 idSeed) public {
        uint256 id = idSeed % MATCH_COUNT;
        ExpectedMatch storage m = model[id];
        bool allowed = (m.phase == 1 && vm.getBlockTimestamp() >= m.opened + 1 hours)
            || (m.phase == 2 && vm.getBlockTimestamp() >= m.joined + 24 hours);
        (bool ok,) = address(escrow).call(abi.encodeCall(GameEscrow.refund, (matchIds[id])));
        assertEq(ok, allowed, "refund success differs from model");
        if (ok) {
            bool joined = m.phase == 2;
            m.phase = 3;
            _pay(address(tokens[m.tokenIndex]), m.a, m.stake);
            if (joined) _pay(address(tokens[m.tokenIndex]), m.b, m.stake);
            ++successes[4];
        }
    }

    /// @dev Complements raw, frequently invalid calls with reachable lifecycle transitions.
    /// Closed slots get fresh IDs; every archived match remains subject to immutability checks.
    function progress(uint256 idSeed, uint256 choice, uint256 amountSeed) external {
        uint256 id = idSeed % MATCH_COUNT;
        ExpectedMatch storage m = model[id];
        if (m.phase == 3) {
            archivedIds.push(matchIds[id]);
            archivedState[matchIds[id]] = _stateHash(matchIds[id]);
            matchIds[id] = bytes32(nextId++);
            delete model[id];
        }
        if (m.phase == 0) {
            uint256 t = choice % 2;
            _open(id, t, bound(amountSeed, minimum[t], maximum[t]), players[choice % 3]);
        } else if (m.phase == 1) {
            if (vm.getBlockTimestamp() >= m.opened + 1 hours) refund(id);
            else if (choice % 4 == 0) cancel(id, _playerIndex(m.a));
            else join(id, (_playerIndex(m.a) + 1 + choice % 2) % 3);
        } else {
            if (vm.getBlockTimestamp() >= m.joined + 24 hours) refund(id);
            else settle(id, _playerIndex(choice % 2 == 0 ? m.a : m.b), choice % 3 == 0, false, false);
        }
    }

    function donate(uint256 tokenSeed, uint256 actorSeed, uint256 amountSeed) external {
        uint256 t = tokenSeed % 2;
        address actor = players[actorSeed % 3];
        address token = address(tokens[t]);
        uint256 amount = bound(amountSeed, 0, expected[token][actor]);
        vm.prank(actor);
        assertTrue(tokens[t].transfer(address(escrow), amount));
        expected[token][actor] -= amount;
        expected[token][address(escrow)] += amount;
        donations[t] += amount;
    }

    function changeAllowance(uint256 tokenSeed, uint256 actorSeed, uint256 amountSeed) external {
        uint256 t = tokenSeed % 2;
        address actor = players[actorSeed % 3];
        uint256 mode = amountSeed % 4;
        uint256 amount = mode == 0 ? 0 : mode == 1 ? type(uint256).max : bound(amountSeed, 0, caps[t]);
        vm.prank(actor);
        assertTrue(tokens[t].approve(address(escrow), amount));
        allowance[address(tokens[t])][actor] = amount;
    }

    function rotateSigner(bool useOtherKey) external {
        uint256 key = useOtherKey ? WRONG_KEY : SIGNER_KEY;
        address newSigner = vm.addr(key);
        vm.prank(admin);
        escrow.setSigner(newSigner);
        signerKey = key;
    }

    function unauthorizedAdmin(uint256 actorSeed, uint256 operation) external {
        address actor = players[actorSeed % 3];
        bytes memory data;
        if (operation % 4 == 0) data = abi.encodeCall(GameEscrow.setSigner, (actor));
        else if (operation % 4 == 1) data = abi.encodeCall(GameEscrow.setLimits, (address(tokens[0]), 0, 0));
        else if (operation % 4 == 2) data = abi.encodeCall(GameEscrow.pause, ());
        else data = abi.encodeCall(GameEscrow.unpause, ());
        vm.prank(actor);
        (bool ok, bytes memory reason) = address(escrow).call(data);
        assertFalse(ok, "non-owner changed configuration");
        assertEq(reason, abi.encodeWithSelector(GameEscrow.Unauthorized.selector));
    }

    function replayArchived(uint256 seed, uint256 operation) external {
        if (archivedIds.length == 0) return;
        bytes32 id = archivedIds[seed % archivedIds.length];
        bytes memory data;
        if (operation % 5 == 0) {
            data = abi.encodeCall(GameEscrow.join, (id));
        } else if (operation % 5 == 1) {
            data = abi.encodeCall(GameEscrow.cancel, (id));
        } else if (operation % 5 == 2) {
            data = abi.encodeCall(GameEscrow.refund, (id));
        } else if (operation % 5 == 3) {
            uint256 deadline = vm.getBlockTimestamp() + 1 hours;
            data = abi.encodeCall(
                GameEscrow.settle, (id, players[0], true, deadline, _signature(id, players[0], true, deadline, false))
            );
        } else {
            data = abi.encodeCall(GameEscrow.open, (id, address(tokens[0]), minimum[0], GAME));
        }
        vm.prank(players[0]);
        (bool ok,) = address(escrow).call(data);
        assertFalse(ok, "archived match accepted another action");
        assertEq(_stateHash(id), archivedState[id], "archived match mutated");
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
        assertEq(escrow.signer(), vm.addr(signerKey));
        assertEq(escrow.owner(), 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5);
        assertEq(escrow.FEE_RECIPIENT(), 0x1119d5Df2f046bC2d3c0F6279EF2E9cE49422d44);
        assertEq(escrow.FEE_BPS(), 500);
        for (uint256 i; i < archivedIds.length; ++i) {
            assertEq(_stateHash(archivedIds[i]), archivedState[archivedIds[i]], "terminal match changed");
        }
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
            ) = escrow.matches(matchIds[id]);
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
            assertEq(tokens[t].balanceOf(address(escrow)), liabilities[t] + donations[t], "escrow is not fully backed");
            assertEq(tokens[t].balanceOf(address(escrow)), expected[token][address(escrow)]);
            assertEq(tokens[t].balanceOf(feeRecipient), expected[token][feeRecipient]);
            for (uint256 p; p < 3; ++p) {
                uint256 balance = tokens[t].balanceOf(players[p]);
                assertEq(balance, expected[token][players[p]], "player ledger mismatch");
                assertEq(tokens[t].allowance(players[p], address(escrow)), allowance[token][players[p]]);
                total += balance;
            }
            assertEq(total, 3 * START_BALANCE, "tokens lost or created");
            assertEq(tokens[t].totalSupply(), 3 * START_BALANCE, "token supply changed");
        }
    }

    function drainAfterTimeout() external {
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        for (uint256 id; id < MATCH_COUNT; ++id) {
            if (model[id].phase == 1 || model[id].phase == 2) refund(id);
        }
        assertEq(tokens[0].balanceOf(address(escrow)), donations[0], "IMD stakes stuck");
        assertEq(tokens[1].balanceOf(address(escrow)), donations[1], "SHIFT stakes stuck");
    }

    function _deposit(address token, address actor, uint256 amount) private {
        expected[token][actor] -= amount;
        if (allowance[token][actor] != type(uint256).max) allowance[token][actor] -= amount;
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
        uint256 key = wrongSigner ? (signerKey == SIGNER_KEY ? WRONG_KEY : SIGNER_KEY) : signerKey;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked(hex"1901", domain, result)));
        return abi.encodePacked(r, s, v);
    }

    function _playerIndex(address actor) private view returns (uint256) {
        for (uint256 p; p < players.length; ++p) {
            if (players[p] == actor) return p;
        }
        revert("unknown model player");
    }

    function _stateHash(bytes32 id) private view returns (bytes32) {
        (bool ok, bytes memory state) = address(escrow).staticcall(abi.encodeWithSignature("matches(bytes32)", id));
        assertTrue(ok, "match getter failed");
        return keccak256(state);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
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
        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = handler.open.selector;
        selectors[1] = handler.join.selector;
        selectors[2] = handler.settle.selector;
        selectors[3] = handler.cancel.selector;
        selectors[4] = handler.refund.selector;
        selectors[5] = handler.advanceTime.selector;
        selectors[6] = handler.setLimits.selector;
        selectors[7] = handler.setPaused.selector;
        selectors[8] = handler.progress.selector;
        selectors[9] = handler.donate.selector;
        selectors[10] = handler.changeAllowance.selector;
        selectors[11] = handler.rotateSigner.selector;
        selectors[12] = handler.unauthorizedAdmin.selector;
        selectors[13] = handler.replayArchived.selector;
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

    function test_HandlerExercisesEverySuccessfulTransitionAndArchivedReplay() public {
        handler.donate(0, 2, 7);
        handler.changeAllowance(0, 0, 1); // unlimited approval
        handler.rotateSigner(true);
        handler.settle(2, 1, false, false, false);
        handler.settle(3, 2, true, false, false);
        handler.cancel(0, 0);
        handler.progress(0, 0, 1 ether); // archive cancelled ID and open a fresh one
        for (uint256 op; op < 5; ++op) {
            handler.replayArchived(0, op);
        }
        handler.advanceTime(1 hours);
        handler.refund(1);
        handler.progress(2, 1, 10_000 ether);
        handler.progress(2, 1, 0);
        handler.setPaused(true);
        handler.advanceTime(24 hours);
        handler.refund(2);
        for (uint256 op; op < 4; ++op) {
            handler.unauthorizedAdmin(0, op);
        }
        handler.assertModel();
        handler.drainAfterTimeout();
        handler.assertModel();
        for (uint256 op; op < 5; ++op) {
            assertGt(handler.successes(op), 0, "unexercised lifecycle path");
        }
    }
}
