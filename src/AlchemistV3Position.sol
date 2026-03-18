// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IAlchemistV3} from "./interfaces/IAlchemistV3.sol";
import {IAlchemistV3Position} from "./interfaces/IAlchemistV3Position.sol";
import {IAgentMetadataManager} from "./interfaces/IAgentMetadataManager.sol";
import {IMetadataRenderer} from "./interfaces/IMetadataRenderer.sol";
import {AgentMetadataManager} from "./AgentMetadataManager.sol";

/**
 * @title AlchemistV3Position
 * @notice ERC721 position token for AlchemistV3, where only the AlchemistV3 contract
 *         is allowed to mint and burn tokens. Minting returns a unique token id.
 */
contract AlchemistV3Position is ERC721Enumerable, EIP712, IAlchemistV3Position {
    bytes32 public constant SET_AGENT_WALLET_TYPEHASH =
        keccak256("SetAgentWallet(uint256 agentId,address newWallet,uint256 deadline)");

    string private constant _AGENT_WALLET_KEY = "agentWallet";
    bytes32 private constant _AGENT_WALLET_KEY_HASH = keccak256(bytes(_AGENT_WALLET_KEY));

    /// @notice The only address allowed to mint and burn position tokens.
    address public alchemist;

    /// @notice The admin of the NFT contract, allowed to update the metadata renderer.
    address public admin;

    /// @notice Counter used for generating unique token ids.
    uint256 private _currentTokenId;

    /// @notice The external contract that generates tokenURI metadata.
    address public metadataRenderer;

    /// @notice Storage backend for EIP-8004 metadata.
    address public agentMetadataManager;

    /// @notice An error which is used to indicate that the function call failed because the caller is not the alchemist
    error CallerNotAlchemist();

    /// @notice An error which is used to indicate that the function call failed because the caller is not the admin
    error CallerNotAdmin();

    /// @notice An error which is used to indicate that Alchemist set is the zero address
    error AlchemistZeroAddressError();

    /// @notice An error which is used to indicate that address minted to is the zero address
    error MintToZeroAddressError();

    /// @notice An error which is used to indicate that the metadata renderer is not set
    error MetadataRendererNotSet();

    /// @notice An error which is used to indicate that the metadata key is reserved.
    error ReservedMetadataKey();

    /// @notice An error which is used to indicate that a signature is expired.
    error ExpiredSignature();

    /// @notice An error which is used to indicate that the agent wallet is the zero address.
    error AgentWalletZeroAddressError();

    /// @notice An error which is used to indicate that a signature failed verification.
    error InvalidAgentWalletSignature();

    /// @dev Modifier to restrict calls to only the authorized AlchemistV3 contract.
    modifier onlyAlchemist() {
        if (msg.sender != alchemist) {
            revert CallerNotAlchemist();
        }

        _;
    }

    /// @dev Modifier to restrict calls to only the admin.
    modifier onlyAdmin() {
        if (msg.sender != admin) {
            revert CallerNotAdmin();
        }

        _;
    }

    /**
     * @notice Constructor that sets the Alchemist address, admin, and initializes the ERC721 token.
     * @param alchemist_ The address of the Alchemist contract.
     * @param admin_ The address of the admin allowed to update the metadata renderer.
     */
    constructor(address alchemist_, address admin_) ERC721("AlchemistV3Position", "ALCV3") EIP712("AlchemistV3Position", "1") {
        if (alchemist_ == address(0)) {
            revert AlchemistZeroAddressError();
        }
        alchemist = alchemist_;
        admin = admin_;
        agentMetadataManager = address(new AgentMetadataManager(address(this)));
    }

    /// @notice Sets or updates the metadata renderer. Only callable by the admin.
    /// @param renderer The address of the new metadata renderer contract.
    function setMetadataRenderer(address renderer) external onlyAdmin {
        metadataRenderer = renderer;
    }

    /// @notice Transfers admin rights to a new address. Only callable by the current admin.
    /// @param newAdmin The address of the new admin.
    function setAdmin(address newAdmin) external onlyAdmin {
        admin = newAdmin;
    }

    /**
     * @notice Returns the current agent URI for the token.
     * @param tokenId The token id.
     */
    function getAgentURI(uint256 tokenId) public view returns (string memory) {
        ERC721(address(this)).ownerOf(tokenId);
        return IAgentMetadataManager(agentMetadataManager).getAgentURI(tokenId);
    }

    /**
     * @notice Updates the agent URI for the token.
     * @param tokenId The token id.
     * @param newURI The new agent URI.
     */
    function setAgentURI(uint256 tokenId, string calldata newURI) external {
        address owner = ERC721(address(this)).ownerOf(tokenId);
        _checkAuthorized(owner, msg.sender, tokenId);
        IAgentMetadataManager(agentMetadataManager).setAgentURI(tokenId, newURI);
        emit URIUpdated(tokenId, newURI, msg.sender);
    }

    /**
     * @notice Returns arbitrary on-chain metadata for the token.
     * @param tokenId The token id.
     * @param metadataKey The metadata key.
     */
    function getMetadata(uint256 tokenId, string calldata metadataKey) external view returns (bytes memory) {
        ERC721(address(this)).ownerOf(tokenId);
        return IAgentMetadataManager(agentMetadataManager).getMetadata(tokenId, metadataKey);
    }

    /**
     * @notice Updates arbitrary on-chain metadata for the token.
     * @param tokenId The token id.
     * @param metadataKey The metadata key.
     * @param metadataValue The metadata value.
     */
    function setMetadata(uint256 tokenId, string calldata metadataKey, bytes calldata metadataValue) external {
        if (keccak256(bytes(metadataKey)) == _AGENT_WALLET_KEY_HASH) {
            revert ReservedMetadataKey();
        }

        address owner = ERC721(address(this)).ownerOf(tokenId);
        _checkAuthorized(owner, msg.sender, tokenId);
        IAgentMetadataManager(agentMetadataManager).setMetadata(tokenId, metadataKey, metadataValue);
        emit MetadataSet(tokenId, metadataKey, metadataKey, metadataValue);
    }

    /**
     * @notice Returns the currently verified agent wallet for the token.
     * @param tokenId The token id.
     */
    function getAgentWallet(uint256 tokenId) public view returns (address) {
        ERC721(address(this)).ownerOf(tokenId);
        return IAgentMetadataManager(agentMetadataManager).getAgentWallet(tokenId);
    }

    /**
     * @notice Sets the verified agent wallet for the token after wallet proof-of-control.
     * @param tokenId The token id.
     * @param newWallet The new agent wallet.
     * @param deadline The signature deadline.
     * @param signature The signature from the new wallet.
     */
    function setAgentWallet(uint256 tokenId, address newWallet, uint256 deadline, bytes calldata signature) external {
        if (newWallet == address(0)) {
            revert AgentWalletZeroAddressError();
        }
        if (block.timestamp > deadline) {
            revert ExpiredSignature();
        }

        address owner = ERC721(address(this)).ownerOf(tokenId);
        _checkAuthorized(owner, msg.sender, tokenId);

        bytes32 structHash = keccak256(abi.encode(SET_AGENT_WALLET_TYPEHASH, tokenId, newWallet, deadline));
        bytes32 digest = _hashTypedDataV4(structHash);
        if (!SignatureChecker.isValidSignatureNow(newWallet, digest, signature)) {
            revert InvalidAgentWalletSignature();
        }

        IAgentMetadataManager(agentMetadataManager).setAgentWallet(tokenId, newWallet);
        emit MetadataSet(tokenId, _AGENT_WALLET_KEY, _AGENT_WALLET_KEY, abi.encode(newWallet));
    }

    /**
     * @notice Clears the verified agent wallet for the token.
     * @param tokenId The token id.
     */
    function unsetAgentWallet(uint256 tokenId) external {
        address owner = ERC721(address(this)).ownerOf(tokenId);
        _checkAuthorized(owner, msg.sender, tokenId);
        _clearAgentWallet(tokenId);
    }

    /**
     * @notice Mints a new position NFT to `to`.
     * @dev Only callable by the AlchemistV3 contract.
     * @param to The recipient address for the new position.
     * @return tokenId The unique token id minted.
     */
    function mint(address to) external onlyAlchemist returns (uint256) {
        if (to == address(0)) {
            revert MintToZeroAddressError();
        }
        _currentTokenId++;
        uint256 tokenId = _currentTokenId;
        _mint(to, tokenId);
        IAgentMetadataManager(agentMetadataManager).initializeAgent(tokenId, to);
        emit Registered(tokenId, "", to);
        emit MetadataSet(tokenId, _AGENT_WALLET_KEY, _AGENT_WALLET_KEY, abi.encode(to));
        return tokenId;
    }

    function burn(uint256 tokenId) public onlyAlchemist {
        _burn(tokenId);
    }

    /**
     * @notice Returns the token URI with embedded SVG
     * @param tokenId The token ID
     * @return The full token URI with data
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        // revert if the token does not exist
        ERC721(address(this)).ownerOf(tokenId);
        if (metadataRenderer == address(0)) {
            revert MetadataRendererNotSet();
        }
        return IMetadataRenderer(metadataRenderer).tokenURI(tokenId);
    }

    /**
     * @notice Override supportsInterface to resolve inheritance conflicts.
     */
    function totalSupply() public view virtual override(ERC721Enumerable, IAlchemistV3Position) returns (uint256) {
        return super.totalSupply();
    }

    function tokenOfOwnerByIndex(
        address owner,
        uint256 index
    ) public view virtual override(ERC721Enumerable, IAlchemistV3Position) returns (uint256) {
        return super.tokenOfOwnerByIndex(owner, index);
    }

    function tokenByIndex(uint256 index) public view virtual override(ERC721Enumerable, IAlchemistV3Position) returns (uint256) {
        return super.tokenByIndex(index);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC721Enumerable, IERC165) returns (bool) {
        return interfaceId == type(IAlchemistV3Position).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @notice Hook that is called before any token transfer
     */
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);
        // Reset mint allowances before the transfer completes
        if (from != address(0)) {
            // Skip during minting
            IAlchemistV3(alchemist).resetMintAllowances(tokenId);
            _clearAgentWallet(tokenId);
        }
        // Call parent implementation first
        return super._update(to, tokenId, auth);
    }

    function _clearAgentWallet(uint256 tokenId) internal {
        IAgentMetadataManager(agentMetadataManager).clearAgentWallet(tokenId);
        emit MetadataSet(tokenId, _AGENT_WALLET_KEY, _AGENT_WALLET_KEY, abi.encode(address(0)));
    }
}
