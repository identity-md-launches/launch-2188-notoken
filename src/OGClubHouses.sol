// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { OGClubPayments } from "./OGClubPayments.sol";

/// @title OG Club houses
/// @notice Permanent, nontransferable membership, with at most one house per wallet.
contract OGClubHouses is OGClubPayments {
    /// @notice The beneficiary already owns its permanent house.
    error AlreadyHasHouse(address account);

    /// @notice Emitted after a successful purchase and exact payment.
    event HouseBought(address indexed account, address indexed payer, uint256 price, uint256 burned, uint256 toVault);

    /// @notice Whether a wallet has ever purchased or received a house.
    mapping(address account => bool) public hasHouse;
    /// @notice Total houses purchased; this only increases.
    uint256 public houseCount;

    /// @param token_ Existing 18-decimal OG token.
    /// @param vault_ Immutable farming vault.
    /// @param owner_ Explicit administrator (a Safe on mainnet).
    /// @param initialPrice_ Initial price in wei; the launch uses 100,000 ether.
    /// @param priceNotice_ Immutable price notice in seconds.
    constructor(address token_, address vault_, address owner_, uint256 initialPrice_, uint256 priceNotice_)
        OGClubPayments(token_, vault_, owner_, initialPrice_, priceNotice_)
    { }

    /// @notice Pays from msg.sender and permanently grants that wallet a house.
    /// @param maxPrice Highest acceptable price in token wei.
    function buyHouse(uint256 maxPrice) external nonReentrant whenNotPaused {
        _buyHouse(msg.sender, maxPrice);
    }

    /// @notice Pays from msg.sender and permanently grants a house to account.
    /// @dev Gifting is permissionless; no delegation or recipient callback is required.
    /// @param account Nonzero beneficiary, for example a delegate's cold vault.
    /// @param maxPrice Highest acceptable price in token wei.
    function buyHouseFor(address account, uint256 maxPrice) external nonReentrant whenNotPaused {
        _buyHouse(account, maxPrice);
    }

    function _buyHouse(address account, uint256 maxPrice) private {
        if (account == address(0)) revert ZeroAddress();
        if (hasHouse[account]) revert AlreadyHasHouse(account);
        uint256 purchasePrice = _checkedPrice(maxPrice);
        hasHouse[account] = true;
        ++houseCount;
        (uint256 burned, uint256 toVault) = _collectPayment(purchasePrice);
        emit HouseBought(account, msg.sender, purchasePrice, burned, toVault);
    }
}

