// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {FixedPointMath} from "./FixedPointMath.sol";
import {AccountingLogic} from "./AccountingLogic.sol";

library LiquidationLogic {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant FIXED_POINT_SCALAR = 1e18;

    struct LiquidationQuote {
        uint256 debtToBurn;
        uint256 collateralToSeizeInYield;
        uint256 feeInYield;
        uint256 outsourcedFeeInUnderlying;
        bool isDebtOnly;
    }

    struct LiquidationPlan {
        uint256 collateralToSeize;
        uint256 debtToBurn;
        uint256 feeInYield;
        uint256 netToTransmuter;
        bool doCloseout;
        uint256 closeoutCollateralToRemove;
        uint256 closeoutDebtToBurn;
        uint256 closeoutUnbackedDebtToClear;
        uint256 outsourcedFeeInUnderlying;
    }

    enum LiquidationStep {
        NONE,
        REPAYMENT_ONLY,
        FULL_LIQUIDATION
    }

    function calculateLiquidation(
        uint256 collateral,
        uint256 debt,
        uint256 targetCollateralization,
        uint256 alchemistCurrentCollateralization,
        uint256 alchemistMinimumCollateralization,
        uint256 feeBps
    ) internal pure returns (uint256 grossCollateralToSeize, uint256 debtToBurn, uint256 fee, uint256 outsourcedFee) {
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

    /// @dev Builds a quote from raw calculateLiquidation outputs and pre-converted yield/underlying values.
    function buildQuote(
        uint256 liquidationAmount,
        uint256 debtToBurn,
        uint256 outsourcedFee,
        uint256 liquidationAmountInYield,
        uint256 baseFeeInYield,
        uint256 outsourcedFeeInUnderlying
    ) internal pure returns (LiquidationQuote memory quote) {
        quote.debtToBurn = debtToBurn;
        quote.isDebtOnly = liquidationAmount == 0;

        if (!quote.isDebtOnly) {
            quote.collateralToSeizeInYield = liquidationAmountInYield;
            quote.feeInYield = baseFeeInYield;
        }

        if (outsourcedFee > 0) {
            quote.outsourcedFeeInUnderlying = outsourcedFeeInUnderlying;
        }
    }

    /// @dev Clamps debt burn against realized collateral value and current debt accounting.
    function clampDebtBurn(
        uint256 requested,
        uint256 maxByRealized,
        uint256 accountDebt,
        uint256 globalDebt
    ) internal pure returns (uint256) {
        return min(requested, min(maxByRealized, min(accountDebt, globalDebt)));
    }

    /// @dev Returns the max fee (in debt denomination) removable from collateral while keeping
    ///      the account strictly healthy (collateralization ratio > lowerBound).
    ///      Returns type(uint256).max when debt == 0 to signal "no cap" (caller uses collateralBalance).
    function maxRepaymentFeeInDebt(
        uint256 debt,
        uint256 collateralInDebt,
        uint256 lowerBound
    ) internal pure returns (uint256) {
        if (debt == 0) return type(uint256).max;

        uint256 minimumByLowerBound = FixedPointMath.mulDivUp(debt, lowerBound, FIXED_POINT_SCALAR);
        if (minimumByLowerBound == type(uint256).max) return 0;

        uint256 minRequiredPostFee = minimumByLowerBound + 1;
        if (collateralInDebt <= minRequiredPostFee) return 0;

        return collateralInDebt - minRequiredPostFee;
    }

    function calculateRepaymentFee(uint256 repaidAmountInYield, uint256 feeBps) internal pure returns (uint256) {
        return repaidAmountInYield * feeBps / BPS;
    }

    /// @dev Decides whether a repayment fee should come from account collateral (yield) or the fee vault (underlying).
    ///      All-or-nothing: if the account can't safely cover the full fee, switch entirely to underlying.
    /// @return useYield  True if fee should be taken from collateral, false if from fee vault.
    function shouldPayRepaymentFeeInYield(
        uint256 targetFeeInYield,
        uint256 maxSafeFeeInYield
    ) internal pure returns (bool useYield) {
        return targetFeeInYield > 0 && maxSafeFeeInYield >= targetFeeInYield;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev Returns true if account is healthy: debt == 0 or collateralization > lowerBound.
    function isHealthy(
        uint256 collateralInUnderlying,
        uint256 debt,
        uint256 lowerBound
    ) internal pure returns (bool) {
        if (debt == 0) return true;
        uint256 collateralizationRatio = collateralInUnderlying * FIXED_POINT_SCALAR / debt;
        return collateralizationRatio > lowerBound;
    }

    /// @dev Computes seize amounts. Caller computes debtToBurn via clampDebtBurn(quote.debtToBurn, convertYieldToDebt(netToTransmuter), accountDebt, totalDebt).
    function computeSeizeAmounts(
        LiquidationQuote memory quote,
        uint256 effectiveCollateral
    ) internal pure returns (uint256 collateralToSeize, uint256 feeInYield, uint256 netToTransmuter) {
        if (quote.isDebtOnly) return (0, 0, 0);

        collateralToSeize = min(quote.collateralToSeizeInYield, effectiveCollateral);
        if (collateralToSeize == 0) return (0, 0, 0);

        feeInYield = min(quote.feeInYield, collateralToSeize);
        netToTransmuter = collateralToSeize - feeInYield;
    }

    /// @dev Computes closeout amounts. Caller passes collateralInDebt = convertYieldToDebt(effectiveCollateral).
    function computeCloseoutAmounts(
        uint256 effectiveCollateral,
        uint256 debt,
        uint256 totalDebt,
        uint256 collateralInDebt
    ) internal pure returns (uint256 collateralToRemove, uint256 debtToBurn, uint256 unbackedDebtToClear) {
        collateralToRemove = effectiveCollateral;
        debtToBurn = AccountingLogic.capDebtCredit(collateralInDebt, debt, totalDebt);
        uint256 remainingDebt = debt - debtToBurn;
        uint256 totalDebtAfterBurn = totalDebt - debtToBurn;
        unbackedDebtToClear = remainingDebt > 0 ? AccountingLogic.clearableDebt(remainingDebt, totalDebtAfterBurn) : 0;
    }
}
