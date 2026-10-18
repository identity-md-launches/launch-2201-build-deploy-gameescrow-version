// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title NIGHTSHIFT GameEscrow v2
/// @notice Two-player, equal-stake escrow for server-verified skill games.
/// @dev Match IDs are permanent nonces, including after cancellation or refund.
contract GameEscrow is EIP712, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant SHIFT = 0xE5e58E53d0Bb204Aa62c995A6c8CC8a48e60C3AC;
    address public constant FEE_RECIPIENT = 0x1119d5Df2f046bC2d3c0F6279EF2E9cE49422d44;
    address public constant owner = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;

    uint256 public constant IMD_HARD_CAP = 10_000 ether;
    uint256 public constant SHIFT_HARD_CAP = 1_000_000_000 ether;
    uint256 public constant FEE_BPS = 500;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant JOIN_TIMEOUT = 1 hours;
    uint256 public constant SETTLE_TIMEOUT = 24 hours;
    bytes32 public constant RESULT_TYPEHASH =
        keccak256("Result(bytes32 matchId,address winner,bool draw,uint256 deadline)");

    struct Match {
        address token;
        uint256 stake;
        bytes32 game;
        address playerA;
        address playerB;
        uint256 openedAt;
        uint256 joinedAt;
        bool settled;
    }

    struct Limits {
        uint256 min;
        uint256 max;
    }

    mapping(bytes32 matchId => Match) public matches;
    mapping(address token => Limits) public limits;
    address public signer;

    event Opened(bytes32 indexed matchId, address indexed token, uint256 stake, bytes32 game, address indexed playerA);
    event Joined(bytes32 indexed matchId, address indexed playerB);
    /// @param payout Winner's total payout, or the amount refunded to EACH player on a draw.
    event Settled(bytes32 indexed matchId, address indexed winner, bool draw, uint256 payout, uint256 fee);
    event Refunded(bytes32 indexed matchId);
    event Cancelled(bytes32 indexed matchId);
    event SignerSet(address indexed previousSigner, address indexed newSigner);
    event LimitsSet(address indexed token, uint256 min, uint256 max);

    error Unauthorized();
    error InvalidSigner();
    error UnsupportedToken();
    error InvalidLimits();
    error StakeOutOfBounds();
    error MatchAlreadyExists();
    error MatchNotFound();
    error MatchClosed();
    error AlreadyJoined();
    error NotJoined();
    error CannotJoinOwnMatch();
    error JoinWindowClosed();
    error SettleWindowClosed();
    error RefundTooEarly();
    error SignatureExpired();
    error InvalidSignature();
    error InvalidWinner();
    error IncorrectDeposit();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    /// @param initialSigner The launch supplies the fixed owner's address as this argument.
    /// @dev No external calls: deployment also works on an empty chain and through a factory.
    constructor(address initialSigner) EIP712("NightshiftGames", "2") {
        if (initialSigner == address(0)) revert InvalidSigner();
        signer = initialSigner;
        emit SignerSet(address(0), initialSigner);
        _setLimits(IMD, 0.5 ether, 1_000 ether);
        _setLimits(SHIFT, 10_000 ether, 50_000_000 ether);
    }

    /// @notice Deposit the selected stake. Every match ID, including zero, may be used only once.
    function open(bytes32 matchId, address token, uint256 stake, bytes32 game) external nonReentrant whenNotPaused {
        if (token != IMD && token != SHIFT) revert UnsupportedToken();
        if (matches[matchId].playerA != address(0)) revert MatchAlreadyExists();
        Limits memory bounds = limits[token];
        if (stake < bounds.min || stake > bounds.max) revert StakeOutOfBounds();

        matches[matchId] = Match({
            token: token,
            stake: stake,
            game: game,
            playerA: msg.sender,
            playerB: address(0),
            openedAt: block.timestamp,
            joinedAt: 0,
            settled: false
        });
        emit Opened(matchId, token, stake, game, msg.sender);
        _deposit(token, msg.sender, stake);
    }

    /// @notice Join before the one-hour cutoff, depositing the originally agreed stake.
    function join(bytes32 matchId) external nonReentrant whenNotPaused {
        Match storage gameMatch = _activeMatch(matchId);
        if (gameMatch.playerB != address(0)) revert AlreadyJoined();
        if (msg.sender == gameMatch.playerA) revert CannotJoinOwnMatch();
        if (block.timestamp >= gameMatch.openedAt + JOIN_TIMEOUT) revert JoinWindowClosed();

        gameMatch.playerB = msg.sender;
        gameMatch.joinedAt = block.timestamp;
        emit Joined(matchId, msg.sender);
        _deposit(gameMatch.token, msg.sender, gameMatch.stake);
    }

    /// @notice Anyone may relay a valid result before the 24-hour settlement cutoff.
    /// @dev On a draw the signed winner is ignored for transfers but retained in the event.
    function settle(bytes32 matchId, address winner, bool draw, uint256 deadline, bytes calldata signature)
        external
        nonReentrant
    {
        Match storage gameMatch = _activeMatch(matchId);
        if (gameMatch.playerB == address(0)) revert NotJoined();
        if (block.timestamp >= gameMatch.joinedAt + SETTLE_TIMEOUT) revert SettleWindowClosed();
        if (block.timestamp > deadline) revert SignatureExpired();
        if (!draw && winner != gameMatch.playerA && winner != gameMatch.playerB) revert InvalidWinner();
        if (ECDSA.recover(hashResult(matchId, winner, draw, deadline), signature) != signer) revert InvalidSignature();

        // A terminal match can never be reopened, settled, cancelled or refunded again.
        gameMatch.settled = true;
        IERC20 token = IERC20(gameMatch.token);
        uint256 stake = gameMatch.stake;
        if (draw) {
            emit Settled(matchId, winner, true, stake, 0);
            token.safeTransfer(gameMatch.playerA, stake);
            token.safeTransfer(gameMatch.playerB, stake);
        } else {
            // The hard caps bound the pot. Round the fee down; all dust goes to the winner.
            uint256 pot = stake * 2;
            uint256 fee = pot * FEE_BPS / BPS_DENOMINATOR;
            uint256 payout = pot - fee;
            emit Settled(matchId, winner, false, payout, fee);
            token.safeTransfer(winner, payout);
            token.safeTransfer(FEE_RECIPIENT, fee);
        }
    }

    /// @notice Anyone may trigger a full refund at or after the applicable cutoff.
    function refund(bytes32 matchId) external nonReentrant {
        Match storage gameMatch = _activeMatch(matchId);
        bool joined = gameMatch.playerB != address(0);
        uint256 refundableAt = joined ? gameMatch.joinedAt + SETTLE_TIMEOUT : gameMatch.openedAt + JOIN_TIMEOUT;
        if (block.timestamp < refundableAt) revert RefundTooEarly();

        gameMatch.settled = true;
        emit Refunded(matchId);
        IERC20 token = IERC20(gameMatch.token);
        token.safeTransfer(gameMatch.playerA, gameMatch.stake);
        if (joined) token.safeTransfer(gameMatch.playerB, gameMatch.stake);
    }

    /// @notice Only player A can cancel an unjoined match, even when paused.
    function cancel(bytes32 matchId) external nonReentrant {
        Match storage gameMatch = _activeMatch(matchId);
        if (msg.sender != gameMatch.playerA) revert Unauthorized();
        if (gameMatch.playerB != address(0)) revert AlreadyJoined();

        gameMatch.settled = true;
        emit Cancelled(matchId);
        IERC20(gameMatch.token).safeTransfer(gameMatch.playerA, gameMatch.stake);
    }

    function setSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert InvalidSigner();
        address previousSigner = signer;
        signer = newSigner;
        emit SignerSet(previousSigner, newSigner);
    }

    /// @notice Change future opens only. Bounds are inclusive and expressed in token base units.
    function setLimits(address token, uint256 min, uint256 max) external onlyOwner {
        _setLimits(token, min, max);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice EIP-712 domain separator, rebuilt if the chain ID changes.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Digest the server signs (not an Ethereum personal_sign message).
    function hashResult(bytes32 matchId, address winner, bool draw, uint256 deadline) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(RESULT_TYPEHASH, matchId, winner, draw, deadline)));
    }

    function _activeMatch(bytes32 matchId) private view returns (Match storage gameMatch) {
        gameMatch = matches[matchId];
        if (gameMatch.playerA == address(0)) revert MatchNotFound();
        if (gameMatch.settled) revert MatchClosed();
    }

    function _setLimits(address token, uint256 min, uint256 max) private {
        uint256 cap;
        if (token == IMD) cap = IMD_HARD_CAP;
        else if (token == SHIFT) cap = SHIFT_HARD_CAP;
        else revert UnsupportedToken();
        if (min > max || max > cap) revert InvalidLimits();
        limits[token] = Limits(min, max);
        emit LimitsSet(token, min, max);
    }

    function _deposit(address token, address player, uint256 amount) private {
        IERC20 asset = IERC20(token);
        uint256 beforeBalance = asset.balanceOf(address(this));
        asset.safeTransferFrom(player, address(this), amount);
        uint256 afterBalance = asset.balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert IncorrectDeposit();
    }
}
