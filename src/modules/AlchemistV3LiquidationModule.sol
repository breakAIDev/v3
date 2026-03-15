// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../interfaces/IAlchemistV3.sol";
import "./AlchemistV3EarmarkModule.sol";
import {MissingInputData} from "../base/Errors.sol";
import {IFeeVault} from "../interfaces/IFeeVault.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {IVaultV2} from "../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";

abstract contract AlchemistV3LiquidationModule is AlchemistV3EarmarkModule {
    function _forceRepay(uint256 accountId, uint256 amount, bool skipPoke) internal virtual returns (uint256);

    /// @inheritdoc IAlchemistV3Actions
    function liquidate(uint256 accountId) external virtual override returns (uint256 yieldAmount, uint256 feeInYield, uint256 feeInUnderlying) {
        _checkForValidAccountId(accountId);
        bool progressed;
        (yieldAmount, feeInYield, feeInUnderlying, progressed) = _executeLiquidation(accountId);
        if (!progressed) revert LiquidationError();
        return (yieldAmount, feeInYield, feeInUnderlying);
    }

    /// @inheritdoc IAlchemistV3Actions
    function batchLiquidate(uint256[] memory accountIds)
        external
        virtual
        returns (uint256 totalAmountLiquidated, uint256 totalFeesInYield, uint256 totalFeesInUnderlying)
    {
        if (accountIds.length == 0) {
            revert MissingInputData();
        }

        bool anyProgress = false;
        for (uint256 i = 0; i < accountIds.length; i++) {
            uint256 accountId = accountIds[i];
            if (accountId == 0 || !_tokenExists(alchemistPositionNFT, accountId)) {
                continue;
            }
            uint256 underlyingAmount;
            uint256 feeInYield;
            uint256 feeInUnderlying;
            bool progressed;
            (underlyingAmount, feeInYield, feeInUnderlying, progressed) = _executeLiquidation(accountId);
            totalAmountLiquidated += underlyingAmount;
            totalFeesInYield += feeInYield;
            totalFeesInUnderlying += feeInUnderlying;
            if (progressed) anyProgress = true;
        }

        if (anyProgress) {
            return (totalAmountLiquidated, totalFeesInYield, totalFeesInUnderlying);
        } else {
            revert LiquidationError();
        }
    }

    /// @inheritdoc IAlchemistV3Actions
    function selfLiquidate(uint256 accountId, address recipient) public virtual returns (uint256 amountLiquidated) {
        _requireNonZeroAddress(recipient);
        _checkForValidAccountId(accountId);
        _requireTokenOwner(accountId, msg.sender);
        _poke(accountId);
        _checkState(_accounts[accountId].debt > 0);
        if (!_isAccountHealthy(accountId, false)) {
            revert AccountNotHealthy();
        }
        Account storage account = _accounts[accountId];

        uint256 repaidEarmarkedDebtInYield = _forceRepay(accountId, account.earmarked, true);

        uint256 debt = account.debt;
        _subDebt(accountId, debt);

        uint256 repaidDebtInYield = _subCollateralBalance(convertDebtTokensToYield(debt), accountId);
        uint256 remainingCollateral = _subCollateralBalance(account.collateralBalance, accountId);

        if (repaidDebtInYield > 0) {
            TokenUtils.safeTransfer(myt, transmuter, repaidDebtInYield);
        }

        if (remainingCollateral > 0) {
            TokenUtils.safeTransfer(myt, recipient, remainingCollateral);
        }

        emit SelfLiquidated(accountId, repaidEarmarkedDebtInYield + repaidDebtInYield);
        return repaidEarmarkedDebtInYield + repaidDebtInYield;
    }

    /// @inheritdoc IAlchemistV3State
    function calculateLiquidation(
        uint256 collateral,
        uint256 debt,
        uint256 targetCollateralization,
        uint256 alchemistCurrentCollateralization,
        uint256 alchemistMinimumCollateralization,
        uint256 feeBps
    ) public pure virtual returns (uint256 grossCollateralToSeize, uint256 debtToBurn, uint256 fee, uint256 outsourcedFee) {
        if (debt >= collateral) {
            outsourcedFee = (debt * feeBps) / BPS;
            return (collateral, debt, 0, outsourcedFee);
        }

        if (alchemistCurrentCollateralization < alchemistMinimumCollateralization) {
            outsourcedFee = (debt * feeBps) / BPS;
            return (debt, debt, 0, outsourcedFee);
        }

        uint256 surplus = collateral - debt;
        fee = (surplus * feeBps) / BPS;

        uint256 adjCollat = collateral - fee;
        uint256 md = (targetCollateralization * debt) / FIXED_POINT_SCALAR;
        if (md <= adjCollat) {
            return (0, 0, 0, 0);
        }

        uint256 num = md - adjCollat;
        uint256 denom = targetCollateralization - FIXED_POINT_SCALAR;

        debtToBurn = (num * FIXED_POINT_SCALAR) / denom;
        grossCollateralToSeize = debtToBurn + fee;
    }

    /// @dev Fetches and applies the liquidation amount to account `tokenId` if the account collateral ratio touches `collateralizationLowerBound`.
    /// @dev Repays earmarked debt if it exists.
    function _liquidate(uint256 accountId) internal returns (uint256 amountLiquidated, uint256 feeInYield, uint256 feeInUnderlying) {
        _earmark();
        _sync(accountId);

        Account storage account = _accounts[accountId];

        if (IVaultV2(myt).convertToAssets(1e18) == 0) {
            return (0, 0, 0);
        }

        if (_isAccountHealthy(accountId, false)) {
            return (0, 0, 0);
        }

        uint256 repaidAmountInYield = 0;
        if (account.earmarked > 0) {
            repaidAmountInYield = _forceRepay(accountId, account.earmarked, false);
            feeInYield = _calculateRepaymentFee(repaidAmountInYield);
            if (account.collateralBalance == 0 && account.debt > 0) {
                uint256 debtToClear = _clearableDebt(account.debt);
                if (debtToClear > 0) {
                    _subDebt(accountId, debtToClear);
                }
            }
        }

        if (_isAccountHealthy(accountId, false)) {
            if (feeInYield > 0) {
                uint256 targetFeeInYield = feeInYield;
                uint256 maxSafeFeeInYield = _maxRepaymentFeeInYield(accountId);
                if (maxSafeFeeInYield < targetFeeInYield) {
                    feeInYield = 0;
                    feeInUnderlying = convertYieldTokensToUnderlying(targetFeeInYield);
                }
            }

            if (feeInYield > 0) {
                feeInYield = _subCollateralBalance(feeInYield, accountId);
                TokenUtils.safeTransfer(myt, msg.sender, feeInYield);
            } else if (feeInUnderlying > 0) {
                feeInUnderlying = _payWithFeeVault(feeInUnderlying);
            }
            emit RepaymentFee(accountId, msg.sender, feeInYield, feeInUnderlying);
            return (repaidAmountInYield, feeInYield, feeInUnderlying);
        } else {
            return _doLiquidation(accountId);
        }
    }

    /// @dev Pays the fee to msg.sender in underlying tokens using the fee vault.
    function _payWithFeeVault(uint256 amountInUnderlying) internal returns (uint256) {
        if (amountInUnderlying == 0) return 0;
        if (alchemistFeeVault == address(0)) {
            emit FeeShortfall(msg.sender, amountInUnderlying, 0);
            return 0;
        }
        uint256 vaultBalance = IFeeVault(alchemistFeeVault).totalDeposits();
        if (vaultBalance > 0) {
            uint256 adjustedAmount = amountInUnderlying > vaultBalance ? vaultBalance : amountInUnderlying;
            IFeeVault(alchemistFeeVault).withdraw(msg.sender, adjustedAmount);
            if (adjustedAmount < amountInUnderlying) {
                emit FeeShortfall(msg.sender, amountInUnderlying, adjustedAmount);
            }
            return adjustedAmount;
        }
        emit FeeShortfall(msg.sender, amountInUnderlying, 0);
        return 0;
    }

    /// @dev Performs the actual liquidation logic when collateralization is below the lower bound.
    function _doLiquidation(uint256 accountId)
        internal
        returns (uint256 amountLiquidated, uint256 feeInYield, uint256 feeInUnderlying)
    {
        Account storage account = _accounts[accountId];
        uint256 debt = account.debt;
        uint256 collateralInUnderlying = totalValue(accountId);
        (uint256 liquidationAmount, uint256 debtToBurn, uint256 baseFee, uint256 outsourcedFee) = calculateLiquidation(
            collateralInUnderlying,
            debt,
            liquidationTargetCollateralization,
            _globalCollateralization(),
            globalMinimumCollateralization,
            liquidatorFee
        );

        if (liquidationAmount == 0) {
            if (debtToBurn > 0) {
                uint256 burnableDebt = _capDebtCredit(debtToBurn, account.debt);
                if (burnableDebt > 0) {
                    _subDebt(accountId, burnableDebt);
                }
            }

            uint256 feeRequestInUnderlying = normalizeDebtTokensToUnderlying(outsourcedFee);
            if (feeRequestInUnderlying > 0) {
                feeInUnderlying = _payWithFeeVault(feeRequestInUnderlying);
            }

            if (account.debt < debt || feeInUnderlying > 0) {
                emit Liquidated(accountId, msg.sender, 0, 0, feeInUnderlying);
                return (0, 0, feeInUnderlying);
            }

            return (0, 0, 0);
        }

        uint256 requestedLiquidationInYield = convertDebtTokensToYield(liquidationAmount);
        amountLiquidated = _subCollateralBalance(requestedLiquidationInYield, accountId);
        if (amountLiquidated == 0) return (0, 0, 0);

        uint256 requestedFeeInYield = convertDebtTokensToYield(baseFee);
        feeInYield = requestedFeeInYield > amountLiquidated ? amountLiquidated : requestedFeeInYield;

        uint256 netToTransmuter = amountLiquidated - feeInYield;
        uint256 maxDebtByRealized = convertYieldTokensToDebt(netToTransmuter);
        uint256 maxDebtByStorage = account.debt < totalDebt ? account.debt : totalDebt;

        if (debtToBurn > maxDebtByRealized) debtToBurn = maxDebtByRealized;
        if (debtToBurn > maxDebtByStorage) debtToBurn = maxDebtByStorage;

        if (debtToBurn > 0) {
            _subDebt(accountId, debtToBurn);
        }

        if (account.debt > 0 && !_isAccountHealthy(accountId, false)) {
            uint256 remainingShares = account.collateralBalance;
            if (remainingShares > 0) {
                uint256 removedShares = _subCollateralBalance(remainingShares, accountId);
                netToTransmuter += removedShares;

                uint256 extraDebtBurn = _capDebtCredit(convertYieldTokensToDebt(removedShares), account.debt);
                if (extraDebtBurn > 0) {
                    _subDebt(accountId, extraDebtBurn);
                }
            }

            if (account.collateralBalance == 0 && account.debt > 0) {
                uint256 debtToClear = _clearableDebt(account.debt);
                if (debtToClear > 0) {
                    _subDebt(accountId, debtToClear);
                }
            }
        }

        TokenUtils.safeTransfer(myt, transmuter, netToTransmuter);

        if (feeInYield > 0) {
            TokenUtils.safeTransfer(myt, msg.sender, feeInYield);
        } else if (normalizeDebtTokensToUnderlying(outsourcedFee) > 0) {
            feeInUnderlying = _payWithFeeVault(normalizeDebtTokensToUnderlying(outsourcedFee));
        }
        emit Liquidated(accountId, msg.sender, amountLiquidated, feeInYield, feeInUnderlying);
        return (amountLiquidated, feeInYield, feeInUnderlying);
    }

    /// @dev Handles repayment fee calculation.
    function _calculateRepaymentFee(uint256 repaidAmountInYield) internal view returns (uint256 feeInYield) {
        return repaidAmountInYield * repaymentFee / BPS;
    }

    /// @dev Returns max yield-fee removable while remaining strictly healthy (> lower bound).
    function _maxRepaymentFeeInYield(uint256 accountId) internal view returns (uint256) {
        Account storage account = _accounts[accountId];
        uint256 debt = account.debt;
        if (debt == 0) {
            return account.collateralBalance;
        }

        uint256 collateralInDebt = convertYieldTokensToDebt(account.collateralBalance);
        uint256 minimumByLowerBound = FixedPointMath.mulDivUp(debt, collateralizationLowerBound, FIXED_POINT_SCALAR);
        if (minimumByLowerBound == type(uint256).max) {
            return 0;
        }

        uint256 minRequiredPostFee = minimumByLowerBound + 1;
        if (collateralInDebt <= minRequiredPostFee) {
            return 0;
        }

        uint256 removableInDebt = collateralInDebt - minRequiredPostFee;
        return convertDebtTokensToYield(removableInDebt);
    }

    function _executeLiquidation(uint256 accountId)
        internal
        returns (uint256 amountLiquidated, uint256 feeInYield, uint256 feeInUnderlying, bool progressed)
    {
        uint256 debtBefore = _accounts[accountId].debt;
        (amountLiquidated, feeInYield, feeInUnderlying) = _liquidate(accountId);
        progressed = _didLiquidationProgress(
            debtBefore, _accounts[accountId].debt, amountLiquidated, feeInYield, feeInUnderlying
        );
    }

    function _didLiquidationProgress(
        uint256 debtBefore,
        uint256 debtAfter,
        uint256 amountLiquidated,
        uint256 feeInYield,
        uint256 feeInUnderlying
    ) internal pure returns (bool) {
        return amountLiquidated > 0 || feeInYield > 0 || feeInUnderlying > 0 || debtAfter < debtBefore;
    }
}
