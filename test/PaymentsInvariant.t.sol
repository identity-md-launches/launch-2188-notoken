// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { OGClubHouses } from "../src/OGClubHouses.sol";
import { OGClubDeeds } from "../src/OGClubDeeds.sol";
import { MockOG } from "../src/mocks/MockOG.sol";
import { MockSwarmPepe } from "../src/mocks/MockSwarmPepe.sol";
import { MockDelegateRegistry } from "../src/mocks/MockDelegateRegistry.sol";

/// @dev The handler is the admin; six distinct actors pay and trade. Expected reverts are asserted explicitly.
contract PaymentHandler is Test {
    uint256 internal constant PEPE_COUNT = 16;
    address public immutable vault;
    MockOG public token;
    MockSwarmPepe public pepe;
    MockDelegateRegistry public registry;
    OGClubHouses public houses;
    OGClubDeeds public deeds;
    address[6] public actors;

    uint256 public totalFunded;
    uint256 public observedSpent;
    uint256 public quotedSpent;
    uint256 public expectedBurned;
    uint256 public expectedVault;
    address[] public houseRecipients;
    uint256[] public mintedIds;

    constructor() {
        vault = makeAddr("invariantFarmingVault");
        token = new MockOG(address(this));
        pepe = new MockSwarmPepe();
        registry = new MockDelegateRegistry();
        houses = new OGClubHouses(address(token), vault, address(this), 100_000 ether, 7 days);
        deeds = new OGClubDeeds(
            address(token), vault, address(this), 250_000 ether, 7 days, address(pepe), address(registry), address(this)
        );
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = address(uint160(0x1000 + i));
        }
        for (uint256 id; id < PEPE_COUNT; ++id) {
            pepe.mint(actors[id % actors.length], id);
        }
    }

    function buyHouse(uint256 actorSeed, uint256 beneficiarySeed, bool gift) external {
        address payer = actors[actorSeed % actors.length];
        address recipient = gift ? address(uint160(0x100000 + beneficiarySeed % 32)) : payer;
        uint256 quoted = houses.price();
        uint256 beforeBalance = _fund(payer, address(houses), quoted);
        bool fails = houses.paused() || houses.hasHouse(recipient);
        if (houses.paused()) {
            vm.expectRevert(Pausable.EnforcedPause.selector);
        } else if (houses.hasHouse(recipient)) {
            vm.expectRevert(abi.encodeWithSelector(OGClubHouses.AlreadyHasHouse.selector, recipient));
        }
        vm.prank(payer);
        if (gift) houses.buyHouseFor(recipient, quoted);
        else houses.buyHouse(quoted);

        if (fails) {
            assertEq(token.balanceOf(payer), beforeBalance);
        } else {
            _record(payer, beforeBalance, quoted);
            houseRecipients.push(recipient);
        }
    }

    function mintClub(uint256 actorSeed, uint256 idSeed, bool asDelegate, bool revoke) external {
        uint256 id = idSeed % PEPE_COUNT;
        address pepeOwner = pepe.ownerOf(id);
        address payer = asDelegate ? actors[actorSeed % actors.length] : pepeOwner;
        if (payer != pepeOwner) {
            vm.prank(pepeOwner);
            registry.delegateERC721(payer, address(pepe), id, bytes32(0), !revoke);
        }
        uint256 quoted = deeds.price();
        uint256 beforeBalance = _fund(payer, address(deeds), quoted);
        bool unauthorized = payer != pepeOwner && revoke;
        bool fails = deeds.paused() || deeds.clubExists(id) || unauthorized;
        if (deeds.paused()) {
            vm.expectRevert(Pausable.EnforcedPause.selector);
        } else if (deeds.clubExists(id)) {
            vm.expectRevert(abi.encodeWithSelector(OGClubDeeds.ClubExists.selector, id));
        } else if (unauthorized) {
            vm.expectRevert(abi.encodeWithSelector(OGClubDeeds.NotPepeOwnerOrDelegate.selector, payer, id));
        }
        vm.prank(payer);
        deeds.mint(id, quoted);

        if (fails) {
            assertEq(token.balanceOf(payer), beforeBalance);
        } else {
            _record(payer, beforeBalance, quoted);
            mintedIds.push(id);
            assertEq(deeds.ownerOf(id), pepeOwner);
        }
    }

    function setPrices(uint96 housePrice, uint96 deedPrice) external {
        houses.setPrice(uint256(housePrice) % 1e27);
        deeds.setPrice(uint256(deedPrice) % 1e27);
    }

    function advanceTime(uint32 secondsForward) external {
        vm.warp(vm.getBlockTimestamp() + uint256(secondsForward) % 15 days);
    }

    function setPause(bool pauseHouses, bool pauseDeeds) external {
        houses.setPaused(pauseHouses);
        deeds.setPaused(pauseDeeds);
    }

    function transferPepe(uint256 idSeed, uint256 actorSeed) external {
        uint256 id = idSeed % PEPE_COUNT;
        address from = pepe.ownerOf(id);
        vm.prank(from);
        pepe.transferFrom(from, actors[actorSeed % actors.length], id);
    }

    function transferDeed(uint256 idSeed, uint256 actorSeed) external {
        uint256 id = idSeed % PEPE_COUNT;
        if (!deeds.clubExists(id)) return;
        address from = deeds.ownerOf(id);
        vm.prank(from);
        deeds.transferFrom(from, actors[actorSeed % actors.length], id);
    }

    function _fund(address payer, address spender, uint256 amount) private returns (uint256) {
        token.mint(payer, amount);
        totalFunded += amount;
        vm.prank(payer);
        token.approve(spender, amount);
        return token.balanceOf(payer);
    }

    function _record(address payer, uint256 beforeBalance, uint256 quoted) private {
        observedSpent += beforeBalance - token.balanceOf(payer);
        quotedSpent += quoted;
        expectedBurned += quoted / 2;
        expectedVault += quoted - quoted / 2;
    }

    function actorBalanceTotal() external view returns (uint256 total) {
        for (uint256 i; i < actors.length; ++i) {
            total += token.balanceOf(actors[i]);
        }
    }

    function houseRecipientCount() external view returns (uint256) {
        return houseRecipients.length;
    }

    function mintedIdCount() external view returns (uint256) {
        return mintedIds.length;
    }
}

