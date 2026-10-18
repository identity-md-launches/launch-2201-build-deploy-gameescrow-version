// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Installed at the two fixed token addresses with vm.etch. Adversarial modes are test-only.
contract TestToken is ERC20 {
    bool public failTransfers;
    bool public noReturnData;
    uint256 public depositLoss;
    uint256 public depositBonus;
    address public blockedRecipient;
    address public hookTarget;
    bytes public hookData;
    bool public hookEnabled;
    bool public hookSucceeded;
    bytes public hookResult;

    error BlockedRecipient();

    constructor() ERC20("Test Token", "TEST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTransferMode(bool fail, bool noReturn) external {
        failTransfers = fail;
        noReturnData = noReturn;
    }

    function setDepositDelta(uint256 loss, uint256 bonus) external {
        depositLoss = loss;
        depositBonus = bonus;
    }

    function setBlockedRecipient(address recipient) external {
        blockedRecipient = recipient;
    }

    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
        hookEnabled = true;
        hookSucceeded = false;
        delete hookResult;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == blockedRecipient) revert BlockedRecipient();
        if (failTransfers) return false;
        super.transfer(to, amount);
        _hook();
        if (noReturnData) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (failTransfers) return false;
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount - depositLoss);
        if (depositLoss != 0) _burn(from, depositLoss);
        if (depositBonus != 0) _mint(to, depositBonus);
        _hook();
        if (noReturnData) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    function _hook() private {
        if (!hookEnabled) return;
        hookEnabled = false;
        (hookSucceeded, hookResult) = hookTarget.call(hookData);
    }
}
