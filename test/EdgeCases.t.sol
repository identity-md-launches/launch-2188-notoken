// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { OGClubPayments } from "../src/OGClubPayments.sol";
import { OGClubHouses } from "../src/OGClubHouses.sol";
import { OGClubDeeds } from "../src/OGClubDeeds.sol";
import { MockOG } from "../src/mocks/MockOG.sol";
import { MockSwarmPepe } from "../src/mocks/MockSwarmPepe.sol";
import { MockDelegateRegistry } from "../src/mocks/MockDelegateRegistry.sol";

/// @dev Extremes and ordering questions not pinned elsewhere: the largest payable price, the 30-day notice
/// limit on both contracts, which check wins when several fail, and pause idempotence.
contract EdgeCasesTest is Test {
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    address internal admin = makeAddr("edgeSafe");
    address internal vault = makeAddr("edgeVault");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    MockOG internal token;
    MockSwarmPepe internal pepe;
    MockDelegateRegistry internal registry;

    function setUp() public {
        token = new MockOG(address(this));
        pepe = new MockSwarmPepe();
        registry = new MockDelegateRegistry();
    }

    function _houses(uint256 price_, uint256 notice) internal returns (OGClubHouses) {
        return new OGClubHouses(address(token), vault, admin, price_, notice);
    }

    function _deeds(uint256 price_, uint256 notice) internal returns (OGClubDeeds) {
        return new OGClubDeeds(address(token), vault, admin, price_, notice, address(pepe), address(registry), admin);
    }

    function _fund(address who, address spender, uint256 amount) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.approve(spender, amount);
    }

    /// @dev The largest price a payer can hold (supply already has 1 OG). It is odd, so the vault gets the extra wei.
    function test_LargestPayablePriceSplitsExactlyWithoutOverflow() public {
        uint256 maxPayable = type(uint256).max - token.totalSupply();
        assertEq(maxPayable % 2, 1);
        OGClubHouses houses = _houses(maxPayable, 0);
        _fund(alice, address(houses), maxPayable);
        vm.expectEmit(true, true, false, true, address(houses));
        emit OGClubHouses.HouseBought(alice, alice, maxPayable, maxPayable / 2, maxPayable / 2 + 1);
        vm.prank(alice);
        houses.buyHouse(type(uint256).max);
        assertEq(token.balanceOf(BURN), maxPayable / 2);
        assertEq(token.balanceOf(vault), maxPayable / 2 + 1);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(houses)), 0);
    }

    function test_ThirtyDayNoticeIsAcceptedAndOneSecondMoreIsNot() public {
        OGClubHouses houses = _houses(1, 30 days);
        OGClubDeeds deeds = _deeds(1, 30 days);
        assertEq(houses.priceNotice(), 30 days);
        assertEq(deeds.priceNotice(), 30 days);

        vm.expectRevert(abi.encodeWithSelector(OGClubPayments.InvalidPriceNotice.selector, 30 days + 1));
        _houses(1, 30 days + 1);
        vm.expectRevert(abi.encodeWithSelector(OGClubPayments.InvalidPriceNotice.selector, 30 days + 1));
        _deeds(1, 30 days + 1);
        vm.expectRevert(abi.encodeWithSelector(OGClubPayments.InvalidPriceNotice.selector, type(uint256).max));
        _houses(1, type(uint256).max);
    }

    function test_ThirtyDayNoticeBoundaryOnDeeds() public {
        OGClubDeeds deeds = _deeds(250_000 ether, 30 days);
        uint256 t0 = vm.getBlockTimestamp();
        vm.prank(admin);
        deeds.setPrice(3);
        vm.warp(t0 + 30 days - 1);
        assertEq(deeds.price(), 250_000 ether);
        pepe.mint(alice, 9);
        _fund(alice, address(deeds), 3);
        vm.expectRevert(abi.encodeWithSelector(OGClubPayments.PriceTooHigh.selector, 250_000 ether, 3));
        vm.prank(alice);
        deeds.mint(9, 3);
        vm.warp(t0 + 30 days);
        assertEq(deeds.price(), 3);
        vm.prank(alice);
        deeds.mint(9, 3);
        assertEq(token.balanceOf(BURN), 1);
        assertEq(token.balanceOf(vault), 2);
        assertEq(deeds.ownerOf(9), alice);
    }

    /// @dev A pending increase does not affect the price in force; a buyer who quotes now is charged now's price.
    function test_PendingIncreaseDoesNotChargeEarlyBuyers() public {
        OGClubHouses houses = _houses(100, 7 days);
        vm.prank(admin);
        houses.setPrice(1_000_000);
        _fund(alice, address(houses), 1_000_000);
        vm.prank(alice);
        houses.buyHouse(type(uint256).max);
        assertEq(token.balanceOf(alice), 1_000_000 - 100);
    }

    function test_DuplicateBeatsMaxPriceButPauseBeatsEverything() public {
        OGClubHouses houses = _houses(10, 0);
        _fund(alice, address(houses), 10);
        vm.prank(alice);
        houses.buyHouse(10);
        // Owner raises the price: a duplicate is still identified as a duplicate.
        vm.prank(admin);
        houses.setPrice(1000);
        vm.expectRevert(abi.encodeWithSelector(OGClubHouses.AlreadyHasHouse.selector, alice));
        vm.prank(bob);
        houses.buyHouseFor(alice, 1);
        // Pause takes priority over every other check.
        vm.prank(admin);
        houses.setPaused(true);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(bob);
        houses.buyHouseFor(alice, 1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(bob);
        houses.buyHouseFor(address(0), 1);
    }

    function test_ClubExistsReportedBeforeAuthorization() public {
        OGClubDeeds deeds = _deeds(4, 0);
        pepe.mint(alice, 1);
        _fund(alice, address(deeds), 4);
        vm.prank(alice);
        deeds.mint(1, 4);
        // A stranger with no tokens and a too-low limit learns the club exists, and nothing moves.
        vm.expectRevert(abi.encodeWithSelector(OGClubDeeds.ClubExists.selector, 1));
        vm.prank(bob);
        deeds.mint(1, 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_StrangerWithTokensButTooLowLimitStillGetsPriceError() public {
        OGClubDeeds deeds = _deeds(4, 0);
        pepe.mint(alice, 1);
        vm.expectRevert(abi.encodeWithSelector(OGClubPayments.PriceTooHigh.selector, 4, 3));
        vm.prank(bob);
        deeds.mint(1, 3);
        vm.expectRevert(abi.encodeWithSelector(OGClubDeeds.NotPepeOwnerOrDelegate.selector, bob, 1));
        vm.prank(bob);
        deeds.mint(1, 4);
        assertFalse(deeds.clubExists(1));
    }

    function test_SetPausedIsIdempotentAndOnlyEmitsOnChange() public {
        OGClubHouses houses = _houses(1, 0);
        vm.recordLogs();
        vm.startPrank(admin);
        houses.setPaused(false);
        houses.setPaused(true);
        houses.setPaused(true);
        vm.stopPrank();
        assertEq(vm.getRecordedLogs().length, 1);
        assertTrue(houses.paused());
        vm.prank(admin);
        houses.setPaused(false);
        assertFalse(houses.paused());
    }

    /// @dev Pausing deeds does not pause houses and vice versa; each owner switch is independent.
    function test_PauseIsPerContract() public {
        OGClubHouses houses = _houses(2, 0);
        OGClubDeeds deeds = _deeds(2, 0);
        vm.prank(admin);
        deeds.setPaused(true);
        _fund(alice, address(houses), 2);
        vm.prank(alice);
        houses.buyHouse(2);
        assertTrue(houses.hasHouse(alice));
        pepe.mint(alice, 5);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        deeds.mint(5, 2);
    }

    /// @dev A delegation for a different Pepe id does not authorize this one.
    function test_DelegationForAnotherPepeDoesNotAuthorize() public {
        OGClubDeeds deeds = _deeds(2, 0);
        pepe.mint(alice, 1);
        pepe.mint(alice, 2);
        vm.prank(alice);
        registry.delegateERC721(bob, address(pepe), 1, bytes32(0), true);
        _fund(bob, address(deeds), 4);
        vm.expectRevert(abi.encodeWithSelector(OGClubDeeds.NotPepeOwnerOrDelegate.selector, bob, 2));
        vm.prank(bob);
        deeds.mint(2, 2);
        vm.prank(bob);
        deeds.mint(1, 2);
        assertEq(deeds.ownerOf(1), alice);
        assertEq(token.balanceOf(bob), 2);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_DeedOfUnmintedIdHasNoOwnerAndNoURI() public {
        OGClubDeeds deeds = _deeds(2, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 42));
        deeds.ownerOf(42);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 42));
        deeds.tokenURI(42);
        assertEq(deeds.balanceOf(alice), 0);
    }

    function test_RoyaltyExactCapAndZeroAllowed() public {
        OGClubDeeds deeds = _deeds(2, 0);
        vm.startPrank(admin);
        deeds.setRoyalty(bob, 1000);
        (address r, uint256 amount) = deeds.royaltyInfo(1, 1 ether);
        assertEq(r, bob);
        assertEq(amount, 0.1 ether);
        deeds.setRoyalty(bob, 0);
        (, amount) = deeds.royaltyInfo(1, 1 ether);
        assertEq(amount, 0);
        vm.expectRevert(abi.encodeWithSelector(OGClubDeeds.RoyaltyTooHigh.selector, 1001));
        deeds.setRoyalty(bob, 1001);
        vm.stopPrank();
    }
}
