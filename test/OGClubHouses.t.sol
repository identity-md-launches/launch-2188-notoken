// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { OGClubHouses } from "../src/OGClubHouses.sol";
import { OGClubPayments } from "../src/OGClubPayments.sol";
import { MockOG } from "../src/mocks/MockOG.sol";

contract OGClubHousesTest is Test {
    uint256 internal constant PRICE = 100_000 ether;
    address internal admin;
    address internal payer;
    address internal beneficiary;
    address internal vault;
    MockOG internal token;
    OGClubHouses internal houses;

    function setUp() public {
        admin = makeAddr("ownerSafe");
        payer = makeAddr("hotWallet");
        beneficiary = makeAddr("coldVault");
        vault = makeAddr("farmingVault");
        token = new MockOG(address(this));
        houses = new OGClubHouses(address(token), vault, admin, PRICE, 0);
        token.mint(payer, PRICE * 4);
        vm.prank(payer);
        token.approve(address(houses), PRICE * 4);
    }

    function test_BuyHouseForSelfEmitsPaymentAndMembership() public {
        vm.expectEmit(true, true, false, true, address(houses));
        emit OGClubHouses.HouseBought(payer, payer, PRICE, PRICE / 2, PRICE / 2);
        vm.prank(payer);
        houses.buyHouse(PRICE);
        assertTrue(houses.hasHouse(payer));
        assertEq(houses.houseCount(), 1);
        assertEq(token.balanceOf(payer), PRICE * 3);
        assertEq(token.balanceOf(address(houses)), 0);
    }

    function test_GiftToVaultChargesOnlyHotWalletAndEmitsBothAddresses() public {
        vm.expectEmit(true, true, false, true, address(houses));
        emit OGClubHouses.HouseBought(beneficiary, payer, PRICE, PRICE / 2, PRICE / 2);
        vm.prank(payer);
        houses.buyHouseFor(beneficiary, PRICE);
        assertTrue(houses.hasHouse(beneficiary));
        assertFalse(houses.hasHouse(payer));
        assertEq(token.balanceOf(beneficiary), 0);
        assertEq(token.balanceOf(payer), PRICE * 3);
        vm.prank(payer);
        houses.buyHouse(PRICE);
        assertEq(houses.houseCount(), 2);
    }

    function test_DuplicateHouseRejectedAcrossBothEntrypoints() public {
        vm.prank(payer);
        houses.buyHouse(PRICE);
        vm.expectRevert(abi.encodeWithSelector(OGClubHouses.AlreadyHasHouse.selector, payer));
        vm.prank(payer);
        houses.buyHouse(PRICE);
        vm.expectRevert(abi.encodeWithSelector(OGClubHouses.AlreadyHasHouse.selector, payer));
        vm.prank(beneficiary);
        houses.buyHouseFor(payer, PRICE);
        assertEq(houses.houseCount(), 1);
        assertEq(token.balanceOf(payer), PRICE * 3);
    }

    function test_GiftedWalletCannotPurchaseAnotherHouse() public {
        vm.prank(payer);
        houses.buyHouseFor(beneficiary, PRICE);
        vm.expectRevert(abi.encodeWithSelector(OGClubHouses.AlreadyHasHouse.selector, beneficiary));
        vm.prank(beneficiary);
        houses.buyHouse(PRICE);
        assertEq(houses.houseCount(), 1);
    }

    function test_ZeroGiftRecipientRevertsBeforePayment() public {
        vm.expectRevert(OGClubPayments.ZeroAddress.selector);
        vm.prank(payer);
        houses.buyHouseFor(address(0), PRICE);
        assertEq(token.balanceOf(payer), PRICE * 4);
        assertEq(houses.houseCount(), 0);
    }

    function test_PauseAlsoStopsSelfPurchaseAndUnpauseRestoresIt() public {
        vm.prank(admin);
        houses.setPaused(true);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(payer);
        houses.buyHouse(PRICE);
        vm.prank(admin);
        houses.setPaused(false);
        vm.prank(payer);
        houses.buyHouse(PRICE);
        assertTrue(houses.hasHouse(payer));
    }

    function test_AdminChangesCannotRemoveMembership() public {
        vm.prank(payer);
        houses.buyHouse(PRICE);
        vm.startPrank(admin);
        houses.setPaused(true);
        houses.setPrice(0);
        houses.transferOwnership(beneficiary);
        vm.stopPrank();
        vm.prank(beneficiary);
        houses.acceptOwnership();
        vm.prank(beneficiary);
        houses.renounceOwnership();
        assertTrue(houses.hasHouse(payer));
        assertEq(houses.houseCount(), 1);
    }
}

