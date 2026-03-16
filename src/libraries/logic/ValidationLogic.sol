// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../base/Errors.sol";
import "../../interfaces/IAlchemistV3.sol";
import {IAlchemistV3Position} from "../../interfaces/IAlchemistV3Position.sol";

library ValidationLogic {
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

    function validateWithdraw(address positionNFT, address caller, address recipient, uint256 tokenId, uint256 amount)
        internal
        view
    {
        if (recipient == address(0)) revert IllegalArgument();
        ensureValidAccount(positionNFT, tokenId);
        if (amount == 0) revert IllegalArgument();
        requireTokenOwner(positionNFT, tokenId, caller);
    }

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

    function validateMintFrom(address positionNFT, address recipient, uint256 tokenId, uint256 amount, bool loansPaused)
        internal
        view
    {
        if (recipient == address(0)) revert IllegalArgument();
        ensureValidAccount(positionNFT, tokenId);
        if (amount == 0) revert IllegalArgument();
        if (loansPaused) revert IllegalState();
    }

    function validateDebtRepayment(address positionNFT, uint256 tokenId, uint256 amount, uint256 lastMintBlock)
        internal
        view
    {
        if (amount == 0) revert IllegalArgument();
        ensureValidAccount(positionNFT, tokenId);
        if (block.number == lastMintBlock) revert IAlchemistV3Errors.CannotRepayOnMintBlock();
    }

    function validatePoke(address positionNFT, uint256 tokenId) internal view {
        ensureValidAccount(positionNFT, tokenId);
    }

    function validateApproveMint(address positionNFT, address caller, uint256 tokenId) internal view {
        ensureValidAccount(positionNFT, tokenId);
        requireTokenOwner(positionNFT, tokenId, caller);
    }

    function validateResetMintAllowances(address positionNFT, address caller, uint256 tokenId) internal view {
        if (caller == positionNFT) return;

        address tokenOwner = IAlchemistV3Position(positionNFT).ownerOf(tokenId);
        if (caller != tokenOwner) revert Unauthorized();
    }

    function requireTokenOwner(address positionNFT, uint256 tokenId, address user) internal view {
        if (IAlchemistV3Position(positionNFT).ownerOf(tokenId) != user) {
            revert IAlchemistV3Errors.UnauthorizedAccountAccessError();
        }
    }

    function ensureValidAccount(address positionNFT, uint256 tokenId) internal view {
        if (!tokenExists(positionNFT, tokenId)) {
            revert IAlchemistV3Errors.UnknownAccountOwnerIDError();
        }
    }

    function tokenExists(address positionNFT, uint256 tokenId) internal view returns (bool exists) {
        if (tokenId == 0) return false;

        try IAlchemistV3Position(positionNFT).ownerOf(tokenId) {
            exists = true;
        } catch {
            exists = false;
        }
    }
}
