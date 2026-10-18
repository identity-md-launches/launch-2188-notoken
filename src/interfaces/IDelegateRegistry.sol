// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal delegate.xyz v2 read interface used by OG Club.
interface IDelegateRegistry {
    /// @notice Checks whether to may act for from on an ERC-721 token with the specified rights.
    /// @param to Delegate wallet.
    /// @param from Current NFT owner (delegating vault).
    /// @param contract_ NFT collection address.
    /// @param tokenId NFT identifier.
    /// @param rights Rights identifier; bytes32(0) requests unrestricted delegation.
    /// @return valid Whether this delegation is currently valid.
    function checkDelegateForERC721(address to, address from, address contract_, uint256 tokenId, bytes32 rights)
        external
        view
        returns (bool valid);
}

