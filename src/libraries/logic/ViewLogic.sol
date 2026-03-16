// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../interfaces/IAlchemistV3.sol";
import {StateLogic} from "./StateLogic.sol";
import {SyncLogic} from "./SyncLogic.sol";

library ViewLogic {
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

    function getTotalDeposited(uint256 totalDeposited) internal pure returns (uint256) {
        return totalDeposited;
    }

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

    function mintAllowance(mapping(uint256 => Account) storage accounts, uint256 ownerTokenId, address spender)
        internal
        view
        returns (uint256)
    {
        Account storage account = accounts[ownerTokenId];
        return account.mintAllowances[account.allowancesVersion][spender];
    }

    function getTotalUnderlyingValue(address myt, uint256 totalDeposited) internal view returns (uint256) {
        return StateLogic.getTotalUnderlyingValue(myt, totalDeposited);
    }

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

    function getUnrealizedCumulativeEarmarked(uint256 totalDebt, uint256 cumulativeEarmarked, uint256 effectiveEarmarked)
        internal
        pure
        returns (uint256)
    {
        if (totalDebt == 0) return 0;
        return cumulativeEarmarked + effectiveEarmarked;
    }
}
