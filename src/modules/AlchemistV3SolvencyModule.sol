// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./AlchemistV3ViewModule.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {IVaultV2} from "../../lib/vault-v2/src/interfaces/IVaultV2.sol";

abstract contract AlchemistV3SolvencyModule is AlchemistV3ViewModule {
    function _calculateUnrealizedDebt(uint256 tokenId)
        internal
        view
        virtual
        returns (uint256, uint256, uint256);

    function convertYieldTokensToDebt(uint256 amount) public view virtual returns (uint256) {
        return normalizeUnderlyingTokensToDebt(convertYieldTokensToUnderlying(amount));
    }

    function convertDebtTokensToYield(uint256 amount) public view virtual returns (uint256) {
        return convertUnderlyingTokensToYield(normalizeDebtTokensToUnderlying(amount));
    }

    function convertYieldTokensToUnderlying(uint256 amount) public view virtual returns (uint256) {
        return IVaultV2(myt).convertToAssets(amount);
    }

    function convertUnderlyingTokensToYield(uint256 amount) public view virtual returns (uint256) {
        return IVaultV2(myt).convertToShares(amount);
    }

    function normalizeUnderlyingTokensToDebt(uint256 amount) public view virtual returns (uint256) {
        return amount * underlyingConversionFactor;
    }

    function normalizeDebtTokensToUnderlying(uint256 amount) public view virtual returns (uint256) {
        return amount / underlyingConversionFactor;
    }

    /// @dev Checks if the account is healthy
    /// @dev An account is healthy if its collateralization ratio is greater than the collateralization lower bound
    /// @dev An account is healthy if it has no debt
    /// @param accountId The tokenId of the account to check.
    /// @param refresh Whether to refresh the account's collateral value by including unrealized debt.
    /// @return true if the account is healthy, false otherwise.
    function _isAccountHealthy(uint256 accountId, bool refresh) internal view returns (bool) {
        if (_accounts[accountId].debt == 0) {
            return true;
        }
        uint256 collateralValue = _collateralValueInDebt(_accountCollateralBalance(accountId, refresh));
        return _isDebtHealthyAtBound(_accounts[accountId].debt, collateralValue, collateralizationLowerBound);
    }

    /// @dev Returns true only if the account is undercollateralized at minimum collateralization.
    ///
    /// @param tokenId The id of the account owner.
    function _isUnderCollateralized(uint256 tokenId) internal view virtual override returns (bool) {
        uint256 debt = _accounts[tokenId].debt;
        if (debt == 0) return false;

        uint256 collateralValue = _collateralValueInDebt(_accountCollateralBalance(tokenId, true));
        return !_meetsCollateralization(debt, collateralValue, minimumCollateralization);
    }

    function _getAccountView(uint256 tokenId)
        internal
        view
        virtual
        override
        returns (uint256 debt, uint256 earmarked, uint256 collateral)
    {
        return _calculateUnrealizedDebt(tokenId);
    }

    function _accountCollateralBalance(uint256 tokenId, bool includeUnrealizedDebt)
        internal
        view
        virtual
        override
        returns (uint256 collateral)
    {
        if (!includeUnrealizedDebt) {
            return _accounts[tokenId].collateralBalance;
        }

        (,, collateral) = _getAccountView(tokenId);
    }

    function _collateralValueInDebt(uint256 collateralBalance) internal view virtual override returns (uint256) {
        return convertYieldTokensToDebt(collateralBalance);
    }

    function _lockedCollateralForDebt(uint256 debt) internal view returns (uint256) {
        if (debt == 0) return 0;
        uint256 debtShares = convertDebtTokensToYield(debt);
        return FixedPointMath.mulDivUp(debtShares, minimumCollateralization, FIXED_POINT_SCALAR);
    }

    function _maxBorrowableFromState(uint256 debt, uint256 collateral) internal view virtual override returns (uint256) {
        uint256 capacity = _collateralValueInDebt(collateral) * FIXED_POINT_SCALAR / minimumCollateralization;
        return debt > capacity ? 0 : capacity - debt;
    }

    function _maxWithdrawableFromState(uint256 debt, uint256 collateral) internal view virtual override returns (uint256) {
        uint256 lockedCollateral = _lockedCollateralForDebt(debt);
        uint256 positionFree = collateral > lockedCollateral ? collateral - lockedCollateral : 0;
        uint256 globalFree = _availableProtocolShares();
        return positionFree < globalFree ? positionFree : globalFree;
    }

    function _requiredCollateralValue(uint256 debt, uint256 collateralization) internal pure returns (uint256) {
        return FixedPointMath.mulDivUp(debt, collateralization, FIXED_POINT_SCALAR);
    }

    function _meetsCollateralization(uint256 debt, uint256 collateralValue, uint256 collateralization)
        internal
        pure
        returns (bool)
    {
        return collateralValue >= _requiredCollateralValue(debt, collateralization);
    }

    function _isDebtHealthyAtBound(uint256 debt, uint256 collateralValue, uint256 lowerBound) internal pure returns (bool) {
        return collateralValue * FIXED_POINT_SCALAR / debt > lowerBound;
    }

    /// @dev Returns the underlying value of MYT shares currently tracked by the Alchemist.
    function _getTotalUnderlyingValue() internal view virtual override returns (uint256 totalUnderlyingValue) {
        return _underlyingValueForShares(_mytSharesDeposited);
    }

    /// @dev Returns the underlying value of globally required locked shares, capped by held shares.
    function _getTotalLockedUnderlyingValue() internal view virtual override returns (uint256) {
        return _underlyingValueForShares(_lockedProtocolShares());
    }

    /// @dev Returns true if issued synthetics exceed protocol backing used by redemption haircut logic.
    ///      Backing is locked collateral in the Alchemist plus MYT shares currently held by the Transmuter.
    function _isProtocolInBadDebt() internal view virtual override returns (bool) {
        if (totalSyntheticsIssued == 0) return false;

        return totalSyntheticsIssued > _protocolBackingDebtValue();
    }

    /// @dev Returns the MYT shares required to collateralize current total debt at minimum collateralization.
    function _requiredLockedShares() internal view returns (uint256) {
        return _lockedCollateralForDebt(totalDebt);
    }

    function _underlyingValueForShares(uint256 shares) internal view returns (uint256) {
        return convertYieldTokensToUnderlying(shares);
    }

    function _transmuterSharesBalance() internal view returns (uint256) {
        return TokenUtils.safeBalanceOf(myt, address(transmuter));
    }

    function _lockedProtocolShares() internal view returns (uint256) {
        uint256 required = _requiredLockedShares();
        return required > _mytSharesDeposited ? _mytSharesDeposited : required;
    }

    function _availableProtocolShares() internal view returns (uint256) {
        return _mytSharesDeposited - _lockedProtocolShares();
    }

    function _protocolBackingUnderlyingValue() internal view returns (uint256) {
        return _getTotalLockedUnderlyingValue() + _underlyingValueForShares(_transmuterSharesBalance());
    }

    function _protocolBackingDebtValue() internal view returns (uint256) {
        return normalizeUnderlyingTokensToDebt(_protocolBackingUnderlyingValue());
    }

    function _globalCollateralization() internal view returns (uint256) {
        if (totalDebt == 0) return type(uint256).max;
        return normalizeUnderlyingTokensToDebt(_getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / totalDebt;
    }
}
