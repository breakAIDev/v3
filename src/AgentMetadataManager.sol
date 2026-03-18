// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAgentMetadataManager} from "./interfaces/IAgentMetadataManager.sol";

/**
 * @title AgentMetadataManager
 * @notice Stores EIP-8004 metadata for AlchemistV3Position NFTs.
 */
contract AgentMetadataManager is IAgentMetadataManager {
    /// @notice The only contract allowed to mutate metadata.
    address public immutable position;

    mapping(uint256 => string) private _agentURIs;
    mapping(uint256 => mapping(bytes32 => bytes)) private _metadata;
    mapping(uint256 => address) private _agentWallets;

    error CallerNotPosition();

    modifier onlyPosition() {
        if (msg.sender != position) {
            revert CallerNotPosition();
        }

        _;
    }

    constructor(address position_) {
        position = position_;
    }

    function initializeAgent(uint256 tokenId, address initialAgentWallet) external onlyPosition {
        _agentWallets[tokenId] = initialAgentWallet;
    }

    function setAgentURI(uint256 tokenId, string calldata agentURI) external onlyPosition {
        _agentURIs[tokenId] = agentURI;
    }

    function getAgentURI(uint256 tokenId) external view returns (string memory) {
        return _agentURIs[tokenId];
    }

    function setMetadata(uint256 tokenId, string calldata metadataKey, bytes calldata metadataValue) external onlyPosition {
        _metadata[tokenId][_metadataKeyHash(metadataKey)] = metadataValue;
    }

    function getMetadata(uint256 tokenId, string calldata metadataKey) external view returns (bytes memory) {
        return _metadata[tokenId][_metadataKeyHash(metadataKey)];
    }

    function setAgentWallet(uint256 tokenId, address agentWallet) external onlyPosition {
        _agentWallets[tokenId] = agentWallet;
    }

    function getAgentWallet(uint256 tokenId) external view returns (address) {
        return _agentWallets[tokenId];
    }

    function clearAgentWallet(uint256 tokenId) external onlyPosition {
        delete _agentWallets[tokenId];
    }

    function _metadataKeyHash(string calldata metadataKey) private pure returns (bytes32) {
        return keccak256(bytes(metadataKey));
    }
}
