// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {FixedPointMath} from "./FixedPointMath.sol";
import {AccountingLogic} from "./AccountingLogic.sol";

library LiquidationLogic {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant FIXED_POINT_SCALAR = 1e18;

    /// @notice Output of a liquidation quote. Amounts are in yield or underlying as indicated.
    /// @param debtToBurn Debt tokens to burn for this liquidation.
    /// @param collateralToSeizeInYield Collateral to seize in yield tokens (0 when isDebtOnly).
    /// @param feeInYield Liquidator fee in yield tokens (0 when isDebtOnly).
    /// @param outsourcedFeeInUnderlying Fee paid from fee vault when debt-only liquidation.
    /// @param isDebtOnly True when no collateral can be seized (debt >= collateral or alchemist below min collateralization).
    struct LiquidationQuote {
        uint256 debtToBurn;
        uint256 collateralToSeizeInYield;
        uint256 feeInYield;
        uint256 outsourcedFeeInUnderlying;
        bool isDebtOnly;
    }

    /// @notice Executable plan for a liquidation. Built from a quote, then applied to state.
    /// @param collateralToSeize Collateral (yield) to seize from account.
    /// @param debtToBurn Debt to burn for this liquidation.
    /// @param feeInYield Liquidator fee in yield tokens.
    /// @param netToTransmuter Collateral (yield) sent to transmuter after fee.
    /// @param doCloseout True if account needs closeout (unbacked debt cleared, collateral/debt reconciled).
    /// @param closeoutCollateralToRemove Collateral removed during closeout.
    /// @param closeoutDebtToBurn Debt burned during closeout.
    /// @param closeoutUnbackedDebtToClear Unbacked debt cleared during closeout.
    /// @param outsourcedFeeInUnderlying Fee in underlying for debt-only liquidation (from fee vault).
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

    /// @notice Indicates the next step after repay earmarked debt.
    /// @dev NONE: no step; REPAYMENT_ONLY: account healthy after repay; FULL_LIQUIDATION: still unhealthy.
    enum LiquidationStep {
        NONE,
        REPAYMENT_ONLY,
        FULL_LIQUIDATION
    }

    /// @dev Computes liquidation amounts in debt/underlying space. Returns gross seize, debt burn, fee, and outsourced fee.
    /// @param collateral Account collateral value in underlying.
    /// @param debt Account debt in debt tokens.
    /// @param targetCollateralization Target ratio for post-liquidation account.
    /// @param alchemistCurrentCollateralization Global alchemist collateralization ratio.
    /// @param alchemistMinimumCollateralization Minimum global ratio below which no collateral is seized.
    /// @param feeBps Liquidator fee in basis points.
    /// @return grossCollateralToSeize Collateral to seize in underlying (before conversion to yield).
    /// @return debtToBurn Debt tokens to burn.
    /// @return fee Liquidator fee in underlying (0 when debt-only).
    /// @return outsourcedFee Fee in debt tokens when debt-only (paid from fee vault).
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

    /// @dev Builds a LiquidationQuote from raw calculateLiquidation outputs and pre-converted yield/underlying values.
    /// @param liquidationAmount Gross collateral to seize in debt tokens (0 when debt-only).
    /// @param debtToBurn Debt tokens to burn.
    /// @param outsourcedFee Fee in debt tokens when debt-only.
    /// @param liquidationAmountInYield Gross seize amount converted to yield tokens.
    /// @param baseFeeInYield Liquidator fee converted to yield tokens.
    /// @param outsourcedFeeInUnderlying Outsourced fee converted to underlying tokens.
    /// @return quote The populated LiquidationQuote.
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
    /// @param requested Requested debt burn from quote.
    /// @param maxByRealized Max burn allowed by realized collateral (e.g. convertYieldToDebt(netToTransmuter)).
    /// @param accountDebt Account's current debt.
    /// @param globalDebt Total protocol debt.
    /// @return Clamped debt burn amount.
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
    /// @param debt Account debt in debt tokens.
    /// @param collateralInDebt Account collateral value converted to debt tokens.
    /// @param lowerBound Collateralization lower bound (e.g. 1.2e18 for 120%).
    /// @return Max fee in debt tokens, or type(uint256).max when debt == 0.
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

    /// @dev Computes repayment fee for earmarked debt repayment.
    /// @param repaidAmountInYield Amount repaid in yield tokens.
    /// @param feeBps Fee in basis points.
    /// @return Fee in yield tokens.
    function calculateRepaymentFee(uint256 repaidAmountInYield, uint256 feeBps) internal pure returns (uint256) {
        return repaidAmountInYield * feeBps / BPS;
    }

    /// @dev Decides whether a repayment fee should come from account collateral (yield) or the fee vault (underlying).
    ///      All-or-nothing: if the account can't safely cover the full fee, switch entirely to underlying.
    /// @param targetFeeInYield Target fee to pay in yield tokens.
    /// @param maxSafeFeeInYield Max fee that can be taken from collateral without violating health.
    /// @return useYield True if fee should be taken from collateral, false if from fee vault.
    function shouldPayRepaymentFeeInYield(
        uint256 targetFeeInYield,
        uint256 maxSafeFeeInYield
    ) internal pure returns (bool useYield) {
        return targetFeeInYield > 0 && maxSafeFeeInYield >= targetFeeInYield;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev Clamps collateral to available global shares (reconciles local vs global).
    /// @param collateralBalance Account's collateral balance in yield tokens.
    /// @param mytSharesDeposited Total MYT shares deposited in vault.
    /// @return Effective collateral capped by global shares.
    function clampCollateralToShares(uint256 collateralBalance, uint256 mytSharesDeposited)
        internal
        pure
        returns (uint256)
    {
        return min(collateralBalance, mytSharesDeposited);
    }

    /// @dev Returns true if account is healthy: debt == 0 or collateralization > lowerBound.
    /// @param collateralInUnderlying Collateral value in underlying tokens.
    /// @param debt Debt in debt tokens.
    /// @param lowerBound Collateralization lower bound (e.g. 1.2e18 for 120%).
    /// @return True if healthy, false otherwise.
    function isHealthy(
        uint256 collateralInUnderlying,
        uint256 debt,
        uint256 lowerBound
    ) internal pure returns (bool) {
        if (debt == 0) return true;
        uint256 collateralizationRatio = collateralInUnderlying * FIXED_POINT_SCALAR / debt;
        return collateralizationRatio > lowerBound;
    }

    /// @dev Computes seize amounts from a quote and effective collateral. Caller computes debtToBurn via clampDebtBurn.
    /// @param quote Pre-built LiquidationQuote.
    /// @param effectiveCollateral Collateral available (e.g. clampCollateralToShares result).
    /// @return collateralToSeize Amount to seize from account.
    /// @return feeInYield Liquidator fee in yield tokens.
    /// @return netToTransmuter Collateral sent to transmuter after fee.
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

    /// @dev Computes closeout amounts for unbacked debt. Caller passes collateralInDebt = convertYieldToDebt(effectiveCollateral).
    /// @param effectiveCollateral Collateral remaining in yield tokens.
    /// @param debt Account debt in debt tokens.
    /// @param totalDebt Global total debt.
    /// @param collateralInDebt Effective collateral converted to debt tokens.
    /// @return collateralToRemove Collateral to remove (all effective collateral).
    /// @return debtToBurn Debt that can be backed by collateral.
    /// @return unbackedDebtToClear Debt to clear (unbacked by protocol reserves).
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
