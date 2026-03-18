// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./interfaces/IAlchemistV3.sol";
import {Initializable} from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {Unauthorized} from "./base/Errors.sol";

abstract contract AlchemistV3Storage is Initializable {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant FIXED_POINT_SCALAR = 1e18;
    uint256 internal constant ONE_Q128 = uint256(1) << 128;

    address internal _admin;
    address internal _alchemistFeeVault;
    address internal _debtToken;
    address internal _myt;
    uint256 internal _underlyingConversionFactor;
    uint256 internal _cumulativeEarmarked;
    uint256 internal _depositCap;
    uint256 internal _lastEarmarkBlock;
    uint256 internal _lastRedemptionBlock;
    uint256 internal _lastTransmuterTokenBalance;
    uint256 internal _minimumCollateralization;
    uint256 internal _collateralizationLowerBound;
    uint256 internal _globalMinimumCollateralization;
    uint256 internal _liquidationTargetCollateralization;
    uint256 internal _totalDebt;
    uint256 internal _totalSyntheticsIssued;
    uint256 internal _protocolFee;
    uint256 internal _liquidatorFee;
    uint256 internal _repaymentFee;
    address internal _alchemistPositionNFT;
    address internal _protocolFeeReceiver;
    address internal _underlyingToken;
    address internal _tokenAdapter;
    address internal _transmuter;
    address internal _pendingAdmin;
    bool internal _depositsPaused;
    bool internal _loansPaused;
    mapping(address => bool) internal _guardians;

    uint256 internal _totalRedeemedDebt;
    uint256 internal _totalRedeemedSharesOut;
    uint256 internal _earmarkWeight;
    uint256 internal _redemptionWeight;
    uint256 internal _survivalAccumulator;
    uint256 internal _mytSharesDeposited;
    uint256 internal _pendingCoverShares;

    mapping(uint256 => Account) internal _accounts;
    mapping(uint256 => uint256) internal _earmarkEpochStartRedemptionWeight;
    mapping(uint256 => uint256) internal _earmarkEpochStartSurvivalAccumulator;

    uint256 internal constant _REDEMPTION_INDEX_BITS = 129;
    uint256 internal constant _REDEMPTION_INDEX_MASK = (uint256(1) << _REDEMPTION_INDEX_BITS) - 1;

    uint256 internal constant _EARMARK_INDEX_BITS = 129;
    uint256 internal constant _EARMARK_INDEX_MASK = (uint256(1) << _EARMARK_INDEX_BITS) - 1;

    function _checkAdmin() internal view {
        if (msg.sender != _admin) {
            revert Unauthorized();
        }
    }

    function _checkAdminOrGuardian() internal view {
        if (msg.sender != _admin && !_guardians[msg.sender]) {
            revert Unauthorized();
        }
    }

    function _checkTransmuter() internal view {
        if (msg.sender != _transmuter) {
            revert Unauthorized();
        }
    }

    modifier onlyAdmin() {
        _checkAdmin();
        _;
    }

    modifier onlyAdminOrGuardian() {
        _checkAdminOrGuardian();
        _;
    }

    modifier onlyTransmuter() {
        _checkTransmuter();
        _;
    }

    constructor() initializer {}
}
