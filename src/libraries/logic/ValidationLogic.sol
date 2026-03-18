// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../base/Errors.sol";
import "../../interfaces/IAlchemistV3.sol";
import {IAlchemistV3Position} from "../../interfaces/IAlchemistV3Position.sol";

/// @dev Shared argument, ownership, and state guards for external actions.
library ValidationLogic {
    /// @dev Validates deposit arguments and protocol-wide deposit eligibility.
    function validateDeposit(
        address positionNFT,
        address recipient,
        uint256 tokenId,
        uint256 amount,
        uint256 totalDeposited,
        uint256 depositCap,
        bool depositsPaused,
        bool protocolInBadDebt
    ) internal view {
        if (recipient == address(0) || amount == 0) revert IllegalArgument();
        if (depositsPaused || protocolInBadDebt) revert IllegalState();
        if (totalDeposited + amount > depositCap) revert IllegalState();
        if (tokenId != 0) ensureValidAccount(positionNFT, tokenId);
    }

    /// @dev Validates withdrawal arguments and requires ownership of the target position.
    function validateWithdraw(address positionNFT, address caller, address recipient, uint256 tokenId, uint256 amount)
        internal
        view
    {
        if (recipient == address(0)) revert IllegalArgument();
        ensureValidAccount(positionNFT, tokenId);
        if (amount == 0) revert IllegalArgument();
        requireTokenOwner(positionNFT, tokenId, caller);
    }

    /// @dev Validates direct minting from a position owned by the caller.
    function validateMint(
        address positionNFT,
        address caller,
        address recipient,
        uint256 tokenId,
        uint256 amount,
        bool loansPaused
    ) internal view {
        if (recipient == address(0)) revert IllegalArgument();
        ensureValidAccount(positionNFT, tokenId);
        if (amount == 0) revert IllegalArgument();
        if (loansPaused) revert IllegalState();
        requireTokenOwner(positionNFT, tokenId, caller);
    }

    /// @dev Validates delegated minting where allowance, not ownership, governs access.
    function validateMintFrom(address positionNFT, address recipient, uint256 tokenId, uint256 amount, bool loansPaused)
        internal
        view
    {
        if (recipient == address(0)) revert IllegalArgument();
        ensureValidAccount(positionNFT, tokenId);
        if (amount == 0) revert IllegalArgument();
        if (loansPaused) revert IllegalState();
    }

    /// @dev Validates burn and repay flows and enforces the mint/repay cooldown.
    function validateDebtRepayment(address positionNFT, uint256 tokenId, uint256 amount, uint256 lastMintBlock)
        internal
        view
    {
        if (amount == 0) revert IllegalArgument();
        ensureValidAccount(positionNFT, tokenId);
        if (block.number == lastMintBlock) revert IAlchemistV3Errors.CannotRepayOnMintBlock();
    }

    /// @dev Validates that the target position exists before syncing it.
    function validatePoke(address positionNFT, uint256 tokenId) internal view {
        ensureValidAccount(positionNFT, tokenId);
    }

    /// @dev Validates that the caller can manage mint approvals for the target position.
    function validateApproveMint(address positionNFT, address caller, uint256 tokenId) internal view {
        ensureValidAccount(positionNFT, tokenId);
        requireTokenOwner(positionNFT, tokenId, caller);
    }

    /// @dev Allows the position NFT contract or the owner to clear all mint approvals.
    function validateResetMintAllowances(address positionNFT, address caller, uint256 tokenId) internal view {
        if (caller == positionNFT) return;

        address tokenOwner = IAlchemistV3Position(positionNFT).ownerOf(tokenId);
        if (caller != tokenOwner) revert Unauthorized();
    }

    /// @dev Reverts unless `user` currently owns `tokenId`.
    function requireTokenOwner(address positionNFT, uint256 tokenId, address user) internal view {
        if (IAlchemistV3Position(positionNFT).ownerOf(tokenId) != user) {
            revert IAlchemistV3Errors.UnauthorizedAccountAccessError();
        }
    }

    /// @dev Reverts unless `tokenId` is a minted position.
    function ensureValidAccount(address positionNFT, uint256 tokenId) internal view {
        if (!tokenExists(positionNFT, tokenId)) {
            revert IAlchemistV3Errors.UnknownAccountOwnerIDError();
        }
    }

    /// @dev Best-effort existence check for a position NFT token id.
    function tokenExists(address positionNFT, uint256 tokenId) internal view returns (bool exists) {
        if (tokenId == 0) return false;

        try IAlchemistV3Position(positionNFT).ownerOf(tokenId) {
            // If the call succeeds, the token exists.
            exists = true;
        } catch {
            // If the call fails, then the token does not exist.
            exists = false;
        }
    }
}
