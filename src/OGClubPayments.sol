// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title OG Club purchase payments
/// @notice Immutable payment destinations, announced prices, and purchase-only pausing.
/// @dev Expects an honest, non-rebasing, 18-decimal ERC-20. No custody or withdrawal functions.
abstract contract OGClubPayments is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Required addresses must be nonzero.
    error ZeroAddress();
    /// @notice The vault must differ from the burn address and this contract.
    error InvalidVault(address vault);
    /// @notice A price notice may not exceed 30 days.
    error InvalidPriceNotice(uint256 notice);
    /// @notice The effective price exceeds the payer's limit.
    error PriceTooHigh(uint256 currentPrice, uint256 maxPrice);
    /// @notice A recipient's credit or the payer's debit did not equal the required amount.
    /// @dev Also rejects excess amounts; actual is zero if the balance moved in the opposite direction.
    error ShortTransfer(address account, uint256 expected, uint256 actual);

    /// @notice Emitted for each new price announcement, replacing any unactivated announcement.
    event PriceScheduled(uint256 newPrice, uint256 effectiveAt);

    /// @notice Unspendable recipient of floor(price / 2).
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    /// @notice Largest permitted notice interval.
    uint256 public constant MAX_PRICE_NOTICE = 30 days;
    /// @notice Payment token, fixed at deployment.
    IERC20 public immutable token;
    /// @notice Recipient of price - floor(price / 2), fixed at deployment.
    address public immutable vault;
    /// @notice Delay between announcement and activation, fixed at deployment.
    uint256 public immutable priceNotice;

    uint256 private _activePrice;
    uint256 private _announcedPrice;
    uint256 private _effectiveAt;

    /// @param token_ Existing 18-decimal payment token; its code is checked through use, not construction.
    /// @param vault_ Farming vault, distinct from the burn address and this contract.
    /// @param owner_ Explicit administrative owner; use a Safe on mainnet.
    /// @param initialPrice_ Starting price in token wei; zero is allowed.
    /// @param priceNotice_ Announcement delay, at most 30 days; use 7 days on mainnet and 0 on testnets.
    constructor(address token_, address vault_, address owner_, uint256 initialPrice_, uint256 priceNotice_)
        Ownable(owner_)
    {
        if (token_ == address(0) || vault_ == address(0)) revert ZeroAddress();
        if (vault_ == BURN_ADDRESS || vault_ == address(this)) revert InvalidVault(vault_);
        if (priceNotice_ > MAX_PRICE_NOTICE) revert InvalidPriceNotice(priceNotice_);
        token = IERC20(token_);
        vault = vault_;
        priceNotice = priceNotice_;
        _activePrice = initialPrice_;
    }

    /// @notice Returns the price in force at this block's timestamp, including an activated announcement.
    function price() public view returns (uint256) {
        if (_effectiveAt != 0 && block.timestamp >= _effectiveAt) return _announcedPrice;
        return _activePrice;
    }

    /// @notice Returns the future price and its start time, or (0, 0) if no future change is pending.
    /// @dev A zero price with a nonzero start time is a pending free-purchase price.
    function pendingPrice() external view returns (uint256 newPrice, uint256 effectiveAt) {
        if (_effectiveAt > block.timestamp) return (_announcedPrice, _effectiveAt);
        return (0, 0);
    }

    /// @notice Announces a price, replacing any pending change and restarting the full notice period.
    /// @dev A change already in force is preserved as the current price before scheduling the next one.
    function setPrice(uint256 newPrice) external onlyOwner {
        _activePrice = price();
        uint256 startsAt = block.timestamp + priceNotice;
        if (priceNotice == 0) {
            _activePrice = newPrice;
            delete _announcedPrice;
            delete _effectiveAt;
        } else {
            _announcedPrice = newPrice;
            _effectiveAt = startsAt;
        }
        emit PriceScheduled(newPrice, startsAt);
    }

    /// @notice Pauses or resumes new purchases only; repeating the current state is a no-op.
    function setPaused(bool pausePurchases) external onlyOwner {
        if (pausePurchases == paused()) return;
        if (pausePurchases) _pause();
        else _unpause();
    }

    /// @dev Capture the price once per purchase so callbacks cannot change its quoted payment.
    function _checkedPrice(uint256 maxPrice) internal view returns (uint256 currentPrice) {
        currentPrice = price();
        if (currentPrice > maxPrice) revert PriceTooHigh(currentPrice, maxPrice);
    }

    /// @dev Call only within nonReentrant purchase entrypoints. All transfers and effects roll back on failure.
    function _collectPayment(uint256 purchasePrice) internal returns (uint256 burned, uint256 toVault) {
        burned = purchasePrice / 2;
        toVault = purchasePrice - burned;
        uint256 burnBefore = token.balanceOf(BURN_ADDRESS);
        uint256 vaultBefore = token.balanceOf(vault);
        uint256 payerBefore = token.balanceOf(msg.sender);
        token.safeTransferFrom(msg.sender, BURN_ADDRESS, burned);
        token.safeTransferFrom(msg.sender, vault, toVault);
        // Check both final balances, so the second transfer cannot silently undo the first receipt.
        _checkReceipt(BURN_ADDRESS, burnBefore, burned);
        _checkReceipt(vault, vaultBefore, toVault);
        // Reject sender-paid surcharges even when both recipients receive the full requested amount.
        uint256 payerAfter = token.balanceOf(msg.sender);
        uint256 spent = payerBefore >= payerAfter ? payerBefore - payerAfter : 0;
        if (payerAfter > payerBefore || spent != purchasePrice) {
            revert ShortTransfer(msg.sender, purchasePrice, spent);
        }
    }

    /// @dev Avoid arithmetic panics when a nonstandard token reduces a recipient's balance.
    function _checkReceipt(address recipient, uint256 balanceBefore, uint256 expected) private view {
        uint256 balanceAfter = token.balanceOf(recipient);
        uint256 received = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
        if (balanceAfter < balanceBefore || received != expected) {
            revert ShortTransfer(recipient, expected, received);
        }
    }
}

