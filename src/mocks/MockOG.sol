// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Sepolia-only OG stand-in
/// @notice An 18-decimal public faucet named notoken (nt), with one whole token initially.
/// @dev The public mint makes total supply unbounded after deployment. Never use this mock on mainnet.
contract MockOG is ERC20 {
    /// @notice Gives the initial one-token supply to the explicitly supplied test deployer.
    constructor(address initialHolder) ERC20("notoken", "nt") {
        _mint(initialHolder, 1 ether);
    }

    /// @notice Public test faucet; anyone may mint any amount to any nonzero account.
    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

