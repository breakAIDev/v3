// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./AlchemistV3SyncModule.sol";
import {ITransmuter} from "../interfaces/ITransmuter.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";

abstract contract AlchemistV3EarmarkModule is AlchemistV3SyncModule {
    /// @dev Commits one new earmark window into global accounting.
    function _earmark() internal virtual override {
        if (totalDebt == 0) return;
        if (block.number <= lastEarmarkBlock) return;

        uint256 transmuterBalance = _transmuterSharesBalance();

        if (transmuterBalance > lastTransmuterTokenBalance) {
            _pendingCoverShares += (transmuterBalance - lastTransmuterTokenBalance);
        }

        lastTransmuterTokenBalance = transmuterBalance;

        uint256 amount = ITransmuter(transmuter).queryGraph(lastEarmarkBlock + 1, block.number);

        uint256 sharesUsed;
        (amount, sharesUsed) = _applyPendingCover(amount, _pendingCoverShares);
        _pendingCoverShares -= sharesUsed;

        uint256 liveUnearmarked = totalDebt - cumulativeEarmarked;
        if (amount > liveUnearmarked) amount = liveUnearmarked;

        if (amount > 0 && liveUnearmarked != 0) {
            (
                uint256 packedNew,
                uint256 ratioApplied,
                uint256 effectiveEarmarked,
                uint256 oldIndex,
                uint256 newEpoch,
                bool epochAdvanced
            ) = _simulateEarmarkWindow(_earmarkWeight, liveUnearmarked, amount);
            _earmarkWeight = packedNew;

            uint256 earmarkedFraction = ONE_Q128 - ratioApplied;
            _survivalAccumulator += FixedPointMath.mulQ128(oldIndex, earmarkedFraction);

            if (epochAdvanced) {
                _earmarkEpochStartRedemptionWeight[newEpoch] = _redemptionWeight;
                _earmarkEpochStartSurvivalAccumulator[newEpoch] = _survivalAccumulator;
            }
            cumulativeEarmarked += effectiveEarmarked;
        }

        lastEarmarkBlock = block.number;
    }

    // Survival ratio of *unearmarked* exposure between two packed earmark states.
    function _earmarkSurvivalRatio(uint256 oldPacked, uint256 newPacked)
        internal
        pure
        virtual
        override
        returns (uint256)
    {
        if (newPacked == oldPacked) return ONE_Q128;
        if (oldPacked == 0) return ONE_Q128;

        uint256 oldEpoch = oldPacked >> _EARMARK_INDEX_BITS;
        uint256 newEpoch = newPacked >> _EARMARK_INDEX_BITS;
        if (newEpoch > oldEpoch) return 0;

        uint256 oldIdx = oldPacked & _EARMARK_INDEX_MASK;
        uint256 newIdx = newPacked & _EARMARK_INDEX_MASK;

        if (oldIdx == 0) return 0;

        return FixedPointMath.divQ128(newIdx, oldIdx);
    }

    /// @dev Computes redemption survival ratio between two packed redemption states.
    function _redemptionSurvivalRatio(uint256 oldPacked, uint256 newPacked)
        internal
        pure
        virtual
        override
        returns (uint256)
    {
        if (newPacked == oldPacked) return ONE_Q128;
        if (oldPacked == 0) return ONE_Q128;

        uint256 oldEpoch = oldPacked >> _REDEMPTION_INDEX_BITS;
        uint256 newEpoch = newPacked >> _REDEMPTION_INDEX_BITS;
        if (newEpoch > oldEpoch) return 0;

        uint256 oldIndex = oldPacked & _REDEMPTION_INDEX_MASK;
        uint256 newIndex = newPacked & _REDEMPTION_INDEX_MASK;
        if (oldIndex == 0) return 0;

        return FixedPointMath.divQ128(newIndex, oldIndex);
    }

    /// @dev Simulates one uncommitted earmark window using current on-chain state.
    /// @return earmarkWeightCopy Simulated earmark packed weight after the window.
    /// @return effectiveEarmarked The additional earmarked debt from this simulated window.
    function _simulateUnrealizedEarmark()
        internal
        view
        virtual
        override
        returns (uint256 earmarkWeightCopy, uint256 effectiveEarmarked)
    {
        earmarkWeightCopy = _earmarkWeight;
        if (block.number <= lastEarmarkBlock || totalDebt == 0) return (earmarkWeightCopy, 0);

        uint256 transmuterBalance = _transmuterSharesBalance();

        uint256 pendingCover = _pendingCoverShares;
        if (transmuterBalance > lastTransmuterTokenBalance) {
            pendingCover += (transmuterBalance - lastTransmuterTokenBalance);
        }

        uint256 amount = ITransmuter(transmuter).queryGraph(lastEarmarkBlock + 1, block.number);

        (amount,) = _applyPendingCover(amount, pendingCover);

        uint256 liveUnearmarked = totalDebt - cumulativeEarmarked;
        if (amount > liveUnearmarked) amount = liveUnearmarked;
        if (amount == 0 || liveUnearmarked == 0) return (earmarkWeightCopy, 0);

        (earmarkWeightCopy,, effectiveEarmarked,,,) =
            _simulateEarmarkWindow(earmarkWeightCopy, liveUnearmarked, amount);
    }

    /// @dev Simulates the packed earmark update and returns the applied survival ratio.
    function _simulateEarmarkPackedUpdate(uint256 packedOld, uint256 ratioWanted)
        internal
        pure
        returns (uint256 packedNew, uint256 ratioApplied, uint256 oldIndex, uint256 newEpoch, bool epochAdvanced)
    {
        return _simulatePackedWeightUpdate(packedOld, ratioWanted, _EARMARK_INDEX_BITS, _EARMARK_INDEX_MASK);
    }

    /// @dev Simulates the packed redemption update and returns the applied survival ratio.
    function _simulateRedemptionPackedUpdate(uint256 packedOld, uint256 ratioWanted)
        internal
        pure
        returns (uint256 packedNew, uint256 ratioApplied, uint256 oldIndex, uint256 newEpoch, bool epochAdvanced)
    {
        return _simulatePackedWeightUpdate(packedOld, ratioWanted, _REDEMPTION_INDEX_BITS, _REDEMPTION_INDEX_MASK);
    }

    /// @dev Applies one committed redemption window to global redemption accounting.
    function _applyRedemptionWindow(uint256 liveEarmarked, uint256 amount) internal returns (uint256 effectiveRedeemed) {
        if (liveEarmarked == 0 || amount == 0) {
            return 0;
        }

        uint256 ratioWanted = amount == liveEarmarked ? 0 : FixedPointMath.divQ128(liveEarmarked - amount, liveEarmarked);
        (uint256 packedNew, uint256 ratioApplied,,,) = _simulateRedemptionPackedUpdate(_redemptionWeight, ratioWanted);
        _redemptionWeight = packedNew;
        _survivalAccumulator = FixedPointMath.mulQ128(_survivalAccumulator, ratioApplied);

        effectiveRedeemed = _effectiveAppliedAmount(liveEarmarked, ratioApplied);
        cumulativeEarmarked = liveEarmarked - effectiveRedeemed;
        totalDebt -= effectiveRedeemed;
    }

    /// @dev Applies pending cover shares against a debt-denominated earmark amount.
    function _applyPendingCover(uint256 amount, uint256 pendingCoverShares)
        internal
        view
        returns (uint256 adjustedAmount, uint256 sharesUsed)
    {
        adjustedAmount = amount;
        if (amount == 0 || pendingCoverShares == 0) {
            return (adjustedAmount, 0);
        }

        uint256 coverInDebt = convertYieldTokensToDebt(pendingCoverShares);
        if (coverInDebt == 0) {
            return (adjustedAmount, 0);
        }

        uint256 usedDebt = amount > coverInDebt ? coverInDebt : amount;
        adjustedAmount -= usedDebt;

        sharesUsed = FixedPointMath.mulDivUp(pendingCoverShares, usedDebt, coverInDebt);
        if (sharesUsed > pendingCoverShares) sharesUsed = pendingCoverShares;
    }

    /// @dev Simulates one earmark window and returns the effective newly earmarked amount.
    function _simulateEarmarkWindow(uint256 packedOld, uint256 liveUnearmarked, uint256 amount)
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
            uint256 normalizedIndex = _packedIndex(packedOld, _EARMARK_INDEX_MASK);
            if (packedOld == 0 || normalizedIndex == 0) {
                normalizedIndex = ONE_Q128;
            }
            return (packedOld, ONE_Q128, 0, normalizedIndex, _packedEpoch(packedOld, _EARMARK_INDEX_BITS), false);
        }

        uint256 ratioWanted =
            amount == liveUnearmarked ? 0 : FixedPointMath.divQ128(liveUnearmarked - amount, liveUnearmarked);
        (packedNew, ratioApplied, oldIndex, newEpoch, epochAdvanced) = _simulateEarmarkPackedUpdate(packedOld, ratioWanted);
        effectiveEarmarked = _effectiveAppliedAmount(liveUnearmarked, ratioApplied);
    }

    /// @dev Generic packed epoch/index weight update shared by earmark and redemption.
    function _simulatePackedWeightUpdate(uint256 packedOld, uint256 ratioWanted, uint256 indexBits, uint256 indexMask)
        internal
        pure
        returns (uint256 packedNew, uint256 ratioApplied, uint256 oldIndex, uint256 newEpoch, bool epochAdvanced)
    {
        uint256 oldEpoch = _packedEpoch(packedOld, indexBits);
        oldIndex = _packedIndex(packedOld, indexMask);

        if (packedOld == 0) {
            oldEpoch = 0;
            oldIndex = ONE_Q128;
        }
        if (oldIndex == 0) {
            oldEpoch += 1;
            oldIndex = ONE_Q128;
        }

        newEpoch = oldEpoch;
        uint256 newIndex;

        if (ratioWanted == 0) {
            newEpoch += 1;
            newIndex = ONE_Q128;
        } else {
            newIndex = FixedPointMath.mulQ128(oldIndex, ratioWanted);
        }

        epochAdvanced = newEpoch > oldEpoch;
        packedNew = _packWeight(newEpoch, newIndex, indexBits);
        ratioApplied = epochAdvanced ? 0 : FixedPointMath.divQ128(newIndex, oldIndex);
    }

    /// @dev Converts an applied survival ratio into the realized amount removed from `totalAmount`.
    function _effectiveAppliedAmount(uint256 totalAmount, uint256 ratioApplied) internal pure returns (uint256) {
        uint256 remainingAmount = FixedPointMath.mulQ128(totalAmount, ratioApplied);
        return totalAmount - remainingAmount;
    }

    /// @dev Extracts the epoch portion from a packed weight.
    function _packedEpoch(uint256 packed, uint256 indexBits)
        internal
        pure
        virtual
        override
        returns (uint256)
    {
        return packed >> indexBits;
    }

    /// @dev Extracts the index portion from a packed weight.
    function _packedIndex(uint256 packed, uint256 indexMask)
        internal
        pure
        virtual
        override
        returns (uint256)
    {
        return packed & indexMask;
    }

    /// @dev Packs an epoch and index into a single weight word.
    function _packWeight(uint256 epoch, uint256 index, uint256 indexBits) internal pure returns (uint256) {
        return (epoch << indexBits) | index;
    }
}
