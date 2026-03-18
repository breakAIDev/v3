// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../interfaces/IAlchemistV3.sol";
import {IAlchemistV3Position} from "../../interfaces/IAlchemistV3Position.sol";
import "../FixedPointMath.sol";
import "../TokenUtils.sol";
import "../../base/Errors.sol";

/// @dev Collateral deposit and withdrawal helpers for position accounts.
library SupplyLogic {
    /// @dev Deposits MYT shares into an existing position or mints a new one when `tokenId` is zero.
    function deposit(
        mapping(uint256 => Account) storage accounts,
        address positionNFT,
        address myt,
        address payer,
        address recipient,
        uint256 tokenId,
        uint256 amount,
        uint256 totalDeposited
    ) internal returns (uint256 positionId, uint256 newTotalDeposited, bool createdPosition) {
        positionId = tokenId;

        // Only mint a new position if the id is 0.
        if (positionId == 0) {
            positionId = IAlchemistV3Position(positionNFT).mint(recipient);
            createdPosition = true;
        }

        // Pull tokens from the payer after internal position selection has been committed.
        newTotalDeposited = executeDeposit(
            accounts[positionId],
            ExecuteDepositParams({
                myt: myt,
                payer: payer,
                amount: amount,
                totalDeposited: totalDeposited
            })
        );
    }

    /// @dev Withdraws collateral shares from a position and transfers them to `recipient`.
    function withdraw(
        mapping(uint256 => Account) storage accounts,
        address myt,
        address recipient,
        uint256 tokenId,
        uint256 amount,
        uint256 totalDeposited,
        uint256 minimumCollateralization,
        uint256 fixedPointScalar,
        uint256 debtShares
    ) internal returns (uint256 amountRemoved, uint256 newTotalDeposited) {
        // Assure that the collateralization invariant is still held.
        (amountRemoved, newTotalDeposited) = executeWithdraw(
            accounts[tokenId],
            ExecuteWithdrawParams({
                amount: amount,
                totalDeposited: totalDeposited,
                debtShares: debtShares,
                minimumCollateralization: minimumCollateralization,
                fixedPointScalar: fixedPointScalar
            })
        );

        // Transfer the yield tokens to the recipient.
        TokenUtils.safeTransfer(myt, recipient, amountRemoved);
    }

    /// @dev Parameters for the raw collateral deposit helper.
    struct ExecuteDepositParams {
        address myt;
        address payer;
        uint256 amount;
        uint256 totalDeposited;
    }

    /// @dev Parameters for the raw collateral withdrawal helper.
    struct ExecuteWithdrawParams {
        uint256 amount;
        uint256 totalDeposited;
        uint256 debtShares;
        uint256 minimumCollateralization;
        uint256 fixedPointScalar;
    }

    /// @dev Credits collateral to an account and pulls the shares from `payer`.
    function executeDeposit(Account storage account, ExecuteDepositParams memory params)
        internal
        returns (uint256 newTotalDeposited)
    {
        account.collateralBalance += params.amount;
        TokenUtils.safeTransferFrom(params.myt, params.payer, address(this), params.amount);
        return params.totalDeposited + params.amount;
    }

    /// @dev Removes collateral while preserving the position's required locked balance.
    function executeWithdraw(Account storage account, ExecuteWithdrawParams memory params)
        internal
        returns (uint256 amountRemoved, uint256 newTotalDeposited)
    {
        reconcileCollateralBalance(account, params.totalDeposited);

        uint256 lockedCollateral = FixedPointMath.mulDivUp(
            params.debtShares, params.minimumCollateralization, params.fixedPointScalar
        );
        uint256 freeCollateral = account.collateralBalance - lockedCollateral;
        if (freeCollateral < params.amount) revert IllegalArgument();

        return subCollateralBalance(account, params.amount, params.totalDeposited);
    }

    /// @dev Removes up to `amountInYieldTokens` from the account and global deposit total.
    function subCollateralBalance(Account storage account, uint256 amountInYieldTokens, uint256 totalDeposited)
        internal
        returns (uint256 amountRemoved, uint256 newTotalDeposited)
    {
        // Reconcile local collateral against global tracked shares before subtraction.
        // This prevents underflow if rounding or drift made local storage exceed global storage.
        uint256 collateralBalance = account.collateralBalance;

        if (collateralBalance > totalDeposited) {
            collateralBalance = totalDeposited;
            account.collateralBalance = collateralBalance;
        }

        amountRemoved = amountInYieldTokens > collateralBalance ? collateralBalance : amountInYieldTokens;
        account.collateralBalance = collateralBalance - amountRemoved;
        newTotalDeposited = totalDeposited - amountRemoved;
    }

    /// @dev Clamps stale collateral balances to the protocol's tracked total deposits.
    function reconcileCollateralBalance(Account storage account, uint256 totalDeposited) internal {
        if (account.collateralBalance > totalDeposited) {
            account.collateralBalance = totalDeposited;
        }
    }
}

