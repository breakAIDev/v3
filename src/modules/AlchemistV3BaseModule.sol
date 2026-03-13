// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../interfaces/IAlchemistV3.sol";
import "./AlchemistV3Storage.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Unauthorized, IllegalArgument, IllegalState} from "../base/Errors.sol";

abstract contract AlchemistV3BaseModule is AlchemistV3Storage {
    /// @dev Hook implemented by the solvency/read-path layer.
    function _isProtocolInBadDebt() internal view virtual returns (bool);

    /// @dev Hook implemented by the solvency/read-path layer.
    function _isUnderCollateralized(uint256 tokenId) internal view virtual returns (bool);

    /// @dev Subtracts the earmarked debt by `amount` for the account owned by `accountId`.
    function _subEarmarkedDebt(uint256 amountInDebtTokens, uint256 accountId) internal returns (uint256) {
        Account storage account = _accounts[accountId];

        uint256 debt = account.debt;
        uint256 earmarkedDebt = account.earmarked;

        uint256 credit = amountInDebtTokens > debt ? debt : amountInDebtTokens;
        uint256 earmarkToRemove = credit > earmarkedDebt ? earmarkedDebt : credit;

        account.earmarked = earmarkedDebt - earmarkToRemove;

        uint256 remove = earmarkToRemove > cumulativeEarmarked ? cumulativeEarmarked : earmarkToRemove;
        cumulativeEarmarked -= remove;

        return earmarkToRemove;
    }

    /// @dev Subtracts collateral from an account, clamped to realized local/global balances.
    function _subCollateralBalance(uint256 amountInYieldTokens, uint256 accountId) internal returns (uint256) {
        Account storage account = _accounts[accountId];
        uint256 collateralBalance = account.collateralBalance;

        if (collateralBalance > _mytSharesDeposited) {
            collateralBalance = _mytSharesDeposited;
            account.collateralBalance = collateralBalance;
        }

        uint256 amountToRemove = amountInYieldTokens > collateralBalance ? collateralBalance : amountInYieldTokens;
        account.collateralBalance = collateralBalance - amountToRemove;
        _mytSharesDeposited -= amountToRemove;
        return amountToRemove;
    }

    /// @dev Subtracts the debt by `amount` for the account owned by `tokenId`.
    function _subDebt(uint256 tokenId, uint256 amount) internal {
        Account storage account = _accounts[tokenId];

        account.debt -= amount;
        totalDebt -= amount;

        if (account.debt == 0) {
            account.earmarked = 0;
            _checkpointAccountState(account);
        }

        if (cumulativeEarmarked > totalDebt) {
            cumulativeEarmarked = totalDebt;
        }
    }

    /// @dev Caps a debt-denominated credit against account debt and global debt.
    function _capDebtCredit(uint256 requested, uint256 accountDebt) internal view returns (uint256) {
        uint256 credit = requested > accountDebt ? accountDebt : requested;
        if (credit > totalDebt) credit = totalDebt;
        return credit;
    }

    /// @dev Returns debt that can be safely cleared against global debt accounting.
    function _clearableDebt(uint256 accountDebt) internal view returns (uint256) {
        return accountDebt > totalDebt ? totalDebt : accountDebt;
    }

    /// @dev Snapshots an account against the current global accounting state.
    function _checkpointAccountState(Account storage account) internal {
        account.lastTotalRedeemedDebt = _totalRedeemedDebt;
        account.lastTotalRedeemedSharesOut = _totalRedeemedSharesOut;
        account.lastAccruedEarmarkWeight = _earmarkWeight;
        account.lastAccruedRedemptionWeight = _redemptionWeight;
        account.lastSurvivalAccumulator = _survivalAccumulator;
    }

    /// @dev Set the mint allowance for `spender` to `amount` for the account owned by `tokenId`.
    function _approveMint(uint256 ownerTokenId, address spender, uint256 amount) internal {
        Account storage account = _accounts[ownerTokenId];
        account.mintAllowances[account.allowancesVersion][spender] = amount;
        emit ApproveMint(ownerTokenId, spender, amount);
    }

    function _resetMintAllowances(uint256 tokenId) internal {
        _accounts[tokenId].allowancesVersion += 1;
        emit MintAllowancesReset(tokenId);
    }

    /// @dev Decrease the mint allowance for `spender` by `amount` for the account owned by `ownerTokenId`.
    function _decreaseMintAllowance(uint256 ownerTokenId, address spender, uint256 amount) internal {
        Account storage account = _accounts[ownerTokenId];
        account.mintAllowances[account.allowancesVersion][spender] -= amount;
    }

    function _requireNonZeroAddress(address account) internal pure {
        _checkArgument(account != address(0));
    }

    function _requirePositiveAmount(uint256 amount) internal pure {
        _checkArgument(amount > 0);
    }

    function _requireDepositsEnabledAndSolvent() internal view {
        _checkState(!depositsPaused);
        _checkState(!_isProtocolInBadDebt());
    }

    function _requireLoansEnabled() internal view {
        _checkState(!loansPaused);
    }

    function _requireTokenOwner(uint256 tokenId, address user) internal view {
        _checkAccountOwnership(IERC721(alchemistPositionNFT).ownerOf(tokenId), user);
    }

    function _requireOwnedAccount(uint256 tokenId, address user) internal view {
        _checkForValidAccountId(tokenId);
        _requireTokenOwner(tokenId, user);
    }

    function _requireMintAllowanceResetAuthorized(uint256 tokenId, address caller) internal view {
        if (caller == address(alchemistPositionNFT)) {
            return;
        }

        address tokenOwner = IERC721(alchemistPositionNFT).ownerOf(tokenId);
        if (caller != tokenOwner) {
            revert Unauthorized();
        }
    }

    function _requireNotMintedThisBlock(uint256 tokenId) internal view {
        if (block.number == _accounts[tokenId].lastMintBlock) revert CannotRepayOnMintBlock();
    }

    /// @dev Checks an expression and reverts with an {IllegalArgument} error if the expression is {false}.
    function _checkArgument(bool expression) internal pure {
        if (!expression) {
            revert IllegalArgument();
        }
    }

    /// @dev Checks if owner == sender and reverts with an {UnauthorizedAccountAccessError} error if false.
    function _checkAccountOwnership(address owner, address user) internal pure {
        if (owner != user) {
            revert UnauthorizedAccountAccessError();
        }
    }

    /// @dev Reverts with {UnknownAccountOwnerIDError} if the token id does not exist.
    function _checkForValidAccountId(uint256 tokenId) internal view {
        if (!_tokenExists(alchemistPositionNFT, tokenId)) {
            revert UnknownAccountOwnerIDError();
        }
    }

    /// @notice Checks whether a token id is linked to an owner. Non-blocking / no reverts.
    function _tokenExists(address nft, uint256 tokenId) internal view returns (bool exists) {
        if (tokenId == 0) {
            return false;
        }
        try IERC721(nft).ownerOf(tokenId) {
            exists = true;
        } catch {
            exists = false;
        }
    }

    /// @dev Checks an expression and reverts with an {IllegalState} error if the expression is {false}.
    function _checkState(bool expression) internal pure {
        if (!expression) {
            revert IllegalState();
        }
    }

    /// @dev Checks that the account owned by `tokenId` is properly collateralized.
    function _validate(uint256 tokenId) internal view {
        if (_isUnderCollateralized(tokenId)) revert Undercollateralized();
    }
}
