// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { MockOG } from "../src/mocks/MockOG.sol";
import { MockSwarmPepe } from "../src/mocks/MockSwarmPepe.sol";
import { MockDelegateRegistry } from "../src/mocks/MockDelegateRegistry.sol";
import { OGClubHouses } from "../src/OGClubHouses.sol";
import { OGClubDeeds } from "../src/OGClubDeeds.sol";

/// @title OG Club Sepolia deployment recipe
/// @notice Explicit configuration, public test faucets, and zero price notice. Never deploys on mainnet.
contract Deploy is Script {
    /// @notice The mock deployment recipe is restricted to Sepolia.
    error WrongChain(uint256 chainId);
    /// @notice The operator must supply real, nonzero deployment and ownership addresses.
    error ZeroAddress();

    uint256 public constant SEPOLIA_CHAIN_ID = 11_155_111;
    uint256 public constant HOUSE_PRICE = 100_000 ether;
    uint256 public constant DEED_PRICE = 250_000 ether;

    /// @notice Addresses returned to the deployment operator and local tests.
    struct Deployment {
        MockOG token;
        MockSwarmPepe swarmPepe;
        MockDelegateRegistry registry;
        OGClubHouses houses;
        OGClubDeeds deeds;
    }

    /// @notice Forge entrypoint. Supply the broadcaster and administrator explicitly; no keys are read by this script.
    /// @dev Without Forge's --broadcast flag this only simulates. Do not pass the factory as deployer or owner.
    /// @param deployer Wallet funding the Sepolia deployment; receives the initial token and both vault shares.
    /// @param owner Administrative owner and royalty receiver; may differ from the test deployer.
    function run(address deployer, address owner) external returns (Deployment memory result) {
        _validate(deployer, owner);
        vm.startBroadcast(deployer);
        result = deploy(deployer, owner);
        vm.stopBroadcast();
    }

    /// @notice Testable deployment function with no environment dependency or broadcast cheatcodes.
    function deploy(address deployer, address owner) public returns (Deployment memory result) {
        _validate(deployer, owner);
        result.token = new MockOG(deployer);
        result.swarmPepe = new MockSwarmPepe();
        result.registry = new MockDelegateRegistry();
        result.houses = new OGClubHouses(address(result.token), deployer, owner, HOUSE_PRICE, 0);
        result.deeds = new OGClubDeeds(
            address(result.token),
            deployer,
            owner,
            DEED_PRICE,
            0,
            address(result.swarmPepe),
            address(result.registry),
            owner
        );
    }

    function _validate(address deployer, address owner) private view {
        if (block.chainid != SEPOLIA_CHAIN_ID) revert WrongChain(block.chainid);
        if (deployer == address(0) || owner == address(0)) revert ZeroAddress();
    }
}

