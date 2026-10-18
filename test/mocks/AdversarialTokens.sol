// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MockOG } from "../../src/mocks/MockOG.sol";

/// @dev Charges 1% only on transfers to the selected recipient, or all transfers when selected is zero.
contract FeeOnTransferOG is MockOG {
    address public immutable taxedRecipient;
    address public immutable feeSink;

    constructor(address selected, address sink) MockOG(msg.sender) {
        taxedRecipient = selected;
        feeSink = sink;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0) && (taxedRecipient == address(0) || to == taxedRecipient)) {
            uint256 fee = amount / 100;
            super._update(from, feeSink, fee);
            super._update(from, to, amount - fee);
        } else {
            super._update(from, to, amount);
        }
    }
}

contract FalseReturnOG is MockOG {
    address public immutable failedRecipient;

    constructor(address recipient) MockOG(msg.sender) {
        failedRecipient = recipient;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (to == failedRecipient) return false;
        return super.transferFrom(from, to, amount);
    }
}

/// @dev Delivers the requested amount in full, but charges an extra 1% to the sender.
contract SenderFeeOG is MockOG {
    address public immutable feeSink;

    constructor(address sink) MockOG(msg.sender) {
        feeSink = sink;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        _transfer(from, feeSink, amount / 100);
        return true;
    }
}

/// @dev Minimal legacy ERC-20 that transfers successfully without returning a value.
contract NoReturnOG {
    error InsufficientAllowance();
    error InsufficientBalance();

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        if (allowance[from][msg.sender] < amount) revert InsufficientAllowance();
        if (balanceOf[from] < amount) revert InsufficientBalance();
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Attempts an arbitrary callback during the first payment leg, and records its outcome.
contract ReentrantOG is MockOG {
    address public target;
    bytes public payload;
    bool public attempted;
    bool public callbackSucceeded;
    bytes public callbackResult;

    constructor() MockOG(msg.sender) { }

    function setHook(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (!attempted) {
            attempted = true;
            (callbackSucceeded, callbackResult) = target.call(payload);
        }
        return super.transferFrom(from, to, amount);
    }
}

/// @dev Corrupts the burn receipt only during the second transfer, exercising final-balance checks.
contract UndoBurnOG is MockOG {
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;
    address public immutable vault;
    address public immutable sink;

    constructor(address vault_, address sink_) MockOG(msg.sender) {
        vault = vault_;
        sink = sink_;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (from != address(0) && to == vault) super._update(BURN, sink, 1);
    }
}

