// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { OGClubPayments } from "../src/OGClubPayments.sol";
import { OGClubHouses } from "../src/OGClubHouses.sol";
import { OGClubDeeds } from "../src/OGClubDeeds.sol";
import { MockOG } from "../src/mocks/MockOG.sol";
import { MockSwarmPepe } from "../src/mocks/MockSwarmPepe.sol";
import { MockDelegateRegistry } from "../src/mocks/MockDelegateRegistry.sol";
import {
    FeeOnTransferOG,
    FalseReturnOG,
    SenderFeeOG,
    NoReturnOG,
    ReentrantOG,
    UndoBurnOG
} from "./mocks/AdversarialTokens.sol";

contract ReentrantNFTVault is IERC721Receiver {
    OGClubDeeds public deeds;
    address public destination;
    bool public attempted;
    bool public succeeded;
    bytes public result;

    function configure(OGClubDeeds deeds_, address destination_) external {
        deeds = deeds_;
        destination = destination_;
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        if (msg.sender == address(deeds)) {
            attempted = true;
            (succeeded, result) = address(deeds).call(abi.encodeCall(deeds.mint, (id + 1, type(uint256).max)));
            // The receiving owner is free to transfer immediately, even while the mint guard is held.
            deeds.transferFrom(address(this), destination, id);
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract AdversarialPaymentsTest is Test {
    uint256 internal constant PRICE = 250_000 ether + 1;
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    address internal buyer;
    address internal beneficiary;
    address internal admin;
    address internal vault;
    address internal feeSink;
    MockSwarmPepe internal pepe;
    MockDelegateRegistry internal registry;
    OGClubHouses internal houses;
    OGClubDeeds internal deeds;

    function setUp() public {
        buyer = makeAddr("buyer");
        beneficiary = makeAddr("beneficiary");
        admin = makeAddr("admin");
        vault = makeAddr("farmingVault");
        feeSink = makeAddr("feeSink");
        pepe = new MockSwarmPepe();
        registry = new MockDelegateRegistry();
        pepe.mint(buyer, 1);
    }

    function _deploy(address paymentToken, uint256 price_) internal {
        houses = new OGClubHouses(paymentToken, vault, admin, price_, 0);
        deeds = new OGClubDeeds(paymentToken, vault, admin, price_, 0, address(pepe), address(registry), admin);
    }

    function _fundAndApprove(MockOG paymentToken, uint256 price_) internal {
        paymentToken.mint(buyer, price_ * 3);
        vm.startPrank(buyer);
        paymentToken.approve(address(houses), price_ * 2);
        paymentToken.approve(address(deeds), price_);
        vm.stopPrank();
    }

    function _expectAllPurchasesToFail(bytes memory reason) internal {
        vm.startPrank(buyer);
        vm.expectRevert(reason);
        houses.buyHouse(PRICE);
        vm.expectRevert(reason);
        houses.buyHouseFor(beneficiary, PRICE);
        vm.expectRevert(reason);
        deeds.mint(1, PRICE);
        vm.stopPrank();
        assertFalse(houses.hasHouse(buyer));
        assertFalse(houses.hasHouse(beneficiary));
        assertEq(houses.houseCount(), 0);
        assertFalse(deeds.clubExists(1));
    }

    function _assertRolledBack(MockOG paymentToken) internal view {
        assertEq(paymentToken.balanceOf(buyer), PRICE * 3);
        assertEq(paymentToken.balanceOf(BURN), 0);
        assertEq(paymentToken.balanceOf(vault), 0);
        assertEq(paymentToken.balanceOf(feeSink), 0);
        assertEq(paymentToken.balanceOf(address(houses)), 0);
        assertEq(paymentToken.balanceOf(address(deeds)), 0);
        assertEq(paymentToken.allowance(buyer, address(houses)), PRICE * 2);
        assertEq(paymentToken.allowance(buyer, address(deeds)), PRICE);
    }

    function test_FeeOnEveryTransferRejectsEveryPurchaseEntrypoint() public {
        _testFeeRecipient(address(0), BURN, PRICE / 2);
    }

    function test_FeeOnBurnLegRejectsEveryPurchaseEntrypoint() public {
        _testFeeRecipient(BURN, BURN, PRICE / 2);
    }

    function test_FeeOnVaultLegRejectsEveryPurchaseEntrypointAndRollsBackBurn() public {
        _testFeeRecipient(vault, vault, PRICE - PRICE / 2);
    }

    function _testFeeRecipient(address taxedRecipient, address shortRecipient, uint256 expected) internal {
        FeeOnTransferOG taxed = new FeeOnTransferOG(taxedRecipient, feeSink);
        _deploy(address(taxed), PRICE);
        _fundAndApprove(taxed, PRICE);
        _expectAllPurchasesToFail(
            abi.encodeWithSelector(
                OGClubPayments.ShortTransfer.selector, shortRecipient, expected, expected - expected / 100
            )
        );
        _assertRolledBack(taxed);
    }

    function testFuzz_FeeOnTransferRollsBackBothContracts(uint96 rawPrice) public {
        uint256 purchasePrice = bound(rawPrice, 200, type(uint96).max);
        FeeOnTransferOG taxed = new FeeOnTransferOG(address(0), feeSink);
        _deploy(address(taxed), purchasePrice);
        _fundAndApprove(taxed, purchasePrice);
        uint256 burned = purchasePrice / 2;
        bytes memory reason =
            abi.encodeWithSelector(OGClubPayments.ShortTransfer.selector, BURN, burned, burned - burned / 100);
        vm.startPrank(buyer);
        vm.expectRevert(reason);
        houses.buyHouse(purchasePrice);
        vm.expectRevert(reason);
        deeds.mint(1, purchasePrice);
        vm.stopPrank();
        assertFalse(houses.hasHouse(buyer));
        assertFalse(deeds.clubExists(1));
        assertEq(taxed.balanceOf(buyer), purchasePrice * 3);
        assertEq(taxed.balanceOf(vault), 0);
        assertEq(taxed.balanceOf(BURN), 0);
    }

    function test_FalseReturningTokenRollsBackFirstLegOnAllEntrypoints() public {
        FalseReturnOG broken = new FalseReturnOG(vault);
        _deploy(address(broken), PRICE);
        _fundAndApprove(broken, PRICE);
        _expectAllPurchasesToFail(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(broken)));
        _assertRolledBack(broken);
    }

    function test_SenderSurchargeRejectsEveryPurchaseEntrypoint() public {
        SenderFeeOG taxed = new SenderFeeOG(feeSink);
        _deploy(address(taxed), PRICE);
        _fundAndApprove(taxed, PRICE);
        uint256 charged = PRICE + (PRICE / 2) / 100 + (PRICE - PRICE / 2) / 100;
        _expectAllPurchasesToFail(abi.encodeWithSelector(OGClubPayments.ShortTransfer.selector, buyer, PRICE, charged));
        _assertRolledBack(taxed);
    }

    function test_SecondLegCannotUndoFirstReceipt() public {
        UndoBurnOG broken = new UndoBurnOG(vault, feeSink);
        _deploy(address(broken), PRICE);
        _fundAndApprove(broken, PRICE);
        _expectAllPurchasesToFail(
            abi.encodeWithSelector(OGClubPayments.ShortTransfer.selector, BURN, PRICE / 2, PRICE / 2 - 1)
        );
        _assertRolledBack(broken);
    }

    function test_NoReturnTokenWorksWithExactReceipts() public {
        NoReturnOG legacy = new NoReturnOG();
        _deploy(address(legacy), PRICE);
        legacy.mint(buyer, PRICE * 3);
        vm.startPrank(buyer);
        legacy.approve(address(houses), PRICE * 2);
        legacy.approve(address(deeds), PRICE);
        houses.buyHouse(PRICE);
        houses.buyHouseFor(beneficiary, PRICE);
        deeds.mint(1, PRICE);
        vm.stopPrank();
        assertTrue(houses.hasHouse(buyer));
        assertTrue(houses.hasHouse(beneficiary));
        assertEq(deeds.ownerOf(1), buyer);
        assertEq(legacy.balanceOf(buyer), 0);
        assertEq(legacy.balanceOf(BURN), (PRICE / 2) * 3);
        assertEq(legacy.balanceOf(vault), (PRICE - PRICE / 2) * 3);
        assertEq(legacy.balanceOf(address(houses)), 0);
        assertEq(legacy.balanceOf(address(deeds)), 0);
    }

    function test_TokenCallbackCannotReenterSelfPurchase() public {
        _testReentrantHouse(false);
    }

    function test_TokenCallbackCannotReenterGiftPurchase() public {
        _testReentrantHouse(true);
    }

    function _testReentrantHouse(bool gift) internal {
        ReentrantOG callbackToken = new ReentrantOG();
        _deploy(address(callbackToken), PRICE);
        _fundAndApprove(callbackToken, PRICE);
        bytes memory payload =
            gift ? abi.encodeCall(houses.buyHouseFor, (beneficiary, PRICE)) : abi.encodeCall(houses.buyHouse, (PRICE));
        callbackToken.setHook(address(houses), payload);
        vm.prank(buyer);
        houses.buyHouse(PRICE);
        assertTrue(callbackToken.attempted());
        assertFalse(callbackToken.callbackSucceeded());
        assertEq(
            callbackToken.callbackResult(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(houses.houseCount(), 1);
        assertTrue(houses.hasHouse(buyer));
        assertFalse(houses.hasHouse(beneficiary));
        assertFalse(houses.hasHouse(address(callbackToken)));
        assertEq(callbackToken.balanceOf(BURN), PRICE / 2);
    }

    function test_TokenCallbackCannotReenterDeedMint() public {
        ReentrantOG callbackToken = new ReentrantOG();
        _deploy(address(callbackToken), PRICE);
        _fundAndApprove(callbackToken, PRICE);
        callbackToken.setHook(address(deeds), abi.encodeCall(deeds.mint, (1, PRICE)));
        vm.prank(buyer);
        deeds.mint(1, PRICE);
        assertTrue(callbackToken.attempted());
        assertFalse(callbackToken.callbackSucceeded());
        assertEq(
            callbackToken.callbackResult(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(deeds.ownerOf(1), buyer);
        assertEq(callbackToken.balanceOf(vault), PRICE - PRICE / 2);
    }

    function test_NFTReceiverCannotReenterButCanTradeItsDeed() public {
        MockOG paymentToken = new MockOG(address(this));
        _deploy(address(paymentToken), PRICE);
        _fundAndApprove(paymentToken, PRICE);
        ReentrantNFTVault cold = new ReentrantNFTVault();
        cold.configure(deeds, beneficiary);
        vm.prank(buyer);
        pepe.transferFrom(buyer, address(cold), 1);
        pepe.mint(address(cold), 2);
        vm.prank(address(cold));
        registry.delegateERC721(buyer, address(pepe), 1, bytes32(0), true);
        vm.prank(buyer);
        deeds.mint(1, PRICE);
        assertTrue(cold.attempted());
        assertFalse(cold.succeeded());
        assertEq(cold.result(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(deeds.ownerOf(1), beneficiary);
        assertTrue(deeds.clubExists(1));
        assertFalse(deeds.clubExists(2));
        assertEq(paymentToken.balanceOf(vault), PRICE - PRICE / 2);
    }

    function test_VaultCannotPayItselfAndPassExactReceiptChecks() public {
        MockOG paymentToken = new MockOG(address(this));
        _deploy(address(paymentToken), PRICE);
        paymentToken.mint(vault, PRICE);
        vm.prank(vault);
        paymentToken.approve(address(houses), PRICE);
        vm.expectRevert(abi.encodeWithSelector(OGClubPayments.ShortTransfer.selector, vault, PRICE - PRICE / 2, 0));
        vm.prank(vault);
        houses.buyHouse(PRICE);
        assertEq(paymentToken.balanceOf(vault), PRICE);
        assertEq(paymentToken.balanceOf(BURN), 0);
        assertFalse(houses.hasHouse(vault));
    }
}

