// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../base/Errors.sol";
import "../../interfaces/IAlchemistV3.sol";
import "../../interfaces/IFeeVault.sol";
import "../../libraries/FixedPointMath.sol";
import "../../libraries/TokenUtils.sol";
import {IVaultV2} from "../../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {ValidationLogic} from "./ValidationLogic.sol";
import {BorrowLogic} from "./BorrowLogic.sol";
import {SupplyLogic} from "./SupplyLogic.sol";
import {SyncLogic} from "./SyncLogic.sol";
import {EarmarkLogic} from "./EarmarkLogic.sol";
import {StateLogic} from "./StateLogic.sol";

library LiquidationLogic {
    struct Runtime {
        address positionNFT;
        address myt;
        address transmuter;
        address protocolFeeReceiver;
        address alchemistFeeVault;
        uint256 totalDebt;
        uint256 totalDeposited;
        uint256 cumulativeEarmarked;
        uint256 totalSyntheticsIssued;
        uint256 totalRedeemedDebt;
        uint256 totalRedeemedSharesOut;
        uint256 lastEarmarkBlock;
        uint256 lastTransmuterTokenBalance;
        uint256 pendingCoverShares;
        uint256 earmarkWeight;
        uint256 redemptionWeight;
        uint256 survivalAccumulator;
        uint256 underlyingConversionFactor;
        uint256 minimumCollateralization;
        uint256 collateralizationLowerBound;
        uint256 globalMinimumCollateralization;
        uint256 liquidationTargetCollateralization;
        uint256 protocolFee;
        uint256 liquidatorFee;
        uint256 repaymentFee;
        uint256 oneQ128;
        uint256 fixedPointScalar;
        uint256 bps;
        uint256 earmarkIndexBits;
        uint256 earmarkIndexMask;
        uint256 redemptionIndexBits;
        uint256 redemptionIndexMask;
    }

    struct LiquidationResult {
        uint256 amountLiquidated;
        uint256 feeInYield;
        uint256 feeInUnderlying;
        bool progressed;
        uint256 totalDebt;
        uint256 totalDeposited;
        uint256 cumulativeEarmarked;
        uint256 lastEarmarkBlock;
        uint256 lastTransmuterTokenBalance;
        uint256 pendingCoverShares;
        uint256 earmarkWeight;
        uint256 survivalAccumulator;
    }
    function calculateLiquidation(
        uint256 collateral,
        uint256 debt,
        uint256 targetCollateralization,
        uint256 alchemistCurrentCollateralization,
        uint256 alchemistMinimumCollateralization,
        uint256 feeBps,
        uint256 bps,
        uint256 fixedPointScalar
    ) public pure returns (uint256 grossCollateralToSeize, uint256 debtToBurn, uint256 fee, uint256 outsourcedFee) {
        if (debt >= collateral) {
            outsourcedFee = (debt * feeBps) / bps;
            return (collateral, debt, 0, outsourcedFee);
        }

        if (alchemistCurrentCollateralization < alchemistMinimumCollateralization) {
            outsourcedFee = (debt * feeBps) / bps;
            return (debt, debt, 0, outsourcedFee);
        }

        uint256 surplus = collateral - debt;
        fee = (surplus * feeBps) / bps;

        uint256 adjCollat = collateral - fee;
        uint256 md = (targetCollateralization * debt) / fixedPointScalar;
        if (md <= adjCollat) {
            return (0, 0, 0, 0);
        }

        uint256 num = md - adjCollat;
        uint256 denom = targetCollateralization - fixedPointScalar;

        debtToBurn = (num * fixedPointScalar) / denom;
        grossCollateralToSeize = debtToBurn + fee;
    }

    function executeLiquidation(
        mapping(uint256 => Account) storage accounts,
        uint256 accountId,
        mapping(uint256 => uint256) storage earmarkEpochStartRedemptionWeight,
        mapping(uint256 => uint256) storage earmarkEpochStartSurvivalAccumulator,
        Runtime memory runtime,
        address liquidator
    ) public returns (LiquidationResult memory result) {
        ValidationLogic.ensureValidAccount(runtime.positionNFT, accountId);
        uint256 debtBefore = accounts[accountId].debt;

        EarmarkLogic.CommitResult memory commit = SyncLogic.commitEarmarkAndSync(
            accounts,
            accountId,
            earmarkEpochStartRedemptionWeight,
            earmarkEpochStartSurvivalAccumulator,
            earmarkState(runtime),
            runtime.totalRedeemedDebt,
            runtime.totalRedeemedSharesOut,
            SyncLogic.CommitAndSyncParams({
                myt: runtime.myt,
                transmuter: runtime.transmuter,
                underlyingConversionFactor: runtime.underlyingConversionFactor,
                totalSyntheticsIssued: runtime.totalSyntheticsIssued,
                totalDeposited: runtime.totalDeposited,
                minimumCollateralization: runtime.minimumCollateralization,
                fixedPointScalar: runtime.fixedPointScalar,
                enforceNoBadDebt: false
            })
        );
        applyCommit(runtime, commit);

        Account storage account = accounts[accountId];
        if (IVaultV2(runtime.myt).convertToAssets(1e18) == 0) {
            return packResult(runtime, 0, 0, 0, false);
        }
        if (isHealthy(runtime, account)) {
            return packResult(runtime, 0, 0, 0, false);
        }

        uint256 repaidAmountInYield;
        uint256 feeInYield;
        uint256 feeInUnderlying;

        if (account.earmarked > 0) {
            (repaidAmountInYield, runtime.totalDebt, runtime.totalDeposited, runtime.cumulativeEarmarked) = forceRepay(
                accounts, accountId, account.earmarked, runtime, liquidator, true
            );
            feeInYield = calculateRepaymentFee(repaidAmountInYield, runtime.repaymentFee, runtime.bps);
            if (account.collateralBalance == 0 && account.debt > 0) {
                uint256 debtToClear = BorrowLogic.clearableDebt(account.debt, runtime.totalDebt);
                if (debtToClear > 0) {
                    (runtime.totalDebt, runtime.cumulativeEarmarked) = BorrowLogic.subDebt(
                        account, debtToClear, runtime.totalDebt, runtime.cumulativeEarmarked, checkpointParams(runtime)
                    );
                }
            }
        }

        if (isHealthy(runtime, account)) {
            if (feeInYield > 0) {
                uint256 targetFeeInYield = feeInYield;
                uint256 maxSafeFeeInYield = maxRepaymentFeeInYield(account, runtime);
                if (maxSafeFeeInYield < targetFeeInYield) {
                    feeInYield = 0;
                    feeInUnderlying = StateLogic.convertYieldTokensToUnderlying(runtime.myt, targetFeeInYield);
                }
            }

            if (feeInYield > 0) {
                (feeInYield, runtime.totalDeposited) =
                    SupplyLogic.subCollateralBalance(account, feeInYield, runtime.totalDeposited);
                TokenUtils.safeTransfer(runtime.myt, liquidator, feeInYield);
            } else if (feeInUnderlying > 0) {
                feeInUnderlying = payWithFeeVault(runtime.alchemistFeeVault, liquidator, feeInUnderlying);
            }
            emit IAlchemistV3Events.RepaymentFee(accountId, liquidator, feeInYield, feeInUnderlying);
            return packResult(runtime, repaidAmountInYield, feeInYield, feeInUnderlying, true);
        }

        (uint256 amountLiquidated, uint256 liquidationFeeInYield, uint256 liquidationFeeInUnderlying) =
            doLiquidation(accounts, accountId, runtime, liquidator);
        return packResult(runtime, amountLiquidated, liquidationFeeInYield, liquidationFeeInUnderlying, didLiquidationProgress(
            debtBefore, accounts[accountId].debt, amountLiquidated, liquidationFeeInYield, liquidationFeeInUnderlying
        ));
    }

    function executeSelfLiquidation(
        mapping(uint256 => Account) storage accounts,
        uint256 accountId,
        mapping(uint256 => uint256) storage earmarkEpochStartRedemptionWeight,
        mapping(uint256 => uint256) storage earmarkEpochStartSurvivalAccumulator,
        Runtime memory runtime,
        address caller,
        address recipient
    ) public returns (LiquidationResult memory result) {
        if (recipient == address(0)) revert IllegalArgument();
        ValidationLogic.ensureValidAccount(runtime.positionNFT, accountId);
        ValidationLogic.requireTokenOwner(runtime.positionNFT, accountId, caller);

        EarmarkLogic.CommitResult memory commit = SyncLogic.commitEarmarkAndSync(
            accounts,
            accountId,
            earmarkEpochStartRedemptionWeight,
            earmarkEpochStartSurvivalAccumulator,
            earmarkState(runtime),
            runtime.totalRedeemedDebt,
            runtime.totalRedeemedSharesOut,
            SyncLogic.CommitAndSyncParams({
                myt: runtime.myt,
                transmuter: runtime.transmuter,
                underlyingConversionFactor: runtime.underlyingConversionFactor,
                totalSyntheticsIssued: runtime.totalSyntheticsIssued,
                totalDeposited: runtime.totalDeposited,
                minimumCollateralization: runtime.minimumCollateralization,
                fixedPointScalar: runtime.fixedPointScalar,
                enforceNoBadDebt: false
            })
        );
        applyCommit(runtime, commit);

        Account storage account = accounts[accountId];
        if (account.debt == 0) revert IllegalState();
        if (!isHealthy(runtime, account)) revert IAlchemistV3Errors.AccountNotHealthy();

        uint256 repaidEarmarkedDebtInYield;
        (repaidEarmarkedDebtInYield, runtime.totalDebt, runtime.totalDeposited, runtime.cumulativeEarmarked) =
            forceRepay(accounts, accountId, account.earmarked, runtime, caller, true);

        uint256 debt = account.debt;
        (runtime.totalDebt, runtime.cumulativeEarmarked) =
            BorrowLogic.subDebt(account, debt, runtime.totalDebt, runtime.cumulativeEarmarked, checkpointParams(runtime));

        uint256 repaidDebtInYield;
        (repaidDebtInYield, runtime.totalDeposited) =
            SupplyLogic.subCollateralBalance(account, StateLogic.convertDebtTokensToYield(runtime.myt, runtime.underlyingConversionFactor, debt), runtime.totalDeposited);
        uint256 remainingCollateral;
        (remainingCollateral, runtime.totalDeposited) =
            SupplyLogic.subCollateralBalance(account, account.collateralBalance, runtime.totalDeposited);

        if (repaidDebtInYield > 0) {
            TokenUtils.safeTransfer(runtime.myt, runtime.transmuter, repaidDebtInYield);
        }
        if (remainingCollateral > 0) {
            TokenUtils.safeTransfer(runtime.myt, recipient, remainingCollateral);
        }

        uint256 totalLiquidated = repaidEarmarkedDebtInYield + repaidDebtInYield;
        emit IAlchemistV3Events.SelfLiquidated(accountId, totalLiquidated);
        return packResult(runtime, totalLiquidated, 0, 0, totalLiquidated > 0);
    }

    function forceRepay(
        mapping(uint256 => Account) storage accounts,
        uint256 accountId,
        uint256 amount,
        Runtime memory runtime,
        address feeRecipient,
        bool skipPoke
    ) public returns (uint256 creditToYield, uint256 totalDebt, uint256 totalDeposited, uint256 cumulativeEarmarked) {
        if (amount == 0) {
            return (0, runtime.totalDebt, runtime.totalDeposited, runtime.cumulativeEarmarked);
        }
        if (!skipPoke) {
            revert IllegalState();
        }

        Account storage account = accounts[accountId];
        if (account.debt == 0) revert IllegalState();

        uint256 credit = BorrowLogic.capDebtCredit(amount, account.debt, runtime.totalDebt);
        if (credit == 0) return (0, runtime.totalDebt, runtime.totalDeposited, runtime.cumulativeEarmarked);

        (, runtime.cumulativeEarmarked) = BorrowLogic.subEarmarkedDebt(account, credit, runtime.cumulativeEarmarked);
        (runtime.totalDebt, runtime.cumulativeEarmarked) =
            BorrowLogic.subDebt(account, credit, runtime.totalDebt, runtime.cumulativeEarmarked, checkpointParams(runtime));

        (creditToYield, runtime.totalDeposited) = SupplyLogic.subCollateralBalance(
            account,
            StateLogic.convertDebtTokensToYield(runtime.myt, runtime.underlyingConversionFactor, credit),
            runtime.totalDeposited
        );
        uint256 targetProtocolFee = creditToYield * runtime.protocolFee / runtime.bps;
        uint256 protocolFeeTotal;
        (protocolFeeTotal, runtime.totalDeposited) =
            SupplyLogic.subCollateralBalance(account, targetProtocolFee, runtime.totalDeposited);

        emit IAlchemistV3Events.ForceRepay(accountId, amount, creditToYield, protocolFeeTotal);

        if (creditToYield > 0) {
            TokenUtils.safeTransfer(runtime.myt, runtime.transmuter, creditToYield);
        }
        if (protocolFeeTotal > 0) {
            TokenUtils.safeTransfer(runtime.myt, runtime.protocolFeeReceiver, protocolFeeTotal);
        }

        return (creditToYield, runtime.totalDebt, runtime.totalDeposited, runtime.cumulativeEarmarked);
    }

    function doLiquidation(
        mapping(uint256 => Account) storage accounts,
        uint256 accountId,
        Runtime memory runtime,
        address liquidator
    ) public returns (uint256 amountLiquidated, uint256 feeInYield, uint256 feeInUnderlying) {
        Account storage account = accounts[accountId];
        uint256 debt = account.debt;
        uint256 collateralValue = StateLogic.collateralValueInDebt(
            runtime.myt, runtime.underlyingConversionFactor, account.collateralBalance
        );
        (uint256 liquidationAmount, uint256 debtToBurn, uint256 baseFee, uint256 outsourcedFee) = calculateLiquidation(
            collateralValue,
            debt,
            runtime.liquidationTargetCollateralization,
            StateLogic.globalCollateralization(
                runtime.myt,
                runtime.underlyingConversionFactor,
                runtime.totalDebt,
                runtime.totalDeposited,
                runtime.fixedPointScalar
            ),
            runtime.globalMinimumCollateralization,
            runtime.liquidatorFee,
            runtime.bps,
            runtime.fixedPointScalar
        );

        if (liquidationAmount == 0) {
            if (debtToBurn > 0) {
                uint256 burnableDebt = BorrowLogic.capDebtCredit(debtToBurn, account.debt, runtime.totalDebt);
                if (burnableDebt > 0) {
                    (runtime.totalDebt, runtime.cumulativeEarmarked) = BorrowLogic.subDebt(
                        account,
                        burnableDebt,
                        runtime.totalDebt,
                        runtime.cumulativeEarmarked,
                        checkpointParams(runtime)
                    );
                }
            }

            uint256 feeRequestInUnderlying =
                StateLogic.normalizeDebtTokensToUnderlying(outsourcedFee, runtime.underlyingConversionFactor);
            if (feeRequestInUnderlying > 0) {
                feeInUnderlying = payWithFeeVault(runtime.alchemistFeeVault, liquidator, feeRequestInUnderlying);
            }

            if (account.debt < debt || feeInUnderlying > 0) {
                emit IAlchemistV3Events.Liquidated(accountId, liquidator, 0, 0, feeInUnderlying);
            }
            return (0, 0, feeInUnderlying);
        }

        uint256 requestedLiquidationInYield =
            StateLogic.convertDebtTokensToYield(runtime.myt, runtime.underlyingConversionFactor, liquidationAmount);
        (amountLiquidated, runtime.totalDeposited) =
            SupplyLogic.subCollateralBalance(account, requestedLiquidationInYield, runtime.totalDeposited);
        if (amountLiquidated == 0) return (0, 0, 0);

        uint256 requestedFeeInYield =
            StateLogic.convertDebtTokensToYield(runtime.myt, runtime.underlyingConversionFactor, baseFee);
        feeInYield = requestedFeeInYield > amountLiquidated ? amountLiquidated : requestedFeeInYield;

        uint256 netToTransmuter = amountLiquidated - feeInYield;
        uint256 maxDebtByRealized =
            StateLogic.convertYieldTokensToDebt(runtime.myt, runtime.underlyingConversionFactor, netToTransmuter);
        uint256 maxDebtByStorage = account.debt < runtime.totalDebt ? account.debt : runtime.totalDebt;

        if (debtToBurn > maxDebtByRealized) debtToBurn = maxDebtByRealized;
        if (debtToBurn > maxDebtByStorage) debtToBurn = maxDebtByStorage;

        if (debtToBurn > 0) {
            (runtime.totalDebt, runtime.cumulativeEarmarked) = BorrowLogic.subDebt(
                account, debtToBurn, runtime.totalDebt, runtime.cumulativeEarmarked, checkpointParams(runtime)
            );
        }

        if (account.debt > 0 && !isHealthy(runtime, account)) {
            uint256 remainingShares = account.collateralBalance;
            if (remainingShares > 0) {
                uint256 removedShares;
                (removedShares, runtime.totalDeposited) =
                    SupplyLogic.subCollateralBalance(account, remainingShares, runtime.totalDeposited);
                netToTransmuter += removedShares;

                uint256 extraDebtBurn = BorrowLogic.capDebtCredit(
                    StateLogic.convertYieldTokensToDebt(runtime.myt, runtime.underlyingConversionFactor, removedShares),
                    account.debt,
                    runtime.totalDebt
                );
                if (extraDebtBurn > 0) {
                    (runtime.totalDebt, runtime.cumulativeEarmarked) = BorrowLogic.subDebt(
                        account,
                        extraDebtBurn,
                        runtime.totalDebt,
                        runtime.cumulativeEarmarked,
                        checkpointParams(runtime)
                    );
                }
            }

            if (account.collateralBalance == 0 && account.debt > 0) {
                uint256 debtToClear = BorrowLogic.clearableDebt(account.debt, runtime.totalDebt);
                if (debtToClear > 0) {
                    (runtime.totalDebt, runtime.cumulativeEarmarked) = BorrowLogic.subDebt(
                        account,
                        debtToClear,
                        runtime.totalDebt,
                        runtime.cumulativeEarmarked,
                        checkpointParams(runtime)
                    );
                }
            }
        }

        TokenUtils.safeTransfer(runtime.myt, runtime.transmuter, netToTransmuter);

        if (feeInYield > 0) {
            TokenUtils.safeTransfer(runtime.myt, liquidator, feeInYield);
        } else if (StateLogic.normalizeDebtTokensToUnderlying(outsourcedFee, runtime.underlyingConversionFactor) > 0) {
            feeInUnderlying = payWithFeeVault(
                runtime.alchemistFeeVault,
                liquidator,
                StateLogic.normalizeDebtTokensToUnderlying(outsourcedFee, runtime.underlyingConversionFactor)
            );
        }
        emit IAlchemistV3Events.Liquidated(accountId, liquidator, amountLiquidated, feeInYield, feeInUnderlying);
        return (amountLiquidated, feeInYield, feeInUnderlying);
    }

    function calculateRepaymentFee(uint256 repaidAmountInYield, uint256 repaymentFee, uint256 bps) public
        pure
        returns (uint256 feeInYield)
    {
        return repaidAmountInYield * repaymentFee / bps;
    }

    function maxRepaymentFeeInYield(Account storage account, Runtime memory runtime) public
        view
        returns (uint256)
    {
        uint256 debt = account.debt;
        if (debt == 0) {
            return account.collateralBalance;
        }

        uint256 collateralInDebt =
            StateLogic.convertYieldTokensToDebt(runtime.myt, runtime.underlyingConversionFactor, account.collateralBalance);
        uint256 minimumByLowerBound = FixedPointMath.mulDivUp(
            debt, runtime.collateralizationLowerBound, runtime.fixedPointScalar
        );
        if (minimumByLowerBound == type(uint256).max) {
            return 0;
        }

        uint256 minRequiredPostFee = minimumByLowerBound + 1;
        if (collateralInDebt <= minRequiredPostFee) {
            return 0;
        }

        uint256 removableInDebt = collateralInDebt - minRequiredPostFee;
        return StateLogic.convertDebtTokensToYield(runtime.myt, runtime.underlyingConversionFactor, removableInDebt);
    }

    function payWithFeeVault(address alchemistFeeVault, address liquidator, uint256 amountInUnderlying) public
        returns (uint256)
    {
        if (amountInUnderlying == 0) return 0;
        if (alchemistFeeVault == address(0)) {
            emit IAlchemistV3Events.FeeShortfall(liquidator, amountInUnderlying, 0);
            return 0;
        }
        uint256 vaultBalance = IFeeVault(alchemistFeeVault).totalDeposits();
        if (vaultBalance > 0) {
            uint256 adjustedAmount = amountInUnderlying > vaultBalance ? vaultBalance : amountInUnderlying;
            IFeeVault(alchemistFeeVault).withdraw(liquidator, adjustedAmount);
            if (adjustedAmount < amountInUnderlying) {
                emit IAlchemistV3Events.FeeShortfall(liquidator, amountInUnderlying, adjustedAmount);
            }
            return adjustedAmount;
        }
        emit IAlchemistV3Events.FeeShortfall(liquidator, amountInUnderlying, 0);
        return 0;
    }

    function isHealthy(Runtime memory runtime, Account storage account) public view returns (bool) {
        if (account.debt == 0) {
            return true;
        }
        uint256 collateralValue =
            StateLogic.collateralValueInDebt(runtime.myt, runtime.underlyingConversionFactor, account.collateralBalance);
        return StateLogic.isDebtHealthyAtBound(
            account.debt, collateralValue, runtime.collateralizationLowerBound, runtime.fixedPointScalar
        );
    }

    function applyCommit(Runtime memory runtime, EarmarkLogic.CommitResult memory commit) public pure {
        runtime.lastTransmuterTokenBalance = commit.lastTransmuterTokenBalance;
        runtime.pendingCoverShares = commit.pendingCoverShares;
        runtime.cumulativeEarmarked = commit.cumulativeEarmarked;
        runtime.earmarkWeight = commit.earmarkWeight;
        runtime.survivalAccumulator = commit.survivalAccumulator;
        runtime.lastEarmarkBlock = commit.lastEarmarkBlock;
    }

    function earmarkState(Runtime memory runtime) public pure returns (EarmarkLogic.State memory) {
        return EarmarkLogic.State({
            totalDebt: runtime.totalDebt,
            cumulativeEarmarked: runtime.cumulativeEarmarked,
            lastEarmarkBlock: runtime.lastEarmarkBlock,
            lastTransmuterTokenBalance: runtime.lastTransmuterTokenBalance,
            pendingCoverShares: runtime.pendingCoverShares,
            earmarkWeight: runtime.earmarkWeight,
            redemptionWeight: runtime.redemptionWeight,
            survivalAccumulator: runtime.survivalAccumulator,
            oneQ128: runtime.oneQ128,
            redemptionIndexBits: runtime.redemptionIndexBits,
            redemptionIndexMask: runtime.redemptionIndexMask,
            earmarkIndexBits: runtime.earmarkIndexBits,
            earmarkIndexMask: runtime.earmarkIndexMask
        });
    }

    function checkpointParams(Runtime memory runtime) public
        pure
        returns (BorrowLogic.CheckpointParams memory)
    {
        return BorrowLogic.CheckpointParams({
            totalRedeemedDebt: runtime.totalRedeemedDebt,
            totalRedeemedSharesOut: runtime.totalRedeemedSharesOut,
            earmarkWeight: runtime.earmarkWeight,
            redemptionWeight: runtime.redemptionWeight,
            survivalAccumulator: runtime.survivalAccumulator
        });
    }

    function packResult(
        Runtime memory runtime,
        uint256 amountLiquidated,
        uint256 feeInYield,
        uint256 feeInUnderlying,
        bool progressed
    ) public pure returns (LiquidationResult memory result) {
        result.amountLiquidated = amountLiquidated;
        result.feeInYield = feeInYield;
        result.feeInUnderlying = feeInUnderlying;
        result.progressed = progressed;
        result.totalDebt = runtime.totalDebt;
        result.totalDeposited = runtime.totalDeposited;
        result.cumulativeEarmarked = runtime.cumulativeEarmarked;
        result.lastEarmarkBlock = runtime.lastEarmarkBlock;
        result.lastTransmuterTokenBalance = runtime.lastTransmuterTokenBalance;
        result.pendingCoverShares = runtime.pendingCoverShares;
        result.earmarkWeight = runtime.earmarkWeight;
        result.survivalAccumulator = runtime.survivalAccumulator;
    }

    function didLiquidationProgress(
        uint256 debtBefore,
        uint256 debtAfter,
        uint256 amountLiquidated,
        uint256 feeInYield,
        uint256 feeInUnderlying
    ) public pure returns (bool) {
        return amountLiquidated > 0 || feeInYield > 0 || feeInUnderlying > 0 || debtAfter < debtBefore;
    }
}



