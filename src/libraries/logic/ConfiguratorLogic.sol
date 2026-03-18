// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../interfaces/IAlchemistV3.sol";
import "../../base/Errors.sol";
import "../../interfaces/IFeeVault.sol";
import "../../libraries/TokenUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library ConfiguratorLogic {
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

    function alchemistPositionNFT(address currentNft, address nft) internal pure returns (address) {
        if (nft == address(0)) {
            revert IAlchemistV3Errors.AlchemistV3NFTZeroAddressError();
        }

        if (currentNft != address(0)) {
            revert IAlchemistV3Errors.AlchemistV3NFTAlreadySetError();
        }

        return nft;
    }

    function alchemistFeeVault(address value, address underlyingToken) internal view returns (address) {
        if (IFeeVault(value).token() != underlyingToken) {
            revert IAlchemistV3Errors.AlchemistVaultTokenMismatchError();
        }

        return value;
    }

    function pendingAdmin(address value) internal pure returns (address) {
        return value;
    }

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

    function depositCap(uint256 value, address myt, address holder) internal view returns (uint256) {
        if (value < IERC20(myt).balanceOf(holder)) {
            revert IllegalArgument();
        }

        return value;
    }

    function protocolFeeReceiver(address value) internal pure returns (address) {
        if (value == address(0)) {
            revert IllegalArgument();
        }

        return value;
    }

    function feeBps(uint256 fee, uint256 bps) internal pure returns (uint256) {
        if (fee > bps) {
            revert IllegalArgument();
        }

        return fee;
    }

    function tokenAdapter(address value) internal pure returns (address) {
        if (value == address(0)) {
            revert IllegalArgument();
        }

        return value;
    }

    function setGuardian(mapping(address => bool) storage guardians, address guardian, bool isActive) internal {
        if (guardian == address(0)) {
            revert IllegalArgument();
        }

        guardians[guardian] = isActive;
    }

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

    function pauseState(bool isPaused) internal pure returns (bool) {
        return isPaused;
    }
}
