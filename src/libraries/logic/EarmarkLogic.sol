// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../FixedPointMath.sol";
import {StateLogic} from "./StateLogic.sol";

library EarmarkLogic {
    struct State {
        uint256 totalDebt;
        uint256 cumulativeEarmarked;
        uint256 lastEarmarkBlock;
        uint256 lastTransmuterTokenBalance;
        uint256 pendingCoverShares;
        uint256 earmarkWeight;
        uint256 redemptionWeight;
        uint256 survivalAccumulator;
        uint256 oneQ128;
        uint256 redemptionIndexBits;
        uint256 redemptionIndexMask;
        uint256 earmarkIndexBits;
        uint256 earmarkIndexMask;
    }

    struct CommitResult {
        uint256 lastTransmuterTokenBalance;
        uint256 pendingCoverShares;
        uint256 cumulativeEarmarked;
        uint256 earmarkWeight;
        uint256 survivalAccumulator;
        uint256 lastEarmarkBlock;
        bool epochAdvanced;
        uint256 epochBoundary;
    }

    struct RedemptionWindowResult {
        uint256 effectiveRedeemed;
        uint256 totalDebt;
        uint256 cumulativeEarmarked;
        uint256 redemptionWeight;
        uint256 survivalAccumulator;
    }


    function state(
        uint256 totalDebt,
        uint256 cumulativeEarmarked,
        uint256 lastEarmarkBlock,
        uint256 lastTransmuterTokenBalance,
        uint256 pendingCoverShares,
        uint256 earmarkWeight,
        uint256 redemptionWeight,
        uint256 survivalAccumulator,
        uint256 oneQ128,
        uint256 redemptionIndexBits,
        uint256 redemptionIndexMask,
        uint256 earmarkIndexBits,
        uint256 earmarkIndexMask
    ) internal pure returns (State memory) {
        return State({
            totalDebt: totalDebt,
            cumulativeEarmarked: cumulativeEarmarked,
            lastEarmarkBlock: lastEarmarkBlock,
            lastTransmuterTokenBalance: lastTransmuterTokenBalance,
            pendingCoverShares: pendingCoverShares,
            earmarkWeight: earmarkWeight,
            redemptionWeight: redemptionWeight,
            survivalAccumulator: survivalAccumulator,
            oneQ128: oneQ128,
            redemptionIndexBits: redemptionIndexBits,
            redemptionIndexMask: redemptionIndexMask,
            earmarkIndexBits: earmarkIndexBits,
            earmarkIndexMask: earmarkIndexMask
        });
    }
    function commitFromGraph(
        State memory state,
        address transmuter,
        address myt,
        uint256 underlyingConversionFactor,
        uint256 blockNumber
    ) internal view returns (CommitResult memory result) {
        result.lastTransmuterTokenBalance = state.lastTransmuterTokenBalance;
        result.pendingCoverShares = state.pendingCoverShares;
        result.cumulativeEarmarked = state.cumulativeEarmarked;
        result.earmarkWeight = state.earmarkWeight;
        result.survivalAccumulator = state.survivalAccumulator;
        result.lastEarmarkBlock = state.lastEarmarkBlock;

        if (state.totalDebt == 0 || blockNumber <= state.lastEarmarkBlock) {
            return result;
        }

        uint256 transmuterBalance = StateLogic.transmuterSharesBalance(myt, transmuter);
        uint256 amount = StateLogic.queryGraph(transmuter, state.lastEarmarkBlock, blockNumber);
        return commit(state, transmuterBalance, amount, blockNumber, myt, underlyingConversionFactor);
    }

    function commit(
        State memory state,
        uint256 transmuterBalance,
        uint256 amount,
        uint256 blockNumber,
        address myt,
        uint256 underlyingConversionFactor
    ) internal view returns (CommitResult memory result) {
        result.lastTransmuterTokenBalance = transmuterBalance;
        result.pendingCoverShares = state.pendingCoverShares;
        result.cumulativeEarmarked = state.cumulativeEarmarked;
        result.earmarkWeight = state.earmarkWeight;
        result.survivalAccumulator = state.survivalAccumulator;
        result.lastEarmarkBlock = blockNumber;

        if (transmuterBalance > state.lastTransmuterTokenBalance) {
            result.pendingCoverShares += (transmuterBalance - state.lastTransmuterTokenBalance);
        }

        uint256 sharesUsed;
        (amount, sharesUsed) = applyPendingCover(amount, result.pendingCoverShares, myt, underlyingConversionFactor);
        result.pendingCoverShares -= sharesUsed;

        uint256 liveUnearmarked = state.totalDebt - state.cumulativeEarmarked;
        if (amount > liveUnearmarked) amount = liveUnearmarked;

        if (amount > 0 && liveUnearmarked != 0) {
            (
                uint256 packedNew,
                uint256 ratioApplied,
                uint256 effectiveEarmarked,
                uint256 oldIndex,
                uint256 newEpoch,
                bool epochAdvanced
            ) = simulateEarmarkWindow(
                state.earmarkWeight,
                liveUnearmarked,
                amount,
                state.oneQ128,
                state.earmarkIndexBits,
                state.earmarkIndexMask
            );

            result.earmarkWeight = packedNew;

            uint256 earmarkedFraction = state.oneQ128 - ratioApplied;
            result.survivalAccumulator += FixedPointMath.mulQ128(oldIndex, earmarkedFraction);
            result.cumulativeEarmarked += effectiveEarmarked;

            if (epochAdvanced) {
                result.epochAdvanced = true;
                result.epochBoundary = newEpoch;
            }
        }
    }

    function simulateFromGraph(
        State memory state,
        address transmuter,
        address myt,
        uint256 underlyingConversionFactor,
        uint256 blockNumber
    ) internal view returns (uint256 earmarkWeightCopy, uint256 effectiveEarmarked) {
        earmarkWeightCopy = state.earmarkWeight;
        if (state.totalDebt == 0 || blockNumber <= state.lastEarmarkBlock) return (earmarkWeightCopy, 0);

        uint256 transmuterBalance = StateLogic.transmuterSharesBalance(myt, transmuter);
        uint256 amount = StateLogic.queryGraph(transmuter, state.lastEarmarkBlock, blockNumber);
        return simulateUnrealizedEarmark(state, transmuterBalance, amount, myt, underlyingConversionFactor);
    }

    function simulateUnrealizedEarmark(
        State memory state,
        uint256 transmuterBalance,
        uint256 amount,
        address myt,
        uint256 underlyingConversionFactor
    ) internal view returns (uint256 earmarkWeightCopy, uint256 effectiveEarmarked) {
        earmarkWeightCopy = state.earmarkWeight;

        uint256 pendingCover = state.pendingCoverShares;
        if (transmuterBalance > state.lastTransmuterTokenBalance) {
            pendingCover += (transmuterBalance - state.lastTransmuterTokenBalance);
        }

        (amount,) = applyPendingCover(amount, pendingCover, myt, underlyingConversionFactor);

        uint256 liveUnearmarked = state.totalDebt - state.cumulativeEarmarked;
        if (amount > liveUnearmarked) amount = liveUnearmarked;
        if (amount == 0 || liveUnearmarked == 0) return (earmarkWeightCopy, 0);

        (earmarkWeightCopy,, effectiveEarmarked,,,) = simulateEarmarkWindow(
            earmarkWeightCopy, liveUnearmarked, amount, state.oneQ128, state.earmarkIndexBits, state.earmarkIndexMask
        );
    }

    function earmarkSurvivalRatio(
        uint256 oldPacked,
        uint256 newPacked,
        uint256 indexBits,
        uint256 indexMask,
        uint256 oneQ128
    ) internal pure returns (uint256) {
        if (newPacked == oldPacked) return oneQ128;
        if (oldPacked == 0) return oneQ128;

        uint256 oldEpoch = oldPacked >> indexBits;
        uint256 newEpoch = newPacked >> indexBits;
        if (newEpoch > oldEpoch) return 0;

        uint256 oldIdx = oldPacked & indexMask;
        uint256 newIdx = newPacked & indexMask;
        if (oldIdx == 0) return 0;

        return FixedPointMath.divQ128(newIdx, oldIdx);
    }

    function redemptionSurvivalRatio(
        uint256 oldPacked,
        uint256 newPacked,
        uint256 indexBits,
        uint256 indexMask,
        uint256 oneQ128
    ) internal pure returns (uint256) {
        if (newPacked == oldPacked) return oneQ128;
        if (oldPacked == 0) return oneQ128;

        uint256 oldEpoch = oldPacked >> indexBits;
        uint256 newEpoch = newPacked >> indexBits;
        if (newEpoch > oldEpoch) return 0;

        uint256 oldIndexValue = oldPacked & indexMask;
        uint256 newIndexValue = newPacked & indexMask;
        if (oldIndexValue == 0) return 0;

        return FixedPointMath.divQ128(newIndexValue, oldIndexValue);
    }

    function applyRedemptionWindow(State memory state, uint256 liveEarmarked, uint256 amount)
        internal
        pure
        returns (RedemptionWindowResult memory result)
    {
        result.totalDebt = state.totalDebt;
        result.cumulativeEarmarked = state.cumulativeEarmarked;
        result.redemptionWeight = state.redemptionWeight;
        result.survivalAccumulator = state.survivalAccumulator;

        if (liveEarmarked == 0 || amount == 0) {
            return result;
        }

        uint256 ratioWanted =
            amount == liveEarmarked ? 0 : FixedPointMath.divQ128(liveEarmarked - amount, liveEarmarked);
        (uint256 packedNew, uint256 ratioApplied,,,) = simulatePackedWeightUpdate(
            state.redemptionWeight,
            ratioWanted,
            state.redemptionIndexBits,
            state.redemptionIndexMask,
            state.oneQ128
        );
        result.redemptionWeight = packedNew;
        result.survivalAccumulator = FixedPointMath.mulQ128(state.survivalAccumulator, ratioApplied);

        result.effectiveRedeemed = effectiveAppliedAmount(liveEarmarked, ratioApplied);
        result.cumulativeEarmarked = liveEarmarked - result.effectiveRedeemed;
        result.totalDebt = state.totalDebt - result.effectiveRedeemed;
    }

    function applyPendingCover(
        uint256 amount,
        uint256 pendingCoverShares,
        address myt,
        uint256 underlyingConversionFactor
    ) internal view returns (uint256 adjustedAmount, uint256 sharesUsed) {
        adjustedAmount = amount;
        if (amount == 0 || pendingCoverShares == 0) {
            return (adjustedAmount, 0);
        }

        uint256 coverInDebt = StateLogic.convertYieldTokensToDebt(myt, underlyingConversionFactor, pendingCoverShares);
        if (coverInDebt == 0) {
            return (adjustedAmount, 0);
        }

        uint256 usedDebt = amount > coverInDebt ? coverInDebt : amount;
        adjustedAmount -= usedDebt;

        sharesUsed = FixedPointMath.mulDivUp(pendingCoverShares, usedDebt, coverInDebt);
        if (sharesUsed > pendingCoverShares) sharesUsed = pendingCoverShares;
    }

    function simulateEarmarkWindow(
        uint256 packedOld,
        uint256 liveUnearmarked,
        uint256 amount,
        uint256 oneQ128,
        uint256 indexBits,
        uint256 indexMask
    )
        internal
        pure
        returns (
            uint256 packedNew,
            uint256 ratioApplied,
            uint256 effectiveEarmarked,
            uint256 oldIndex,
            uint256 newEpoch,
            bool epochAdvanced
        )
    {
        if (liveUnearmarked == 0 || amount == 0) {
            uint256 normalizedIndex = packedIndex(packedOld, indexMask);
            if (packedOld == 0 || normalizedIndex == 0) {
                normalizedIndex = oneQ128;
            }
            return (packedOld, oneQ128, 0, normalizedIndex, packedEpoch(packedOld, indexBits), false);
        }

        uint256 ratioWanted =
            amount == liveUnearmarked ? 0 : FixedPointMath.divQ128(liveUnearmarked - amount, liveUnearmarked);
        (packedNew, ratioApplied, oldIndex, newEpoch, epochAdvanced) =
            simulatePackedWeightUpdate(packedOld, ratioWanted, indexBits, indexMask, oneQ128);
        effectiveEarmarked = effectiveAppliedAmount(liveUnearmarked, ratioApplied);
    }

    function simulatePackedWeightUpdate(
        uint256 packedOld,
        uint256 ratioWanted,
        uint256 indexBits,
        uint256 indexMask,
        uint256 oneQ128
    ) internal pure returns (uint256 packedNew, uint256 ratioApplied, uint256 oldIndex, uint256 newEpoch, bool epochAdvanced) {
        uint256 oldEpoch = packedEpoch(packedOld, indexBits);
        oldIndex = packedIndex(packedOld, indexMask);

        if (packedOld == 0) {
            oldEpoch = 0;
            oldIndex = oneQ128;
        }
        if (oldIndex == 0) {
            oldEpoch += 1;
            oldIndex = oneQ128;
        }

        newEpoch = oldEpoch;
        uint256 newIndex;

        if (ratioWanted == 0) {
            newEpoch += 1;
            newIndex = oneQ128;
        } else {
            newIndex = FixedPointMath.mulQ128(oldIndex, ratioWanted);
        }

        epochAdvanced = newEpoch > oldEpoch;
        packedNew = packWeight(newEpoch, newIndex, indexBits);
        ratioApplied = epochAdvanced ? 0 : FixedPointMath.divQ128(newIndex, oldIndex);
    }

    function effectiveAppliedAmount(uint256 totalAmount, uint256 ratioApplied) internal pure returns (uint256) {
        uint256 remainingAmount = FixedPointMath.mulQ128(totalAmount, ratioApplied);
        return totalAmount - remainingAmount;
    }

    function packedEpoch(uint256 packed, uint256 indexBits) internal pure returns (uint256) {
        return packed >> indexBits;
    }

    function packedIndex(uint256 packed, uint256 indexMask) internal pure returns (uint256) {
        return packed & indexMask;
    }

    function packWeight(uint256 epoch, uint256 index, uint256 indexBits) internal pure returns (uint256) {
        return (epoch << indexBits) | index;
    }
}

