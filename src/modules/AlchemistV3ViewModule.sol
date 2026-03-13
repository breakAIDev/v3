// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../interfaces/IAlchemistV3.sol";
import "./AlchemistV3AdminModule.sol";

abstract contract AlchemistV3ViewModule is AlchemistV3AdminModule {
    function _getAccountView(uint256 tokenId)
        internal
        view
        virtual
        returns (uint256 debt, uint256 earmarked, uint256 collateral);

    function _accountCollateralBalance(uint256 tokenId, bool includeUnrealizedDebt)
        internal
        view
        virtual
        returns (uint256 collateral);

    function _collateralValueInDebt(uint256 collateralBalance) internal view virtual returns (uint256);

    function _maxBorrowableFromState(uint256 debt, uint256 collateral) internal view virtual returns (uint256);

    function _maxWithdrawableFromState(uint256 debt, uint256 collateral) internal view virtual returns (uint256);

    function _getTotalUnderlyingValue() internal view virtual returns (uint256 totalUnderlyingValue);

    function _getTotalLockedUnderlyingValue() internal view virtual returns (uint256);

    function _simulateUnrealizedEarmark() internal view virtual returns (uint256 earmarkWeightCopy, uint256 effectiveEarmarked);

    /// @inheritdoc IAlchemistV3State
    function getCDP(uint256 tokenId) external view returns (uint256, uint256, uint256) {
        (uint256 debt, uint256 earmarked, uint256 collateral) = _getAccountView(tokenId);
        return (collateral, debt, earmarked);
    }

    /// @inheritdoc IAlchemistV3State
    function getTotalDeposited() external view returns (uint256) {
        return _mytSharesDeposited;
    }

    /// @inheritdoc IAlchemistV3State
    function getMaxBorrowable(uint256 tokenId) external view returns (uint256) {
        (uint256 debt,, uint256 collateral) = _getAccountView(tokenId);
        return _maxBorrowableFromState(debt, collateral);
    }

    /// @inheritdoc IAlchemistV3State
    function getMaxWithdrawable(uint256 tokenId) external view returns (uint256) {
        (uint256 debt,, uint256 collateral) = _getAccountView(tokenId);
        return _maxWithdrawableFromState(debt, collateral);
    }

    /// @inheritdoc IAlchemistV3State
    function mintAllowance(uint256 ownerTokenId, address spender) external view returns (uint256) {
        Account storage account = _accounts[ownerTokenId];
        return account.mintAllowances[account.allowancesVersion][spender];
    }

    /// @inheritdoc IAlchemistV3State
    function getTotalUnderlyingValue() external view returns (uint256) {
        return _getTotalUnderlyingValue();
    }

    /// @inheritdoc IAlchemistV3State
    function getTotalLockedUnderlyingValue() external view returns (uint256) {
        return _getTotalLockedUnderlyingValue();
    }

    /// @inheritdoc IAlchemistV3State
    function totalValue(uint256 tokenId) public view returns (uint256) {
        return _collateralValueInDebt(_accountCollateralBalance(tokenId, true));
    }

    /// @notice Returns cumulative earmarked debt including one simulated pending earmark window.
    function getUnrealizedCumulativeEarmarked() external view returns (uint256) {
        if (totalDebt == 0) return 0;
        (, uint256 effectiveEarmarked) = _simulateUnrealizedEarmark();
        return cumulativeEarmarked + effectiveEarmarked;
    }
}
