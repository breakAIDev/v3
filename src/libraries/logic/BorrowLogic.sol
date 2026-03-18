// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../interfaces/IAlchemistV3.sol";
import "../../interfaces/ITransmuter.sol";
import "../../base/Errors.sol";
import "../FixedPointMath.sol";
import "../TokenUtils.sol";
import {SupplyLogic} from "./SupplyLogic.sol";
import {StateLogic} from "./StateLogic.sol";

/// @dev Debt issuance, burn, and collateral-backed repayment helpers.
library BorrowLogic {
    /// @dev Account snapshots needed to reconcile redemptions during sync.
    struct CheckpointParams {
        uint256 totalRedeemedDebt;
        uint256 totalRedeemedSharesOut;
        uint256 earmarkWeight;
        uint256 redemptionWeight;
        uint256 survivalAccumulator;
    }

    /// @dev Inputs for direct or delegated minting.
    struct MintParams {
        address debtToken;
        address caller;
        uint256 tokenId;
        uint256 amount;
        address recipient;
        uint256 totalDebt;
        uint256 totalSyntheticsIssued;
        uint256 minimumCollateralization;
        uint256 fixedPointScalar;
    }

    /// @dev Inputs for burning debt tokens against a position.
    struct BurnParams {
        address debtToken;
        address transmuter;
        address caller;
        uint256 recipientId;
        uint256 amount;
        uint256 totalDebt;
        uint256 totalSyntheticsIssued;
        uint256 cumulativeEarmarked;
    }

    /// @dev Inputs for repaying debt with yield-token collateral.
    struct RepayParams {
        address myt;
        address transmuter;
        address protocolFeeReceiver;
        address caller;
        uint256 recipientTokenId;
        uint256 amount;
        uint256 totalDebt;
        uint256 totalDeposited;
        uint256 cumulativeEarmarked;
        uint256 underlyingConversionFactor;
        uint256 protocolFee;
        uint256 bps;
    }

    /// @dev Records the latest global redemption and earmark checkpoints on an account.
    function checkpointAccountState(Account storage account, CheckpointParams memory params) internal {
        account.lastTotalRedeemedDebt = params.totalRedeemedDebt;
        account.lastTotalRedeemedSharesOut = params.totalRedeemedSharesOut;
        account.lastAccruedEarmarkWeight = params.earmarkWeight;
        account.lastAccruedRedemptionWeight = params.redemptionWeight;
        account.lastSurvivalAccumulator = params.survivalAccumulator;
    }

    /// @dev Mints debt directly from a position after collateralization checks.
    function mint(
        mapping(uint256 => Account) storage accounts,
        MintParams memory params,
        uint256 collateralValue
    ) internal returns (uint256 newTotalDebt, uint256 newTotalSyntheticsIssued) {
        return _executeMint(accounts, params, collateralValue);
    }

    /// @dev Mints debt using a previously granted mint allowance.
    function mintFrom(
        mapping(uint256 => Account) storage accounts,
        MintParams memory params,
        uint256 collateralValue
    ) internal returns (uint256 newTotalDebt, uint256 newTotalSyntheticsIssued) {
        // Preemptively try to decrease the minting allowance. This saves gas when the allowance is not sufficient.
        Account storage account = accounts[params.tokenId];
        account.mintAllowances[account.allowancesVersion][params.caller] -= params.amount;

        return _executeMint(accounts, params, collateralValue);
    }

    /// @dev Burns debt tokens against unearmarked debt on `recipientId`.
    function burn(
        mapping(uint256 => Account) storage accounts,
        BurnParams memory params,
        CheckpointParams memory checkpoint
    )
        internal
        returns (
            uint256 credit,
            uint256 newTotalDebt,
            uint256 newTotalSyntheticsIssued,
            uint256 newCumulativeEarmarked
        )
    {
        Account storage account = accounts[params.recipientId];
        uint256 debt = account.debt - account.earmarked;
        if (debt == 0) revert IllegalState();

        // Burning alAssets can only repay unearmarked debt.
        credit = capDebtCredit(params.amount, debt, params.totalDebt);
        if (credit == 0) {
            return (0, params.totalDebt, params.totalSyntheticsIssued, params.cumulativeEarmarked);
        }

        // Must only burn enough tokens that the transmuter positions can still be fulfilled.
        uint256 burnLimit = params.totalSyntheticsIssued - ITransmuter(params.transmuter).totalLocked();
        if (credit > burnLimit) revert IAlchemistV3Errors.BurnLimitExceeded(credit, burnLimit);

        // Burn the tokens from the message sender.
        TokenUtils.safeBurnFrom(params.debtToken, params.caller, credit);

        // Update the recipient's debt.
        (newTotalDebt, newCumulativeEarmarked) =
            subDebt(account, credit, params.totalDebt, params.cumulativeEarmarked, checkpoint);
        account.lastRepayBlock = block.number;
        newTotalSyntheticsIssued = params.totalSyntheticsIssued - credit;
    }

    /// @dev Repays debt with collateral shares and routes any protocol fee to the fee receiver.
    function repay(
        mapping(uint256 => Account) storage accounts,
        RepayParams memory params,
        CheckpointParams memory checkpoint
    )
        internal
        returns (
            uint256 creditToYield,
            uint256 feeAmount,
            uint256 newTotalDebt,
            uint256 newTotalDeposited,
            uint256 newCumulativeEarmarked
        )
    {
        Account storage account = accounts[params.recipientTokenId];
        if (account.debt == 0) revert IllegalState();

        // Burning yield tokens will pay off all types of debt.
        uint256 credit = capDebtCredit(
            StateLogic.convertYieldTokensToDebt(params.myt, params.underlyingConversionFactor, params.amount),
            account.debt,
            params.totalDebt
        );
        if (credit == 0) {
            return (0, 0, params.totalDebt, params.totalDeposited, params.cumulativeEarmarked);
        }

        // Repay debt from earmarked amount of debt first.
        uint256 earmarkedRepaid;
        (earmarkedRepaid, newCumulativeEarmarked) = subEarmarkedDebt(account, credit, params.cumulativeEarmarked);

        creditToYield = StateLogic.convertDebtTokensToYield(params.myt, params.underlyingConversionFactor, credit);

        // Protocol fee only applies to earmarked debt repaid.
        feeAmount = StateLogic.convertDebtTokensToYield(
            params.myt, params.underlyingConversionFactor, earmarkedRepaid
        ) * params.protocolFee / params.bps;

        if (feeAmount > account.collateralBalance) revert IllegalState();

        (, newTotalDeposited) = SupplyLogic.subCollateralBalance(account, feeAmount, params.totalDeposited);
        (newTotalDebt, newCumulativeEarmarked) =
            subDebt(account, credit, params.totalDebt, newCumulativeEarmarked, checkpoint);
        account.lastRepayBlock = block.number;

        // Transfer the repaid tokens to the transmuter.
        TokenUtils.safeTransferFrom(params.myt, params.caller, params.transmuter, creditToYield);
        if (feeAmount > 0) {
            // Transfer the protocol fee to the protocol fee receiver.
            TokenUtils.safeTransfer(params.myt, params.protocolFeeReceiver, feeAmount);
        }
    }

    /// @dev Caps a requested debt adjustment to both account debt and total protocol debt.
    function capDebtCredit(uint256 requested, uint256 accountDebt, uint256 totalDebt)
        internal
        pure
        returns (uint256 credit)
    {
        credit = requested > accountDebt ? accountDebt : requested;
        if (credit > totalDebt) credit = totalDebt;
    }

    /// @dev Returns the debt that can be safely cleared without exceeding protocol debt.
    function clearableDebt(uint256 accountDebt, uint256 totalDebt) internal pure returns (uint256) {
        return accountDebt > totalDebt ? totalDebt : accountDebt;
    }

    /// @dev Removes earmarked debt first and updates cumulative earmarked accounting.
    function subEarmarkedDebt(Account storage account, uint256 amountInDebtTokens, uint256 cumulativeEarmarked)
        internal
        returns (uint256 earmarkToRemove, uint256 newCumulativeEarmarked)
    {
        uint256 debt = account.debt;
        uint256 earmarkedDebt = account.earmarked;

        uint256 credit = amountInDebtTokens > debt ? debt : amountInDebtTokens;
        earmarkToRemove = credit > earmarkedDebt ? earmarkedDebt : credit;

        // Always reduce local earmark by the full local repay amount.
        account.earmarked = earmarkedDebt - earmarkToRemove;

        // Global can lag local by rounding; clamp only the global subtraction.
        uint256 remove = earmarkToRemove > cumulativeEarmarked ? cumulativeEarmarked : earmarkToRemove;
        newCumulativeEarmarked = cumulativeEarmarked - remove;
    }

    /// @dev Subtracts debt from an account and clears sync checkpoints when the account reaches zero debt.
    function subDebt(
        Account storage account,
        uint256 amount,
        uint256 totalDebt,
        uint256 cumulativeEarmarked,
        CheckpointParams memory params
    ) internal returns (uint256 newTotalDebt, uint256 newCumulativeEarmarked) {
        account.debt -= amount;
        newTotalDebt = totalDebt - amount;

        if (account.debt == 0) {
            account.earmarked = 0;
            checkpointAccountState(account, params);
        }

        newCumulativeEarmarked = cumulativeEarmarked > newTotalDebt ? newTotalDebt : cumulativeEarmarked;
    }

    /// @dev Adds debt to an account while enforcing the minimum collateralization ratio.
    function addDebt(
        Account storage account,
        uint256 amount,
        uint256 totalDebt,
        uint256 collateralValue,
        uint256 minimumCollateralization,
        uint256 fixedPointScalar
    ) internal returns (uint256 newTotalDebt) {
        uint256 newDebt = account.debt + amount;
        uint256 required = FixedPointMath.mulDivUp(newDebt, minimumCollateralization, fixedPointScalar);
        if (collateralValue < required) revert IAlchemistV3Errors.Undercollateralized();

        account.debt = newDebt;
        return totalDebt + amount;
    }

    /// @dev Shared mint implementation used by both direct and delegated mint paths.
    function _executeMint(
        mapping(uint256 => Account) storage accounts,
        MintParams memory params,
        uint256 collateralValue
    ) private returns (uint256 newTotalDebt, uint256 newTotalSyntheticsIssued) {
        Account storage account = accounts[params.tokenId];
        if (block.number == account.lastRepayBlock) revert IAlchemistV3Errors.CannotMintOnRepayBlock();

        // After sync, current collateralBalance is authoritative, so no extra simulation is needed here.
        newTotalDebt = addDebt(
            account,
            params.amount,
            params.totalDebt,
            collateralValue,
            params.minimumCollateralization,
            params.fixedPointScalar
        );
        newTotalSyntheticsIssued = params.totalSyntheticsIssued + params.amount;
        account.lastMintBlock = block.number;

        // Mint the debt tokens to the recipient.
        TokenUtils.safeMint(params.debtToken, params.recipient, params.amount);
    }
}

