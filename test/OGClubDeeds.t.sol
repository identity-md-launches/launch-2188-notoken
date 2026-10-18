// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { OGClubPayments } from "../src/OGClubPayments.sol";
import { OGClubDeeds } from "../src/OGClubDeeds.sol";
import { MockOG } from "../src/mocks/MockOG.sol";
import { MockSwarmPepe } from "../src/mocks/MockSwarmPepe.sol";
import { MockDelegateRegistry } from "../src/mocks/MockDelegateRegistry.sol";

contract NFTReceivingVault is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract NFTRejectingVault { }

contract OGClubDeedsTest is Test {
    uint256 internal constant PRICE = 250_000 ether;
    uint256 internal constant ID = 42;
    address internal admin;
    address internal pepeOwner;
    address internal hot;
    address internal stranger;
    address internal vault;
    address internal royaltyReceiver;
    MockOG internal token;
    MockSwarmPepe internal pepe;
    MockDelegateRegistry internal registry;
    OGClubDeeds internal deeds;

    function setUp() public {
        admin = makeAddr("adminSafe");
        pepeOwner = makeAddr("pepeOwner");
        hot = makeAddr("hot");
        stranger = makeAddr("stranger");
        vault = makeAddr("farmingVault");
        royaltyReceiver = makeAddr("royaltyReceiver");
        token = new MockOG(address(this));
        pepe = new MockSwarmPepe();
        registry = new MockDelegateRegistry();
        deeds = new OGClubDeeds(
            address(token), vault, admin, PRICE, 0, address(pepe), address(registry), royaltyReceiver
        );
        pepe.mint(pepeOwner, ID);
        _fundAndApprove(pepeOwner);
        _fundAndApprove(hot);
        _fundAndApprove(stranger);
    }

    function _fundAndApprove(address payer) internal {
        token.mint(payer, PRICE);
        vm.prank(payer);
        token.approve(address(deeds), PRICE);
    }

    function _delegate(address from, address to, uint256 id, bool enabled) internal {
        vm.prank(from);
        registry.delegateERC721(to, address(pepe), id, bytes32(0), enabled);
    }

    function _ownerMint() internal {
        vm.prank(pepeOwner);
        deeds.mint(ID, PRICE);
    }

    function test_NameSymbolAndInterfaces() public view {
        assertEq(deeds.name(), "OG Club");
        assertEq(deeds.symbol(), "OGCLUB");
        assertTrue(deeds.supportsInterface(0x01ffc9a7));
        assertTrue(deeds.supportsInterface(type(IERC721).interfaceId));
        assertTrue(deeds.supportsInterface(0x5b5e139f));
        assertTrue(deeds.supportsInterface(type(IERC2981).interfaceId));
        assertFalse(deeds.supportsInterface(0xffffffff));
        assertEq(address(deeds.swarmPepe()), address(pepe));
        assertEq(address(deeds.delegateRegistry()), address(registry));
    }

    function test_OwnerMintsAndEventTracksOwnerAndPayer() public {
        vm.expectEmit(true, true, false, true, address(deeds));
        emit OGClubDeeds.ClubMinted(ID, pepeOwner, pepeOwner, PRICE, PRICE / 2, PRICE / 2);
        _ownerMint();
        assertEq(deeds.ownerOf(ID), pepeOwner);
        assertTrue(deeds.clubExists(ID));
        assertEq(token.balanceOf(pepeOwner), 0);
        assertEq(token.balanceOf(vault), PRICE / 2);
        assertEq(token.balanceOf(address(deeds)), 0);
    }

    function test_DelegateMintsToPepeOwnerAndPaysWithItsOwnTokens() public {
        _delegate(pepeOwner, hot, ID, true);
        vm.expectEmit(true, true, false, true, address(deeds));
        emit OGClubDeeds.ClubMinted(ID, pepeOwner, hot, PRICE, PRICE / 2, PRICE / 2);
        vm.prank(hot);
        deeds.mint(ID, PRICE);
        assertEq(deeds.ownerOf(ID), pepeOwner);
        assertEq(token.balanceOf(hot), 0);
        assertEq(token.balanceOf(pepeOwner), PRICE);
        assertEq(token.allowance(pepeOwner, address(deeds)), PRICE);
    }

    function test_DelegateCanMintToContractVault() public {
        NFTReceivingVault cold = new NFTReceivingVault();
        vm.prank(pepeOwner);
        pepe.safeTransferFrom(pepeOwner, address(cold), ID);
        _delegate(address(cold), hot, ID, true);
        vm.prank(hot);
        deeds.mint(ID, PRICE);
        assertEq(deeds.ownerOf(ID), address(cold));
        assertEq(token.balanceOf(hot), 0);
    }

    function test_StrangerCannotMintEvenWithEnoughTokens() public {
        vm.expectRevert(abi.encodeWithSelector(OGClubDeeds.NotPepeOwnerOrDelegate.selector, stranger, ID));
        vm.prank(stranger);
        deeds.mint(ID, PRICE);
        assertFalse(deeds.clubExists(ID));
        assertEq(token.balanceOf(stranger), PRICE);
    }

    function test_AdminHasNoSpecialMintPrivilege() public {
        vm.expectRevert(abi.encodeWithSelector(OGClubDeeds.NotPepeOwnerOrDelegate.selector, admin, ID));
        vm.prank(admin);
        deeds.mint(ID, PRICE);
        assertFalse(deeds.clubExists(ID));
    }

    function test_ERC721ApprovalDoesNotAuthorizeMint() public {
        vm.prank(pepeOwner);
        pepe.setApprovalForAll(hot, true);
        vm.expectRevert(abi.encodeWithSelector(OGClubDeeds.NotPepeOwnerOrDelegate.selector, hot, ID));
        vm.prank(hot);
        deeds.mint(ID, PRICE);
    }

    function test_RevokedDelegationReverts() public {
        _delegate(pepeOwner, hot, ID, true);
        assertTrue(registry.checkDelegateForERC721(hot, pepeOwner, address(pepe), ID, bytes32(0)));
        _delegate(pepeOwner, hot, ID, false);
        vm.expectRevert(abi.encodeWithSelector(OGClubDeeds.NotPepeOwnerOrDelegate.selector, hot, ID));
        vm.prank(hot);
        deeds.mint(ID, PRICE);
        assertEq(token.balanceOf(hot), PRICE);
        assertFalse(deeds.clubExists(ID));
    }

    function test_DelegationMustMatchCurrentOwnerCollectionIdAndZeroRights() public {
        _delegate(stranger, hot, ID, true);
        _delegate(pepeOwner, hot, ID + 1, true);
        vm.startPrank(pepeOwner);
        registry.delegateERC721(hot, address(deeds), ID, bytes32(0), true);
        registry.delegateERC721(hot, address(pepe), ID, keccak256("someOtherRight"), true);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(OGClubDeeds.NotPepeOwnerOrDelegate.selector, hot, ID));
        vm.prank(hot);
        deeds.mint(ID, PRICE);
    }

    function test_OldOwnersDelegationCannotBeUsedAfterPepeMoves() public {
        _delegate(pepeOwner, hot, ID, true);
        vm.prank(pepeOwner);
        pepe.transferFrom(pepeOwner, stranger, ID);
        vm.expectRevert(abi.encodeWithSelector(OGClubDeeds.NotPepeOwnerOrDelegate.selector, hot, ID));
        vm.prank(hot);
        deeds.mint(ID, PRICE);
        _delegate(stranger, hot, ID, true);
        vm.prank(hot);
        deeds.mint(ID, PRICE);
        assertEq(deeds.ownerOf(ID), stranger);
    }

    function test_ClubExistsAfterDeedIsSoldAndPepeChangesHands() public {
        _ownerMint();
        vm.prank(pepeOwner);
        deeds.transferFrom(pepeOwner, stranger, ID);
        vm.prank(pepeOwner);
        pepe.transferFrom(pepeOwner, hot, ID);
        vm.expectRevert(abi.encodeWithSelector(OGClubDeeds.ClubExists.selector, ID));
        vm.prank(hot);
        deeds.mint(ID, PRICE);
        vm.expectRevert(abi.encodeWithSelector(OGClubDeeds.ClubExists.selector, ID));
        vm.prank(stranger);
        deeds.mint(ID, PRICE);
        assertEq(deeds.ownerOf(ID), stranger);
        assertTrue(deeds.clubExists(ID));
    }

    function test_RepeatedMintFailsBeforeFurtherPayment() public {
        _ownerMint();
        vm.expectRevert(abi.encodeWithSelector(OGClubDeeds.ClubExists.selector, ID));
        vm.prank(pepeOwner);
        deeds.mint(ID, PRICE);
        assertEq(token.balanceOf(vault), PRICE / 2);
    }

    function test_UnmintedPepeCannotProduceDeed() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, ID + 1));
        vm.prank(pepeOwner);
        deeds.mint(ID + 1, PRICE);
    }

    function test_PausedDeedsCanStillBeApprovedAndTraded() public {
        _ownerMint();
        vm.prank(admin);
        deeds.setPaused(true);
        vm.prank(pepeOwner);
        deeds.approve(hot, ID);
        vm.prank(hot);
        deeds.transferFrom(pepeOwner, stranger, ID);
        vm.prank(stranger);
        deeds.setApprovalForAll(hot, true);
        vm.prank(hot);
        deeds.safeTransferFrom(stranger, pepeOwner, ID);
        assertEq(deeds.ownerOf(ID), pepeOwner);
        assertTrue(deeds.paused());
    }

    function test_TransferToZeroIsNotABurn() public {
        _ownerMint();
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        vm.prank(pepeOwner);
        deeds.transferFrom(pepeOwner, address(0), ID);
        assertEq(deeds.ownerOf(ID), pepeOwner);
        assertTrue(deeds.clubExists(ID));
    }

    function test_URIAndPermanentFreeze() public {
        _ownerMint();
        assertEq(deeds.tokenURI(ID), "42.json");
        vm.expectEmit(false, false, false, true, address(deeds));
        emit OGClubDeeds.BaseURIUpdated("ipfs://club/");
        vm.prank(admin);
        deeds.setBaseURI("ipfs://club/");
        assertEq(deeds.tokenURI(ID), "ipfs://club/42.json");
        vm.expectEmit(false, false, false, true, address(deeds));
        emit OGClubDeeds.MetadataFrozenPermanently("ipfs://club/");
        vm.prank(admin);
        deeds.freezeMetadata();
        assertTrue(deeds.metadataFrozen());
        vm.expectRevert(OGClubDeeds.MetadataFrozen.selector);
        vm.prank(admin);
        deeds.setBaseURI("https://changed.invalid/");
        vm.expectRevert(OGClubDeeds.MetadataFrozen.selector);
        vm.prank(admin);
        deeds.freezeMetadata();
        vm.prank(admin);
        deeds.transferOwnership(hot);
        vm.prank(hot);
        deeds.acceptOwnership();
        vm.expectRevert(OGClubDeeds.MetadataFrozen.selector);
        vm.prank(hot);
        deeds.setBaseURI("ipfs://replacement/");
        assertEq(deeds.tokenURI(ID), "ipfs://club/42.json");
    }

    function test_URIMustReferToMintedDeed() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, ID));
        deeds.tokenURI(ID);
    }

    function test_ZeroAndLargestPepeIdsAndURIFormatting() public {
        pepe.mint(pepeOwner, 0);
        pepe.mint(pepeOwner, type(uint256).max);
        token.mint(pepeOwner, PRICE);
        vm.startPrank(pepeOwner);
        token.approve(address(deeds), PRICE * 2);
        deeds.mint(0, PRICE);
        deeds.mint(type(uint256).max, PRICE);
        vm.stopPrank();
        assertEq(deeds.tokenURI(0), "0.json");
        assertEq(
            deeds.tokenURI(type(uint256).max),
            "115792089237316195423570985008687907853269984665640564039457584007913129639935.json"
        );
    }

    function test_DefaultAndBoundedRoyalty() public {
        (address receiver, uint256 amount) = deeds.royaltyInfo(ID, 1 ether);
        assertEq(receiver, royaltyReceiver);
        assertEq(amount, 0.05 ether);
        vm.expectEmit(true, false, false, true, address(deeds));
        emit OGClubDeeds.RoyaltyUpdated(hot, 1000);
        vm.prank(admin);
        deeds.setRoyalty(hot, 1000);
        (receiver, amount) = deeds.royaltyInfo(ID, 1 ether);
        assertEq(receiver, hot);
        assertEq(amount, 0.1 ether);
        vm.expectRevert(abi.encodeWithSelector(OGClubDeeds.RoyaltyTooHigh.selector, uint96(1001)));
        vm.prank(admin);
        deeds.setRoyalty(hot, 1001);
        vm.expectRevert(OGClubPayments.ZeroAddress.selector);
        vm.prank(admin);
        deeds.setRoyalty(address(0), 500);
        vm.prank(admin);
        deeds.setRoyalty(hot, 0);
        (receiver, amount) = deeds.royaltyInfo(ID, 1 ether);
        assertEq(receiver, hot);
        assertEq(amount, 0);
    }

    function testFuzz_RoyaltyBoundsAndRounding(uint96 requestedBps, uint128 salePrice) public {
        if (requestedBps > 1000) {
            vm.expectRevert(abi.encodeWithSelector(OGClubDeeds.RoyaltyTooHigh.selector, requestedBps));
            vm.prank(admin);
            deeds.setRoyalty(hot, requestedBps);
        } else {
            vm.prank(admin);
            deeds.setRoyalty(hot, requestedBps);
            (address receiver, uint256 amount) = deeds.royaltyInfo(ID, salePrice);
            assertEq(receiver, hot);
            assertEq(amount, uint256(salePrice) * requestedBps / 10_000);
        }
    }

    function test_MetadataAndRoyaltyAreOwnerOnly() public {
        vm.startPrank(hot);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, hot));
        deeds.setBaseURI("ipfs://club/");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, hot));
        deeds.freezeMetadata();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, hot));
        deeds.setRoyalty(hot, 1000);
        vm.stopPrank();
        assertFalse(deeds.metadataFrozen());
    }

    function test_MetadataFreezeDoesNotFreezeRoyaltySettingsOrTransfers() public {
        _ownerMint();
        vm.startPrank(admin);
        deeds.freezeMetadata();
        deeds.setRoyalty(hot, 1000);
        vm.stopPrank();
        vm.prank(pepeOwner);
        deeds.transferFrom(pepeOwner, hot, ID);
        assertEq(deeds.ownerOf(ID), hot);
        (address receiver, uint256 amount) = deeds.royaltyInfo(ID, 100);
        assertEq(receiver, hot);
        assertEq(amount, 10);
    }

    function test_NonReceivingOwnerRollsBackPaymentAndEligibility() public {
        NFTRejectingVault rejecting = new NFTRejectingVault();
        vm.prank(pepeOwner);
        pepe.transferFrom(pepeOwner, address(rejecting), ID);
        _delegate(address(rejecting), hot, ID, true);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(rejecting)));
        vm.prank(hot);
        deeds.mint(ID, PRICE);
        assertFalse(deeds.clubExists(ID));
        assertEq(token.balanceOf(hot), PRICE);
        assertEq(token.balanceOf(vault), 0);
        assertEq(token.balanceOf(deeds.BURN_ADDRESS()), 0);
        assertEq(token.allowance(hot, address(deeds)), PRICE);
        vm.prank(address(rejecting));
        pepe.transferFrom(address(rejecting), pepeOwner, ID);
        _ownerMint();
        assertEq(deeds.ownerOf(ID), pepeOwner);
    }

    function test_ConstructorRejectsZeroPepeRegistryAndRoyaltyReceiver() public {
        vm.expectRevert(OGClubPayments.ZeroAddress.selector);
        new OGClubDeeds(address(token), vault, admin, PRICE, 0, address(0), address(registry), royaltyReceiver);
        vm.expectRevert(OGClubPayments.ZeroAddress.selector);
        new OGClubDeeds(address(token), vault, admin, PRICE, 0, address(pepe), address(0), royaltyReceiver);
        vm.expectRevert(OGClubPayments.ZeroAddress.selector);
        new OGClubDeeds(address(token), vault, admin, PRICE, 0, address(pepe), address(registry), address(0));
    }

    function test_ConstructorDoesNotRequireLiveExternalContracts() public {
        address absentToken = makeAddr("absentToken");
        address absentPepe = makeAddr("absentPepe");
        address absentRegistry = makeAddr("absentRegistry");
        OGClubDeeds emptyChain =
            new OGClubDeeds(absentToken, vault, admin, PRICE, 7 days, absentPepe, absentRegistry, royaltyReceiver);
        assertEq(emptyChain.owner(), admin);
        assertEq(address(emptyChain.swarmPepe()), absentPepe);
        assertEq(address(emptyChain.delegateRegistry()), absentRegistry);
    }
}

