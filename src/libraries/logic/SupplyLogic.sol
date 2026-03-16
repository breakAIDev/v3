// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../interfaces/IAlchemistV3.sol";
import {IAlchemistV3Position} from "../../interfaces/IAlchemistV3Position.sol";
import "../FixedPointMath.sol";
import "../TokenUtils.sol";
import "../../base/Errors.sol";

library SupplyLogic {
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
        if (positionId == 0) {
            positionId = IAlchemistV3Position(positionNFT).mint(recipient);
            createdPosition = true;
        }

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

        TokenUtils.safeTransfer(myt, recipient, amountRemoved);
    }
    struct ExecuteDepositParams {
        address myt;
        address payer;
        uint256 amount;
        uint256 totalDeposited;
    }

    struct ExecuteWithdrawParams {
        uint256 amount;
        uint256 totalDeposited;
        uint256 debtShares;
        uint256 minimumCollateralization;
        uint256 fixedPointScalar;
    }

    function executeDeposit(Account storage account, ExecuteDepositParams memory params)
        internal
        returns (uint256 newTotalDeposited)
    {
        account.collateralBalance += params.amount;
        TokenUtils.safeTransferFrom(params.myt, params.payer, address(this), params.amount);
        return params.totalDeposited + params.amount;
    }

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

    function subCollateralBalance(Account storage account, uint256 amountInYieldTokens, uint256 totalDeposited)
        internal
        returns (uint256 amountRemoved, uint256 newTotalDeposited)
    {
        uint256 collateralBalance = account.collateralBalance;

        if (collateralBalance > totalDeposited) {
            collateralBalance = totalDeposited;
            account.collateralBalance = collateralBalance;
        }

        amountRemoved = amountInYieldTokens > collateralBalance ? collateralBalance : amountInYieldTokens;
        account.collateralBalance = collateralBalance - amountRemoved;
        newTotalDeposited = totalDeposited - amountRemoved;
    }

    function reconcileCollateralBalance(Account storage account, uint256 totalDeposited) internal {
        if (account.collateralBalance > totalDeposited) {
            account.collateralBalance = totalDeposited;
        }
    }
}

