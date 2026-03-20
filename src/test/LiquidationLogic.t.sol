// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "lib/forge-std/src/Test.sol";
import {LiquidationLogic} from "../libraries/LiquidationLogic.sol";

/// @notice Harness to expose LiquidationLogic internal functions for unit testing.
contract LiquidationLogicHarness {
    function calculateLiquidation(
        uint256 collateral,
        uint256 debt,
        uint256 targetCollateralization,
        uint256 alchemistCurrentCollateralization,
        uint256 alchemistMinimumCollateralization,
        uint256 feeBps
    ) external pure returns (uint256 grossCollateralToSeize, uint256 debtToBurn, uint256 fee, uint256 outsourcedFee) {
        return LiquidationLogic.calculateLiquidation(
            collateral, debt, targetCollateralization,
            alchemistCurrentCollateralization, alchemistMinimumCollateralization,
            feeBps
        );
    }

    function buildQuote(
        uint256 liquidationAmount,
        uint256 debtToBurn,
        uint256 outsourcedFee,
        uint256 liquidationAmountInYield,
        uint256 baseFeeInYield,
        uint256 outsourcedFeeInUnderlying
    ) external pure returns (LiquidationLogic.LiquidationQuote memory) {
        return LiquidationLogic.buildQuote(
            liquidationAmount, debtToBurn, outsourcedFee,
            liquidationAmountInYield, baseFeeInYield, outsourcedFeeInUnderlying
        );
    }

    function clampDebtBurn(
        uint256 requested,
        uint256 maxByRealized,
        uint256 accountDebt,
        uint256 globalDebt
    ) external pure returns (uint256) {
        return LiquidationLogic.clampDebtBurn(requested, maxByRealized, accountDebt, globalDebt);
    }

    function maxRepaymentFeeInDebt(
        uint256 debt,
        uint256 collateralInDebt,
        uint256 lowerBound
    ) external pure returns (uint256) {
        return LiquidationLogic.maxRepaymentFeeInDebt(debt, collateralInDebt, lowerBound);
    }

    function calculateRepaymentFee(uint256 repaidAmountInYield, uint256 feeBps) external pure returns (uint256) {
        return LiquidationLogic.calculateRepaymentFee(repaidAmountInYield, feeBps);
    }

    function shouldPayRepaymentFeeInYield(uint256 targetFeeInYield, uint256 maxSafeFeeInYield)
        external
        pure
        returns (bool)
    {
        return LiquidationLogic.shouldPayRepaymentFeeInYield(targetFeeInYield, maxSafeFeeInYield);
    }

    function isHealthy(
        uint256 collateralInUnderlying,
        uint256 debt,
        uint256 lowerBound
    ) external pure returns (bool) {
        return LiquidationLogic.isHealthy(collateralInUnderlying, debt, lowerBound);
    }

    function computeSeizeAmounts(
        LiquidationLogic.LiquidationQuote memory quote,
        uint256 effectiveCollateral
    ) external pure returns (uint256 collateralToSeize, uint256 feeInYield, uint256 netToTransmuter) {
        return LiquidationLogic.computeSeizeAmounts(quote, effectiveCollateral);
    }

    function clampCollateralToShares(uint256 collateralBalance, uint256 mytSharesDeposited)
        external
        pure
        returns (uint256)
    {
        return LiquidationLogic.clampCollateralToShares(collateralBalance, mytSharesDeposited);
    }

    function computeCloseoutAmounts(
        uint256 effectiveCollateral,
        uint256 debt,
        uint256 totalDebt,
        uint256 collateralInDebt
    ) external pure returns (uint256 collateralToRemove, uint256 debtToBurn, uint256 unbackedDebtToClear) {
        return LiquidationLogic.computeCloseoutAmounts(effectiveCollateral, debt, totalDebt, collateralInDebt);
    }
}

