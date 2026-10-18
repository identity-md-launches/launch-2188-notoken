// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IDelegateRegistry } from "../interfaces/IDelegateRegistry.sol";

/// @title Sepolia-only delegate.xyz stand-in
/// @notice Models token-specific v2 delegation and revocation; not the full production registry.
contract MockDelegateRegistry is IDelegateRegistry {
    mapping(bytes32 delegationHash => bool) private _delegations;

    /// @notice A vault granted or revoked a token-specific delegation.
    event DelegateERC721(
        address indexed from,
        address indexed to,
        address indexed contract_,
        uint256 tokenId,
        bytes32 rights,
        bool enable
    );

    /// @notice Creates or revokes a delegation from msg.sender only.
    function delegateERC721(address to, address contract_, uint256 tokenId, bytes32 rights, bool enable)
        external
        returns (bytes32 delegationHash)
    {
        delegationHash = _hash(to, msg.sender, contract_, tokenId, rights);
        _delegations[delegationHash] = enable;
        emit DelegateERC721(msg.sender, to, contract_, tokenId, rights, enable);
    }

    /// @inheritdoc IDelegateRegistry
    function checkDelegateForERC721(address to, address from, address contract_, uint256 tokenId, bytes32 rights)
        external
        view
        returns (bool)
    {
        return _delegations[_hash(to, from, contract_, tokenId, rights)];
    }

    function _hash(address to, address from, address contract_, uint256 tokenId, bytes32 rights)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(to, from, contract_, tokenId, rights));
    }
}

