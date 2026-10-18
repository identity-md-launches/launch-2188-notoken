// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title Sepolia-only Swarm Pepe stand-in
/// @notice Publicly mintable NFT collection; no privileged minter or administrator.
contract MockSwarmPepe is ERC721 {
    constructor() ERC721("Mock Swarm Pepe", "MSWARM") { }

    /// @notice Mints a previously unused token id to a nonzero account that can receive NFTs.
    function mint(address account, uint256 tokenId) external {
        _safeMint(account, tokenId);
    }
}

