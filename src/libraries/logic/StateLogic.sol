// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../interfaces/IAlchemistV3.sol";
import "../../interfaces/ITransmuter.sol";
import "../../libraries/FixedPointMath.sol";
import "../../libraries/TokenUtils.sol";
import {IVaultV2} from "../../../lib/vault-v2/src/interfaces/IVaultV2.sol";

library StateLogic {
    function convertYieldTokensToUnderlying(address myt, uint256 amount) internal view returns (uint256) {
        return IVaultV2(myt).convertToAssets(amount);
    }

    function convertUnderlyingTokensToYield(address myt, uint256 amount) internal view returns (uint256) {
        return IVaultV2(myt).convertToShares(amount);
    }

    function normalizeUnderlyingTokensToDebt(uint256 amount, uint256 underlyingConversionFactor)
        internal
        pure
        returns (uint256)
    {
        return amount * underlyingConversionFactor;
    }

    function normalizeDebtTokensToUnderlying(uint256 amount, uint256 underlyingConversionFactor)
        internal
        pure
        returns (uint256)
    {
        return amount / underlyingConversionFactor;
    }

    function convertYieldTokensToDebt(address myt, uint256 underlyingConversionFactor, uint256 amount)
        internal
        view
        returns (uint256)
    {
        return normalizeUnderlyingTokensToDebt(convertYieldTokensToUnderlying(myt, amount), underlyingConversionFactor);
    }

    function convertDebtTokensToYield(address myt, uint256 underlyingConversionFactor, uint256 amount)
        internal
        view
        returns (uint256)
    {
        return convertUnderlyingTokensToYield(myt, normalizeDebtTokensToUnderlying(amount, underlyingConversionFactor));
    }

    function collateralValueInDebt(address myt, uint256 underlyingConversionFactor, uint256 collateralBalance)
        internal
        view
        returns (uint256)
    {
        return convertYieldTokensToDebt(myt, underlyingConversionFactor, collateralBalance);
    }

    function lockedCollateralForDebt(
        address myt,
        uint256 underlyingConversionFactor,
        uint256 debt,
        uint256 minimumCollateralization,
        uint256 fixedPointScalar
    ) internal view returns (uint256) {
        if (debt == 0) return 0;
        uint256 debtShares = convertDebtTokensToYield(myt, underlyingConversionFactor, debt);
        return FixedPointMath.mulDivUp(debtShares, minimumCollateralization, fixedPointScalar);
    }

    function maxBorrowableFromState(
        address myt,
        uint256 underlyingConversionFactor,
        uint256 debt,
        uint256 collateral,
        uint256 minimumCollateralization,
        uint256 fixedPointScalar
    ) internal view returns (uint256) {
        uint256 capacity = collateralValueInDebt(myt, underlyingConversionFactor, collateral) * fixedPointScalar
            / minimumCollateralization;
        return debt > capacity ? 0 : capacity - debt;
    }

    function maxWithdrawableFromState(
        address myt,
        uint256 underlyingConversionFactor,
        uint256 debt,
        uint256 collateral,
        uint256 minimumCollateralization,
        uint256 fixedPointScalar,
        uint256 totalDebt,
        uint256 totalDeposited
    ) internal view returns (uint256) {
        uint256 lockedCollateral = lockedCollateralForDebt(
            myt, underlyingConversionFactor, debt, minimumCollateralization, fixedPointScalar
        );
        uint256 positionFree = collateral > lockedCollateral ? collateral - lockedCollateral : 0;
        uint256 globalFree = availableProtocolShares(
            myt, underlyingConversionFactor, totalDebt, totalDeposited, minimumCollateralization, fixedPointScalar
        );
        return positionFree < globalFree ? positionFree : globalFree;
    }

    function requiredCollateralValue(uint256 debt, uint256 collateralization, uint256 fixedPointScalar)
        internal
        pure
        returns (uint256)
    {
        return FixedPointMath.mulDivUp(debt, collateralization, fixedPointScalar);
    }

    function meetsCollateralization(uint256 debt, uint256 collateralValue, uint256 collateralization, uint256 fixedPointScalar)
        internal
        pure
        returns (bool)
    {
        return collateralValue >= requiredCollateralValue(debt, collateralization, fixedPointScalar);
    }

    function isDebtHealthyAtBound(uint256 debt, uint256 collateralValue, uint256 lowerBound, uint256 fixedPointScalar)
        internal
        pure
        returns (bool)
    {
        return collateralValue * fixedPointScalar / debt > lowerBound;
    }

    function underlyingValueForShares(address myt, uint256 shares) internal view returns (uint256) {
        return convertYieldTokensToUnderlying(myt, shares);
    }

    function transmuterSharesBalance(address myt, address transmuter) internal view returns (uint256) {
        return TokenUtils.safeBalanceOf(myt, transmuter);
    }

    function requiredLockedShares(
        address myt,
        uint256 underlyingConversionFactor,
        uint256 totalDebt,
        uint256 minimumCollateralization,
        uint256 fixedPointScalar
    ) internal view returns (uint256) {
        return lockedCollateralForDebt(
            myt, underlyingConversionFactor, totalDebt, minimumCollateralization, fixedPointScalar
        );
    }

    function lockedProtocolShares(
        address myt,
        uint256 underlyingConversionFactor,
        uint256 totalDebt,
        uint256 totalDeposited,
        uint256 minimumCollateralization,
        uint256 fixedPointScalar
    ) internal view returns (uint256) {
        uint256 required = requiredLockedShares(
            myt, underlyingConversionFactor, totalDebt, minimumCollateralization, fixedPointScalar
        );
        return required > totalDeposited ? totalDeposited : required;
    }

    function availableProtocolShares(
        address myt,
        uint256 underlyingConversionFactor,
        uint256 totalDebt,
        uint256 totalDeposited,
        uint256 minimumCollateralization,
        uint256 fixedPointScalar
    ) internal view returns (uint256) {
        return totalDeposited
            - lockedProtocolShares(
                myt, underlyingConversionFactor, totalDebt, totalDeposited, minimumCollateralization, fixedPointScalar
            );
    }

    function getTotalUnderlyingValue(address myt, uint256 totalDeposited) internal view returns (uint256) {
        return underlyingValueForShares(myt, totalDeposited);
    }

    function getTotalLockedUnderlyingValue(
        address myt,
        uint256 underlyingConversionFactor,
        uint256 totalDebt,
        uint256 totalDeposited,
        uint256 minimumCollateralization,
        uint256 fixedPointScalar
    ) internal view returns (uint256) {
        return underlyingValueForShares(
            myt,
            lockedProtocolShares(
                myt, underlyingConversionFactor, totalDebt, totalDeposited, minimumCollateralization, fixedPointScalar
            )
        );
    }

    function protocolBackingUnderlyingValue(
        address myt,
        address transmuter,
        uint256 underlyingConversionFactor,
        uint256 totalDebt,
        uint256 totalDeposited,
        uint256 minimumCollateralization,
        uint256 fixedPointScalar
    ) internal view returns (uint256) {
        return getTotalLockedUnderlyingValue(
            myt, underlyingConversionFactor, totalDebt, totalDeposited, minimumCollateralization, fixedPointScalar
        ) + underlyingValueForShares(myt, transmuterSharesBalance(myt, transmuter));
    }

    function protocolBackingDebtValue(
        address myt,
        address transmuter,
        uint256 underlyingConversionFactor,
        uint256 totalDebt,
        uint256 totalDeposited,
        uint256 minimumCollateralization,
        uint256 fixedPointScalar
    ) internal view returns (uint256) {
        return normalizeUnderlyingTokensToDebt(
            protocolBackingUnderlyingValue(
                myt,
                transmuter,
                underlyingConversionFactor,
                totalDebt,
                totalDeposited,
                minimumCollateralization,
                fixedPointScalar
            ),
            underlyingConversionFactor
        );
    }

    function isProtocolInBadDebt(
        address myt,
        address transmuter,
        uint256 underlyingConversionFactor,
        uint256 totalDebt,
        uint256 totalDeposited,
        uint256 totalSyntheticsIssued,
        uint256 minimumCollateralization,
        uint256 fixedPointScalar
    ) internal view returns (bool) {
        if (totalSyntheticsIssued == 0) return false;
        return totalSyntheticsIssued
            > protocolBackingDebtValue(
                myt,
                transmuter,
                underlyingConversionFactor,
                totalDebt,
                totalDeposited,
                minimumCollateralization,
                fixedPointScalar
            );
    }

    function globalCollateralization(
        address myt,
        uint256 underlyingConversionFactor,
        uint256 totalDebt,
        uint256 totalDeposited,
        uint256 fixedPointScalar
    ) internal view returns (uint256) {
        if (totalDebt == 0) return type(uint256).max;
        return normalizeUnderlyingTokensToDebt(getTotalUnderlyingValue(myt, totalDeposited), underlyingConversionFactor)
            * fixedPointScalar / totalDebt;
    }

    function queryGraph(address transmuter, uint256 lastEarmarkBlock, uint256 blockNumber)
        internal
        view
        returns (uint256)
    {
        return ITransmuter(transmuter).queryGraph(lastEarmarkBlock + 1, blockNumber);
    }
}
