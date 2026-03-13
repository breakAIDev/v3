// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../interfaces/IAlchemistV3.sol";
import {Initializable} from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {Unauthorized} from "../base/Errors.sol";

abstract contract AlchemistV3Storage is IAlchemistV3, Initializable {
    uint256 public constant BPS = 10_000;
    uint256 public constant FIXED_POINT_SCALAR = 1e18;
    uint256 public constant ONE_Q128 = uint256(1) << 128;

    /// @inheritdoc IAlchemistV3Immutables
    string public constant version = "3.0.0";

    /// @inheritdoc IAlchemistV3State
    address public admin;

    /// @inheritdoc IAlchemistV3State
    address public alchemistFeeVault;

    /// @inheritdoc IAlchemistV3Immutables
    address public debtToken;

    /// @inheritdoc IAlchemistV3State
    address public myt;

    /// @inheritdoc IAlchemistV3State
    uint256 public underlyingConversionFactor;

    /// @inheritdoc IAlchemistV3State
    uint256 public cumulativeEarmarked;

    /// @inheritdoc IAlchemistV3State
    uint256 public depositCap;

    /// @inheritdoc IAlchemistV3State
    uint256 public lastEarmarkBlock;

    /// @inheritdoc IAlchemistV3State
    uint256 public lastRedemptionBlock;

    /// @inheritdoc IAlchemistV3State
    uint256 public lastTransmuterTokenBalance;

    /// @inheritdoc IAlchemistV3State
    uint256 public minimumCollateralization;

    /// @inheritdoc IAlchemistV3State
    uint256 public collateralizationLowerBound;

    /// @inheritdoc IAlchemistV3State
    uint256 public globalMinimumCollateralization;

    /// @inheritdoc IAlchemistV3State
    uint256 public liquidationTargetCollateralization;

    /// @inheritdoc IAlchemistV3State
    uint256 public totalDebt;

    /// @inheritdoc IAlchemistV3State
    uint256 public totalSyntheticsIssued;

    /// @inheritdoc IAlchemistV3State
    uint256 public protocolFee;

    /// @inheritdoc IAlchemistV3State
    uint256 public liquidatorFee;

    /// @inheritdoc IAlchemistV3State
    uint256 public repaymentFee;

    /// @inheritdoc IAlchemistV3State
    address public alchemistPositionNFT;

    /// @inheritdoc IAlchemistV3State
    address public protocolFeeReceiver;

    /// @inheritdoc IAlchemistV3State
    address public underlyingToken;

    /// @inheritdoc IAlchemistV3State
    address public tokenAdapter;

    /// @inheritdoc IAlchemistV3State
    address public transmuter;

    /// @inheritdoc IAlchemistV3State
    address public pendingAdmin;

    /// @inheritdoc IAlchemistV3State
    bool public depositsPaused;

    /// @inheritdoc IAlchemistV3State
    bool public loansPaused;

    /// @inheritdoc IAlchemistV3State
    mapping(address => bool) public guardians;

    /// @dev Total debt redeemed via Transmuter redemptions
    uint256 internal _totalRedeemedDebt;

    /// @dev Total MYT shares paid out for redemptions (collRedeemed + feeCollateral)
    uint256 internal _totalRedeemedSharesOut;

    /// @dev Packed earmark survival state for unearmarked exposure.
    uint256 internal _earmarkWeight;

    /// @dev Packed redemption survival state for earmarked exposure.
    uint256 internal _redemptionWeight;

    /// @dev Cumulative surviving earmark mass used to unwind redemptions across epochs.
    uint256 internal _survivalAccumulator;

    /// @dev Total yield tokens deposited
    /// This is used to differentiate between tokens deposited into a CDP and balance of the contract
    uint256 internal _mytSharesDeposited;

    /// @dev MYT shares of transmuter balance increase not yet applied as cover in _earmark()
    uint256 internal _pendingCoverShares;

    /// @dev User accounts
    mapping(uint256 => Account) internal _accounts;

    /// @dev Redemption weight snapshot at the start of each earmark epoch.
    mapping(uint256 => uint256) internal _earmarkEpochStartRedemptionWeight;

    /// @dev Survival accumulator snapshot at the start of each earmark epoch.
    mapping(uint256 => uint256) internal _earmarkEpochStartSurvivalAccumulator;

    uint256 internal constant _REDEMPTION_INDEX_BITS = 129;
    uint256 internal constant _REDEMPTION_INDEX_MASK = (uint256(1) << _REDEMPTION_INDEX_BITS) - 1;

    uint256 internal constant _EARMARK_INDEX_BITS = 129;
    uint256 internal constant _EARMARK_INDEX_MASK = (uint256(1) << _EARMARK_INDEX_BITS) - 1;

    modifier onlyAdmin() {
        if (msg.sender != admin) {
            revert Unauthorized();
        }
        _;
    }

    modifier onlyAdminOrGuardian() {
        if (msg.sender != admin && !guardians[msg.sender]) {
            revert Unauthorized();
        }
        _;
    }

    modifier onlyTransmuter() {
        if (msg.sender != transmuter) {
            revert Unauthorized();
        }
        _;
    }

    constructor() initializer {}
}
