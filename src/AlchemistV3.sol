// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./interfaces/IAlchemistV3.sol";
import {ITransmuter} from "./interfaces/ITransmuter.sol";
import {IAlchemistV3Position} from "./interfaces/IAlchemistV3Position.sol";
import {IFeeVault} from "./interfaces/IFeeVault.sol";
import {AlchemistV3AdminModule} from "./modules/AlchemistV3AdminModule.sol";
import {TokenUtils} from "./libraries/TokenUtils.sol";
import {Unauthorized, IllegalArgument, IllegalState, MissingInputData} from "./base/Errors.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {FixedPointMath} from "./libraries/FixedPointMath.sol";

/// @title  AlchemistV3
/// @author Alchemix Finance
///
/// For Juris, Graham, and Marcus
contract AlchemistV3 is AlchemistV3AdminModule {
    function initialize(AlchemistInitializationParams memory params) external initializer {
        _initialize(params);
    }

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

    /// @inheritdoc IAlchemistV3Actions
    function deposit(uint256 amount, address recipient, uint256 tokenId) external returns (uint256) {
        _validateDepositRequest(amount, recipient);
        tokenId = _resolveDepositAccount(tokenId, recipient);
        _depositCollateral(tokenId, amount);

        emit Deposit(amount, tokenId);

        return convertYieldTokensToDebt(amount);
    }

    /// @inheritdoc IAlchemistV3Actions
    function withdraw(uint256 amount, address recipient, uint256 tokenId) external returns (uint256) {
        _validateWithdrawRequest(tokenId, amount, recipient);
        uint256 transferred = _withdrawCollateral(tokenId, amount, recipient);

        emit Withdraw(transferred, tokenId, recipient);

        return transferred;
    }

    /// @inheritdoc IAlchemistV3Actions
    function mint(uint256 tokenId, uint256 amount, address recipient) external {
        _validateMintRequest(tokenId, amount, recipient);
        _requireTokenOwner(tokenId, msg.sender);
        _executeMintRequest(tokenId, amount, recipient);
    }

    /// @inheritdoc IAlchemistV3Actions
    function mintFrom(uint256 tokenId, uint256 amount, address recipient) external {
        _validateMintRequest(tokenId, amount, recipient);
        // Preemptively try and decrease the minting allowance. This will save gas when the allowance is not sufficient.
        _decreaseMintAllowance(tokenId, msg.sender, amount);
        _executeMintRequest(tokenId, amount, recipient);
    }

    /// @inheritdoc IAlchemistV3Actions
    function burn(uint256 amount, uint256 recipientId) external returns (uint256) {
        _prepareDebtRepayment(recipientId, amount);

        uint256 debt;
        // Burning alAssets can only repay unearmarked debt
        _checkState((debt = _accounts[recipientId].debt - _accounts[recipientId].earmarked) > 0);

        uint256 credit = _capDebtCredit(amount, debt);
        if (credit == 0) return 0;

        // Must only burn enough tokens that the transmuter positions can still be fulfilled
        if (credit > totalSyntheticsIssued - ITransmuter(transmuter).totalLocked()) {
            revert BurnLimitExceeded(credit, totalSyntheticsIssued - ITransmuter(transmuter).totalLocked());
        }

        // Burn the tokens from the message sender
        TokenUtils.safeBurnFrom(debtToken, msg.sender, credit);

        // Update the position debt.
        _subDebt(recipientId, credit);
        _accounts[recipientId].lastRepayBlock = block.number;

        totalSyntheticsIssued -= credit;

        // Assure that the collateralization invariant is still held.
        _validate(recipientId);

        emit Burn(msg.sender, credit, recipientId);

        return credit;
    }

    /// @inheritdoc IAlchemistV3Actions
    function repay(uint256 amount, uint256 recipientTokenId) public returns (uint256) {
        _prepareDebtRepayment(recipientTokenId, amount);
        Account storage account = _accounts[recipientTokenId];

        uint256 debt;

        // Force-repay burns debt against the account's current total debt.
        _checkState((debt = account.debt) > 0);

        uint256 yieldToDebt = convertYieldTokensToDebt(amount);
        uint256 credit = _capDebtCredit(yieldToDebt, debt);
        if (credit == 0) return 0;

        // Repay debt from earmarked amount of debt first
        uint256 earmarkedRepaid = _subEarmarkedDebt(credit, recipientTokenId);


        uint256 creditToYield = convertDebtTokensToYield(credit);
        uint256 earmarkedRepaidToYield = convertDebtTokensToYield(earmarkedRepaid);


        // Protocol fee only applies to earmarked debt repaid.
        uint256 feeAmount = earmarkedRepaidToYield * protocolFee / BPS;
        if (feeAmount > account.collateralBalance) {
            revert IllegalState();
        } else {
            _subCollateralBalance(feeAmount, recipientTokenId);
        }

        _subDebt(recipientTokenId, credit);
        account.lastRepayBlock = block.number;

        // Transfer the repaid tokens to the transmuter.
        TokenUtils.safeTransferFrom(myt, msg.sender, transmuter, creditToYield);
        if (feeAmount > 0) {
            TokenUtils.safeTransfer(myt, protocolFeeReceiver, feeAmount);
        }
        emit Repay(msg.sender, amount, recipientTokenId, creditToYield);

        return creditToYield;
    }

    /// @inheritdoc IAlchemistV3Actions
    function liquidate(uint256 accountId) external override returns (uint256 yieldAmount, uint256 feeInYield, uint256 feeInUnderlying) {
        _checkForValidAccountId(accountId);
        bool progressed;
        (yieldAmount, feeInYield, feeInUnderlying, progressed) = _executeLiquidation(accountId);
        if (!progressed) revert LiquidationError();
        return (yieldAmount, feeInYield, feeInUnderlying);
    }

    /// @inheritdoc IAlchemistV3Actions
    function batchLiquidate(uint256[] memory accountIds)
        external
        returns (uint256 totalAmountLiquidated, uint256 totalFeesInYield, uint256 totalFeesInUnderlying)
    {
        if (accountIds.length == 0) {
            revert MissingInputData();
        }

        bool anyProgress = false;
        for (uint256 i = 0; i < accountIds.length; i++) {
            uint256 accountId = accountIds[i];
            if (accountId == 0 || !_tokenExists(alchemistPositionNFT, accountId)) {
                continue;
            }
            uint256 underlyingAmount;
            uint256 feeInYield;
            uint256 feeInUnderlying;
            bool progressed;
            (underlyingAmount, feeInYield, feeInUnderlying, progressed) = _executeLiquidation(accountId);
            totalAmountLiquidated += underlyingAmount;
            totalFeesInYield += feeInYield;
            totalFeesInUnderlying += feeInUnderlying;
            if (progressed) anyProgress = true;
        }

        if (anyProgress) {
            return (totalAmountLiquidated, totalFeesInYield, totalFeesInUnderlying);
        } else {
            // no total liquidation amount returned, so no liquidations happened
            revert LiquidationError();
        }
    }

    /// @inheritdoc IAlchemistV3Actions
    function redeem(uint256 amount) external onlyTransmuter returns (uint256 sharesSent) {
        _earmark();

        uint256 liveEarmarked = cumulativeEarmarked;
        if (amount > liveEarmarked) amount = liveEarmarked;

        uint256 effectiveRedeemed = _applyRedemptionWindow(liveEarmarked, amount);

        lastRedemptionBlock = block.number;

        // Use the effective redeemed amount everywhere downstream
        uint256 collRedeemed  = convertDebtTokensToYield(effectiveRedeemed);
        uint256 feeCollateral = collRedeemed * protocolFee / BPS;

        _totalRedeemedDebt += effectiveRedeemed;
        _totalRedeemedSharesOut += collRedeemed;

        TokenUtils.safeTransfer(myt, transmuter, collRedeemed);
        _mytSharesDeposited -= collRedeemed;

        // Skip the protocol fee if the remaining MYT shares cannot cover it.
        if (feeCollateral <= _mytSharesDeposited) {
            TokenUtils.safeTransfer(myt, protocolFeeReceiver, feeCollateral);
            _mytSharesDeposited -= feeCollateral;
            _totalRedeemedSharesOut += feeCollateral;
        }

        emit Redemption(effectiveRedeemed);
        return collRedeemed;
    }

    /// @inheritdoc IAlchemistV3Actions
    function selfLiquidate(uint256 accountId, address recipient) public returns (uint256 amountLiquidated) {
        _requireNonZeroAddress(recipient);
        _checkForValidAccountId(accountId);
        _requireTokenOwner(accountId, msg.sender);
        _poke(accountId);
        _checkState(_accounts[accountId].debt > 0);
        if (!_isAccountHealthy(accountId, false)) {
            // must use the regular liquidation path i.e. liquidate(accountId)
           revert AccountNotHealthy();
        }
        Account storage account = _accounts[accountId];

        // Repay any earmarked debt 
        uint256 repaidEarmarkedDebtInYield = _forceRepay(accountId, account.earmarked, true);
    
        uint256 debt = account.debt;

        // then clear all remaining debt
        _subDebt(accountId, debt);

        // sub the collateral used for repaying debt
        uint256 repaidDebtInYield = _subCollateralBalance(convertDebtTokensToYield(debt), accountId);

        // clear all remaining collateral
        uint256 remainingCollateral = _subCollateralBalance(account.collateralBalance, accountId);

        if(repaidDebtInYield > 0) {
            // transfer collateral used for repaying debt to transmuter
            TokenUtils.safeTransfer(myt, transmuter, repaidDebtInYield);
        }

        if(remainingCollateral > 0) {
            // transfer remaining collateral to the recipient
            TokenUtils.safeTransfer(myt, recipient, remainingCollateral);
        }   
        // emit event
        emit SelfLiquidated(accountId, repaidEarmarkedDebtInYield + repaidDebtInYield);
        return repaidEarmarkedDebtInYield + repaidDebtInYield;
    }

    /// @inheritdoc IAlchemistV3State
    function calculateLiquidation(
        uint256 collateral,
        uint256 debt,
        uint256 targetCollateralization,
        uint256 alchemistCurrentCollateralization,
        uint256 alchemistMinimumCollateralization,
        uint256 feeBps
    ) public pure returns (uint256 grossCollateralToSeize, uint256 debtToBurn, uint256 fee, uint256 outsourcedFee) {
        if (debt >= collateral) {
            outsourcedFee = (debt * feeBps) / BPS;
            // fully liquidate debt if debt is greater than collateral
            return (collateral, debt, 0, outsourcedFee);
        }

        if (alchemistCurrentCollateralization < alchemistMinimumCollateralization) {
            outsourcedFee = (debt * feeBps) / BPS;
            // fully liquidate debt in high ltv global environment
            return (debt, debt, 0, outsourcedFee);
        }

        // fee is taken from surplus = collateral - debt
        uint256 surplus = collateral - debt;

        fee = (surplus * feeBps) / BPS;

        // collateral remaining for margin‐restore calc
        uint256 adjCollat = collateral - fee;
        // compute m*d  (both plain units)
        uint256 md = (targetCollateralization * debt) / FIXED_POINT_SCALAR;
        // if md <= adjCollat, nothing to liquidate
        if (md <= adjCollat) {
            return (0, 0, 0, 0);
        }

        // numerator = md - adjCollat
        uint256 num = md - adjCollat;

        // denom = m - 1  =>  (targetCollateralization - FIXED_POINT_SCALAR)/FIXED_POINT_SCALAR
        uint256 denom = targetCollateralization - FIXED_POINT_SCALAR;

        debtToBurn = (num * FIXED_POINT_SCALAR) / denom;

        // gross collateral seize = net + fee
        grossCollateralToSeize = debtToBurn + fee;
    }

    ///@inheritdoc IAlchemistV3Actions
    function reduceSyntheticsIssued(uint256 amount) external onlyTransmuter {
        totalSyntheticsIssued -= amount;
    }

    ///@inheritdoc IAlchemistV3Actions
    function setTransmuterTokenBalance(uint256 amount) external onlyTransmuter {
        uint256 last = lastTransmuterTokenBalance;

        // If balance went down, assume cover could have been spent and reduce it conservatively.
        if (amount < last) {
            uint256 spent = last - amount;
            uint256 cover = _pendingCoverShares;

            if (spent >= cover) {
                _pendingCoverShares = 0;
            } else {
                _pendingCoverShares = cover - spent;
            }
        }

        // Always keep cover <= actual transmuter balance.
        if (_pendingCoverShares > amount) {
            _pendingCoverShares = amount;
        }

        // Update baseline
        lastTransmuterTokenBalance = amount;
    }

    /// @inheritdoc IAlchemistV3Actions
    function poke(uint256 tokenId) external {
        _checkForValidAccountId(tokenId);
        _poke(tokenId);
    }


    /// @dev Pokes the account owned by `tokenId` to realize committed global accounting.
    /// @param tokenId The tokenId of the account to poke.
    function _poke(uint256 tokenId) internal {
        _earmarkAndSyncAccount(tokenId, false);
    }

    /// @inheritdoc IAlchemistV3Actions
    function approveMint(uint256 tokenId, address spender, uint256 amount) external {
        _requireOwnedAccount(tokenId, msg.sender);
        _approveMint(tokenId, spender, amount);
    }

    /// @inheritdoc IAlchemistV3Actions
    function resetMintAllowances(uint256 tokenId) external {
        _requireMintAllowanceResetAuthorized(tokenId, msg.sender);
        _resetMintAllowances(tokenId);
    }

    /// @inheritdoc IAlchemistV3State
    function convertYieldTokensToDebt(uint256 amount) public view returns (uint256) {
        return normalizeUnderlyingTokensToDebt(convertYieldTokensToUnderlying(amount));
    }

    /// @inheritdoc IAlchemistV3State
    function convertDebtTokensToYield(uint256 amount) public view returns (uint256) {
        return convertUnderlyingTokensToYield(normalizeDebtTokensToUnderlying(amount));
    }

    /// @inheritdoc IAlchemistV3State
    function convertYieldTokensToUnderlying(uint256 amount) public view returns (uint256) {
        return IVaultV2(myt).convertToAssets(amount);
    }

    /// @inheritdoc IAlchemistV3State
    function convertUnderlyingTokensToYield(uint256 amount) public view returns (uint256) {
        return IVaultV2(myt).convertToShares(amount);
    }

    /// @inheritdoc IAlchemistV3State
    function normalizeUnderlyingTokensToDebt(uint256 amount) public view returns (uint256) {
        return amount * underlyingConversionFactor;
    }

    /// @inheritdoc IAlchemistV3State
    function normalizeDebtTokensToUnderlying(uint256 amount) public view returns (uint256) {
        return amount / underlyingConversionFactor;
    }

    /// @dev Mints debt tokens to `recipient` using the account owned by `tokenId`.
    /// @param tokenId     The tokenId of the account to mint from.
    /// @param amount    The amount to mint.
    /// @param recipient The recipient of the minted debt tokens.
    function _mint(uint256 tokenId, uint256 amount, address recipient) internal {
        if (block.number == _accounts[tokenId].lastRepayBlock) revert CannotMintOnRepayBlock();
        _addDebt(tokenId, amount);

        totalSyntheticsIssued += amount;

        // Validate the tokenId's account to assure that the collateralization invariant is still held.
        _validate(tokenId);

        _accounts[tokenId].lastMintBlock = block.number;

        // Mint the debt tokens to the recipient.
        TokenUtils.safeMint(debtToken, recipient, amount);

        emit Mint(tokenId, amount, recipient);
    }

    /**
     * @notice Force repays earmarked debt of the account owned by `accountId` using account's collateral balance.
     * @param accountId The tokenId of the account to repay from.
     * @param amount The amount to repay in debt tokens.
     * @return creditToYield The amount of yield tokens repaid.
     */
     function _forceRepay(uint256 accountId, uint256 amount, bool skipPoke) internal returns (uint256) {
        if (amount == 0) {
            return 0;
        }
        _checkForValidAccountId(accountId);
        if (!skipPoke) {
            _poke(accountId);
        }
        Account storage account = _accounts[accountId];
        uint256 debt;

        // Yield-token repayment can cover both earmarked and unearmarked debt.
        _checkState((debt = account.debt) > 0);

        // earmarked debt always <= account debt
        uint256 credit = _capDebtCredit(amount, debt);
        if (credit == 0) return 0;
        // Repay debt from earmarked amount of debt first
        _subEarmarkedDebt(credit, accountId);
        _subDebt(accountId, credit);
        
        // Remove the realized debt value from collateral.
        uint256 creditToYield = _subCollateralBalance(convertDebtTokensToYield(credit), accountId);

        // Remove any protocol fee from remaining collateral.
        uint256 targetProtocolFee = creditToYield * protocolFee / BPS;
        uint256 protocolFeeTotal = _subCollateralBalance(targetProtocolFee, accountId);


        emit ForceRepay(accountId, amount, creditToYield, protocolFeeTotal);

        if (creditToYield > 0) {
            // Transfer the repaid tokens from the account to the transmuter.
            TokenUtils.safeTransfer(myt, address(transmuter), creditToYield);
        }

        if (protocolFeeTotal > 0) {
            // Transfer the protocol fee to the protocol fee receiver
            TokenUtils.safeTransfer(myt, protocolFeeReceiver, protocolFeeTotal);
        }

        return creditToYield;
    }

    /// @dev Fetches and applies the liquidation amount to account `tokenId` if the account collateral ratio touches `collateralizationLowerBound`.
    /// @dev Repays earmarked debt if it exists
    /// @dev If earmarked repayment restores account to healthy collateralization, no liquidation is performed. Caller receives a repayment fee.
    /// @param accountId  The tokenId of the account to to liquidate.
    /// @return amountLiquidated  The amount (in yield tokens) removed from the account `tokenId`.
    /// @return feeInYield The additional fee as a % of the liquidation amount to be sent to the liquidator
    /// @return feeInUnderlying The additional fee as a % of the liquidation amount, denominated in underlying token, to be sent to the liquidator
    function _liquidate(uint256 accountId) internal returns (uint256 amountLiquidated, uint256 feeInYield, uint256 feeInUnderlying) {
        // Query transmuter and earmark global debt
        _earmark();
        // Sync current user debt before deciding how much needs to be liquidated
        _sync(accountId);

        Account storage account = _accounts[accountId];

        // In the rare scenario where 1 share is worth 0 underlying asset
        if (IVaultV2(myt).convertToAssets(1e18) == 0) {
            return (0, 0, 0);
        }
       
        if (_isAccountHealthy(accountId, false)) {
            return (0, 0, 0);
        }

        // Try to repay earmarked debt if it exists
        uint256 repaidAmountInYield = 0;
        if (account.earmarked > 0) {
            repaidAmountInYield = _forceRepay(accountId, account.earmarked, false);
            feeInYield = _calculateRepaymentFee(repaidAmountInYield);
            // Final safety check after all deductions
            if (account.collateralBalance == 0 && account.debt > 0) {
                uint256 debtToClear = _clearableDebt(account.debt);
                if (debtToClear > 0) {
                    _subDebt(accountId, debtToClear);
                }
            }
        }

        // Recalculate ratio after any repayment to determine if further liquidation is needed
        if (_isAccountHealthy(accountId, false)) {
            if (feeInYield > 0) {
                uint256 targetFeeInYield = feeInYield;
                uint256 maxSafeFeeInYield = _maxRepaymentFeeInYield(accountId);
                // All-or-nothing source switch:
                // if account cannot safely cover full fee, pay entirely from fee vault.
                if (maxSafeFeeInYield < targetFeeInYield) {
                    feeInYield = 0;
                    feeInUnderlying = convertYieldTokensToUnderlying(targetFeeInYield);
                }
            }

            if (feeInYield > 0) {
                feeInYield = _subCollateralBalance(feeInYield, accountId); // clamps to available balance
                TokenUtils.safeTransfer(myt, msg.sender, feeInYield);
            } else if (feeInUnderlying > 0) {
                feeInUnderlying = _payWithFeeVault(feeInUnderlying);
            }
            emit RepaymentFee(accountId, msg.sender, feeInYield, feeInUnderlying);
            return (repaidAmountInYield, feeInYield, feeInUnderlying);
        } else {
            // Do actual liquidation
            return _doLiquidation(accountId);
        }

    }

    /// @dev Pays the fee to msg.sender in underlying tokens using the fee vault
    /// @param amountInUnderlying The amount of underlying tokens to pay
    /// @return actual amount paid based on the vault balance
    function _payWithFeeVault(uint256 amountInUnderlying) internal returns (uint256) {
        if (amountInUnderlying == 0) return 0;
        if (alchemistFeeVault == address(0)) {
            emit FeeShortfall(msg.sender, amountInUnderlying, 0);
            return 0;
        }
        uint256 vaultBalance = IFeeVault(alchemistFeeVault).totalDeposits();
        if (vaultBalance > 0) {
            uint256 adjustedAmount = amountInUnderlying > vaultBalance ? vaultBalance : amountInUnderlying;
            IFeeVault(alchemistFeeVault).withdraw(msg.sender, adjustedAmount);
            if (adjustedAmount < amountInUnderlying) {
                emit FeeShortfall(msg.sender, amountInUnderlying, adjustedAmount);
            }
            return adjustedAmount;
        }
        emit FeeShortfall(msg.sender, amountInUnderlying, 0);
        return 0;
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

    /// @dev Performs the actual liquidation logic when collateralization is below the lower bound
    /// @param accountId The tokenId of the account to to liquidate.
    /// @return amountLiquidated The amount of yield tokens liquidated.
    /// @return feeInYield The fee in yield tokens to be sent to the liquidator.
    /// @return feeInUnderlying The fee in underlying tokens to be sent to the liquidator.
    function _doLiquidation(uint256 accountId)
        internal
        returns (uint256 amountLiquidated, uint256 feeInYield, uint256 feeInUnderlying)
    {
        Account storage account = _accounts[accountId];
        uint256 debt = account.debt;
        uint256 collateralInUnderlying = totalValue(accountId);
        (uint256 liquidationAmount, uint256 debtToBurn, uint256 baseFee, uint256 outsourcedFee) = calculateLiquidation(
            collateralInUnderlying,
            debt,
            liquidationTargetCollateralization,
            _globalCollateralization(),
            globalMinimumCollateralization,
            liquidatorFee
        );

        if (liquidationAmount == 0) {
            // Debt-only closeout path: account can be insolvent with no remaining collateral to seize.
            if (debtToBurn > 0) {
                uint256 burnableDebt = _capDebtCredit(debtToBurn, account.debt);
                if (burnableDebt > 0) {
                    _subDebt(accountId, burnableDebt);
                }
            }

            uint256 feeRequestInUnderlying = normalizeDebtTokensToUnderlying(outsourcedFee);
            if (feeRequestInUnderlying > 0) {
                feeInUnderlying = _payWithFeeVault(feeRequestInUnderlying);
            }

            if (account.debt < debt || feeInUnderlying > 0) {
                emit Liquidated(accountId, msg.sender, 0, 0, feeInUnderlying);
                return (0, 0, feeInUnderlying);
            }

            return (0, 0, 0);
        }

        uint256 requestedLiquidationInYield = convertDebtTokensToYield(liquidationAmount);
        amountLiquidated = _subCollateralBalance(requestedLiquidationInYield, accountId);
        if (amountLiquidated == 0) return (0, 0, 0);

        // Fee and debt burn are derived from idealized liquidation math, so clamp them to what was
        // actually realized after collateral capping to avoid underflow and over-burning debt.
        uint256 requestedFeeInYield = convertDebtTokensToYield(baseFee);
        feeInYield = requestedFeeInYield > amountLiquidated ? amountLiquidated : requestedFeeInYield;

        uint256 netToTransmuter = amountLiquidated - feeInYield;
        uint256 maxDebtByRealized = convertYieldTokensToDebt(netToTransmuter);
        uint256 maxDebtByStorage = account.debt < totalDebt ? account.debt : totalDebt;

        if (debtToBurn > maxDebtByRealized) debtToBurn = maxDebtByRealized;
        if (debtToBurn > maxDebtByStorage) debtToBurn = maxDebtByStorage;

        // update user debt
        if (debtToBurn > 0) {
            _subDebt(accountId, debtToBurn);
        }

        // If liquidation still leaves the account unhealthy, force-close the residual:
        // sweep all remaining collateral and clear any debt that cannot be backed anymore.
        if (account.debt > 0 && !_isAccountHealthy(accountId, false)) {
            uint256 remainingShares = account.collateralBalance;
            if (remainingShares > 0) {
                uint256 removedShares = _subCollateralBalance(remainingShares, accountId);
                netToTransmuter += removedShares;

                uint256 extraDebtBurn = _capDebtCredit(convertYieldTokensToDebt(removedShares), account.debt);
                if (extraDebtBurn > 0) {
                    _subDebt(accountId, extraDebtBurn);
                }
            }

            if (account.collateralBalance == 0 && account.debt > 0) {
                uint256 debtToClear = _clearableDebt(account.debt);
                if (debtToClear > 0) {
                    _subDebt(accountId, debtToClear);
                }
            }
        }

        // send liquidation amount net of liquidator fee to transmuter
        TokenUtils.safeTransfer(myt, transmuter, netToTransmuter);

        // send base fee to liquidator if available
        if (feeInYield > 0) {
            TokenUtils.safeTransfer(myt, msg.sender, feeInYield);
        } else if (normalizeDebtTokensToUnderlying(outsourcedFee) > 0) {
            // Handle outsourced fee from vault
            feeInUnderlying = _payWithFeeVault(normalizeDebtTokensToUnderlying(outsourcedFee));
        }
        emit Liquidated(accountId, msg.sender, amountLiquidated, feeInYield, feeInUnderlying);
        return (amountLiquidated, feeInYield, feeInUnderlying);
    }

 
    /// @dev Handles repayment fee calculation.
    /// @param repaidAmountInYield The amount of debt repaid in yield tokens.
    /// @return feeInYield The fee in yield tokens to be sent to the liquidator.
    function _calculateRepaymentFee(uint256 repaidAmountInYield) internal view returns (uint256 feeInYield) {
        return repaidAmountInYield * repaymentFee / BPS;
    }

    /// @dev Returns max yield-fee removable while remaining strictly healthy (> lower bound).
    /// @param accountId The tokenId of the account to compute the max repayment fee for.
    /// @return The max repayment fee in yield tokens.
    function _maxRepaymentFeeInYield(uint256 accountId) internal view returns (uint256) {
        Account storage account = _accounts[accountId];
        uint256 debt = account.debt;
        if (debt == 0) {
            return account.collateralBalance;
        }

        uint256 collateralInDebt = convertYieldTokensToDebt(account.collateralBalance);
        uint256 minimumByLowerBound = FixedPointMath.mulDivUp(debt, collateralizationLowerBound, FIXED_POINT_SCALAR);
        if (minimumByLowerBound == type(uint256).max) {
            return 0;
        }

        // _isAccountHealthy uses a strict ">" check, so retain one debt-unit of margin.
        uint256 minRequiredPostFee = minimumByLowerBound + 1;
        if (collateralInDebt <= minRequiredPostFee) {
            return 0;
        }

        uint256 removableInDebt = collateralInDebt - minRequiredPostFee;
        return convertDebtTokensToYield(removableInDebt);
    }

    /// @dev Increases the debt by `amount` for the account owned by `tokenId`.
    ///
    /// @param tokenId   The account owned by tokenId.
    /// @param amount  The amount to increase the debt by.
    function _addDebt(uint256 tokenId, uint256 amount) internal {
        Account storage account = _accounts[tokenId];

        uint256 newDebt = account.debt + amount;

        // After _sync(tokenId), you can use the current collateralBalance (no simulation needed)
        uint256 collateralValue = _collateralValueInDebt(_accountCollateralBalance(tokenId, false));

        uint256 required = FixedPointMath.mulDivUp(newDebt, minimumCollateralization, FIXED_POINT_SCALAR);
        if (collateralValue < required) revert Undercollateralized();

        account.debt = newDebt;
        totalDebt += amount;
    }

    function _executeLiquidation(uint256 accountId)
        internal
        returns (uint256 amountLiquidated, uint256 feeInYield, uint256 feeInUnderlying, bool progressed)
    {
        uint256 debtBefore = _accounts[accountId].debt;
        (amountLiquidated, feeInYield, feeInUnderlying) = _liquidate(accountId);
        progressed = _didLiquidationProgress(
            debtBefore, _accounts[accountId].debt, amountLiquidated, feeInYield, feeInUnderlying
        );
    }

    function _didLiquidationProgress(
        uint256 debtBefore,
        uint256 debtAfter,
        uint256 amountLiquidated,
        uint256 feeInYield,
        uint256 feeInUnderlying
    ) internal pure returns (bool) {
        return amountLiquidated > 0 || feeInYield > 0 || feeInUnderlying > 0 || debtAfter < debtBefore;
    }

    function _earmarkAndSyncAccount(uint256 tokenId, bool enforceNoBadDebt) internal {
        _earmark();
        if (enforceNoBadDebt) {
            _checkState(!_isProtocolInBadDebt());
        }
        _sync(tokenId);
    }

    function _prepareDebtRepayment(uint256 tokenId, uint256 amount) internal {
        _requirePositiveAmount(amount);
        _checkForValidAccountId(tokenId);
        _requireNotMintedThisBlock(tokenId);
        _earmarkAndSyncAccount(tokenId, false);
    }

    function _validateMintRequest(uint256 tokenId, uint256 amount, address recipient) internal view {
        _requireNonZeroAddress(recipient);
        _checkForValidAccountId(tokenId);
        _requirePositiveAmount(amount);
        _requireLoansEnabled();
    }

    function _executeMintRequest(uint256 tokenId, uint256 amount, address recipient) internal {
        _earmarkAndSyncAccount(tokenId, true);
        _mint(tokenId, amount, recipient);
    }

    function _validateDepositRequest(uint256 amount, address recipient) internal view {
        _requireNonZeroAddress(recipient);
        _requirePositiveAmount(amount);
        _requireDepositsEnabledAndSolvent();
        _checkState(_mytSharesDeposited + amount <= depositCap);
    }

    function _resolveDepositAccount(uint256 tokenId, address recipient) internal returns (uint256) {
        if (tokenId == 0) {
            tokenId = IAlchemistV3Position(alchemistPositionNFT).mint(recipient);
            emit AlchemistV3PositionNFTMinted(recipient, tokenId);
            return tokenId;
        }

        _checkForValidAccountId(tokenId);
        _earmarkAndSyncAccount(tokenId, false);
        return tokenId;
    }

    function _depositCollateral(uint256 tokenId, uint256 amount) internal {
        _accounts[tokenId].collateralBalance += amount;

        // Transfer tokens from msg.sender now that the internal storage updates have been committed.
        TokenUtils.safeTransferFrom(myt, msg.sender, address(this), amount);
        _mytSharesDeposited += amount;
    }

    function _validateWithdrawRequest(uint256 tokenId, uint256 amount, address recipient) internal {
        _requireNonZeroAddress(recipient);
        _checkForValidAccountId(tokenId);
        _requirePositiveAmount(amount);
        _requireTokenOwner(tokenId, msg.sender);
        _earmarkAndSyncAccount(tokenId, false);
    }

    function _withdrawCollateral(uint256 tokenId, uint256 amount, address recipient) internal returns (uint256 transferred) {
        _reconcileCollateralBalance(tokenId);

        uint256 debtShares = convertDebtTokensToYield(_accounts[tokenId].debt);
        uint256 lockedCollateral = FixedPointMath.mulDivUp(debtShares, minimumCollateralization, FIXED_POINT_SCALAR);
        _checkArgument(_accounts[tokenId].collateralBalance - lockedCollateral >= amount);
        transferred = _subCollateralBalance(amount, tokenId);

        // Assure that the collateralization invariant is still held.
        _validate(tokenId);

        TokenUtils.safeTransfer(myt, recipient, transferred);
    }

    function _reconcileCollateralBalance(uint256 tokenId) internal {
        if (_accounts[tokenId].collateralBalance > _mytSharesDeposited) {
            _accounts[tokenId].collateralBalance = _mytSharesDeposited;
        }
    }

    /// @dev Realizes committed global earmark/redemption state for an account.
    function _sync(uint256 tokenId) internal {
        Account storage account = _accounts[tokenId];
        (uint256 newDebt, uint256 newEarmarked, uint256 collateralBalance,) = _computeCommittedAccountState(account);

        account.collateralBalance = collateralBalance;
        account.earmarked = newEarmarked;
        account.debt = newDebt;
        _checkpointAccountState(account);
    }

    /// @dev Computes account state against committed globals only.
    /// @return newDebt The debt after applying committed earmark + redemption.
    /// @return newEarmarked The earmarked portion after applying committed globals.
    /// @return collateralBalance The collateral after realized redemption debits.
    /// @return redeemedDebt The debt redeemed from committed global state.
    function _computeCommittedAccountState(Account storage account)
        internal
        view
        returns (uint256 newDebt, uint256 newEarmarked, uint256 collateralBalance, uint256 redeemedDebt)
    {
        (newDebt, newEarmarked, redeemedDebt) =
            _computeUnrealizedAccount(account, _earmarkWeight, _redemptionWeight, _survivalAccumulator);
        collateralBalance = _applyRedeemedCollateralDelta(account, account.collateralBalance, redeemedDebt);
    }

    /// @dev Applies realized collateral debits from redemptions and protocol fees.
    function _applyRedeemedCollateralDelta(
        Account storage account,
        uint256 collateralBalance,
        uint256 redeemedDebt
    ) internal view returns (uint256) {
        uint256 globalDebtDelta = _totalRedeemedDebt - account.lastTotalRedeemedDebt;
        if (globalDebtDelta == 0 || redeemedDebt == 0) {
            return collateralBalance;
        }

        uint256 globalSharesDelta = _totalRedeemedSharesOut - account.lastTotalRedeemedSharesOut;
        uint256 sharesToDebit = FixedPointMath.mulDivUp(redeemedDebt, globalSharesDelta, globalDebtDelta);
        if (sharesToDebit > collateralBalance) sharesToDebit = collateralBalance;
        return collateralBalance - sharesToDebit;
    }

    /// @dev Applies one simulated, uncommitted earmark window on top of committed account state.
    function _applyProspectiveEarmark(
        uint256 debt,
        uint256 earmarked,
        uint256 committedEarmarkWeight,
        uint256 simulatedEarmarkWeight
    ) internal pure returns (uint256) {
        if (simulatedEarmarkWeight == committedEarmarkWeight) {
            return earmarked;
        }

        uint256 exposure = debt > earmarked ? debt - earmarked : 0;
        if (exposure == 0) {
            return earmarked;
        }

        uint256 unearmarkedRatio = _earmarkSurvivalRatio(committedEarmarkWeight, simulatedEarmarkWeight);
        uint256 unearmarkedRemaining = FixedPointMath.mulQ128(exposure, unearmarkedRatio);
        uint256 newlyEarmarked = exposure - unearmarkedRemaining;
        earmarked += newlyEarmarked;
        return earmarked > debt ? debt : earmarked;
    }

    /// @dev Computes account debt and earmark state at a given global weight snapshot.
    /// @return newDebt The debt after applying earmark + redemption.
    /// @return newEarmarked The earmarked portion after applying survival and new earmarks.
    /// @return redeemedDebt Realized redeemed debt for this step.
    function _computeUnrealizedAccount(
        Account storage account,
        uint256 earmarkWeightCurrent,
        uint256 redemptionWeightCurrent,
        uint256 survivalAccumulatorCurrent
    ) internal view returns (uint256 newDebt, uint256 newEarmarked, uint256 redeemedDebt) {
        // Survival during current sync window
        uint256 survivalRatio = 
            _redemptionSurvivalRatio(account.lastAccruedRedemptionWeight, redemptionWeightCurrent);

        // User exposure at last sync used to calculate newly earmarked debt pre redemption
        uint256 userExposure = account.debt > account.earmarked ? account.debt - account.earmarked : 0;
        uint256 unearmarkSurvivalRatio = 
            _earmarkSurvivalRatio(account.lastAccruedEarmarkWeight, earmarkWeightCurrent);

        // amount that stayed unearmarked from userExposure
        uint256 unearmarkedRemaining = FixedPointMath.mulQ128(userExposure, unearmarkSurvivalRatio);

        // amount newly earmarked since last sync
        uint256 earmarkRaw = userExposure - unearmarkedRemaining;

        // No redemption in this sync window -> debt cannot decrease.
        if (survivalRatio == ONE_Q128) {
            newDebt = account.debt;
            newEarmarked = account.earmarked + earmarkRaw;
            if (newEarmarked > newDebt) newEarmarked = newDebt;
            redeemedDebt = 0;
            return (newDebt, newEarmarked, redeemedDebt);
        }

        // Unwind via the survival accumulator.
        uint256 earmarkSurvival = _packedIndex(account.lastAccruedEarmarkWeight, _EARMARK_INDEX_MASK);
        if (earmarkSurvival == 0) earmarkSurvival = ONE_Q128;

        // Default path for accounts that stayed inside the same earmark epoch.
        uint256 decayedRedeemed = FixedPointMath.mulQ128(account.lastSurvivalAccumulator, survivalRatio);
        uint256 survivalDiff = survivalAccumulatorCurrent > decayedRedeemed ? survivalAccumulatorCurrent - decayedRedeemed : 0;
        if (survivalDiff > earmarkSurvival) survivalDiff = earmarkSurvival;
        uint256 unredeemedRatio = FixedPointMath.divQ128(survivalDiff, earmarkSurvival);
        uint256 earmarkedUnredeemed = FixedPointMath.mulQ128(userExposure, unredeemedRatio);

        // If the account crossed an earmark epoch, split math at the first boundary:
        // - pre-boundary via accumulator diff at epoch boundary,
        // - post-boundary via redemption survival only.
        // This avoids both over-redemption (pre-boundary redemptions applied twice)
        // and under-redemption (post-boundary accumulator contamination).
        uint256 oldEarEpoch = _packedEpoch(account.lastAccruedEarmarkWeight, _EARMARK_INDEX_BITS);
        uint256 newEarEpoch = _packedEpoch(earmarkWeightCurrent, _EARMARK_INDEX_BITS);
        if (newEarEpoch > oldEarEpoch) {
            uint256 boundaryEpoch = oldEarEpoch + 1;
            uint256 boundaryRedemptionWeight = _earmarkEpochStartRedemptionWeight[boundaryEpoch];
            uint256 boundarySurvivalAccumulator = _earmarkEpochStartSurvivalAccumulator[boundaryEpoch];

            if (boundaryRedemptionWeight != 0) {
                uint256 preBoundarySurvival =
                    _redemptionSurvivalRatio(account.lastAccruedRedemptionWeight, boundaryRedemptionWeight);
                uint256 decayedAtBoundary = FixedPointMath.mulQ128(account.lastSurvivalAccumulator, preBoundarySurvival);

                uint256 boundaryDiff =
                    boundarySurvivalAccumulator > decayedAtBoundary ? boundarySurvivalAccumulator - decayedAtBoundary : 0;
                if (boundaryDiff > earmarkSurvival) boundaryDiff = earmarkSurvival;

                uint256 unredeemedAtBoundaryRatio = FixedPointMath.divQ128(boundaryDiff, earmarkSurvival);
                uint256 unredeemedAtBoundary = FixedPointMath.mulQ128(userExposure, unredeemedAtBoundaryRatio);

                uint256 postBoundarySurvival =
                    _redemptionSurvivalRatio(boundaryRedemptionWeight, redemptionWeightCurrent);

                earmarkedUnredeemed = FixedPointMath.mulQ128(unredeemedAtBoundary, postBoundarySurvival);
            } else {
                // Backward-compatibility fallback for old state without boundary checkpoints.
                earmarkedUnredeemed = FixedPointMath.mulQ128(earmarkRaw, survivalRatio);
            }
        }

        if (earmarkedUnredeemed > earmarkRaw) earmarkedUnredeemed = earmarkRaw;

        // Old earmarks that survived redemptions in the current sync window
        uint256 exposureSurvival = FixedPointMath.mulQ128(account.earmarked, survivalRatio);
        // What was redeemed from the newly earmark between last sync and now
        uint256 redeemedFromEarmarked = earmarkRaw - earmarkedUnredeemed;
        // Total overall earmarked to adjust user debt
        uint256 redeemedTotal = (account.earmarked - exposureSurvival) + redeemedFromEarmarked;

        newDebt = account.debt >= redeemedTotal ? account.debt - redeemedTotal : 0;
        redeemedDebt = account.debt - newDebt;
        newEarmarked = exposureSurvival + earmarkedUnredeemed;
        if (newEarmarked > newDebt) newEarmarked = newDebt;
    }

    /// @dev Commits one new earmark window into global accounting.
    function _earmark() internal {
        if (totalDebt == 0) return;
        if (block.number <= lastEarmarkBlock) return;

        // Track new transmuter MYT shares as pending cover before querying this window.
        uint256 transmuterBalance = _transmuterSharesBalance();

        if (transmuterBalance > lastTransmuterTokenBalance) {
            _pendingCoverShares += (transmuterBalance - lastTransmuterTokenBalance);
        }

        lastTransmuterTokenBalance = transmuterBalance;

        // Debt amount scheduled to earmark over this block window.
        uint256 amount = ITransmuter(transmuter).queryGraph(lastEarmarkBlock + 1, block.number);

        uint256 sharesUsed;
        (amount, sharesUsed) = _applyPendingCover(amount, _pendingCoverShares);
        _pendingCoverShares -= sharesUsed;

        uint256 liveUnearmarked = totalDebt - cumulativeEarmarked;
        if (amount > liveUnearmarked) amount = liveUnearmarked;

        if (amount > 0 && liveUnearmarked != 0) {
            (uint256 packedNew, uint256 ratioApplied, uint256 effectiveEarmarked, uint256 oldIndex, uint256 newEpoch, bool epochAdvanced) =
                _simulateEarmarkWindow(_earmarkWeight, liveUnearmarked, amount);
            _earmarkWeight = packedNew;

            // Survival increment uses the APPLIED earmark fraction
            uint256 earmarkedFraction = ONE_Q128 - ratioApplied;
            _survivalAccumulator += FixedPointMath.mulQ128(oldIndex, earmarkedFraction);

            if (epochAdvanced) {
                _earmarkEpochStartRedemptionWeight[newEpoch] = _redemptionWeight;
                _earmarkEpochStartSurvivalAccumulator[newEpoch] = _survivalAccumulator;
            }
            cumulativeEarmarked += effectiveEarmarked;
        }

        lastEarmarkBlock = block.number;
    }

    /// @dev Returns the current account view including one simulated pending earmark window.
    ///
    /// @param tokenId The id of the account owner.
    ///
    /// @return The debt after committed redemptions plus one simulated pending earmark window.
    /// @return The debt currently earmarked for redemption after the same simulation.
    /// @return The collateral balance after committed redemption debits.
    function _calculateUnrealizedDebt(uint256 tokenId)
        internal
        view
        returns (uint256, uint256, uint256)
    {
        Account storage account = _accounts[tokenId];

        // Simulate one uncommitted earmark window and use its simulated weight.
        (uint256 earmarkWeightCopy,) = _simulateUnrealizedEarmark();

        // First, compute account state against committed globals only.
        (uint256 newDebt, uint256 newEarmarked, uint256 collateralBalanceCopy,) = _computeCommittedAccountState(account);

        // Then, apply the simulated earmark-only delta. Historical redemptions are already accounted for.
        newEarmarked = _applyProspectiveEarmark(newDebt, newEarmarked, _earmarkWeight, earmarkWeightCopy);

        return (newDebt, newEarmarked, collateralBalanceCopy);
    }

    /// @dev Returns true only if the account is undercollateralized at minimum collateralization.
    ///
    /// @param tokenId The id of the account owner.
    function _isUnderCollateralized(uint256 tokenId) internal view override returns (bool) {
        uint256 debt = _accounts[tokenId].debt;
        if (debt == 0) return false;

        uint256 collateralValue = _collateralValueInDebt(_accountCollateralBalance(tokenId, true));
        return !_meetsCollateralization(debt, collateralValue, minimumCollateralization);
    }

    function _getAccountView(uint256 tokenId) internal view returns (uint256 debt, uint256 earmarked, uint256 collateral) {
        return _calculateUnrealizedDebt(tokenId);
    }

    function _accountCollateralBalance(uint256 tokenId, bool includeUnrealizedDebt) internal view returns (uint256 collateral) {
        if (!includeUnrealizedDebt) {
            return _accounts[tokenId].collateralBalance;
        }

        (,, collateral) = _getAccountView(tokenId);
    }

    function _collateralValueInDebt(uint256 collateralBalance) internal view returns (uint256) {
        return convertYieldTokensToDebt(collateralBalance);
    }

    function _lockedCollateralForDebt(uint256 debt) internal view returns (uint256) {
        if (debt == 0) return 0;
        uint256 debtShares = convertDebtTokensToYield(debt);
        return FixedPointMath.mulDivUp(debtShares, minimumCollateralization, FIXED_POINT_SCALAR);
    }

    function _maxBorrowableFromState(uint256 debt, uint256 collateral) internal view returns (uint256) {
        uint256 capacity = _collateralValueInDebt(collateral) * FIXED_POINT_SCALAR / minimumCollateralization;
        return debt > capacity ? 0 : capacity - debt;
    }

    function _maxWithdrawableFromState(uint256 debt, uint256 collateral) internal view returns (uint256) {
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
    function _getTotalUnderlyingValue() internal view returns (uint256 totalUnderlyingValue) {
        return _underlyingValueForShares(_mytSharesDeposited);
    }

    /// @dev Returns the underlying value of globally required locked shares, capped by held shares.
    function _getTotalLockedUnderlyingValue() internal view returns (uint256) {
        return _underlyingValueForShares(_lockedProtocolShares());
    }
    /// @dev Returns true if issued synthetics exceed protocol backing used by redemption haircut logic.
    ///      Backing is locked collateral in the Alchemist plus MYT shares currently held by the Transmuter.
    function _isProtocolInBadDebt() internal view override returns (bool) {
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

    // Survival ratio of *unearmarked* exposure between two packed earmark states.
    function _earmarkSurvivalRatio(uint256 oldPacked, uint256 newPacked) internal pure returns (uint256) {
        if (newPacked == oldPacked) return ONE_Q128;
        if (oldPacked == 0) return ONE_Q128; // uninitialized snapshot => assume "no change"

        uint256 oldEpoch = oldPacked >> _EARMARK_INDEX_BITS;
        uint256 newEpoch = newPacked >> _EARMARK_INDEX_BITS;

        // Epoch advanced => old unearmarked was fully earmarked at some point.
        if (newEpoch > oldEpoch) return 0;

        uint256 oldIdx = oldPacked & _EARMARK_INDEX_MASK;
        uint256 newIdx = newPacked & _EARMARK_INDEX_MASK;

        if (oldIdx == 0) return 0;

        return FixedPointMath.divQ128(newIdx, oldIdx);
    }

    /// @dev Computes redemption survival ratio between two packed redemption states.
    function _redemptionSurvivalRatio(uint256 oldPacked, uint256 newPacked) internal pure returns (uint256) {
        if (newPacked == oldPacked) return ONE_Q128;
        if (oldPacked == 0) return ONE_Q128;

        uint256 oldEpoch = oldPacked >> _REDEMPTION_INDEX_BITS;
        uint256 newEpoch = newPacked >> _REDEMPTION_INDEX_BITS;

        // If epoch advances, there was a full wipe at some point
        if (newEpoch > oldEpoch) return 0;

        uint256 oldIndex = oldPacked & _REDEMPTION_INDEX_MASK;
        uint256 newIndex = newPacked & _REDEMPTION_INDEX_MASK;

        // If oldIndex is 0, treat as fully redeemed.
        if (oldIndex == 0) return 0;

        // ratio = newIndex / oldIndex
        return FixedPointMath.divQ128(newIndex, oldIndex);
    }

    /// @dev Simulates one uncommitted earmark window using current on-chain state.
    /// @return earmarkWeightCopy Simulated earmark packed weight after the window.
    /// @return effectiveEarmarked The additional earmarked debt from this simulated window.
    function _simulateUnrealizedEarmark() internal view returns (uint256 earmarkWeightCopy, uint256 effectiveEarmarked) {
        earmarkWeightCopy = _earmarkWeight;
        if (block.number <= lastEarmarkBlock || totalDebt == 0) return (earmarkWeightCopy, 0);

        uint256 transmuterBalance = _transmuterSharesBalance();

        // Simulate pending cover exactly as `_earmark()` would consume it.
        uint256 pendingCover = _pendingCoverShares;
        if (transmuterBalance > lastTransmuterTokenBalance) {
            pendingCover += (transmuterBalance - lastTransmuterTokenBalance);
        }

        // Simulate this block window's earmark amount.
        uint256 amount = ITransmuter(transmuter).queryGraph(lastEarmarkBlock + 1, block.number);

        (amount,) = _applyPendingCover(amount, pendingCover);

        uint256 liveUnearmarked = totalDebt - cumulativeEarmarked;
        if (amount > liveUnearmarked) amount = liveUnearmarked;
        if (amount == 0 || liveUnearmarked == 0) return (earmarkWeightCopy, 0);

        (earmarkWeightCopy,, effectiveEarmarked,,,) = _simulateEarmarkWindow(earmarkWeightCopy, liveUnearmarked, amount);
    }

    /// @dev Simulates the packed earmark update and returns the applied survival ratio.
    /// @param packedOld Existing packed earmark weight.
    /// @param ratioWanted Wanted survival ratio for unearmarked debt in this step.
    /// @return packedNew The new packed earmark weight.
    /// @return ratioApplied The effective survival ratio that will be observed by accounts.
    /// @return oldIndex The normalized previous index.
    /// @return newEpoch The resulting epoch after this step.
    /// @return epochAdvanced Whether the update crossed an epoch boundary.
    function _simulateEarmarkPackedUpdate(uint256 packedOld, uint256 ratioWanted)
        internal
        pure
        returns (uint256 packedNew, uint256 ratioApplied, uint256 oldIndex, uint256 newEpoch, bool epochAdvanced)
    {
        return _simulatePackedWeightUpdate(packedOld, ratioWanted, _EARMARK_INDEX_BITS, _EARMARK_INDEX_MASK);
    }

    /// @dev Simulates the packed redemption update and returns the applied survival ratio.
    function _simulateRedemptionPackedUpdate(uint256 packedOld, uint256 ratioWanted)
        internal
        pure
        returns (uint256 packedNew, uint256 ratioApplied, uint256 oldIndex, uint256 newEpoch, bool epochAdvanced)
    {
        return _simulatePackedWeightUpdate(packedOld, ratioWanted, _REDEMPTION_INDEX_BITS, _REDEMPTION_INDEX_MASK);
    }

    /// @dev Applies one committed redemption window to global redemption accounting.
    function _applyRedemptionWindow(uint256 liveEarmarked, uint256 amount) internal returns (uint256 effectiveRedeemed) {
        if (liveEarmarked == 0 || amount == 0) {
            return 0;
        }

        uint256 ratioWanted = amount == liveEarmarked ? 0 : FixedPointMath.divQ128(liveEarmarked - amount, liveEarmarked);
        (uint256 packedNew, uint256 ratioApplied,,,) = _simulateRedemptionPackedUpdate(_redemptionWeight, ratioWanted);
        _redemptionWeight = packedNew;
        _survivalAccumulator = FixedPointMath.mulQ128(_survivalAccumulator, ratioApplied);

        effectiveRedeemed = _effectiveAppliedAmount(liveEarmarked, ratioApplied);
        cumulativeEarmarked = liveEarmarked - effectiveRedeemed;
        totalDebt -= effectiveRedeemed;
    }

    /// @dev Applies pending cover shares against a debt-denominated earmark amount.
    function _applyPendingCover(uint256 amount, uint256 pendingCoverShares)
        internal
        view
        returns (uint256 adjustedAmount, uint256 sharesUsed)
    {
        adjustedAmount = amount;
        if (amount == 0 || pendingCoverShares == 0) {
            return (adjustedAmount, 0);
        }

        uint256 coverInDebt = convertYieldTokensToDebt(pendingCoverShares);
        if (coverInDebt == 0) {
            return (adjustedAmount, 0);
        }

        uint256 usedDebt = amount > coverInDebt ? coverInDebt : amount;
        adjustedAmount -= usedDebt;

        sharesUsed = FixedPointMath.mulDivUp(pendingCoverShares, usedDebt, coverInDebt);
        if (sharesUsed > pendingCoverShares) sharesUsed = pendingCoverShares;
    }

    /// @dev Simulates one earmark window and returns the effective newly earmarked amount.
    function _simulateEarmarkWindow(uint256 packedOld, uint256 liveUnearmarked, uint256 amount)
        internal
        pure
        returns (
            uint256 packedNew,
            uint256 ratioApplied,
            uint256 effectiveEarmarked,
            uint256 oldIndex,
            uint256 newEpoch,
            bool epochAdvanced
        )
    {
        if (liveUnearmarked == 0 || amount == 0) {
            uint256 normalizedIndex = _packedIndex(packedOld, _EARMARK_INDEX_MASK);
            if (packedOld == 0 || normalizedIndex == 0) {
                normalizedIndex = ONE_Q128;
            }
            return (packedOld, ONE_Q128, 0, normalizedIndex, _packedEpoch(packedOld, _EARMARK_INDEX_BITS), false);
        }

        uint256 ratioWanted =
            amount == liveUnearmarked ? 0 : FixedPointMath.divQ128(liveUnearmarked - amount, liveUnearmarked);
        (packedNew, ratioApplied, oldIndex, newEpoch, epochAdvanced) = _simulateEarmarkPackedUpdate(packedOld, ratioWanted);
        effectiveEarmarked = _effectiveAppliedAmount(liveUnearmarked, ratioApplied);
    }

    /// @dev Generic packed epoch/index weight update shared by earmark and redemption.
    function _simulatePackedWeightUpdate(uint256 packedOld, uint256 ratioWanted, uint256 indexBits, uint256 indexMask)
        internal
        pure
        returns (uint256 packedNew, uint256 ratioApplied, uint256 oldIndex, uint256 newEpoch, bool epochAdvanced)
    {
        uint256 oldEpoch = _packedEpoch(packedOld, indexBits);
        oldIndex = _packedIndex(packedOld, indexMask);

        if (packedOld == 0) {
            oldEpoch = 0;
            oldIndex = ONE_Q128;
        }
        if (oldIndex == 0) {
            oldEpoch += 1;
            oldIndex = ONE_Q128;
        }

        newEpoch = oldEpoch;
        uint256 newIndex;

        if (ratioWanted == 0) {
            newEpoch += 1;
            newIndex = ONE_Q128;
        } else {
            newIndex = FixedPointMath.mulQ128(oldIndex, ratioWanted);
        }

        epochAdvanced = newEpoch > oldEpoch;
        packedNew = _packWeight(newEpoch, newIndex, indexBits);
        ratioApplied = epochAdvanced ? 0 : FixedPointMath.divQ128(newIndex, oldIndex);
    }

    /// @dev Converts an applied survival ratio into the realized amount removed from `totalAmount`.
    function _effectiveAppliedAmount(uint256 totalAmount, uint256 ratioApplied) internal pure returns (uint256) {
        uint256 remainingAmount = FixedPointMath.mulQ128(totalAmount, ratioApplied);
        return totalAmount - remainingAmount;
    }

    /// @dev Extracts the epoch portion from a packed weight.
    function _packedEpoch(uint256 packed, uint256 indexBits) internal pure returns (uint256) {
        return packed >> indexBits;
    }

    /// @dev Extracts the index portion from a packed weight.
    function _packedIndex(uint256 packed, uint256 indexMask) internal pure returns (uint256) {
        return packed & indexMask;
    }

    /// @dev Packs an epoch and index into a single weight word.
    function _packWeight(uint256 epoch, uint256 index, uint256 indexBits) internal pure returns (uint256) {
        return (epoch << indexBits) | index;
    }

}





