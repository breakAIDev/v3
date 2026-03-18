// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IAgentMetadataManager
 * @notice Storage backend for EIP-8004 metadata attached to AlchemistV3Position NFTs.
 */
interface IAgentMetadataManager {
    function initializeAgent(uint256 tokenId, address initialAgentWallet) external;

    function setAgentURI(uint256 tokenId, string calldata agentURI) external;

    function getAgentURI(uint256 tokenId) external view returns (string memory);

    function setMetadata(uint256 tokenId, string calldata metadataKey, bytes calldata metadataValue) external;

    function getMetadata(uint256 tokenId, string calldata metadataKey) external view returns (bytes memory);

    function setAgentWallet(uint256 tokenId, address agentWallet) external;

    function getAgentWallet(uint256 tokenId) external view returns (address);

    function clearAgentWallet(uint256 tokenId) external;
}
