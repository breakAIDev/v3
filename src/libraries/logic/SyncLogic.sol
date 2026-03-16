// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../interfaces/IAlchemistV3.sol";
import "../../base/Errors.sol";
import "../FixedPointMath.sol";
import {BorrowLogic} from "./BorrowLogic.sol";
import {EarmarkLogic} from "./EarmarkLogic.sol";
import {StateLogic} from "./StateLogic.sol";

library SyncLogic {
    struct GlobalSyncState {
        uint256 totalRedeemedDebt;
        uint256 totalRedeemedSharesOut;
        uint256 earmarkWeight;
        uint256 redemptionWeight;
        uint256 survivalAccumulator;
        uint256 oneQ128;
        uint256 earmarkIndexMask;
        uint256 earmarkIndexBits;
        uint256 redemptionIndexMask;
        uint256 redemptionIndexBits;
    }

    struct CommitAndSyncParams {
        address myt;
        address transmuter;
        uint256 underlyingConversionFactor;
        uint256 totalSyntheticsIssued;
        uint256 totalDeposited;
        uint256 minimumCollateralization;
        uint256 fixedPointScalar;
        bool enforceNoBadDebt;
    }

    function globalSyncState(
        uint256 totalRedeemedDebt,
        uint256 totalRedeemedSharesOut,
        uint256 earmarkWeight,
        uint256 redemptionWeight,
        uint256 survivalAccumulator,
        uint256 oneQ128,
        uint256 earmarkIndexMask,
        uint256 earmarkIndexBits,
        uint256 redemptionIndexMask,
        uint256 redemptionIndexBits
    ) internal pure returns (GlobalSyncState memory) {
        return GlobalSyncState({
            totalRedeemedDebt: totalRedeemedDebt,
            totalRedeemedSharesOut: totalRedeemedSharesOut,
            earmarkWeight: earmarkWeight,
            redemptionWeight: redemptionWeight,
            survivalAccumulator: survivalAccumulator,
            oneQ128: oneQ128,
            earmarkIndexMask: earmarkIndexMask,
            earmarkIndexBits: earmarkIndexBits,
            redemptionIndexMask: redemptionIndexMask,
            redemptionIndexBits: redemptionIndexBits
        });
    }

    function commitEarmarkAndSync(
        mapping(uint256 => Account) storage accounts,
        uint256 tokenId,
        mapping(uint256 => uint256) storage earmarkEpochStartRedemptionWeight,
        mapping(uint256 => uint256) storage earmarkEpochStartSurvivalAccumulator,
        EarmarkLogic.State memory earmarkState,
        uint256 totalRedeemedDebt,
        uint256 totalRedeemedSharesOut,
        CommitAndSyncParams memory params
    ) internal returns (EarmarkLogic.CommitResult memory result) {
        result = EarmarkLogic.commitFromGraph(
            earmarkState, params.transmuter, params.myt, params.underlyingConversionFactor, block.number
        );

        if (result.epochAdvanced) {
            earmarkEpochStartRedemptionWeight[result.epochBoundary] = earmarkState.redemptionWeight;
            earmarkEpochStartSurvivalAccumulator[result.epochBoundary] = result.survivalAccumulator;
        }

        if (
            params.enforceNoBadDebt
                && StateLogic.isProtocolInBadDebt(
                    params.myt,
                    params.transmuter,
                    params.underlyingConversionFactor,
                    earmarkState.totalDebt,
                    params.totalDeposited,
                    params.totalSyntheticsIssued,
                    params.minimumCollateralization,
                    params.fixedPointScalar
                )
        ) {
            revert IllegalState();
        }

        sync(
            accounts[tokenId],
            globalSyncState(
                totalRedeemedDebt,
                totalRedeemedSharesOut,
                result.earmarkWeight,
                earmarkState.redemptionWeight,
                result.survivalAccumulator,
                earmarkState.oneQ128,
                earmarkState.earmarkIndexMask,
                earmarkState.earmarkIndexBits,
                earmarkState.redemptionIndexMask,
                earmarkState.redemptionIndexBits
            ),
            earmarkEpochStartRedemptionWeight,
            earmarkEpochStartSurvivalAccumulator
        );
    }

    function sync(
        Account storage account,
        GlobalSyncState memory state,
        mapping(uint256 => uint256) storage earmarkEpochStartRedemptionWeight,
        mapping(uint256 => uint256) storage earmarkEpochStartSurvivalAccumulator
    ) internal {
        (uint256 newDebt, uint256 newEarmarked, uint256 collateralBalance,) = computeCommittedAccountState(
            account, state, earmarkEpochStartRedemptionWeight, earmarkEpochStartSurvivalAccumulator
        );

        account.collateralBalance = collateralBalance;
        account.earmarked = newEarmarked;
        account.debt = newDebt;
        BorrowLogic.checkpointAccountState(account, checkpointParams(state));
    }

    function computeCommittedAccountState(
        Account storage account,
        GlobalSyncState memory state,
        mapping(uint256 => uint256) storage earmarkEpochStartRedemptionWeight,
        mapping(uint256 => uint256) storage earmarkEpochStartSurvivalAccumulator
    ) internal view returns (uint256 newDebt, uint256 newEarmarked, uint256 collateralBalance, uint256 redeemedDebt) {
        (newDebt, newEarmarked, redeemedDebt) =
            computeUnrealizedAccount(account, state, earmarkEpochStartRedemptionWeight, earmarkEpochStartSurvivalAccumulator);
        collateralBalance = applyRedeemedCollateralDelta(
            account, account.collateralBalance, redeemedDebt, state.totalRedeemedDebt, state.totalRedeemedSharesOut
        );
    }

    function applyRedeemedCollateralDelta(
        Account storage account,
        uint256 collateralBalance,
        uint256 redeemedDebt,
        uint256 totalRedeemedDebt,
        uint256 totalRedeemedSharesOut
    ) internal view returns (uint256) {
        uint256 globalDebtDelta = totalRedeemedDebt - account.lastTotalRedeemedDebt;
        if (globalDebtDelta == 0 || redeemedDebt == 0) {
            return collateralBalance;
        }

        uint256 globalSharesDelta = totalRedeemedSharesOut - account.lastTotalRedeemedSharesOut;
        uint256 sharesToDebit = FixedPointMath.mulDivUp(redeemedDebt, globalSharesDelta, globalDebtDelta);
        if (sharesToDebit > collateralBalance) sharesToDebit = collateralBalance;
        return collateralBalance - sharesToDebit;
    }

    function applyProspectiveEarmark(
        uint256 debt,
        uint256 earmarked,
        uint256 committedEarmarkWeight,
        uint256 simulatedEarmarkWeight,
        uint256 earmarkIndexBits,
        uint256 earmarkIndexMask,
        uint256 oneQ128
    ) internal pure returns (uint256) {
        if (simulatedEarmarkWeight == committedEarmarkWeight) {
            return earmarked;
        }

        uint256 exposure = debt > earmarked ? debt - earmarked : 0;
        if (exposure == 0) {
            return earmarked;
        }

        uint256 unearmarkedRatio = EarmarkLogic.earmarkSurvivalRatio(
            committedEarmarkWeight, simulatedEarmarkWeight, earmarkIndexBits, earmarkIndexMask, oneQ128
        );
        uint256 unearmarkedRemaining = FixedPointMath.mulQ128(exposure, unearmarkedRatio);
        uint256 newlyEarmarked = exposure - unearmarkedRemaining;
        earmarked += newlyEarmarked;
        return earmarked > debt ? debt : earmarked;
    }

    function computeUnrealizedAccount(
        Account storage account,
        GlobalSyncState memory state,
        mapping(uint256 => uint256) storage earmarkEpochStartRedemptionWeight,
        mapping(uint256 => uint256) storage earmarkEpochStartSurvivalAccumulator
    ) internal view returns (uint256 newDebt, uint256 newEarmarked, uint256 redeemedDebt) {
        uint256 survivalRatio = EarmarkLogic.redemptionSurvivalRatio(
            account.lastAccruedRedemptionWeight,
            state.redemptionWeight,
            state.redemptionIndexBits,
            state.redemptionIndexMask,
            state.oneQ128
        );

        uint256 userExposure = account.debt > account.earmarked ? account.debt - account.earmarked : 0;
        uint256 unearmarkSurvivalRatio = EarmarkLogic.earmarkSurvivalRatio(
            account.lastAccruedEarmarkWeight,
            state.earmarkWeight,
            state.earmarkIndexBits,
            state.earmarkIndexMask,
            state.oneQ128
        );

        uint256 unearmarkedRemaining = FixedPointMath.mulQ128(userExposure, unearmarkSurvivalRatio);
        uint256 earmarkRaw = userExposure - unearmarkedRemaining;

        if (survivalRatio == state.oneQ128) {
            newDebt = account.debt;
            newEarmarked = account.earmarked + earmarkRaw;
            if (newEarmarked > newDebt) newEarmarked = newDebt;
            redeemedDebt = 0;
            return (newDebt, newEarmarked, redeemedDebt);
        }

        uint256 earmarkSurvival = EarmarkLogic.packedIndex(account.lastAccruedEarmarkWeight, state.earmarkIndexMask);
        if (earmarkSurvival == 0) earmarkSurvival = state.oneQ128;

        uint256 decayedRedeemed = FixedPointMath.mulQ128(account.lastSurvivalAccumulator, survivalRatio);
        uint256 survivalDiff =
            state.survivalAccumulator > decayedRedeemed ? state.survivalAccumulator - decayedRedeemed : 0;
        if (survivalDiff > earmarkSurvival) survivalDiff = earmarkSurvival;
        uint256 unredeemedRatio = FixedPointMath.divQ128(survivalDiff, earmarkSurvival);
        uint256 earmarkedUnredeemed = FixedPointMath.mulQ128(userExposure, unredeemedRatio);

        uint256 oldEarEpoch = EarmarkLogic.packedEpoch(account.lastAccruedEarmarkWeight, state.earmarkIndexBits);
        uint256 newEarEpoch = EarmarkLogic.packedEpoch(state.earmarkWeight, state.earmarkIndexBits);
        if (newEarEpoch > oldEarEpoch) {
            uint256 boundaryEpoch = oldEarEpoch + 1;
            uint256 boundaryRedemptionWeight = earmarkEpochStartRedemptionWeight[boundaryEpoch];
            uint256 boundarySurvivalAccumulator = earmarkEpochStartSurvivalAccumulator[boundaryEpoch];

            if (boundaryRedemptionWeight != 0) {
                uint256 preBoundarySurvival = EarmarkLogic.redemptionSurvivalRatio(
                    account.lastAccruedRedemptionWeight,
                    boundaryRedemptionWeight,
                    state.redemptionIndexBits,
                    state.redemptionIndexMask,
                    state.oneQ128
                );
                uint256 decayedAtBoundary = FixedPointMath.mulQ128(account.lastSurvivalAccumulator, preBoundarySurvival);

                uint256 boundaryDiff = boundarySurvivalAccumulator > decayedAtBoundary
                    ? boundarySurvivalAccumulator - decayedAtBoundary
                    : 0;
                if (boundaryDiff > earmarkSurvival) boundaryDiff = earmarkSurvival;

                uint256 unredeemedAtBoundaryRatio = FixedPointMath.divQ128(boundaryDiff, earmarkSurvival);
                uint256 unredeemedAtBoundary = FixedPointMath.mulQ128(userExposure, unredeemedAtBoundaryRatio);

                uint256 postBoundarySurvival = EarmarkLogic.redemptionSurvivalRatio(
                    boundaryRedemptionWeight,
                    state.redemptionWeight,
                    state.redemptionIndexBits,
                    state.redemptionIndexMask,
                    state.oneQ128
                );

                earmarkedUnredeemed = FixedPointMath.mulQ128(unredeemedAtBoundary, postBoundarySurvival);
            } else {
                earmarkedUnredeemed = FixedPointMath.mulQ128(earmarkRaw, survivalRatio);
            }
        }

        if (earmarkedUnredeemed > earmarkRaw) earmarkedUnredeemed = earmarkRaw;

        uint256 exposureSurvival = FixedPointMath.mulQ128(account.earmarked, survivalRatio);
        uint256 redeemedFromEarmarked = earmarkRaw - earmarkedUnredeemed;
        uint256 redeemedTotal = (account.earmarked - exposureSurvival) + redeemedFromEarmarked;

        newDebt = account.debt >= redeemedTotal ? account.debt - redeemedTotal : 0;
        redeemedDebt = account.debt - newDebt;
        newEarmarked = exposureSurvival + earmarkedUnredeemed;
        if (newEarmarked > newDebt) newEarmarked = newDebt;
    }

    function calculateUnrealizedDebt(
        Account storage account,
        GlobalSyncState memory state,
        uint256 simulatedEarmarkWeight,
        mapping(uint256 => uint256) storage earmarkEpochStartRedemptionWeight,
        mapping(uint256 => uint256) storage earmarkEpochStartSurvivalAccumulator
    ) internal view returns (uint256, uint256, uint256) {
        (uint256 newDebt, uint256 newEarmarked, uint256 collateralBalanceCopy,) = computeCommittedAccountState(
            account, state, earmarkEpochStartRedemptionWeight, earmarkEpochStartSurvivalAccumulator
        );

        newEarmarked = applyProspectiveEarmark(
            newDebt,
            newEarmarked,
            state.earmarkWeight,
            simulatedEarmarkWeight,
            state.earmarkIndexBits,
            state.earmarkIndexMask,
            state.oneQ128
        );

        return (newDebt, newEarmarked, collateralBalanceCopy);
    }

    function checkpointParams(GlobalSyncState memory state)
        internal
        pure
        returns (BorrowLogic.CheckpointParams memory)
    {
        return BorrowLogic.CheckpointParams({
            totalRedeemedDebt: state.totalRedeemedDebt,
            totalRedeemedSharesOut: state.totalRedeemedSharesOut,
            earmarkWeight: state.earmarkWeight,
            redemptionWeight: state.redemptionWeight,
            survivalAccumulator: state.survivalAccumulator
        });
    }
}