contract LiquidationLogicTest is Test {
    LiquidationLogicHarness public harness;
    uint256 constant FIXED_POINT_SCALAR = 1e18;
    uint256 constant BPS = 10_000;

    function setUp() public {
        harness = new LiquidationLogicHarness();
    }

    // ─── calculateLiquidation ─────────────────────────────────────────────────────

    function test_calculateLiquidation_DebtExceedsCollateral() public {
        (
            uint256 grossCollateralToSeize,
            uint256 debtToBurn,
            uint256 fee,
            uint256 outsourcedFee
        ) = harness.calculateLiquidation(
            100e18, 150e18, 1.2e18, 1.5e18, 1.1e18, 300
        );
        // debt >= collateral: full seizure, outsourced fee
        assertEq(grossCollateralToSeize, 100e18);
        assertEq(debtToBurn, 150e18);
        assertEq(fee, 0);
        assertEq(outsourcedFee, 150e18 * 300 / BPS);
    }

    function test_calculateLiquidation_AlchemistUndercollateralized() public {
        LiquidationLogicHarness h = new LiquidationLogicHarness();
        (
            uint256 grossCollateralToSeize,
            uint256 debtToBurn,
            uint256 fee,
            uint256 outsourcedFee
        ) = h.calculateLiquidation(
            150e18, 100e18, 1.2e18, 1.0e18, 1.1e18, 300  // alchemist CR < minimum
        );
        assertEq(grossCollateralToSeize, 100e18);
        assertEq(debtToBurn, 100e18);
        assertEq(fee, 0);
        assertEq(outsourcedFee, 100e18 * 300 / BPS);
    }

    function test_calculateLiquidation_HealthyAccount_NoLiquidation() public {
        LiquidationLogicHarness h = new LiquidationLogicHarness();
        // Account healthy: adjCollat >= md, no liquidation
        (
            uint256 grossCollateralToSeize,
            uint256 debtToBurn,
            uint256 fee,
            uint256 outsourcedFee
        ) = h.calculateLiquidation(
            200e18, 100e18, 1.2e18, 1.5e18, 1.1e18, 300
        );
        assertEq(grossCollateralToSeize, 0);
        assertEq(debtToBurn, 0);
        assertEq(fee, 0);
        assertEq(outsourcedFee, 0);
    }

    function test_calculateLiquidation_PartialLiquidation() public {
        LiquidationLogicHarness h = new LiquidationLogicHarness();
        // collateral 120, debt 100, target 1.2 -> md = 120, surplus = 20, fee = 20*0.03 = 0.6
        // adjCollat = 119.4, md > adjCollat, num = 0.6, denom = 0.2, debtToBurn = 3, gross = 3.6
        (
            uint256 grossCollateralToSeize,
            uint256 debtToBurn,
            uint256 fee,
            uint256 outsourcedFee
        ) = h.calculateLiquidation(
            120e18, 100e18, 1.2e18, 1.5e18, 1.1e18, 300
        );
        assertGt(grossCollateralToSeize, 0);
        assertGt(debtToBurn, 0);
        assertGt(fee, 0);
        assertEq(outsourcedFee, 0);
    }

    // ─── clampDebtBurn ────────────────────────────────────────────────────────────

    function test_clampDebtBurn() public {
        LiquidationLogicHarness h = new LiquidationLogicHarness();
        assertEq(h.clampDebtBurn(100, 80, 90, 85), 80);  // min of all
        assertEq(h.clampDebtBurn(50, 100, 90, 85), 50);  // requested is min
        assertEq(h.clampDebtBurn(100, 100, 100, 60), 60);  // global is min
        assertEq(h.clampDebtBurn(100, 100, 70, 100), 70);  // account is min
    }

    // ─── maxRepaymentFeeInDebt ────────────────────────────────────────────────────

    function test_maxRepaymentFeeInDebt_ZeroDebt() public {
        LiquidationLogicHarness h = new LiquidationLogicHarness();
        assertEq(h.maxRepaymentFeeInDebt(0, 100e18, 1.1e18), type(uint256).max);
    }

    function test_maxRepaymentFeeInDebt_CollateralBelowMin() public {
        LiquidationLogicHarness h = new LiquidationLogicHarness();
        // minRequiredPostFee = debt * lowerBound / 1e18 + 1 = 110e18 + 1. collateralInDebt 110e18 <= that -> 0
        assertEq(h.maxRepaymentFeeInDebt(100e18, 110e18, 1.1e18), 0);
    }

    function test_maxRepaymentFeeInDebt_RemovableFee() public {
        LiquidationLogicHarness h = new LiquidationLogicHarness();
        uint256 debt = 100e18;
        uint256 collateralInDebt = 120e18;
        uint256 lowerBound = 1.1e18;
        uint256 result = h.maxRepaymentFeeInDebt(debt, collateralInDebt, lowerBound);
        assertGt(result, 0);
        assertLt(result, collateralInDebt);
    }

    // ─── calculateRepaymentFee ────────────────────────────────────────────────────

    function test_calculateRepaymentFee() public {
        LiquidationLogicHarness h = new LiquidationLogicHarness();
        assertEq(h.calculateRepaymentFee(100e18, 100), 1e18);   // 1%
        assertEq(h.calculateRepaymentFee(100e18, 300), 3e18);  // 3%
        assertEq(h.calculateRepaymentFee(50e18, 200), 1e18);   // 2% of 50
    }

    // ─── shouldPayRepaymentFeeInYield ──────────────────────────────────────────────

    function test_shouldPayRepaymentFeeInYield() public {
        LiquidationLogicHarness h = new LiquidationLogicHarness();
        assertTrue(h.shouldPayRepaymentFeeInYield(10, 10));
        assertTrue(h.shouldPayRepaymentFeeInYield(5, 10));
        assertFalse(h.shouldPayRepaymentFeeInYield(10, 5));
        assertFalse(h.shouldPayRepaymentFeeInYield(0, 10));
    }

    // ─── isHealthy ────────────────────────────────────────────────────────────────

    function test_isHealthy_ZeroDebt() public {
        LiquidationLogicHarness h = new LiquidationLogicHarness();
        assertTrue(h.isHealthy(0, 0, 1.1e18));
        assertTrue(h.isHealthy(100e18, 0, 1.1e18));
    }

    function test_isHealthy_AboveLowerBound() public {
        LiquidationLogicHarness h = new LiquidationLogicHarness();
        // 120/100 = 1.2 > 1.1
        assertTrue(h.isHealthy(120e18, 100e18, 1.1e18));
    }

    function test_isHealthy_BelowLowerBound() public {
        LiquidationLogicHarness h = new LiquidationLogicHarness();
        // 105/100 = 1.05 < 1.1
        assertFalse(h.isHealthy(105e18, 100e18, 1.1e18));
    }

    // ─── computeSeizeAmounts ─────────────────────────────────────────────────────

    function test_computeSeizeAmounts_DebtOnly() public {
        LiquidationLogicHarness h = new LiquidationLogicHarness();
        LiquidationLogic.LiquidationQuote memory quote = LiquidationLogic.LiquidationQuote({
            debtToBurn: 100e18,
            collateralToSeizeInYield: 0,
            feeInYield: 0,
            outsourcedFeeInUnderlying: 10e18,
            isDebtOnly: true
        });
        (uint256 col, uint256 fee, uint256 net) = h.computeSeizeAmounts(quote, 50e18);
        assertEq(col, 0);
        assertEq(fee, 0);
        assertEq(net, 0);
    }

    function test_computeSeizeAmounts_PartialSeize() public {
        LiquidationLogicHarness h = new LiquidationLogicHarness();
        LiquidationLogic.LiquidationQuote memory quote = LiquidationLogic.LiquidationQuote({
            debtToBurn: 100e18,
            collateralToSeizeInYield: 50e18,
            feeInYield: 5e18,
            outsourcedFeeInUnderlying: 0,
            isDebtOnly: false
        });
        (uint256 col, uint256 fee, uint256 net) = h.computeSeizeAmounts(quote, 30e18);  // effective < quote
        assertEq(col, 30e18);
        assertEq(fee, 5e18);
        assertEq(net, 25e18);
    }

    // ─── computeCloseoutAmounts ───────────────────────────────────────────────────

    function test_computeCloseoutAmounts() public {
        LiquidationLogicHarness h = new LiquidationLogicHarness();
        uint256 effectiveCollateral = 50e18;
        uint256 debt = 100e18;
        uint256 totalDebt = 200e18;
        uint256 collateralInDebt = 50e18;
        (uint256 colRemove, uint256 debtBurn, uint256 unbacked) = h.computeCloseoutAmounts(
            effectiveCollateral, debt, totalDebt, collateralInDebt
        );
        assertEq(colRemove, 50e18);
        assertEq(debtBurn, 50e18);  // capDebtCredit(50, 100, 200) = 50
        assertEq(unbacked, 50e18);  // remaining 50, totalAfter 150, clearable = 50
    }

    function test_clampCollateralToShares() public {
        LiquidationLogicHarness h = new LiquidationLogicHarness();
        assertEq(h.clampCollateralToShares(100, 150), 100);
        assertEq(h.clampCollateralToShares(150, 100), 100);
        assertEq(h.clampCollateralToShares(50, 50), 50);
    }

    function test_computeCloseoutAmounts_NoRemainingDebt() public {
        LiquidationLogicHarness h = new LiquidationLogicHarness();
        (uint256 colRemove, uint256 debtBurn, uint256 unbacked) = h.computeCloseoutAmounts(
            100e18, 100e18, 200e18, 100e18
        );
        assertEq(colRemove, 100e18);
        assertEq(debtBurn, 100e18);
        assertEq(unbacked, 0);
    }
}
