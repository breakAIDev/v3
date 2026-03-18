// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./interfaces/IAlchemistV3.sol";
import {AlchemistV3Storage} from "./AlchemistV3Storage.sol";
import {SupplyLogic} from "./libraries/logic/SupplyLogic.sol";
import {BorrowLogic} from "./libraries/logic/BorrowLogic.sol";
import {ValidationLogic} from "./libraries/logic/ValidationLogic.sol";
import {RedemptionLogic} from "./libraries/logic/RedemptionLogic.sol";
import {AccountControlLogic} from "./libraries/logic/AccountControlLogic.sol";
import {LiquidationLogic} from "./libraries/logic/LiquidationLogic.sol";
import {ConfiguratorLogic} from "./libraries/logic/ConfiguratorLogic.sol";
import {ViewLogic} from "./libraries/logic/ViewLogic.sol";
import {SyncLogic} from "./libraries/logic/SyncLogic.sol";
import {EarmarkLogic} from "./libraries/logic/EarmarkLogic.sol";
import {StateLogic} from "./libraries/logic/StateLogic.sol";
import {IFeeVault} from "./interfaces/IFeeVault.sol";
import "./base/Errors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  AlchemistV3
/// @author Alchemix Finance
///
/// For Juris, Graham, and Marcus
contract AlchemistV3 is IAlchemistV3, AlchemistV3Storage {
    function initialize(AlchemistInitializationParams calldata params) external initializer {
        _debtToken = params.debtToken;
        _underlyingToken = params.underlyingToken;
        _underlyingConversionFactor = ConfiguratorLogic.initialize(params, BPS);
        _depositCap = params.depositCap;
        _minimumCollateralization = params.minimumCollateralization;
        _globalMinimumCollateralization = params.globalMinimumCollateralization;
        _collateralizationLowerBound = params.collateralizationLowerBound;
        _liquidationTargetCollateralization = params.liquidationTargetCollateralization;
        _admin = params.admin;
        _transmuter = params.transmuter;
        _protocolFee = params.protocolFee;
        _protocolFeeReceiver = params.protocolFeeReceiver;
        _liquidatorFee = params.liquidatorFee;
        _repaymentFee = params.repaymentFee;
        _lastEarmarkBlock = block.number;
        _lastRedemptionBlock = block.number;
        _myt = params.myt;

        _redemptionWeight = ONE_Q128;
        _earmarkWeight = ONE_Q128;

        _earmarkEpochStartRedemptionWeight[0] = _redemptionWeight;
        _earmarkEpochStartSurvivalAccumulator[0] = _survivalAccumulator;
    }

    // ---------------- Protocol and CDP getters ---------------- //

    /// @inheritdoc IAlchemistV3State
    function getCDP(uint256 tokenId) external view override(IAlchemistV3State) returns (uint256, uint256, uint256) {
        (SyncLogic.GlobalSyncState memory syncState, uint256 simulatedEarmarkWeight) = _viewContext();

        return ViewLogic.getCDP(
            _accounts,
            tokenId,
            syncState,
            simulatedEarmarkWeight,
            _earmarkEpochStartRedemptionWeight,
            _earmarkEpochStartSurvivalAccumulator
        );
    }

    /// @inheritdoc IAlchemistV3State
    function getTotalDeposited() external view override(IAlchemistV3State) returns (uint256) {
        return _mytSharesDeposited;
    }

    /// @inheritdoc IAlchemistV3State
    function getMaxBorrowable(uint256 tokenId) external view override(IAlchemistV3State) returns (uint256) {
        (SyncLogic.GlobalSyncState memory syncState, uint256 simulatedEarmarkWeight) = _viewContext();

        return ViewLogic.getMaxBorrowable(
            _accounts,
            tokenId,
            syncState,
            simulatedEarmarkWeight,
            _earmarkEpochStartRedemptionWeight,
            _earmarkEpochStartSurvivalAccumulator,
            _myt,
            _underlyingConversionFactor,
            _minimumCollateralization,
            FIXED_POINT_SCALAR
        );
    }

    /// @inheritdoc IAlchemistV3State
    function getMaxWithdrawable(uint256 tokenId) external view override(IAlchemistV3State) returns (uint256) {
        (SyncLogic.GlobalSyncState memory syncState, uint256 simulatedEarmarkWeight) = _viewContext();

        return ViewLogic.getMaxWithdrawable(
            _accounts,
            tokenId,
            syncState,
            simulatedEarmarkWeight,
            _earmarkEpochStartRedemptionWeight,
            _earmarkEpochStartSurvivalAccumulator,
            _myt,
            _underlyingConversionFactor,
            _minimumCollateralization,
            FIXED_POINT_SCALAR,
            _totalDebt,
            _mytSharesDeposited
        );
    }

    /// @inheritdoc IAlchemistV3State
    function mintAllowance(uint256 ownerTokenId, address spender)
        external
        view
        override(IAlchemistV3State)
        returns (uint256)
    {
        Account storage account = _accounts[ownerTokenId];
        return account.mintAllowances[account.allowancesVersion][spender];
    }

    /// @inheritdoc IAlchemistV3State
    function getTotalUnderlyingValue() external view override(IAlchemistV3State) returns (uint256) {
        return StateLogic.getTotalUnderlyingValue(_myt, _mytSharesDeposited);
    }

    /// @inheritdoc IAlchemistV3State
    function getTotalLockedUnderlyingValue() external view override(IAlchemistV3State) returns (uint256) {
        return StateLogic.getTotalLockedUnderlyingValue(
            _myt,
            _underlyingConversionFactor,
            _totalDebt,
            _mytSharesDeposited,
            _minimumCollateralization,
            FIXED_POINT_SCALAR
        );
    }

    /// @inheritdoc IAlchemistV3State
    function totalValue(uint256 tokenId) external view override(IAlchemistV3State) returns (uint256) {
        (SyncLogic.GlobalSyncState memory syncState, uint256 simulatedEarmarkWeight) = _viewContext();

        return ViewLogic.totalValue(
            _accounts,
            tokenId,
            syncState,
            simulatedEarmarkWeight,
            _earmarkEpochStartRedemptionWeight,
            _earmarkEpochStartSurvivalAccumulator,
            _myt,
            _underlyingConversionFactor
        );
    }

    function getUnrealizedCumulativeEarmarked() external view returns (uint256) {
        (, uint256 effectiveEarmarked) = _simulateFromGraph(_earmarkState());
        if (_totalDebt == 0) return 0;
        return _cumulativeEarmarked + effectiveEarmarked;
    }

    // ---------------- Core CDP actions ---------------- //

    /// @inheritdoc IAlchemistV3Actions
    function deposit(uint256 amount, address recipient, uint256 tokenId)
        external
        override(IAlchemistV3Actions)
        returns (uint256 positionId, uint256 debtValue)
    {
        ValidationLogic.validateDeposit(
            _alchemistPositionNFT,
            recipient,
            tokenId,
            amount,
            _mytSharesDeposited,
            _depositCap,
            _depositsPaused,
            StateLogic.isProtocolInBadDebt(
                _myt,
                _transmuter,
                _underlyingConversionFactor,
                _totalDebt,
                _mytSharesDeposited,
                _totalSyntheticsIssued,
                _minimumCollateralization,
                FIXED_POINT_SCALAR
            )
        );

        if (tokenId != 0) {
            _commitAndApply(tokenId, false);
        }

        bool createdPosition;
        (positionId, _mytSharesDeposited, createdPosition) = SupplyLogic.deposit(
            _accounts, _alchemistPositionNFT, _myt, msg.sender, recipient, tokenId, amount, _mytSharesDeposited
        );

        if (createdPosition) {
            emit AlchemistV3PositionNFTMinted(recipient, positionId);
        }
        emit Deposit(amount, positionId);
        debtValue = StateLogic.convertYieldTokensToDebt(_myt, _underlyingConversionFactor, amount);
    }

    /// @inheritdoc IAlchemistV3Actions
    function withdraw(uint256 amount, address recipient, uint256 tokenId)
        external
        override(IAlchemistV3Actions)
        returns (uint256)
    {
        ValidationLogic.validateWithdraw(_alchemistPositionNFT, msg.sender, recipient, tokenId, amount);
        _commitAndApply(tokenId, false);

        uint256 transferred;
        (transferred, _mytSharesDeposited) = SupplyLogic.withdraw(
            _accounts,
            _myt,
            recipient,
            tokenId,
            amount,
            _mytSharesDeposited,
            _minimumCollateralization,
            FIXED_POINT_SCALAR,
            StateLogic.convertDebtTokensToYield(_myt, _underlyingConversionFactor, _accounts[tokenId].debt)
        );

        emit Withdraw(transferred, tokenId, recipient);
        return transferred;
    }

    /// @inheritdoc IAlchemistV3Actions
    function mint(uint256 tokenId, uint256 amount, address recipient)
        external
        override(IAlchemistV3Actions)
    {
        ValidationLogic.validateMintRequest(
            _alchemistPositionNFT,
            msg.sender,
            recipient,
            tokenId,
            amount,
            _loansPaused,
            _accounts[tokenId].lastRepayBlock,
            true
        );
        _commitAndApply(tokenId, true);

        (_totalDebt, _totalSyntheticsIssued) = BorrowLogic.mint(
            _accounts,
            _mintParams(tokenId, amount, recipient),
            _collateralValueInDebt(tokenId)
        );

        emit Mint(tokenId, amount, recipient);
    }

    /// @inheritdoc IAlchemistV3Actions
    function mintFrom(uint256 tokenId, uint256 amount, address recipient)
        external
        override(IAlchemistV3Actions)
    {
        ValidationLogic.validateMintRequest(
            _alchemistPositionNFT,
            msg.sender,
            recipient,
            tokenId,
            amount,
            _loansPaused,
            _accounts[tokenId].lastRepayBlock,
            false
        );
        _commitAndApply(tokenId, true);

        (_totalDebt, _totalSyntheticsIssued) = BorrowLogic.mintFrom(
            _accounts,
            _mintParams(tokenId, amount, recipient),
            _collateralValueInDebt(tokenId)
        );

        emit Mint(tokenId, amount, recipient);
    }

    /// @inheritdoc IAlchemistV3Actions
    function burn(uint256 amount, uint256 recipientId)
        external
        override(IAlchemistV3Actions)
        returns (uint256)
    {
        ValidationLogic.validateDebtRepayment(
            _alchemistPositionNFT, recipientId, amount, _accounts[recipientId].lastMintBlock
        );
        _commitAndApply(recipientId, false);

        uint256 credit;
        (credit, _totalDebt, _totalSyntheticsIssued, _cumulativeEarmarked) = BorrowLogic.burn(
            _accounts,
            BorrowLogic.BurnParams({
                debtToken: _debtToken,
                transmuter: _transmuter,
                caller: msg.sender,
                recipientId: recipientId,
                amount: amount,
                totalDebt: _totalDebt,
                totalSyntheticsIssued: _totalSyntheticsIssued,
                cumulativeEarmarked: _cumulativeEarmarked
            }),
            _borrowCheckpointParams()
        );

        if (credit == 0) return 0;
        emit Burn(msg.sender, credit, recipientId);
        return credit;
    }

    /// @inheritdoc IAlchemistV3Actions
    function repay(uint256 amount, uint256 recipientTokenId)
        external
        override(IAlchemistV3Actions)
        returns (uint256)
    {
        ValidationLogic.validateDebtRepayment(
            _alchemistPositionNFT, recipientTokenId, amount, _accounts[recipientTokenId].lastMintBlock
        );
        _commitAndApply(recipientTokenId, false);

        uint256 creditToYield;
        uint256 feeAmount;
        (creditToYield, feeAmount, _totalDebt, _mytSharesDeposited, _cumulativeEarmarked) = BorrowLogic.repay(
            _accounts,
            BorrowLogic.RepayParams({
                myt: _myt,
                transmuter: _transmuter,
                protocolFeeReceiver: _protocolFeeReceiver,
                caller: msg.sender,
                recipientTokenId: recipientTokenId,
                amount: amount,
                totalDebt: _totalDebt,
                totalDeposited: _mytSharesDeposited,
                cumulativeEarmarked: _cumulativeEarmarked,
                underlyingConversionFactor: _underlyingConversionFactor,
                protocolFee: _protocolFee,
                bps: BPS
            }),
            _borrowCheckpointParams()
        );

        if (creditToYield == 0 && feeAmount == 0) return 0;
        emit Repay(msg.sender, amount, recipientTokenId, creditToYield);
        return creditToYield;
    }

    /// @inheritdoc IAlchemistV3Actions
    function redeem(uint256 amount)
        external
        override(IAlchemistV3Actions)
        onlyTransmuter
        returns (uint256 sharesSent)
    {
        RedemptionLogic.RedeemResult memory result = RedemptionLogic.redeem(
            RedemptionLogic.RedeemParams({
                myt: _myt,
                transmuter: _transmuter,
                protocolFeeReceiver: _protocolFeeReceiver,
                underlyingConversionFactor: _underlyingConversionFactor,
                amount: amount,
                totalDeposited: _mytSharesDeposited,
                totalRedeemedDebt: _totalRedeemedDebt,
                totalRedeemedSharesOut: _totalRedeemedSharesOut,
                protocolFee: _protocolFee,
                bps: BPS
            }),
            _earmarkState()
        );

        if (result.epochAdvanced) {
            _earmarkEpochStartRedemptionWeight[result.epochBoundary] = _redemptionWeight;
            _earmarkEpochStartSurvivalAccumulator[result.epochBoundary] = result.epochStartSurvivalAccumulator;
        }
        _lastRedemptionBlock = result.newLastRedemptionBlock;
        _totalDebt = result.newTotalDebt;
        _cumulativeEarmarked = result.newCumulativeEarmarked;
        _lastEarmarkBlock = result.newLastEarmarkBlock;
        _lastTransmuterTokenBalance = result.newLastTransmuterTokenBalance;
        _pendingCoverShares = result.newPendingCoverShares;
        _earmarkWeight = result.newEarmarkWeight;
        _redemptionWeight = result.newRedemptionWeight;
        _survivalAccumulator = result.newSurvivalAccumulator;
        _mytSharesDeposited = result.newTotalDeposited;
        _totalRedeemedDebt = result.newTotalRedeemedDebt;
        _totalRedeemedSharesOut = result.newTotalRedeemedSharesOut;
        emit Redemption(result.effectiveRedeemed);
        return result.sharesSent;
    }

    /// @inheritdoc IAlchemistV3Actions
    function reduceSyntheticsIssued(uint256 amount)
        external
        override(IAlchemistV3Actions)
        onlyTransmuter
    {
        _totalSyntheticsIssued = RedemptionLogic.reduceSyntheticsIssued(_totalSyntheticsIssued, amount);
    }

    /// @inheritdoc IAlchemistV3Actions
    function setTransmuterTokenBalance(uint256 amount)
        external
        override(IAlchemistV3Actions)
        onlyTransmuter
    {
        (_lastTransmuterTokenBalance, _pendingCoverShares) =
            RedemptionLogic.setTransmuterTokenBalance(_lastTransmuterTokenBalance, _pendingCoverShares, amount);
    }

    /// @inheritdoc IAlchemistV3Actions
    function poke(uint256 tokenId) external override(IAlchemistV3Actions) {
        ValidationLogic.validatePoke(_alchemistPositionNFT, tokenId);
        _commitAndApply(tokenId, false);
    }

    /// @inheritdoc IAlchemistV3Actions
    function liquidate(uint256 accountId)
        external
        override(IAlchemistV3Actions)
        returns (uint256 yieldAmount, uint256 feeInYield, uint256 feeInUnderlying)
    {
        ValidationLogic.ensureValidAccount(_alchemistPositionNFT, accountId);
        LiquidationLogic.LiquidationResult memory result = LiquidationLogic.executeLiquidation(
            _accounts,
            accountId,
            _earmarkEpochStartRedemptionWeight,
            _earmarkEpochStartSurvivalAccumulator,
            _liquidationRuntime(),
            msg.sender
        );
        _applyLiquidationResult(result);
        if (!result.progressed) revert IAlchemistV3Errors.LiquidationError();
        return (result.amountLiquidated, result.feeInYield, result.feeInUnderlying);
    }

    /// @inheritdoc IAlchemistV3Actions
    function batchLiquidate(uint256[] calldata accountIds)
        external
        override(IAlchemistV3Actions)
        returns (uint256 totalAmountLiquidated, uint256 totalFeesInYield, uint256 totalFeesInUnderlying)
    {
        if (accountIds.length == 0) revert MissingInputData();

        LiquidationLogic.Runtime memory runtime = _liquidationRuntime();
        bool anyProgress;
        uint256 accountCount = accountIds.length;
        for (uint256 i = 0; i < accountCount;) {
            uint256 accountId = accountIds[i];
            if (accountId == 0 || !ValidationLogic.tokenExists(_alchemistPositionNFT, accountId)) {
                unchecked {
                    ++i;
                }
                continue;
            }

            LiquidationLogic.LiquidationResult memory result = LiquidationLogic.executeLiquidation(
                _accounts,
                accountId,
                _earmarkEpochStartRedemptionWeight,
                _earmarkEpochStartSurvivalAccumulator,
                runtime,
                msg.sender
            );
            runtime.totalDebt = result.totalDebt;
            runtime.totalDeposited = result.totalDeposited;
            runtime.cumulativeEarmarked = result.cumulativeEarmarked;
            runtime.lastEarmarkBlock = result.lastEarmarkBlock;
            runtime.lastTransmuterTokenBalance = result.lastTransmuterTokenBalance;
            runtime.pendingCoverShares = result.pendingCoverShares;
            runtime.earmarkWeight = result.earmarkWeight;
            runtime.survivalAccumulator = result.survivalAccumulator;

            unchecked {
                totalAmountLiquidated += result.amountLiquidated;
                totalFeesInYield += result.feeInYield;
                totalFeesInUnderlying += result.feeInUnderlying;
            }
            if (result.progressed) anyProgress = true;
            unchecked {
                ++i;
            }
        }

        if (!anyProgress) revert IAlchemistV3Errors.LiquidationError();

        _totalDebt = runtime.totalDebt;
        _mytSharesDeposited = runtime.totalDeposited;
        _cumulativeEarmarked = runtime.cumulativeEarmarked;
        _lastEarmarkBlock = runtime.lastEarmarkBlock;
        _lastTransmuterTokenBalance = runtime.lastTransmuterTokenBalance;
        _pendingCoverShares = runtime.pendingCoverShares;
        _earmarkWeight = runtime.earmarkWeight;
        _survivalAccumulator = runtime.survivalAccumulator;
        emit BatchLiquidated(accountIds, msg.sender, totalAmountLiquidated, totalFeesInYield, totalFeesInUnderlying);
        return (totalAmountLiquidated, totalFeesInYield, totalFeesInUnderlying);
    }

    /// @inheritdoc IAlchemistV3Actions
    function selfLiquidate(uint256 accountId, address recipient)
        external
        override(IAlchemistV3Actions)
        returns (uint256 amountLiquidated)
    {
        LiquidationLogic.LiquidationResult memory result = LiquidationLogic.executeSelfLiquidation(
            _accounts,
            accountId,
            _earmarkEpochStartRedemptionWeight,
            _earmarkEpochStartSurvivalAccumulator,
            _liquidationRuntime(),
            msg.sender,
            recipient
        );
        _applyLiquidationResult(result);
        return result.amountLiquidated;
    }

    /// @inheritdoc IAlchemistV3State
    function calculateLiquidation(
        uint256 collateral,
        uint256 debt,
        uint256 targetCollateralization,
        uint256 alchemistCurrentCollateralization,
        uint256 alchemistMinimumCollateralization,
        uint256 feeBps
    )
        external
        pure
        override(IAlchemistV3State)
        returns (uint256 grossCollateralToSeize, uint256 debtToBurn, uint256 fee, uint256 outsourcedFee)
    {
        return LiquidationLogic.calculateLiquidation(
            collateral,
            debt,
            targetCollateralization,
            alchemistCurrentCollateralization,
            alchemistMinimumCollateralization,
            feeBps,
            BPS,
            FIXED_POINT_SCALAR
        );
    }

    /// @inheritdoc IAlchemistV3Actions
    function approveMint(uint256 tokenId, address spender, uint256 amount)
        external
        override(IAlchemistV3Actions)
    {
        ValidationLogic.validateApproveMint(_alchemistPositionNFT, msg.sender, tokenId);
        AccountControlLogic.approveMint(_accounts, tokenId, spender, amount);
        emit ApproveMint(tokenId, spender, amount);
    }

    /// @inheritdoc IAlchemistV3Actions
    function resetMintAllowances(uint256 tokenId)
        external
        override(IAlchemistV3Actions)
    {
        ValidationLogic.validateResetMintAllowances(_alchemistPositionNFT, msg.sender, tokenId);
        AccountControlLogic.resetMintAllowances(_accounts, tokenId);
        emit MintAllowancesReset(tokenId);
    }

    // ---------------- State and return building ---------------- //

    function _globalSyncState() private view returns (SyncLogic.GlobalSyncState memory) {
        return SyncLogic.globalSyncState(
            _totalRedeemedDebt,
            _totalRedeemedSharesOut,
            _earmarkWeight,
            _redemptionWeight,
            _survivalAccumulator,
            ONE_Q128,
            _EARMARK_INDEX_MASK,
            _EARMARK_INDEX_BITS,
            _REDEMPTION_INDEX_MASK,
            _REDEMPTION_INDEX_BITS
        );
    }

    function _earmarkState() private view returns (EarmarkLogic.State memory) {
        return EarmarkLogic.state(
            _totalDebt,
            _cumulativeEarmarked,
            _lastEarmarkBlock,
            _lastTransmuterTokenBalance,
            _pendingCoverShares,
            _earmarkWeight,
            _redemptionWeight,
            _survivalAccumulator,
            ONE_Q128,
            _REDEMPTION_INDEX_BITS,
            _REDEMPTION_INDEX_MASK,
            _EARMARK_INDEX_BITS,
            _EARMARK_INDEX_MASK
        );
    }

    function _simulateFromGraph(EarmarkLogic.State memory earmarkState_)
        private
        view
        returns (uint256 simulatedEarmarkWeight, uint256 effectiveEarmarked)
    {
        return EarmarkLogic.simulateFromGraph(
            earmarkState_, _transmuter, _myt, _underlyingConversionFactor, block.number
        );
    }

    function _viewContext()
        private
        view
        returns (SyncLogic.GlobalSyncState memory syncState, uint256 simulatedEarmarkWeight)
    {
        syncState = _globalSyncState();
        (simulatedEarmarkWeight,) = _simulateFromGraph(_earmarkState());
    }

    function _commitAndApply(uint256 tokenId, bool enforceNoBadDebt) private {
        EarmarkLogic.CommitResult memory commit = SyncLogic.commitEarmarkAndSync(
            _accounts,
            tokenId,
            _earmarkEpochStartRedemptionWeight,
            _earmarkEpochStartSurvivalAccumulator,
            _earmarkState(),
            _totalRedeemedDebt,
            _totalRedeemedSharesOut,
            SyncLogic.CommitAndSyncParams({
                myt: _myt,
                transmuter: _transmuter,
                underlyingConversionFactor: _underlyingConversionFactor,
                totalSyntheticsIssued: _totalSyntheticsIssued,
                totalDeposited: _mytSharesDeposited,
                minimumCollateralization: _minimumCollateralization,
                fixedPointScalar: FIXED_POINT_SCALAR,
                enforceNoBadDebt: enforceNoBadDebt
            })
        );

        _lastTransmuterTokenBalance = commit.lastTransmuterTokenBalance;
        _pendingCoverShares = commit.pendingCoverShares;
        _cumulativeEarmarked = commit.cumulativeEarmarked;
        _earmarkWeight = commit.earmarkWeight;
        _survivalAccumulator = commit.survivalAccumulator;
        _lastEarmarkBlock = commit.lastEarmarkBlock;
    }

    function _borrowCheckpointParams() private view returns (BorrowLogic.CheckpointParams memory) {
        return BorrowLogic.CheckpointParams({
            totalRedeemedDebt: _totalRedeemedDebt,
            totalRedeemedSharesOut: _totalRedeemedSharesOut,
            earmarkWeight: _earmarkWeight,
            redemptionWeight: _redemptionWeight,
            survivalAccumulator: _survivalAccumulator
        });
    }

    function _mintParams(uint256 tokenId, uint256 amount, address recipient)
        private
        view
        returns (BorrowLogic.MintParams memory)
    {
        return BorrowLogic.MintParams({
            debtToken: _debtToken,
            caller: msg.sender,
            tokenId: tokenId,
            amount: amount,
            recipient: recipient,
            totalDebt: _totalDebt,
            totalSyntheticsIssued: _totalSyntheticsIssued,
            minimumCollateralization: _minimumCollateralization,
            fixedPointScalar: FIXED_POINT_SCALAR
        });
    }

    function _collateralValueInDebt(uint256 tokenId) private view returns (uint256) {
        return StateLogic.collateralValueInDebt(
            _myt, _underlyingConversionFactor, _accounts[tokenId].collateralBalance
        );
    }

    function _liquidationRuntime() private view returns (LiquidationLogic.Runtime memory) {
        return LiquidationLogic.Runtime({
            positionNFT: _alchemistPositionNFT,
            myt: _myt,
            transmuter: _transmuter,
            protocolFeeReceiver: _protocolFeeReceiver,
            alchemistFeeVault: _alchemistFeeVault,
            totalDebt: _totalDebt,
            totalDeposited: _mytSharesDeposited,
            cumulativeEarmarked: _cumulativeEarmarked,
            totalSyntheticsIssued: _totalSyntheticsIssued,
            totalRedeemedDebt: _totalRedeemedDebt,
            totalRedeemedSharesOut: _totalRedeemedSharesOut,
            lastEarmarkBlock: _lastEarmarkBlock,
            lastTransmuterTokenBalance: _lastTransmuterTokenBalance,
            pendingCoverShares: _pendingCoverShares,
            earmarkWeight: _earmarkWeight,
            redemptionWeight: _redemptionWeight,
            survivalAccumulator: _survivalAccumulator,
            underlyingConversionFactor: _underlyingConversionFactor,
            minimumCollateralization: _minimumCollateralization,
            collateralizationLowerBound: _collateralizationLowerBound,
            globalMinimumCollateralization: _globalMinimumCollateralization,
            liquidationTargetCollateralization: _liquidationTargetCollateralization,
            protocolFee: _protocolFee,
            liquidatorFee: _liquidatorFee,
            repaymentFee: _repaymentFee,
            oneQ128: ONE_Q128,
            fixedPointScalar: FIXED_POINT_SCALAR,
            bps: BPS,
            earmarkIndexBits: _EARMARK_INDEX_BITS,
            earmarkIndexMask: _EARMARK_INDEX_MASK,
            redemptionIndexBits: _REDEMPTION_INDEX_BITS,
            redemptionIndexMask: _REDEMPTION_INDEX_MASK
        });
    }

    function _applyLiquidationResult(LiquidationLogic.LiquidationResult memory result) private {
        _totalDebt = result.totalDebt;
        _mytSharesDeposited = result.totalDeposited;
        _cumulativeEarmarked = result.cumulativeEarmarked;
        _lastEarmarkBlock = result.lastEarmarkBlock;
        _lastTransmuterTokenBalance = result.lastTransmuterTokenBalance;
        _pendingCoverShares = result.pendingCoverShares;
        _earmarkWeight = result.earmarkWeight;
        _survivalAccumulator = result.survivalAccumulator;
    }

    // ---------------- Unit conversion ---------------- //

    /// @inheritdoc IAlchemistV3State
    function convertYieldTokensToDebt(uint256 amount) external view override(IAlchemistV3State) returns (uint256) {
        return StateLogic.convertYieldTokensToDebt(_myt, _underlyingConversionFactor, amount);
    }

    /// @inheritdoc IAlchemistV3State
    function convertDebtTokensToYield(uint256 amount) external view override(IAlchemistV3State) returns (uint256) {
        return StateLogic.convertDebtTokensToYield(_myt, _underlyingConversionFactor, amount);
    }

    /// @inheritdoc IAlchemistV3State
    function convertYieldTokensToUnderlying(uint256 amount) external view override(IAlchemistV3State) returns (uint256) {
        return StateLogic.convertYieldTokensToUnderlying(_myt, amount);
    }

    /// @inheritdoc IAlchemistV3State
    function convertUnderlyingTokensToYield(uint256 amount) external view override(IAlchemistV3State) returns (uint256) {
        return StateLogic.convertUnderlyingTokensToYield(_myt, amount);
    }

    /// @inheritdoc IAlchemistV3State
    function normalizeUnderlyingTokensToDebt(uint256 amount) external view override(IAlchemistV3State) returns (uint256) {
        return StateLogic.normalizeUnderlyingTokensToDebt(amount, _underlyingConversionFactor);
    }

    /// @inheritdoc IAlchemistV3State
    function normalizeDebtTokensToUnderlying(uint256 amount) external view override(IAlchemistV3State) returns (uint256) {
        return StateLogic.normalizeDebtTokensToUnderlying(amount, _underlyingConversionFactor);
    }

    // ---------------- Protocol state getters ---------------- //

    /// @inheritdoc IAlchemistV3Immutables
    function version() external pure override(IAlchemistV3Immutables) returns (string memory) {
        return "3.0.0";
    }

    /// @inheritdoc IAlchemistV3Immutables
    function debtToken() external view override(IAlchemistV3Immutables) returns (address) {
        return _debtToken;
    }

    /// @inheritdoc IAlchemistV3State
    function admin() external view override(IAlchemistV3State) returns (address) {
        return _admin;
    }

    function depositCap() external view override(IAlchemistV3State) returns (uint256) {
        return _depositCap;
    }

    function guardians(address guardian) external view override(IAlchemistV3State) returns (bool) {
        return _guardians[guardian];
    }

    function cumulativeEarmarked() external view override(IAlchemistV3State) returns (uint256) {
        return _cumulativeEarmarked;
    }

    function lastEarmarkBlock() external view override(IAlchemistV3State) returns (uint256) {
        return _lastEarmarkBlock;
    }

    function lastRedemptionBlock() external view override(IAlchemistV3State) returns (uint256) {
        return _lastRedemptionBlock;
    }

    function lastTransmuterTokenBalance() external view override(IAlchemistV3State) returns (uint256) {
        return _lastTransmuterTokenBalance;
    }

    function totalDebt() external view override(IAlchemistV3State) returns (uint256) {
        return _totalDebt;
    }

    function totalSyntheticsIssued() external view override(IAlchemistV3State) returns (uint256) {
        return _totalSyntheticsIssued;
    }

    function protocolFee() external view override(IAlchemistV3State) returns (uint256) {
        return _protocolFee;
    }

    function liquidatorFee() external view override(IAlchemistV3State) returns (uint256) {
        return _liquidatorFee;
    }

    function repaymentFee() external view override(IAlchemistV3State) returns (uint256) {
        return _repaymentFee;
    }

    function underlyingConversionFactor() external view override(IAlchemistV3State) returns (uint256) {
        return _underlyingConversionFactor;
    }

    function protocolFeeReceiver() external view override(IAlchemistV3State) returns (address) {
        return _protocolFeeReceiver;
    }

    function underlyingToken() external view override(IAlchemistV3State) returns (address) {
        return _underlyingToken;
    }

    function myt() external view override(IAlchemistV3State) returns (address) {
        return _myt;
    }

    function depositsPaused() external view override(IAlchemistV3State) returns (bool) {
        return _depositsPaused;
    }

    function loansPaused() external view override(IAlchemistV3State) returns (bool) {
        return _loansPaused;
    }

    function alchemistPositionNFT() external view override(IAlchemistV3State) returns (address) {
        return _alchemistPositionNFT;
    }

    /// @inheritdoc IAlchemistV3State
    function pendingAdmin() external view override(IAlchemistV3State) returns (address) {
        return _pendingAdmin;
    }

    /// @inheritdoc IAlchemistV3State
    function tokenAdapter() external view override(IAlchemistV3State) returns (address) {
        return _tokenAdapter;
    }

    /// @inheritdoc IAlchemistV3State
    function alchemistFeeVault() external view override(IAlchemistV3State) returns (address) {
        return _alchemistFeeVault;
    }

    /// @inheritdoc IAlchemistV3State
    function transmuter() external view override(IAlchemistV3State) returns (address) {
        return _transmuter;
    }

    /// @inheritdoc IAlchemistV3State
    function minimumCollateralization() external view override(IAlchemistV3State) returns (uint256) {
        return _minimumCollateralization;
    }

    /// @inheritdoc IAlchemistV3State
    function globalMinimumCollateralization() external view override(IAlchemistV3State) returns (uint256) {
        return _globalMinimumCollateralization;
    }

    /// @inheritdoc IAlchemistV3State
    function collateralizationLowerBound() external view override(IAlchemistV3State) returns (uint256) {
        return _collateralizationLowerBound;
    }

    /// @inheritdoc IAlchemistV3State
    function liquidationTargetCollateralization() external view override(IAlchemistV3State) returns (uint256) {
        return _liquidationTargetCollateralization;
    }

    // ---------------- Protocol admin actions ---------------- //

    function setAlchemistPositionNFT(address nft) external onlyAdmin {
        if (nft == address(0)) {
            revert IAlchemistV3Errors.AlchemistV3NFTZeroAddressError();
        }
        if (_alchemistPositionNFT != address(0)) {
            revert IAlchemistV3Errors.AlchemistV3NFTAlreadySetError();
        }
        _alchemistPositionNFT = nft;
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setAlchemistFeeVault(address value) external override(IAlchemistV3AdminActions) onlyAdmin {
        if (IFeeVault(value).token() != _underlyingToken) {
            revert IAlchemistV3Errors.AlchemistVaultTokenMismatchError();
        }
        _alchemistFeeVault = value;
        emit AlchemistFeeVaultUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setPendingAdmin(address value) external override(IAlchemistV3AdminActions) onlyAdmin {
        _pendingAdmin = value;
        emit PendingAdminUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function acceptAdmin() external override(IAlchemistV3AdminActions) {
        if (_pendingAdmin == address(0)) revert IllegalState();
        if (msg.sender != _pendingAdmin) revert Unauthorized();
        _admin = _pendingAdmin;
        _pendingAdmin = address(0);
        emit AdminUpdated(_admin);
        emit PendingAdminUpdated(address(0));
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setDepositCap(uint256 value) external override(IAlchemistV3AdminActions) onlyAdmin {
        if (value < IERC20(_myt).balanceOf(address(this))) revert IllegalArgument();
        _depositCap = value;
        emit DepositCapUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setProtocolFeeReceiver(address value)
        external
        override(IAlchemistV3AdminActions)
        onlyAdmin
    {
        if (value == address(0)) revert IllegalArgument();
        _protocolFeeReceiver = value;
        emit ProtocolFeeReceiverUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setProtocolFee(uint256 fee) external override(IAlchemistV3AdminActions) onlyAdmin {
        _protocolFee = ConfiguratorLogic.feeBps(fee, BPS);
        emit ProtocolFeeUpdated(fee);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setLiquidatorFee(uint256 fee) external override(IAlchemistV3AdminActions) onlyAdmin {
        _liquidatorFee = ConfiguratorLogic.feeBps(fee, BPS);
        emit LiquidatorFeeUpdated(fee);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setRepaymentFee(uint256 fee) external override(IAlchemistV3AdminActions) onlyAdmin {
        _repaymentFee = ConfiguratorLogic.feeBps(fee, BPS);
        emit RepaymentFeeUpdated(fee);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setTokenAdapter(address value) external override(IAlchemistV3AdminActions) onlyAdmin {
        if (value == address(0)) revert IllegalArgument();
        _tokenAdapter = value;
        emit TokenAdapterUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setGuardian(address guardian, bool isActive)
        external
        override(IAlchemistV3AdminActions)
        onlyAdmin
    {
        if (guardian == address(0)) revert IllegalArgument();
        _guardians[guardian] = isActive;
        emit GuardianSet(guardian, isActive);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setMinimumCollateralization(uint256 value)
        external
        override(IAlchemistV3AdminActions)
        onlyAdmin
    {
        if (value < FIXED_POINT_SCALAR) revert IllegalArgument();
        _minimumCollateralization = value > _globalMinimumCollateralization ? _globalMinimumCollateralization : value;
        if (_minimumCollateralization > _liquidationTargetCollateralization) {
            _minimumCollateralization = _liquidationTargetCollateralization;
        }
        emit MinimumCollateralizationUpdated(_minimumCollateralization);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setGlobalMinimumCollateralization(uint256 value)
        external
        override(IAlchemistV3AdminActions)
        onlyAdmin
    {
        if (value < _minimumCollateralization) revert IllegalArgument();
        _globalMinimumCollateralization = value;
        emit GlobalMinimumCollateralizationUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setCollateralizationLowerBound(uint256 value)
        external
        override(IAlchemistV3AdminActions)
        onlyAdmin
    {
        if (value >= _minimumCollateralization) revert IllegalArgument();
        if (value < FIXED_POINT_SCALAR) revert IllegalArgument();
        _collateralizationLowerBound = value;
        emit CollateralizationLowerBoundUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setLiquidationTargetCollateralization(uint256 value)
        external
        override(IAlchemistV3AdminActions)
        onlyAdmin
    {
        if (value <= FIXED_POINT_SCALAR) revert IllegalArgument();
        if (value < _minimumCollateralization) revert IllegalArgument();
        if (value <= _collateralizationLowerBound) revert IllegalArgument();
        if (value > 2 * FIXED_POINT_SCALAR) revert IllegalArgument();
        _liquidationTargetCollateralization = value;
        emit LiquidationTargetCollateralizationUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function pauseDeposits(bool isPaused)
        external
        override(IAlchemistV3AdminActions)
        onlyAdminOrGuardian
    {
        _depositsPaused = isPaused;
        emit DepositsPaused(isPaused);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function pauseLoans(bool isPaused)
        external
        override(IAlchemistV3AdminActions)
        onlyAdminOrGuardian
    {
        _loansPaused = isPaused;
        emit LoansPaused(isPaused);
    }
}
