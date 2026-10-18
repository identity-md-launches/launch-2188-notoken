// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OGClubPayments } from "../src/OGClubPayments.sol";
import { OGClubHouses } from "../src/OGClubHouses.sol";
import { OGClubDeeds } from "../src/OGClubDeeds.sol";
import { MockOG } from "../src/mocks/MockOG.sol";
import { MockSwarmPepe } from "../src/mocks/MockSwarmPepe.sol";
import { MockDelegateRegistry } from "../src/mocks/MockDelegateRegistry.sol";

/// @dev Drives three sales with different notices (7 days, 1 second, 0) through random price announcements,
/// time jumps (including exact activation boundaries), pauses and purchases at, above and below the quote.
/// The expected price is derived from a log of every setPrice call, not from the contract's own storage:
/// the price at time `t` is the last announcement whose notice elapsed by `t`, unless a later announcement
/// replaced it first, in which case it is whatever was in force when that replacement was made.
contract ScheduleHandler is Test {
    struct Announcement {
        uint256 at;
        uint256 newPrice;
    }

    uint256 internal constant SALES = 3;
    address public immutable vault;
    address public immutable admin;
    MockOG public token;
    MockSwarmPepe public pepe;
    MockDelegateRegistry public registry;
    OGClubPayments[3] public sales;
    uint256[3] public initialPrices;
    address[5] public actors;

    mapping(uint256 sale => Announcement[]) internal _log;

    uint256 public totalSpent;
    uint256 public expectedBurned;
    uint256 public expectedVault;
    uint256 public successfulPurchases;
    uint256 public rejectedPurchases;
    uint256 internal _nextPepe;
    uint256 internal _giftNonce;

    constructor() {
        vault = makeAddr("scheduleVault");
        admin = makeAddr("scheduleSafe");
        token = new MockOG(address(this));
        pepe = new MockSwarmPepe();
        registry = new MockDelegateRegistry();
        initialPrices = [uint256(100_000 ether), 250_000 ether + 1, 100_000 ether];
        sales[0] = new OGClubHouses(address(token), vault, admin, initialPrices[0], 7 days);
        sales[1] = new OGClubDeeds(
            address(token), vault, admin, initialPrices[1], 1, address(pepe), address(registry), admin
        );
        sales[2] = new OGClubHouses(address(token), vault, admin, initialPrices[2], 0);
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = address(uint160(0xA000 + i));
        }
    }

    // ------------------------------------------------------------------ oracle

    /// @notice Price in force at the current block according to the announcement log.
    function modelPrice(uint256 s) public view returns (uint256) {
        return _priceAt(s, _log[s].length, block.timestamp);
    }

    /// @dev Price in force at time `t`, considering only the first `n` announcements.
    function _priceAt(uint256 s, uint256 n, uint256 t) internal view returns (uint256) {
        uint256 notice = sales[s].priceNotice();
        while (n > 0) {
            Announcement storage a = _log[s][n - 1];
            if (t >= a.at + notice) return a.newPrice;
            // The last announcement is not yet active: what applies is what was in force when it was made.
            t = a.at;
            --n;
        }
        return initialPrices[s];
    }

    function modelPending(uint256 s) public view returns (uint256 newPrice, uint256 effectiveAt) {
        uint256 n = _log[s].length;
        if (n == 0) return (0, 0);
        Announcement storage last = _log[s][n - 1];
        uint256 startsAt = last.at + sales[s].priceNotice();
        if (block.timestamp < startsAt) return (last.newPrice, startsAt);
        return (0, 0);
    }

    function logLength(uint256 s) external view returns (uint256) {
        return _log[s].length;
    }

    // ------------------------------------------------------------------ actions

    function announce(uint256 saleSeed, uint96 rawPrice, bool odd) external {
        uint256 s = saleSeed % SALES;
        uint256 newPrice = uint256(rawPrice) % 1_000_000 ether;
        if (odd) newPrice |= 1;
        vm.prank(admin);
        sales[s].setPrice(newPrice);
        _log[s].push(Announcement({ at: block.timestamp, newPrice: newPrice }));
    }

    function strangerAnnounce(uint256 saleSeed, uint256 actorSeed, uint256 newPrice) external {
        uint256 s = saleSeed % SALES;
        address stranger = actors[actorSeed % actors.length];
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        sales[s].setPrice(newPrice);
    }

    function warp(uint32 rawSeconds) external {
        vm.warp(vm.getBlockTimestamp() + uint256(rawSeconds) % 10 days);
    }

    /// @dev Lands exactly one second before, on, or one second after the newest activation time.
    function warpToBoundary(uint256 saleSeed, uint8 where) external {
        uint256 s = saleSeed % SALES;
        uint256 n = _log[s].length;
        if (n == 0) return;
        uint256 startsAt = _log[s][n - 1].at + sales[s].priceNotice();
        uint256 target = startsAt + (where % 3) - 1;
        if (target > block.timestamp) vm.warp(target);
    }

    function pause(uint256 saleSeed, bool paused_) external {
        vm.prank(admin);
        sales[saleSeed % SALES].setPaused(paused_);
    }

    /// @param mode 0 pays exactly the quote, 1 offers one wei less, 2 offers far more than the quote.
    function purchase(uint256 saleSeed, uint256 actorSeed, uint8 mode) external {
        uint256 s = saleSeed % SALES;
        OGClubPayments sale = sales[s];
        address payer = actors[actorSeed % actors.length];
        uint256 expected = modelPrice(s);
        mode %= 3;
        if (mode == 1 && expected == 0) mode = 0;
        uint256 maxPrice = mode == 0 ? expected : mode == 1 ? expected - 1 : type(uint256).max;

        token.mint(payer, expected);
        vm.prank(payer);
        token.approve(address(sale), type(uint256).max);
        uint256 payerBefore = token.balanceOf(payer);
        uint256 burnBefore = token.balanceOf(sale.BURN_ADDRESS());
        uint256 vaultBefore = token.balanceOf(vault);

        // Prepare the beneficiary or Pepe before arming expectRevert, which applies to the next call.
        uint256 target = _prepare(s, payer);
        bool fails = sale.paused() || mode == 1;
        if (sale.paused()) {
            vm.expectRevert(Pausable.EnforcedPause.selector);
        } else if (mode == 1) {
            vm.expectRevert(abi.encodeWithSelector(OGClubPayments.PriceTooHigh.selector, expected, maxPrice));
        }
        vm.prank(payer);
        if (s == 1) OGClubDeeds(address(sale)).mint(target, maxPrice);
        else OGClubHouses(address(sale)).buyHouseFor(address(uint160(target)), maxPrice);

        if (fails) {
            ++rejectedPurchases;
            assertEq(token.balanceOf(payer), payerBefore, "rejected purchase moved tokens");
            return;
        }
        ++successfulPurchases;
        assertEq(payerBefore - token.balanceOf(payer), expected, "charged a price other than the one in force");
        assertEq(token.balanceOf(sale.BURN_ADDRESS()) - burnBefore, expected / 2, "burn share");
        assertEq(token.balanceOf(vault) - vaultBefore, expected - expected / 2, "vault share");
        totalSpent += expected;
        expectedBurned += expected / 2;
        expectedVault += expected - expected / 2;
    }

    /// @dev Houses are bought for a fresh beneficiary; deeds use a fresh Pepe owned by the payer.
    function _prepare(uint256 s, address payer) internal returns (uint256) {
        if (s == 1) {
            uint256 id = _nextPepe++;
            pepe.mint(payer, id);
            return id;
        }
        return uint160(uint256(keccak256(abi.encode("gift", _giftNonce++))));
    }
}

