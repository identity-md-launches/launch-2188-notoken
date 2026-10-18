// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { ERC2981 } from "@openzeppelin/contracts/token/common/ERC2981.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { OGClubPayments } from "./OGClubPayments.sol";
import { IDelegateRegistry } from "./interfaces/IDelegateRegistry.sol";

/// @title OG Club deeds
/// @notice A freely transferable club deed for each Swarm Pepe, minted at most once per Pepe forever.
/// @dev Purchases are pausable; ERC-721 approvals and transfers are never paused.
contract OGClubDeeds is OGClubPayments, ERC721, ERC2981 {
    /// @notice This Pepe already produced its one deed.
    error ClubExists(uint256 pepeId);
    /// @notice The payer is neither the current Pepe owner nor its authorized delegate.
    error NotPepeOwnerOrDelegate(address payer, uint256 pepeId);
    /// @notice Metadata has already been permanently frozen.
    error MetadataFrozen();
    /// @notice The royalty exceeds the 10% ceiling.
    error RoyaltyTooHigh(uint96 feeNumerator);

    /// @notice Emitted after payment and minting to the Pepe owner captured at purchase time.
    event ClubMinted(
        uint256 indexed pepeId, address indexed owner, address payer, uint256 price, uint256 burned, uint256 toVault
    );
    /// @notice The metadata prefix was changed.
    event BaseURIUpdated(string baseURI);
    /// @notice The metadata prefix was frozen permanently.
    event MetadataFrozenPermanently(string baseURI);
    /// @notice Global ERC-2981 receiver and fee were changed.
    event RoyaltyUpdated(address indexed receiver, uint96 feeNumerator);

    /// @notice Default 5% royalty, expressed in basis points.
    uint96 public constant DEFAULT_ROYALTY_BPS = 500;
    /// @notice Maximum 10% royalty, expressed in basis points.
    uint96 public constant MAX_ROYALTY_BPS = 1000;
    /// @notice Immutable Swarm Pepe collection.
    IERC721 public immutable swarmPepe;
    /// @notice Immutable delegate.xyz v2 registry.
    IDelegateRegistry public immutable delegateRegistry;
    /// @notice Permanent record of Pepe ids used to mint a club.
    mapping(uint256 pepeId => bool) public clubExists;
    /// @notice Metadata prefix, including any desired trailing slash.
    string public baseURI;
    /// @notice Whether the metadata prefix has been frozen permanently.
    bool public metadataFrozen;

    /// @param token_ Existing 18-decimal OG token.
    /// @param vault_ Immutable farming vault.
    /// @param owner_ Explicit administrator (a Safe on mainnet).
    /// @param initialPrice_ Initial price in wei; the launch uses 250,000 ether.
    /// @param priceNotice_ Immutable price notice in seconds.
    /// @param swarmPepe_ Existing Swarm Pepe ERC-721 collection.
    /// @param delegateRegistry_ delegate.xyz v2 registry.
    /// @param royaltyReceiver_ Nonzero initial royalty recipient; default rate is 5%.
    constructor(
        address token_,
        address vault_,
        address owner_,
        uint256 initialPrice_,
        uint256 priceNotice_,
        address swarmPepe_,
        address delegateRegistry_,
        address royaltyReceiver_
    ) OGClubPayments(token_, vault_, owner_, initialPrice_, priceNotice_) ERC721("OG Club", "OGCLUB") {
        if (swarmPepe_ == address(0) || delegateRegistry_ == address(0) || royaltyReceiver_ == address(0)) {
            revert ZeroAddress();
        }
        swarmPepe = IERC721(swarmPepe_);
        delegateRegistry = IDelegateRegistry(delegateRegistry_);
        _setDefaultRoyalty(royaltyReceiver_, DEFAULT_ROYALTY_BPS);
    }

    /// @notice Purchases the unique club deed for pepeId, paying from msg.sender and minting to the Pepe owner.
    /// @dev Uses the registry's unrestricted ERC-721 delegation check. ERC-721 approvals alone do not qualify.
    /// @param pepeId Pepe id and resulting deed id.
    /// @param maxPrice Highest acceptable price in token wei.
    function mint(uint256 pepeId, uint256 maxPrice) external nonReentrant whenNotPaused {
        if (clubExists[pepeId]) revert ClubExists(pepeId);
        uint256 purchasePrice = _checkedPrice(maxPrice);
        address pepeOwner = swarmPepe.ownerOf(pepeId);
        if (pepeOwner == address(0)) revert ZeroAddress();
        if (
            msg.sender != pepeOwner
                && !delegateRegistry.checkDelegateForERC721(
                    msg.sender, pepeOwner, address(swarmPepe), pepeId, bytes32(0)
                )
        ) revert NotPepeOwnerOrDelegate(msg.sender, pepeId);

        clubExists[pepeId] = true;
        (uint256 burned, uint256 toVault) = _collectPayment(purchasePrice);
        _safeMint(pepeOwner, pepeId);
        emit ClubMinted(pepeId, pepeOwner, msg.sender, purchasePrice, burned, toVault);
    }

    /// @notice Sets the metadata prefix until freezeMetadata is called.
    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        if (metadataFrozen) revert MetadataFrozen();
        baseURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }

    /// @notice Permanently prevents any future change to the metadata prefix.
    /// @dev Freezes the URI prefix, not content served by an external host.
    function freezeMetadata() external onlyOwner {
        if (metadataFrozen) revert MetadataFrozen();
        metadataFrozen = true;
        emit MetadataFrozenPermanently(baseURI);
    }

    /// @notice Sets the global royalty receiver and rate, capped at 1,000 basis points (10%).
    /// @dev Royalties are advisory ERC-2981 information; transfers do not collect a royalty.
    function setRoyalty(address receiver, uint96 feeNumerator) external onlyOwner {
        if (receiver == address(0)) revert ZeroAddress();
        if (feeNumerator > MAX_ROYALTY_BPS) revert RoyaltyTooHigh(feeNumerator);
        _setDefaultRoyalty(receiver, feeNumerator);
        emit RoyaltyUpdated(receiver, feeNumerator);
    }

    /// @notice Returns baseURI + decimal token id + ".json"; reverts for an unminted deed.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return string.concat(baseURI, Strings.toString(tokenId), ".json");
    }

    /// @notice Supports ERC-165, ERC-721, ERC-721 metadata and ERC-2981.
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}

