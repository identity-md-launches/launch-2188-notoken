// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { OGClubPayments } from "../src/OGClubPayments.sol";
import { OGClubHouses } from "../src/OGClubHouses.sol";
import { OGClubDeeds } from "../src/OGClubDeeds.sol";
import { MockOG } from "../src/mocks/MockOG.sol";
import { MockSwarmPepe } from "../src/mocks/MockSwarmPepe.sol";
import { MockDelegateRegistry } from "../src/mocks/MockDelegateRegistry.sol";

/// @dev Every shared behavior runs independently against both purchase implementations.
abstract contract SharedPaymentsTest is Test {
    uint256 internal constant INITIAL_PRICE = 100_000 ether;
    uint256 internal constant NOTICE = 7 days;
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;

    address internal admin;
    address internal buyer;
    address internal vault;
    MockOG internal token;
    MockSwarmPepe internal pepe;
    MockDelegateRegistry internal registry;
    OGClubPayments internal sale;

    function setUp() public {
        admin = makeAddr("admin");
        buyer = makeAddr("buyer");
        vault = makeAddr("farmingVault");
        token = new MockOG(address(this));
        pepe = new MockSwarmPepe();
        registry = new MockDelegateRegistry();
        for (uint256 id; id < 4; ++id) {
            pepe.mint(buyer, id);
        }
        sale = _deploy(address(token), vault, admin, INITIAL_PRICE, NOTICE);
    }

    function _deploy(address token_, address vault_, address owner_, uint256 price_, uint256 notice_)
        internal
        virtual
        returns (OGClubPayments);

    function _buy(uint256 id, uint256 maxPrice) internal virtual;
    function _purchased(uint256 id) internal view virtual returns (bool);

    function _fundAndApprove(uint256 amount) internal {
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(sale), amount);
    }

    function _activate(uint256 newPrice) internal {
        vm.prank(admin);
        sale.setPrice(newPrice);
        vm.warp(vm.getBlockTimestamp() + sale.priceNotice());
    }

    function test_InitialConfiguration() public view {
        assertEq(address(sale.token()), address(token));
        assertEq(sale.vault(), vault);
        assertEq(sale.owner(), admin);
        assertEq(sale.priceNotice(), NOTICE);
        assertEq(sale.price(), INITIAL_PRICE);
        assertEq(sale.BURN_ADDRESS(), BURN);
        assertFalse(sale.paused());
        (uint256 next, uint256 startsAt) = sale.pendingPrice();
        assertEq(next, 0);
        assertEq(startsAt, 0);
    }

    function test_ExactSplitAndNoCustody() public {
        _fundAndApprove(INITIAL_PRICE);
        vm.prank(buyer);
        _buy(0, INITIAL_PRICE);
        assertTrue(_purchased(0));
        assertEq(token.balanceOf(buyer), 0);
        assertEq(token.balanceOf(BURN), INITIAL_PRICE / 2);
        assertEq(token.balanceOf(vault), INITIAL_PRICE / 2);
        assertEq(token.balanceOf(address(sale)), 0);
        assertEq(token.allowance(buyer, address(sale)), 0);
        // Sending to the burn address does not invoke an ERC-20 burn or reduce totalSupply.
        assertEq(token.totalSupply(), 1 ether + INITIAL_PRICE);
    }

    function test_OddPriceRemainderGoesToVault() public {
        _activate(101);
        _fundAndApprove(101);
        vm.prank(buyer);
        _buy(0, 101);
        assertEq(token.balanceOf(BURN), 50);
        assertEq(token.balanceOf(vault), 51);
        assertEq(token.balanceOf(address(sale)), 0);
    }

    function testFuzz_ExactSplit(uint128 purchasePrice) public {
        _activate(purchasePrice);
        _fundAndApprove(purchasePrice);
        vm.prank(buyer);
        _buy(0, purchasePrice);
        assertEq(token.balanceOf(buyer), 0);
        assertEq(token.balanceOf(BURN), uint256(purchasePrice) / 2);
        assertEq(token.balanceOf(vault), uint256(purchasePrice) - uint256(purchasePrice) / 2);
        assertEq(token.balanceOf(address(sale)), 0);
    }

    function test_ZeroAndOneWeiPrices() public {
        _activate(0);
        vm.prank(buyer);
        _buy(0, 0);
        assertTrue(_purchased(0));
        _activate(1);
        _fundAndApprove(1);
        vm.prank(buyer);
        _buy(1, 1);
        assertTrue(_purchased(1));
        assertEq(token.balanceOf(BURN), 0);
        assertEq(token.balanceOf(vault), 1);
    }

    function test_MaxPriceFailureDoesNotSpendOrGrant() public {
        _fundAndApprove(INITIAL_PRICE);
        vm.expectRevert(abi.encodeWithSelector(OGClubPayments.PriceTooHigh.selector, INITIAL_PRICE, INITIAL_PRICE - 1));
        vm.prank(buyer);
        _buy(0, INITIAL_PRICE - 1);
        assertFalse(_purchased(0));
        assertEq(token.balanceOf(buyer), INITIAL_PRICE);
        assertEq(token.allowance(buyer, address(sale)), INITIAL_PRICE);
        vm.prank(buyer);
        _buy(0, INITIAL_PRICE);
        assertTrue(_purchased(0));
    }

    function test_PauseAndUnpauseRestorePurchases() public {
        _fundAndApprove(INITIAL_PRICE);
        vm.prank(admin);
        sale.setPaused(true);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(buyer);
        _buy(0, INITIAL_PRICE);
        assertFalse(_purchased(0));
        assertEq(token.balanceOf(buyer), INITIAL_PRICE);
        vm.prank(admin);
        sale.setPaused(true);
        assertTrue(sale.paused());
        vm.prank(admin);
        sale.setPaused(false);
        vm.prank(admin);
        sale.setPaused(false);
        vm.prank(buyer);
        _buy(0, INITIAL_PRICE);
        assertTrue(_purchased(0));
    }

    function test_NoticeExactBoundaryAndPurchasesOnBothSides() public {
        uint256 startsAt = vm.getBlockTimestamp() + NOTICE;
        vm.expectEmit(false, false, false, true, address(sale));
        emit OGClubPayments.PriceScheduled(INITIAL_PRICE + 1, startsAt);
        vm.prank(admin);
        sale.setPrice(INITIAL_PRICE + 1);
        (uint256 next, uint256 when) = sale.pendingPrice();
        assertEq(next, INITIAL_PRICE + 1);
        assertEq(when, startsAt);
        _fundAndApprove(INITIAL_PRICE * 2 + 1);
        vm.warp(startsAt - 1);
        assertEq(sale.price(), INITIAL_PRICE);
        vm.prank(buyer);
        _buy(0, INITIAL_PRICE);
        vm.warp(startsAt);
        assertEq(sale.price(), INITIAL_PRICE + 1);
        (next, when) = sale.pendingPrice();
        assertEq(next, 0);
        assertEq(when, 0);
        vm.expectRevert(abi.encodeWithSelector(OGClubPayments.PriceTooHigh.selector, INITIAL_PRICE + 1, INITIAL_PRICE));
        vm.prank(buyer);
        _buy(1, INITIAL_PRICE);
        vm.prank(buyer);
        _buy(1, INITIAL_PRICE + 1);
        assertEq(token.balanceOf(buyer), 0);
    }

    function test_ReplacedAnnouncementRestartsNotice() public {
        uint256 start = vm.getBlockTimestamp();
        vm.prank(admin);
        sale.setPrice(5);
        vm.warp(start + 2 days);
        vm.prank(admin);
        sale.setPrice(7);
        (uint256 next, uint256 when) = sale.pendingPrice();
        assertEq(next, 7);
        assertEq(when, start + 2 days + NOTICE);
        vm.warp(start + NOTICE);
        assertEq(sale.price(), INITIAL_PRICE);
        vm.warp(when - 1);
        assertEq(sale.price(), INITIAL_PRICE);
        vm.warp(when);
        assertEq(sale.price(), 7);
    }

    function test_ReschedulingAtActivatedBoundaryPreservesEffectivePrice() public {
        uint256 start = vm.getBlockTimestamp();
        vm.prank(admin);
        sale.setPrice(5);
        vm.warp(start + NOTICE);
        vm.prank(admin);
        sale.setPrice(7);
        assertEq(sale.price(), 5);
        vm.warp(start + NOTICE * 2 - 1);
        assertEq(sale.price(), 5);
        vm.warp(start + NOTICE * 2);
        assertEq(sale.price(), 7);
    }

    function test_ReschedulingLongAfterActivationPreservesEffectivePrice() public {
        vm.prank(admin);
        sale.setPrice(5);
        vm.warp(vm.getBlockTimestamp() + NOTICE * 2);
        vm.prank(admin);
        sale.setPrice(7);
        assertEq(sale.price(), 5);
    }

    function test_ZeroNoticeImmediateEvenAtTimestampZero() public {
        sale = _deploy(address(token), vault, admin, INITIAL_PRICE, 0);
        vm.warp(0);
        vm.prank(admin);
        sale.setPrice(101);
        assertEq(sale.price(), 101);
        (uint256 next, uint256 when) = sale.pendingPrice();
        assertEq(next, 0);
        assertEq(when, 0);
        _fundAndApprove(101);
        vm.prank(buyer);
        _buy(0, 101);
        assertEq(token.balanceOf(vault), 51);
    }

    function test_ZeroPriceAnnouncementIsNotMistakenForNoPendingChange() public {
        uint256 when = vm.getBlockTimestamp() + NOTICE;
        vm.prank(admin);
        sale.setPrice(0);
        (uint256 next, uint256 startsAt) = sale.pendingPrice();
        assertEq(next, 0);
        assertEq(startsAt, when);
        vm.warp(when);
        vm.prank(buyer);
        _buy(0, 0);
        assertTrue(_purchased(0));
    }

    function test_NoticeKeepsRunningWhilePaused() public {
        vm.startPrank(admin);
        sale.setPaused(true);
        sale.setPrice(3);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + NOTICE);
        assertEq(sale.price(), 3);
        assertTrue(sale.paused());
        vm.prank(admin);
        sale.setPaused(false);
        _fundAndApprove(3);
        vm.prank(buyer);
        _buy(0, 3);
        assertEq(token.balanceOf(vault), 2);
    }

    function test_NoticeUpperBound() public {
        vm.expectRevert(abi.encodeWithSelector(OGClubPayments.InvalidPriceNotice.selector, 30 days + 1));
        _deploy(address(token), vault, admin, INITIAL_PRICE, 30 days + 1);
        sale = _deploy(address(token), vault, admin, INITIAL_PRICE, 30 days);
        assertEq(sale.priceNotice(), 30 days);
    }

    function test_ConstructorRejectsZeroToken() public {
        vm.expectRevert(OGClubPayments.ZeroAddress.selector);
        _deploy(address(0), vault, admin, INITIAL_PRICE, NOTICE);
    }

    function test_ConstructorRejectsZeroVault() public {
        vm.expectRevert(OGClubPayments.ZeroAddress.selector);
        _deploy(address(token), address(0), admin, INITIAL_PRICE, NOTICE);
    }

    function test_ConstructorRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        _deploy(address(token), vault, address(0), INITIAL_PRICE, NOTICE);
    }

    function test_ConstructorRejectsBurnAddressAsVault() public {
        vm.expectRevert(abi.encodeWithSelector(OGClubPayments.InvalidVault.selector, BURN));
        _deploy(address(token), BURN, admin, INITIAL_PRICE, NOTICE);
    }

    function test_ConstructorDoesNotCallTokenOrVault() public {
        address absentToken = makeAddr("absentToken");
        address absentVault = makeAddr("absentVault");
        sale = _deploy(absentToken, absentVault, admin, INITIAL_PRICE, NOTICE);
        assertEq(address(sale.token()), absentToken);
        assertEq(sale.vault(), absentVault);
    }

    function test_OnlyOwnerChangesPriceOrPause() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        vm.prank(buyer);
        sale.setPrice(0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        vm.prank(buyer);
        sale.setPaused(true);
        assertEq(sale.price(), INITIAL_PRICE);
        assertFalse(sale.paused());
    }

    function test_TwoStepOwnerHandover() public {
        address newOwner = makeAddr("newSafe");
        vm.prank(admin);
        sale.transferOwnership(newOwner);
        assertEq(sale.owner(), admin);
        assertEq(sale.pendingOwner(), newOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        vm.prank(buyer);
        sale.acceptOwnership();
        vm.prank(newOwner);
        sale.acceptOwnership();
        assertEq(sale.owner(), newOwner);
        assertEq(sale.pendingOwner(), address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        vm.prank(admin);
        sale.setPaused(true);
        vm.prank(newOwner);
        sale.setPaused(true);
        assertTrue(sale.paused());
    }

    function test_InsufficientAllowanceOnSecondLegRollsBackFirstLeg() public {
        token.mint(buyer, INITIAL_PRICE);
        vm.prank(buyer);
        token.approve(address(sale), INITIAL_PRICE / 2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(sale), 0, INITIAL_PRICE / 2
            )
        );
        vm.prank(buyer);
        _buy(0, INITIAL_PRICE);
        assertFalse(_purchased(0));
        assertEq(token.balanceOf(buyer), INITIAL_PRICE);
        assertEq(token.balanceOf(BURN), 0);
        assertEq(token.balanceOf(vault), 0);
        assertEq(token.allowance(buyer, address(sale)), INITIAL_PRICE / 2);
    }

    function test_InsufficientBalanceOnSecondLegRollsBackFirstLeg() public {
        token.mint(buyer, INITIAL_PRICE / 2);
        vm.prank(buyer);
        token.approve(address(sale), INITIAL_PRICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, buyer, 0, INITIAL_PRICE / 2)
        );
        vm.prank(buyer);
        _buy(0, INITIAL_PRICE);
        assertFalse(_purchased(0));
        assertEq(token.balanceOf(buyer), INITIAL_PRICE / 2);
        assertEq(token.balanceOf(BURN), 0);
        assertEq(token.balanceOf(vault), 0);
        assertEq(token.allowance(buyer, address(sale)), INITIAL_PRICE);
    }
}

contract HousesPaymentsTest is SharedPaymentsTest {
    function _deploy(address token_, address vault_, address owner_, uint256 price_, uint256 notice_)
        internal
        override
        returns (OGClubPayments)
    {
        return new OGClubHouses(token_, vault_, owner_, price_, notice_);
    }

    function _buy(uint256 id, uint256 maxPrice) internal override {
        OGClubHouses(address(sale)).buyHouseFor(address(uint160(100 + id)), maxPrice);
    }

    function _purchased(uint256 id) internal view override returns (bool) {
        return OGClubHouses(address(sale)).hasHouse(address(uint160(100 + id)));
    }
}

contract DeedsPaymentsTest is SharedPaymentsTest {
    function _deploy(address token_, address vault_, address owner_, uint256 price_, uint256 notice_)
        internal
        override
        returns (OGClubPayments)
    {
        return new OGClubDeeds(token_, vault_, owner_, price_, notice_, address(pepe), address(registry), admin);
    }

    function _buy(uint256 id, uint256 maxPrice) internal override {
        OGClubDeeds(address(sale)).mint(id, maxPrice);
    }

    function _purchased(uint256 id) internal view override returns (bool) {
        return OGClubDeeds(address(sale)).clubExists(id);
    }
}