contract PriceScheduleInvariantTest is StdInvariant, Test {
    ScheduleHandler internal handler;

    function setUp() public {
        vm.warp(1_700_000_000);
        handler = new ScheduleHandler();
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.announce.selector;
        selectors[1] = handler.strangerAnnounce.selector;
        selectors[2] = handler.warp.selector;
        selectors[3] = handler.warpToBoundary.selector;
        selectors[4] = handler.pause.selector;
        selectors[5] = handler.purchase.selector;
        selectors[6] = handler.purchase.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_PriceMatchesAnnouncementLog() public view {
        for (uint256 s; s < 3; ++s) {
            assertEq(handler.sales(s).price(), handler.modelPrice(s), "price() diverges from announcement log");
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_PendingViewMatchesAnnouncementLog() public view {
        for (uint256 s; s < 3; ++s) {
            (uint256 p, uint256 at) = handler.sales(s).pendingPrice();
            (uint256 mp, uint256 mat) = handler.modelPending(s);
            assertEq(p, mp, "pending price");
            assertEq(at, mat, "pending start");
            if (at != 0) assertGt(at, block.timestamp, "pending start must be in the future");
        }
        // Zero notice never leaves anything pending.
        (uint256 p2, uint256 at2) = handler.sales(2).pendingPrice();
        assertEq(p2, 0);
        assertEq(at2, 0);
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_BurnPlusVaultEqualsSpentAndNoCustody() public view {
        MockOG token = handler.token();
        address burn = handler.sales(0).BURN_ADDRESS();
        assertEq(token.balanceOf(burn), handler.expectedBurned());
        assertEq(token.balanceOf(handler.vault()), handler.expectedVault());
        assertEq(token.balanceOf(burn) + token.balanceOf(handler.vault()), handler.totalSpent());
        for (uint256 s; s < 3; ++s) {
            assertEq(token.balanceOf(address(handler.sales(s))), 0, "sale holds tokens");
        }
    }
}

/// @dev Pins the oracle against hand-computed timelines so the invariant above is not vacuous.
contract PriceScheduleOracleTest is Test {
    ScheduleHandler internal handler;

    function setUp() public {
        vm.warp(1_700_000_000);
        handler = new ScheduleHandler();
    }

    function test_ReplacedAnnouncementNeverActivates() public {
        uint256 t0 = vm.getBlockTimestamp();
        handler.announce(0, 1 ether, false); // effective t0 + 7 days
        vm.warp(t0 + 3 days);
        handler.announce(0, 2 ether, false); // replaces it; effective t0 + 10 days
        vm.warp(t0 + 7 days);
        assertEq(handler.modelPrice(0), 100_000 ether);
        assertEq(handler.sales(0).price(), 100_000 ether);
        vm.warp(t0 + 10 days - 1);
        assertEq(handler.sales(0).price(), 100_000 ether);
        vm.warp(t0 + 10 days);
        assertEq(handler.modelPrice(0), 2 ether);
        assertEq(handler.sales(0).price(), 2 ether);
    }

    function test_ActivatedPriceSurvivesNextAnnouncement() public {
        uint256 t0 = vm.getBlockTimestamp();
        handler.announce(0, 1 ether, false);
        vm.warp(t0 + 7 days); // exactly on the boundary: 1 ether is in force
        handler.announce(0, 3 ether, false);
        assertEq(handler.modelPrice(0), 1 ether);
        assertEq(handler.sales(0).price(), 1 ether);
        (uint256 p, uint256 at) = handler.sales(0).pendingPrice();
        assertEq(p, 3 ether);
        assertEq(at, t0 + 14 days);
    }

    function test_OneSecondNoticeAndZeroNotice() public {
        handler.announce(1, 7 ether, true);
        assertEq(handler.sales(1).price(), 250_000 ether + 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(handler.sales(1).price(), 7 ether + 1);
        handler.announce(2, 5, false);
        assertEq(handler.sales(2).price(), 5);
        assertEq(handler.modelPrice(2), 5);
    }

    function test_PurchaseAtExactQuoteBelowAndAbove() public {
        handler.purchase(0, 0, 0);
        handler.purchase(1, 1, 1);
        handler.purchase(2, 2, 2);
        assertEq(handler.successfulPurchases(), 2);
        assertEq(handler.rejectedPurchases(), 1);
        assertEq(handler.totalSpent(), 200_000 ether);
    }
}
