// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../interfaces/IAlchemistV3.sol";
import "../../base/Errors.sol";
import "../../interfaces/IFeeVault.sol";
import "../../libraries/TokenUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Validation and normalization helpers for admin configuration updates.
library ConfiguratorLogic {
    /// @dev Validates initialization parameters and computes the debt-to-underlying conversion factor.
    function initialize(AlchemistInitializationParams memory params, uint256 bps)
        internal
        view
        returns (uint256 underlyingConversionFactor)
    {
        if (params.protocolFee > bps) {
            revert IllegalArgument();
        }
        if (params.liquidatorFee > bps) {
            revert IllegalArgument();
        }
        if (params.repaymentFee > bps) {
            revert IllegalArgument();
        }
        if (params.liquidationTargetCollateralization < params.minimumCollateralization) {
            revert IllegalArgument();
        }

        underlyingConversionFactor =
            10 ** (TokenUtils.expectDecimals(params.debtToken) - TokenUtils.expectDecimals(params.underlyingToken));
    }

    /// @dev Validates the one-time position NFT assignment.
    function alchemistPositionNFT(address currentNft, address nft) internal pure returns (address) {
        if (nft == address(0)) {
            revert IAlchemistV3Errors.AlchemistV3NFTZeroAddressError();
        }

        if (currentNft != address(0)) {
            revert IAlchemistV3Errors.AlchemistV3NFTAlreadySetError();
        }

        return nft;
    }

    /// @dev Validates that the fee vault matches the alchemist's underlying token.
    function alchemistFeeVault(address value, address underlyingToken) internal view returns (address) {
        if (IFeeVault(value).token() != underlyingToken) {
            revert IAlchemistV3Errors.AlchemistVaultTokenMismatchError();
        }

        return value;
    }

    /// @dev Normalizes the pending admin value.
    function pendingAdmin(address value) internal pure returns (address) {
        return value;
    }

    /// @dev Completes the two-step admin transfer and clears the pending admin.
    function acceptAdmin(address pendingAdmin_, address caller)
        internal
        pure
        returns (address newAdmin, address newPendingAdmin)
    {
        if (pendingAdmin_ == address(0)) {
            revert IllegalState();
        }

        if (caller != pendingAdmin_) {
            revert Unauthorized();
        }

        return (pendingAdmin_, address(0));
    }

    /// @dev Ensures the new deposit cap still covers the alchemist's current MYT balance.
    function depositCap(uint256 value, address myt, address holder) internal view returns (uint256) {
        if (value < IERC20(myt).balanceOf(holder)) {
            revert IllegalArgument();
        }

        return value;
    }

    /// @dev Ensures the fee receiver is non-zero.
    function protocolFeeReceiver(address value) internal pure returns (address) {
        if (value == address(0)) {
            revert IllegalArgument();
        }

        return value;
    }

    /// @dev Validates a basis-points fee value against the configured maximum.
    function feeBps(uint256 fee, uint256 bps) internal pure returns (uint256) {
        if (fee > bps) {
            revert IllegalArgument();
        }

        return fee;
    }

    /// @dev Ensures the token adapter address is non-zero.
    function tokenAdapter(address value) internal pure returns (address) {
        if (value == address(0)) {
            revert IllegalArgument();
        }

        return value;
    }

    /// @dev Sets or clears guardian status for an address.
    function setGuardian(mapping(address => bool) storage guardians, address guardian, bool isActive) internal {
        if (guardian == address(0)) {
            revert IllegalArgument();
        }

        guardians[guardian] = isActive;
    }

    /// @dev Clamps the position minimum collateralization within global and liquidation-target bounds.
    function minimumCollateralization(
        uint256 value,
        uint256 globalMinimumCollateralization,
        uint256 liquidationTargetCollateralization,
        uint256 fixedPointScalar
    ) internal pure returns (uint256) {
        if (value < fixedPointScalar) {
            revert IllegalArgument();
        }

        uint256 newMinimum =
            value > globalMinimumCollateralization ? globalMinimumCollateralization : value;

        if (newMinimum > liquidationTargetCollateralization) {
            newMinimum = liquidationTargetCollateralization;
        }

        return newMinimum;
    }

    /// @dev Validates that the global minimum does not fall below the position minimum.
    function globalMinimumCollateralization(uint256 value, uint256 minimumCollateralization_)
        internal
        pure
        returns (uint256)
    {
        if (value < minimumCollateralization_) {
            revert IllegalArgument();
        }

        return value;
    }

    /// @dev Validates the liquidation eligibility lower bound.
    function collateralizationLowerBound(
        uint256 value,
        uint256 minimumCollateralization_,
        uint256 fixedPointScalar
    ) internal pure returns (uint256) {
        if (value >= minimumCollateralization_) {
            revert IllegalArgument();
        }
        if (value < fixedPointScalar) {
            revert IllegalArgument();
        }

        return value;
    }

    /// @dev Validates the target collateralization used to restore liquidated accounts.
    function liquidationTargetCollateralization(
        uint256 value,
        uint256 minimumCollateralization_,
        uint256 collateralizationLowerBound_,
        uint256 fixedPointScalar
    ) internal pure returns (uint256) {
        if (value <= fixedPointScalar) {
            revert IllegalArgument();
        }
        if (value < minimumCollateralization_) {
            revert IllegalArgument();
        }
        if (value <= collateralizationLowerBound_) {
            revert IllegalArgument();
        }
        if (value > 2 * fixedPointScalar) {
            revert IllegalArgument();
        }

        return value;
    }

    /// @dev Returns the requested pause state unchanged after the caller-level auth checks.
    function pauseState(bool isPaused) internal pure returns (bool) {
        return isPaused;
    }
}
