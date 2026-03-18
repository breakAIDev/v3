// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721Enumerable} from "../interfaces/IERC721Enumerable.sol";

/**
 * @title IAlchemistV3Position
 * @notice Interface for the AlchemistV3Position ERC721 token.
 */
interface IAlchemistV3Position is IERC721Enumerable {
    /**
     * @notice Emits when a position token is first registered as an EIP-8004 agent.
     * @param agentId The identity token id.
     * @param agentURI The initial agent URI, if any.
     * @param owner The owner of the identity token.
     */
    event Registered(uint256 indexed agentId, string agentURI, address indexed owner);

    /**
     * @notice Emits when the agent URI is updated.
     * @param agentId The identity token id.
     * @param newURI The new agent URI.
     * @param updatedBy The caller which updated the URI.
     */
    event URIUpdated(uint256 indexed agentId, string newURI, address indexed updatedBy);

    /**
     * @notice Emits when on-chain metadata is updated.
     * @param agentId The identity token id.
     * @param indexedMetadataKey The indexed metadata key.
     * @param metadataKey The plain text metadata key.
     * @param metadataValue The raw metadata value.
     */
    event MetadataSet(
        uint256 indexed agentId,
        string indexed indexedMetadataKey,
        string metadataKey,
        bytes metadataValue
    );

    /**
     * @notice Mints a new position NFT to the specified address.
     * @param to The recipient address for the new position.
     * @return tokenId The unique token ID minted.
     */
    function mint(address to) external returns (uint256);

    /**
     * @notice Burns the NFT with the specified token ID.
     * @param tokenId The ID of the token to burn.
     */
    function burn(uint256 tokenId) external;

    /**
     * @notice Returns the address of the AlchemistV3 contract which is allowed to mint and burn tokens.
     */
    function alchemist() external view returns (address);

    /**
     * @notice Returns the address of the admin allowed to update the metadata renderer.
     */
    function admin() external view returns (address);

    /**
     * @notice Returns the address of the current metadata renderer contract.
     */
    function metadataRenderer() external view returns (address);

    /**
     * @notice Returns the address of the metadata manager used by the NFT contract.
     */
    function agentMetadataManager() external view returns (address);

    /**
     * @notice Sets or updates the metadata renderer contract. Only callable by the admin.
     * @param renderer The address of the new metadata renderer.
     */
    function setMetadataRenderer(address renderer) external;

    /**
     * @notice Transfers admin rights to a new address. Only callable by the current admin.
     * @param newAdmin The address of the new admin.
     */
    function setAdmin(address newAdmin) external;

    /**
     * @notice Returns the current agent URI for a token.
     * @param tokenId The token id.
     */
    function getAgentURI(uint256 tokenId) external view returns (string memory);

    /**
     * @notice Updates the agent URI for a token.
     * @param tokenId The token id.
     * @param newURI The new agent URI.
     */
    function setAgentURI(uint256 tokenId, string calldata newURI) external;

    /**
     * @notice Returns arbitrary metadata for a token.
     * @param tokenId The token id.
     * @param metadataKey The metadata key.
     */
    function getMetadata(uint256 tokenId, string calldata metadataKey) external view returns (bytes memory);

    /**
     * @notice Updates arbitrary metadata for a token.
     * @param tokenId The token id.
     * @param metadataKey The metadata key.
     * @param metadataValue The raw metadata value.
     */
    function setMetadata(uint256 tokenId, string calldata metadataKey, bytes calldata metadataValue) external;

    /**
     * @notice Returns the verified agent wallet for a token.
     * @param tokenId The token id.
     */
    function getAgentWallet(uint256 tokenId) external view returns (address);

    /**
     * @notice Sets a new verified agent wallet for a token.
     * @param tokenId The token id.
     * @param newWallet The new agent wallet.
     * @param deadline The signature deadline.
     * @param signature The proof-of-control signature from the new wallet.
     */
    function setAgentWallet(uint256 tokenId, address newWallet, uint256 deadline, bytes calldata signature) external;

    /**
     * @notice Clears the verified agent wallet for a token.
     * @param tokenId The token id.
     */
    function unsetAgentWallet(uint256 tokenId) external;

    /**
     * @dev Returns the total amount of tokens stored by the contract.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns a token ID owned by `owner` at a given `index` of its token list.
     * Use along with {balanceOf} to enumerate all of ``owner``'s tokens.
     */
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);

    /**
     * @dev Returns a token ID at a given `index` of all the tokens stored by the contract.
     * Use along with {totalSupply} to enumerate all tokens.
     */
    function tokenByIndex(uint256 index) external view returns (uint256);
}
