// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../TokenUtils.sol";
import {EarmarkLogic} from "./EarmarkLogic.sol";
import {StateLogic} from "./StateLogic.sol";

/// @dev Redemption flows that move earmarked debt into transmuter payouts.
library RedemptionLogic {
    /// @dev Inputs required to execute a redemption against the live earmark state.
    struct RedeemParams {
        address myt;
        address transmuter;
        address protocolFeeReceiver;
        uint256 underlyingConversionFactor;
        uint256 amount;
        uint256 totalDeposited;
        uint256 totalRedeemedDebt;
        uint256 totalRedeemedSharesOut;
        uint256 protocolFee;
        uint256 bps;
    }

    /// @dev State updates produced by a redemption.
    struct RedeemResult {
        uint256 sharesSent;
        uint256 effectiveRedeemed;
        uint256 newLastRedemptionBlock;
        uint256 newTotalDeposited;
        uint256 newTotalRedeemedDebt;
        uint256 newTotalRedeemedSharesOut;
        uint256 newTotalDebt;
        uint256 newCumulativeEarmarked;
        uint256 newLastEarmarkBlock;
        uint256 newLastTransmuterTokenBalance;
        uint256 newPendingCoverShares;
        uint256 newEarmarkWeight;
        uint256 newRedemptionWeight;
        uint256 newSurvivalAccumulator;
        uint256 epochStartSurvivalAccumulator;
        uint256 epochBoundary;
        bool epochAdvanced;
    }

    /// @dev Commits pending earmarks, applies the redemption window, and transfers redeemed collateral.
    function redeem(RedeemParams memory params, EarmarkLogic.State memory state)
        internal
        returns (RedeemResult memory result)
    {
        EarmarkLogic.CommitResult memory commit = EarmarkLogic.commitFromGraph(
            state, params.transmuter, params.myt, params.underlyingConversionFactor, block.number
        );

        result.newLastTransmuterTokenBalance = commit.lastTransmuterTokenBalance;
        result.newPendingCoverShares = commit.pendingCoverShares;
        result.newLastEarmarkBlock = commit.lastEarmarkBlock;
        result.newEarmarkWeight = commit.earmarkWeight;
        result.epochAdvanced = commit.epochAdvanced;
        result.epochBoundary = commit.epochBoundary;
        result.epochStartSurvivalAccumulator = commit.survivalAccumulator;

        uint256 liveEarmarked = commit.cumulativeEarmarked;
        if (params.amount > liveEarmarked) params.amount = liveEarmarked;

        EarmarkLogic.State memory committedState = EarmarkLogic.state(
            state.totalDebt,
            commit.cumulativeEarmarked,
            commit.lastEarmarkBlock,
            commit.lastTransmuterTokenBalance,
            commit.pendingCoverShares,
            commit.earmarkWeight,
            state.redemptionWeight,
            commit.survivalAccumulator,
            state.oneQ128,
            state.redemptionIndexBits,
            state.redemptionIndexMask,
            state.earmarkIndexBits,
            state.earmarkIndexMask
        );

        EarmarkLogic.RedemptionWindowResult memory redemption =
            EarmarkLogic.applyRedemptionWindow(committedState, liveEarmarked, params.amount);
        result.effectiveRedeemed = redemption.effectiveRedeemed;
        result.newLastRedemptionBlock = block.number;
        result.newTotalDebt = redemption.totalDebt;
        result.newCumulativeEarmarked = redemption.cumulativeEarmarked;
        result.newRedemptionWeight = redemption.redemptionWeight;
        result.newSurvivalAccumulator = redemption.survivalAccumulator;

        uint256 collRedeemed =
            StateLogic.convertDebtTokensToYield(params.myt, params.underlyingConversionFactor, result.effectiveRedeemed);
        uint256 feeCollateral = collRedeemed * params.protocolFee / params.bps;

        // Use the effective redeemed amount everywhere downstream.
        result.newTotalRedeemedDebt = params.totalRedeemedDebt + result.effectiveRedeemed;
        result.newTotalRedeemedSharesOut = params.totalRedeemedSharesOut + collRedeemed;

        TokenUtils.safeTransfer(params.myt, params.transmuter, collRedeemed);
        result.newTotalDeposited = params.totalDeposited - collRedeemed;

        if (feeCollateral <= result.newTotalDeposited) {
            TokenUtils.safeTransfer(params.myt, params.protocolFeeReceiver, feeCollateral);
            result.newTotalDeposited -= feeCollateral;
            result.newTotalRedeemedSharesOut += feeCollateral;
        }

        result.sharesSent = collRedeemed;
    }

    /// @dev Decrements the protocol's issued synthetic total after a redemption burn.
    function reduceSyntheticsIssued(uint256 totalSyntheticsIssued, uint256 amount)
        internal
        pure
        returns (uint256)
    {
        return totalSyntheticsIssued - amount;
    }

    /// @dev Reconciles the transmuter balance tracker and pending cover after an external balance update.
    function setTransmuterTokenBalance(uint256 lastTransmuterTokenBalance, uint256 pendingCoverShares, uint256 amount)
        internal
        pure
        returns (uint256 newLastTransmuterTokenBalance, uint256 newPendingCoverShares)
    {
        newPendingCoverShares = pendingCoverShares;

        if (amount < lastTransmuterTokenBalance) {
            uint256 spent = lastTransmuterTokenBalance - amount;

            if (spent >= newPendingCoverShares) {
                newPendingCoverShares = 0;
            } else {
                newPendingCoverShares -= spent;
            }
        }

        if (newPendingCoverShares > amount) {
            newPendingCoverShares = amount;
        }

        newLastTransmuterTokenBalance = amount;
    }
}
