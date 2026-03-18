// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../interfaces/IAlchemistV3.sol";
import "../../interfaces/ITransmuter.sol";
import "../../libraries/FixedPointMath.sol";
import "../../libraries/TokenUtils.sol";
import {IVaultV2} from "../../../lib/vault-v2/src/interfaces/IVaultV2.sol";

/// @dev Conversion and collateralization math shared across the protocol.
library StateLogic {
    /// @dev Converts MYT shares into underlying token units.
    function convertYieldTokensToUnderlying(address myt, uint256 amount) internal view returns (uint256) {
        return IVaultV2(myt).convertToAssets(amount);
    }

    /// @dev Converts underlying token units into MYT shares.
    function convertUnderlyingTokensToYield(address myt, uint256 amount) internal view returns (uint256) {
        return IVaultV2(myt).convertToShares(amount);
    }

    /// @dev Normalizes underlying-token units into debt-token units.
    function normalizeUnderlyingTokensToDebt(uint256 amount, uint256 underlyingConversionFactor)
        internal
        pure
        returns (uint256)
    {
        return amount * underlyingConversionFactor;
    }

    /// @dev Normalizes debt-token units into underlying-token units.
    function normalizeDebtTokensToUnderlying(uint256 amount, uint256 underlyingConversionFactor)
        internal
        pure
        returns (uint256)
    {
        return amount / underlyingConversionFactor;
    }

    /// @dev Converts MYT shares directly into debt-token value.
    function convertYieldTokensToDebt(address myt, uint256 underlyingConversionFactor, uint256 amount)
        internal
        view
        returns (uint256)
    {
        return normalizeUnderlyingTokensToDebt(convertYieldTokensToUnderlying(myt, amount), underlyingConversionFactor);
    }

    /// @dev Converts debt-token value into the equivalent MYT shares.
    function convertDebtTokensToYield(address myt, uint256 underlyingConversionFactor, uint256 amount)
        internal
        view
        returns (uint256)
    {
        return convertUnderlyingTokensToYield(myt, normalizeDebtTokensToUnderlying(amount, underlyingConversionFactor));
    }

    /// @dev Returns the debt-token value of a position's collateral shares.
    function collateralValueInDebt(address myt, uint256 underlyingConversionFactor, uint256 collateralBalance)
        internal
        view
        returns (uint256)
    {
        return convertYieldTokensToDebt(myt, underlyingConversionFactor, collateralBalance);
    }

    /// @dev Computes the shares that must remain locked to support `debt`.
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

    /// @dev Returns the extra debt capacity available from the provided collateral state.
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

    /// @dev Returns the shares withdrawable from a position after local and protocol-level locking.
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

    /// @dev Computes the collateral value required to support `debt` at `collateralization`.
    function requiredCollateralValue(uint256 debt, uint256 collateralization, uint256 fixedPointScalar)
        internal
        pure
        returns (uint256)
    {
        return FixedPointMath.mulDivUp(debt, collateralization, fixedPointScalar);
    }

    /// @dev Returns whether `collateralValue` is sufficient to back `debt`.
    function meetsCollateralization(uint256 debt, uint256 collateralValue, uint256 collateralization, uint256 fixedPointScalar)
        internal
        pure
        returns (bool)
    {
        return collateralValue >= requiredCollateralValue(debt, collateralization, fixedPointScalar);
    }

    /// @dev Returns whether an account remains above the liquidation lower bound.
    function isDebtHealthyAtBound(uint256 debt, uint256 collateralValue, uint256 lowerBound, uint256 fixedPointScalar)
        internal
        pure
        returns (bool)
    {
        return collateralValue * fixedPointScalar / debt > lowerBound;
    }

    /// @dev Returns the underlying-token value of `shares`.
    function underlyingValueForShares(address myt, uint256 shares) internal view returns (uint256) {
        return convertYieldTokensToUnderlying(myt, shares);
    }

    /// @dev Returns the MYT shares currently held by the transmuter.
    function transmuterSharesBalance(address myt, address transmuter) internal view returns (uint256) {
        return TokenUtils.safeBalanceOf(myt, transmuter);
    }

    /// @dev Returns the protocol shares that must remain locked against total debt.
    function requiredLockedShares(
        address myt,
        uint256 underlyingConversionFactor,
        uint256 totalDebt,
        uint256 minimumCollateralization,
        uint256 fixedPointScalar
    ) internal view returns (uint256) {
        // Calculate locked collateral based on the current share price.
        return lockedCollateralForDebt(
            myt, underlyingConversionFactor, totalDebt, minimumCollateralization, fixedPointScalar
        );
    }

    /// @dev Returns the actual protocol shares currently locked, capped by total deposits.
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

    /// @dev Returns the protocol shares available for withdrawal or fee extraction.
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

    /// @dev Returns the underlying-token value of all deposited shares.
    function getTotalUnderlyingValue(address myt, uint256 totalDeposited) internal view returns (uint256) {
        return underlyingValueForShares(myt, totalDeposited);
    }

    /// @dev Returns the underlying-token value of the shares locked against protocol debt.
    function getTotalLockedUnderlyingValue(
        address myt,
        uint256 underlyingConversionFactor,
        uint256 totalDebt,
        uint256 totalDeposited,
        uint256 minimumCollateralization,
        uint256 fixedPointScalar
    ) internal view returns (uint256) {
        // Cap locked shares by what the alchemist actually holds.
        return underlyingValueForShares(
            myt,
            lockedProtocolShares(
                myt, underlyingConversionFactor, totalDebt, totalDeposited, minimumCollateralization, fixedPointScalar
            )
        );
    }

    /// @dev Returns protocol backing in underlying units, including transmuter-held shares.
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

    /// @dev Returns protocol backing normalized into debt-token units.
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

    /// @dev Returns whether outstanding synths exceed the protocol's effective collateral backing.
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
        // Backing mirrors transmuter claim math:
        // locked collateral in the alchemist plus MYT shares currently held by the transmuter.
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

    /// @dev Returns the protocol-wide collateralization ratio in fixed-point form.
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

    /// @dev Queries the transmuter's staking graph for the latest earmark window.
    function queryGraph(address transmuter, uint256 lastEarmarkBlock, uint256 blockNumber)
        internal
        view
        returns (uint256)
    {
        return ITransmuter(transmuter).queryGraph(lastEarmarkBlock + 1, blockNumber);
    }
}
