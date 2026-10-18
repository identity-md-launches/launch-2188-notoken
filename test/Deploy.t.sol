// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Deploy } from "../script/Deploy.s.sol";
import { OGClubHouses } from "../src/OGClubHouses.sol";
import { OGClubDeeds } from "../src/OGClubDeeds.sol";
import { OGClubPayments } from "../src/OGClubPayments.sol";
import { NFTReceivingVault } from "./OGClubDeeds.t.sol";

contract DeployTest is Test {
    Deploy internal recipe;
    address internal deployer;
    address internal ownerSafe;

    function setUp() public {
        vm.chainId(11_155_111);
        recipe = new Deploy();
        deployer = makeAddr("explicitTestDeployer");
        ownerSafe = address(new NFTReceivingVault());
    }

    function test_ExplicitSepoliaConfigurationAndFaucets() public {
        Deploy.Deployment memory result = recipe.deploy(deployer, ownerSafe);
        assertEq(result.houses.owner(), ownerSafe);
        assertEq(result.deeds.owner(), ownerSafe);
        assertTrue(result.houses.owner() != address(recipe));
        assertEq(result.houses.vault(), deployer);
        assertEq(result.deeds.vault(), deployer);
        assertEq(result.houses.price(), 100_000 ether);
        assertEq(result.deeds.price(), 250_000 ether);
        assertEq(result.houses.priceNotice(), 0);
        assertEq(result.deeds.priceNotice(), 0);
        assertEq(address(result.houses.token()), address(result.token));
        assertEq(address(result.deeds.token()), address(result.token));
        assertEq(address(result.deeds.swarmPepe()), address(result.swarmPepe));
        assertEq(address(result.deeds.delegateRegistry()), address(result.registry));
        assertEq(result.token.name(), "notoken");
        assertEq(result.token.symbol(), "nt");
        assertEq(result.token.decimals(), 18);
        assertEq(result.token.totalSupply(), 1 ether);
        assertEq(result.token.balanceOf(deployer), 1 ether);
        (address receiver, uint256 amount) = result.deeds.royaltyInfo(1, 10_000);
        assertEq(receiver, ownerSafe);
        assertEq(amount, 500);

        address buyer = makeAddr("testBuyer");
        // Faucets are public and calls work regardless of who invoked the deployment recipe.
        vm.startPrank(buyer);
        result.token.mint(buyer, 350_000 ether);
        result.swarmPepe.mint(buyer, 1);
        result.token.approve(address(result.houses), 100_000 ether);
        result.houses.buyHouse(100_000 ether);
        result.token.approve(address(result.deeds), 250_000 ether);
        result.deeds.mint(1, 250_000 ether);
        vm.stopPrank();
        assertTrue(result.houses.hasHouse(buyer));
        assertEq(result.deeds.ownerOf(1), buyer);
        assertEq(result.token.balanceOf(deployer), 175_001 ether);
    }

    function test_SafeAddressCanExerciseOwnerFunctions() public {
        Deploy.Deployment memory result = recipe.deploy(deployer, ownerSafe);
        vm.startPrank(ownerSafe);
        result.houses.setPrice(7);
        result.deeds.setPrice(11);
        result.houses.setPaused(true);
        result.deeds.setBaseURI("ipfs://club/");
        result.deeds.freezeMetadata();
        result.deeds.setRoyalty(ownerSafe, 1000);
        vm.stopPrank();
        assertEq(result.houses.price(), 7);
        assertEq(result.deeds.price(), 11);
        assertTrue(result.houses.paused());
        assertTrue(result.deeds.metadataFrozen());
    }

    function test_RecipeRejectsMainnet() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(Deploy.WrongChain.selector, 1));
        recipe.deploy(deployer, ownerSafe);
    }

    function test_RecipeRejectsMissingAddresses() public {
        vm.expectRevert(Deploy.ZeroAddress.selector);
        recipe.deploy(address(0), ownerSafe);
        vm.expectRevert(Deploy.ZeroAddress.selector);
        recipe.deploy(deployer, address(0));
    }

    function test_AllFiveLaunchRuntimesAreBoundedAndHaveNoEscapeOpcodes() public {
        Deploy.Deployment memory result = recipe.deploy(deployer, ownerSafe);
        _checkRuntime(address(result.token));
        _checkRuntime(address(result.swarmPepe));
        _checkRuntime(address(result.registry));
        _checkRuntime(address(result.houses));
        _checkRuntime(address(result.deeds));
    }

    function test_ConstructorsWorkTogetherWithoutExternalCodeAndUseExplicitOwner() public {
        // Same empty-chain dependency conditions as the protected constructor probe.
        address absentToken = makeAddr("absentToken");
        address absentPepe = makeAddr("absentPepe");
        address absentRegistry = makeAddr("absentRegistry");
        OGClubHouses houses = new OGClubHouses(absentToken, deployer, ownerSafe, 100_000 ether, 7 days);
        OGClubDeeds deeds = new OGClubDeeds(
            absentToken, deployer, ownerSafe, 250_000 ether, 7 days, absentPepe, absentRegistry, ownerSafe
        );
        assertEq(houses.owner(), ownerSafe);
        assertEq(deeds.owner(), ownerSafe);
        _checkRuntime(address(houses));
        _checkRuntime(address(deeds));
    }

    function test_HousesRejectOwnPredictedAddressAsVault() public {
        address selfVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(abi.encodeWithSelector(OGClubPayments.InvalidVault.selector, selfVault));
        new OGClubHouses(makeAddr("absentToken"), selfVault, ownerSafe, 1, 0);
    }

    function test_DeedsRejectOwnPredictedAddressAsVault() public {
        address absentToken = makeAddr("absentToken");
        address absentPepe = makeAddr("absentPepe");
        address absentRegistry = makeAddr("absentRegistry");
        address selfVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(abi.encodeWithSelector(OGClubPayments.InvalidVault.selector, selfVault));
        new OGClubDeeds(absentToken, selfVault, ownerSafe, 1, 0, absentPepe, absentRegistry, ownerSafe);
    }

    function _checkRuntime(address application) private view {
        bytes memory code = application.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}

