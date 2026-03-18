// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../interfaces/IAlchemistV3.sol";
import {StateLogic} from "./StateLogic.sol";
import {SyncLogic} from "./SyncLogic.sol";

/// @dev Read-only helpers for projecting account and protocol state.
library ViewLogic {
    /// @dev Returns the fully projected account debt, earmark state, and collateral balance.
    function accountView(
        mapping(uint256 => Account) storage accounts,
        uint256 tokenId,
        SyncLogic.GlobalSyncState memory syncState,
        uint256 simulatedEarmarkWeight,
        mapping(uint256 => uint256) storage earmarkEpochStartRedemptionWeight,
        mapping(uint256 => uint256) storage earmarkEpochStartSurvivalAccumulator
    ) internal view returns (uint256 debt, uint256 earmarked, uint256 collateral) {
        return SyncLogic.calculateUnrealizedDebt(
            accounts[tokenId],
            syncState,
            simulatedEarmarkWeight,
            earmarkEpochStartRedemptionWeight,
            earmarkEpochStartSurvivalAccumulator
        );
    }

    /// @dev Formats the projected account view into the `getCDP` return order.
    function getCDP(
        mapping(uint256 => Account) storage accounts,
        uint256 tokenId,
        SyncLogic.GlobalSyncState memory syncState,
        uint256 simulatedEarmarkWeight,
        mapping(uint256 => uint256) storage earmarkEpochStartRedemptionWeight,
        mapping(uint256 => uint256) storage earmarkEpochStartSurvivalAccumulator
    ) internal view returns (uint256 collateral, uint256 debt, uint256 earmarked) {
        (debt, earmarked, collateral) = accountView(
            accounts,
            tokenId,
            syncState,
            simulatedEarmarkWeight,
            earmarkEpochStartRedemptionWeight,
            earmarkEpochStartSurvivalAccumulator
        );
    }

    /// @dev Returns the tracked total deposited shares unchanged.
    function getTotalDeposited(uint256 totalDeposited) internal pure returns (uint256) {
        return totalDeposited;
    }

    /// @dev Computes the additional debt a position can safely mint against its current collateral.
    function getMaxBorrowable(
        mapping(uint256 => Account) storage accounts,
        uint256 tokenId,
        SyncLogic.GlobalSyncState memory syncState,
        uint256 simulatedEarmarkWeight,
        mapping(uint256 => uint256) storage earmarkEpochStartRedemptionWeight,
        mapping(uint256 => uint256) storage earmarkEpochStartSurvivalAccumulator,
        address myt,
        uint256 underlyingConversionFactor,
        uint256 minimumCollateralization,
        uint256 fixedPointScalar
    ) internal view returns (uint256) {
        (uint256 debt,, uint256 collateral) = accountView(
            accounts,
            tokenId,
            syncState,
            simulatedEarmarkWeight,
            earmarkEpochStartRedemptionWeight,
            earmarkEpochStartSurvivalAccumulator
        );
        return StateLogic.maxBorrowableFromState(
            myt,
            underlyingConversionFactor,
            debt,
            collateral,
            minimumCollateralization,
            fixedPointScalar
        );
    }

    /// @dev Computes the maximum shares a position can withdraw while respecting local and global constraints.
    function getMaxWithdrawable(
        mapping(uint256 => Account) storage accounts,
        uint256 tokenId,
        SyncLogic.GlobalSyncState memory syncState,
        uint256 simulatedEarmarkWeight,
        mapping(uint256 => uint256) storage earmarkEpochStartRedemptionWeight,
        mapping(uint256 => uint256) storage earmarkEpochStartSurvivalAccumulator,
        address myt,
        uint256 underlyingConversionFactor,
        uint256 minimumCollateralization,
        uint256 fixedPointScalar,
        uint256 totalDebt,
        uint256 totalDeposited
    ) internal view returns (uint256) {
        (uint256 debt,, uint256 collateral) = accountView(
            accounts,
            tokenId,
            syncState,
            simulatedEarmarkWeight,
            earmarkEpochStartRedemptionWeight,
            earmarkEpochStartSurvivalAccumulator
        );
        return StateLogic.maxWithdrawableFromState(
            myt,
            underlyingConversionFactor,
            debt,
            collateral,
            minimumCollateralization,
            fixedPointScalar,
            totalDebt,
            totalDeposited
        );
    }

    /// @dev Reads the active mint allowance for `spender` on `ownerTokenId`.
    function mintAllowance(mapping(uint256 => Account) storage accounts, uint256 ownerTokenId, address spender)
        internal
        view
        returns (uint256)
    {
        Account storage account = accounts[ownerTokenId];
        return account.mintAllowances[account.allowancesVersion][spender];
    }

    /// @dev Returns the underlying-denominated value of all deposited MYT shares.
    function getTotalUnderlyingValue(address myt, uint256 totalDeposited) internal view returns (uint256) {
        return StateLogic.getTotalUnderlyingValue(myt, totalDeposited);
    }

    /// @dev Returns the underlying-denominated value of the shares required to back outstanding debt.
    function getTotalLockedUnderlyingValue(
        address myt,
        uint256 underlyingConversionFactor,
        uint256 totalDebt,
        uint256 totalDeposited,
        uint256 minimumCollateralization,
        uint256 fixedPointScalar
    ) internal view returns (uint256) {
        return StateLogic.getTotalLockedUnderlyingValue(
            myt,
            underlyingConversionFactor,
            totalDebt,
            totalDeposited,
            minimumCollateralization,
            fixedPointScalar
        );
    }

    /// @dev Returns the debt-denominated collateral value of a position after projecting unrealized state.
    function totalValue(
        mapping(uint256 => Account) storage accounts,
        uint256 tokenId,
        SyncLogic.GlobalSyncState memory syncState,
        uint256 simulatedEarmarkWeight,
        mapping(uint256 => uint256) storage earmarkEpochStartRedemptionWeight,
        mapping(uint256 => uint256) storage earmarkEpochStartSurvivalAccumulator,
        address myt,
        uint256 underlyingConversionFactor
    ) internal view returns (uint256) {
        (,, uint256 collateral) = accountView(
            accounts,
            tokenId,
            syncState,
            simulatedEarmarkWeight,
            earmarkEpochStartRedemptionWeight,
            earmarkEpochStartSurvivalAccumulator
        );
        return StateLogic.collateralValueInDebt(myt, underlyingConversionFactor, collateral);
    }

    /// @dev Returns cumulative earmarked debt including the pending simulated earmark window.
    function getUnrealizedCumulativeEarmarked(uint256 totalDebt, uint256 cumulativeEarmarked, uint256 effectiveEarmarked)
        internal
        pure
        returns (uint256)
    {
        if (totalDebt == 0) return 0;
        return cumulativeEarmarked + effectiveEarmarked;
    }
}
