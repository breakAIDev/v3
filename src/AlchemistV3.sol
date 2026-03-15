// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./interfaces/IAlchemistV3.sol";
import {ITransmuter} from "./interfaces/ITransmuter.sol";
import {IAlchemistV3Position} from "./interfaces/IAlchemistV3Position.sol";
import {AlchemistV3LiquidationModule} from "./modules/AlchemistV3LiquidationModule.sol";
import {TokenUtils} from "./libraries/TokenUtils.sol";
import {IllegalState} from "./base/Errors.sol";
import {FixedPointMath} from "./libraries/FixedPointMath.sol";

/// @title  AlchemistV3
/// @author Alchemix Finance
///
/// For Juris, Graham, and Marcus
contract AlchemistV3 is AlchemistV3LiquidationModule {
    function initialize(AlchemistInitializationParams memory params) external initializer {
        _initialize(params);
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
     function _forceRepay(uint256 accountId, uint256 amount, bool skipPoke) internal override returns (uint256) {
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
    /// @dev Increases the debt by `amount` for the account owned by `tokenId`.
    function _addDebt(uint256 tokenId, uint256 amount) internal {
        Account storage account = _accounts[tokenId];

        uint256 newDebt = account.debt + amount;
        uint256 collateralValue = _collateralValueInDebt(_accountCollateralBalance(tokenId, false));
        uint256 required = FixedPointMath.mulDivUp(newDebt, minimumCollateralization, FIXED_POINT_SCALAR);
        if (collateralValue < required) revert Undercollateralized();

        account.debt = newDebt;
        totalDebt += amount;
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

}