contract PaymentsInvariantTest is StdInvariant, Test {
    PaymentHandler internal handler;
    MockOG internal token;
    OGClubHouses internal houses;
    OGClubDeeds internal deeds;

    function setUp() public {
        handler = new PaymentHandler();
        token = handler.token();
        houses = handler.houses();
        deeds = handler.deeds();
        // Seed real purchases so conservation and permanence cannot pass vacuously.
        handler.buyHouse(0, 0, false);
        handler.mintClub(0, 0, false, false);

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.buyHouse.selector;
        selectors[1] = handler.mintClub.selector;
        selectors[2] = handler.setPrices.selector;
        selectors[3] = handler.advanceTime.selector;
        selectors[4] = handler.setPause.selector;
        selectors[5] = handler.transferPepe.selector;
        selectors[6] = handler.transferDeed.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    function invariant_BurnPlusVaultEqualsActualPayerSpending() public view {
        uint256 burned = token.balanceOf(houses.BURN_ADDRESS());
        uint256 toVault = token.balanceOf(handler.vault());
        assertEq(burned + toVault, handler.observedSpent());
        assertEq(handler.observedSpent(), handler.quotedSpent());
        assertEq(burned, handler.expectedBurned());
        assertEq(toVault, handler.expectedVault());
        assertEq(handler.actorBalanceTotal() + handler.observedSpent(), handler.totalFunded());
    }

    function invariant_PurchasesNeverLeaveTokensInEitherContract() public view {
        assertEq(token.balanceOf(address(houses)), 0);
        assertEq(token.balanceOf(address(deeds)), 0);
    }

    function invariant_HousesArePermanentAndCountedOnce() public view {
        uint256 count = handler.houseRecipientCount();
        assertGt(count, 0);
        assertEq(houses.houseCount(), count);
        for (uint256 i; i < count; ++i) {
            assertTrue(houses.hasHouse(handler.houseRecipients(i)));
        }
    }

    function invariant_ClubEligibilityStaysConsumedAfterTrading() public view {
        uint256 count = handler.mintedIdCount();
        assertGt(count, 0);
        for (uint256 i; i < count; ++i) {
            uint256 id = handler.mintedIds(i);
            assertTrue(deeds.clubExists(id));
            assertTrue(deeds.ownerOf(id) != address(0));
        }
    }
}

