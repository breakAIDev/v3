// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./AlchemistV3SolvencyModule.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";

abstract contract AlchemistV3SyncModule is AlchemistV3SolvencyModule {
    function _earmark() internal virtual;

    function _earmarkSurvivalRatio(uint256 oldPacked, uint256 newPacked) internal pure virtual returns (uint256);

    function _redemptionSurvivalRatio(uint256 oldPacked, uint256 newPacked) internal pure virtual returns (uint256);

    function _packedIndex(uint256 packed, uint256 indexMask) internal pure virtual returns (uint256);

    function _packedEpoch(uint256 packed, uint256 indexBits) internal pure virtual returns (uint256);

    function _earmarkAndSyncAccount(uint256 tokenId, bool enforceNoBadDebt) internal {
        _earmark();
        if (enforceNoBadDebt) {
            _checkState(!_isProtocolInBadDebt());
        }
        _sync(tokenId);
    }

    /// @dev Pokes the account owned by `tokenId` to realize committed global accounting.
    /// @param tokenId The tokenId of the account to poke.
    function _poke(uint256 tokenId) internal {
        _earmarkAndSyncAccount(tokenId, false);
    }

    /// @dev Realizes committed global earmark/redemption state for an account.
    function _sync(uint256 tokenId) internal {
        Account storage account = _accounts[tokenId];
        (uint256 newDebt, uint256 newEarmarked, uint256 collateralBalance,) = _computeCommittedAccountState(account);

        account.collateralBalance = collateralBalance;
        account.earmarked = newEarmarked;
        account.debt = newDebt;
        _checkpointAccountState(account);
    }

    /// @dev Computes account state against committed globals only.
    /// @return newDebt The debt after applying committed earmark + redemption.
    /// @return newEarmarked The earmarked portion after applying committed globals.
    /// @return collateralBalance The collateral after realized redemption debits.
    /// @return redeemedDebt The debt redeemed from committed global state.
    function _computeCommittedAccountState(Account storage account)
        internal
        view
        returns (uint256 newDebt, uint256 newEarmarked, uint256 collateralBalance, uint256 redeemedDebt)
    {
        (newDebt, newEarmarked, redeemedDebt) =
            _computeUnrealizedAccount(account, _earmarkWeight, _redemptionWeight, _survivalAccumulator);
        collateralBalance = _applyRedeemedCollateralDelta(account, account.collateralBalance, redeemedDebt);
    }

    /// @dev Applies realized collateral debits from redemptions and protocol fees.
    function _applyRedeemedCollateralDelta(
        Account storage account,
        uint256 collateralBalance,
        uint256 redeemedDebt
    ) internal view returns (uint256) {
        uint256 globalDebtDelta = _totalRedeemedDebt - account.lastTotalRedeemedDebt;
        if (globalDebtDelta == 0 || redeemedDebt == 0) {
            return collateralBalance;
        }

        uint256 globalSharesDelta = _totalRedeemedSharesOut - account.lastTotalRedeemedSharesOut;
        uint256 sharesToDebit = FixedPointMath.mulDivUp(redeemedDebt, globalSharesDelta, globalDebtDelta);
        if (sharesToDebit > collateralBalance) sharesToDebit = collateralBalance;
        return collateralBalance - sharesToDebit;
    }

    /// @dev Applies one simulated, uncommitted earmark window on top of committed account state.
    function _applyProspectiveEarmark(
        uint256 debt,
        uint256 earmarked,
        uint256 committedEarmarkWeight,
        uint256 simulatedEarmarkWeight
    ) internal pure returns (uint256) {
        if (simulatedEarmarkWeight == committedEarmarkWeight) {
            return earmarked;
        }

        uint256 exposure = debt > earmarked ? debt - earmarked : 0;
        if (exposure == 0) {
            return earmarked;
        }

        uint256 unearmarkedRatio = _earmarkSurvivalRatio(committedEarmarkWeight, simulatedEarmarkWeight);
        uint256 unearmarkedRemaining = FixedPointMath.mulQ128(exposure, unearmarkedRatio);
        uint256 newlyEarmarked = exposure - unearmarkedRemaining;
        earmarked += newlyEarmarked;
        return earmarked > debt ? debt : earmarked;
    }

    /// @dev Computes account debt and earmark state at a given global weight snapshot.
    /// @return newDebt The debt after applying earmark + redemption.
    /// @return newEarmarked The earmarked portion after applying survival and new earmarks.
    /// @return redeemedDebt Realized redeemed debt for this step.
    function _computeUnrealizedAccount(
        Account storage account,
        uint256 earmarkWeightCurrent,
        uint256 redemptionWeightCurrent,
        uint256 survivalAccumulatorCurrent
    ) internal view returns (uint256 newDebt, uint256 newEarmarked, uint256 redeemedDebt) {
        uint256 survivalRatio = _redemptionSurvivalRatio(account.lastAccruedRedemptionWeight, redemptionWeightCurrent);

        uint256 userExposure = account.debt > account.earmarked ? account.debt - account.earmarked : 0;
        uint256 unearmarkSurvivalRatio =
            _earmarkSurvivalRatio(account.lastAccruedEarmarkWeight, earmarkWeightCurrent);

        uint256 unearmarkedRemaining = FixedPointMath.mulQ128(userExposure, unearmarkSurvivalRatio);
        uint256 earmarkRaw = userExposure - unearmarkedRemaining;

        if (survivalRatio == ONE_Q128) {
            newDebt = account.debt;
            newEarmarked = account.earmarked + earmarkRaw;
            if (newEarmarked > newDebt) newEarmarked = newDebt;
            redeemedDebt = 0;
            return (newDebt, newEarmarked, redeemedDebt);
        }

        uint256 earmarkSurvival = _packedIndex(account.lastAccruedEarmarkWeight, _EARMARK_INDEX_MASK);
        if (earmarkSurvival == 0) earmarkSurvival = ONE_Q128;

        uint256 decayedRedeemed = FixedPointMath.mulQ128(account.lastSurvivalAccumulator, survivalRatio);
        uint256 survivalDiff = survivalAccumulatorCurrent > decayedRedeemed ? survivalAccumulatorCurrent - decayedRedeemed : 0;
        if (survivalDiff > earmarkSurvival) survivalDiff = earmarkSurvival;
        uint256 unredeemedRatio = FixedPointMath.divQ128(survivalDiff, earmarkSurvival);
        uint256 earmarkedUnredeemed = FixedPointMath.mulQ128(userExposure, unredeemedRatio);

        uint256 oldEarEpoch = _packedEpoch(account.lastAccruedEarmarkWeight, _EARMARK_INDEX_BITS);
        uint256 newEarEpoch = _packedEpoch(earmarkWeightCurrent, _EARMARK_INDEX_BITS);
        if (newEarEpoch > oldEarEpoch) {
            uint256 boundaryEpoch = oldEarEpoch + 1;
            uint256 boundaryRedemptionWeight = _earmarkEpochStartRedemptionWeight[boundaryEpoch];
            uint256 boundarySurvivalAccumulator = _earmarkEpochStartSurvivalAccumulator[boundaryEpoch];

            if (boundaryRedemptionWeight != 0) {
                uint256 preBoundarySurvival =
                    _redemptionSurvivalRatio(account.lastAccruedRedemptionWeight, boundaryRedemptionWeight);
                uint256 decayedAtBoundary = FixedPointMath.mulQ128(account.lastSurvivalAccumulator, preBoundarySurvival);

                uint256 boundaryDiff =
                    boundarySurvivalAccumulator > decayedAtBoundary ? boundarySurvivalAccumulator - decayedAtBoundary : 0;
                if (boundaryDiff > earmarkSurvival) boundaryDiff = earmarkSurvival;

                uint256 unredeemedAtBoundaryRatio = FixedPointMath.divQ128(boundaryDiff, earmarkSurvival);
                uint256 unredeemedAtBoundary = FixedPointMath.mulQ128(userExposure, unredeemedAtBoundaryRatio);

                uint256 postBoundarySurvival =
                    _redemptionSurvivalRatio(boundaryRedemptionWeight, redemptionWeightCurrent);

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

    /// @dev Returns the current account view including one simulated pending earmark window.
    ///
    /// @param tokenId The id of the account owner.
    ///
    /// @return The debt after committed redemptions plus one simulated pending earmark window.
    /// @return The debt currently earmarked for redemption after the same simulation.
    /// @return The collateral balance after committed redemption debits.
    function _calculateUnrealizedDebt(uint256 tokenId)
        internal
        view
        virtual
        override
        returns (uint256, uint256, uint256)
    {
        Account storage account = _accounts[tokenId];

        (uint256 earmarkWeightCopy,) = _simulateUnrealizedEarmark();
        (uint256 newDebt, uint256 newEarmarked, uint256 collateralBalanceCopy,) = _computeCommittedAccountState(account);

        newEarmarked = _applyProspectiveEarmark(newDebt, newEarmarked, _earmarkWeight, earmarkWeightCopy);

        return (newDebt, newEarmarked, collateralBalanceCopy);
    }
}
