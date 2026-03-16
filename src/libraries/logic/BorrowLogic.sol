// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../interfaces/IAlchemistV3.sol";
import "../../interfaces/ITransmuter.sol";
import "../../base/Errors.sol";
import "../FixedPointMath.sol";
import "../TokenUtils.sol";
import {SupplyLogic} from "./SupplyLogic.sol";
import {StateLogic} from "./StateLogic.sol";

library BorrowLogic {
    struct CheckpointParams {
        uint256 totalRedeemedDebt;
        uint256 totalRedeemedSharesOut;
        uint256 earmarkWeight;
        uint256 redemptionWeight;
        uint256 survivalAccumulator;
    }

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

    function checkpointAccountState(Account storage account, CheckpointParams memory params) internal {
        account.lastTotalRedeemedDebt = params.totalRedeemedDebt;
        account.lastTotalRedeemedSharesOut = params.totalRedeemedSharesOut;
        account.lastAccruedEarmarkWeight = params.earmarkWeight;
        account.lastAccruedRedemptionWeight = params.redemptionWeight;
        account.lastSurvivalAccumulator = params.survivalAccumulator;
    }

    function mint(
        mapping(uint256 => Account) storage accounts,
        MintParams memory params,
        uint256 collateralValue
    ) internal returns (uint256 newTotalDebt, uint256 newTotalSyntheticsIssued) {
        return _executeMint(accounts, params, collateralValue);
    }

    function mintFrom(
        mapping(uint256 => Account) storage accounts,
        MintParams memory params,
        uint256 collateralValue
    ) internal returns (uint256 newTotalDebt, uint256 newTotalSyntheticsIssued) {
        Account storage account = accounts[params.tokenId];
        account.mintAllowances[account.allowancesVersion][params.caller] -= params.amount;

        return _executeMint(accounts, params, collateralValue);
    }

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

        credit = capDebtCredit(params.amount, debt, params.totalDebt);
        if (credit == 0) {
            return (0, params.totalDebt, params.totalSyntheticsIssued, params.cumulativeEarmarked);
        }

        uint256 burnLimit = params.totalSyntheticsIssued - ITransmuter(params.transmuter).totalLocked();
        if (credit > burnLimit) revert IAlchemistV3Errors.BurnLimitExceeded(credit, burnLimit);

        TokenUtils.safeBurnFrom(params.debtToken, params.caller, credit);

        (newTotalDebt, newCumulativeEarmarked) =
            subDebt(account, credit, params.totalDebt, params.cumulativeEarmarked, checkpoint);
        account.lastRepayBlock = block.number;
        newTotalSyntheticsIssued = params.totalSyntheticsIssued - credit;
    }

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

        uint256 credit = capDebtCredit(
            StateLogic.convertYieldTokensToDebt(params.myt, params.underlyingConversionFactor, params.amount),
            account.debt,
            params.totalDebt
        );
        if (credit == 0) {
            return (0, 0, params.totalDebt, params.totalDeposited, params.cumulativeEarmarked);
        }

        uint256 earmarkedRepaid;
        (earmarkedRepaid, newCumulativeEarmarked) = subEarmarkedDebt(account, credit, params.cumulativeEarmarked);

        creditToYield = StateLogic.convertDebtTokensToYield(params.myt, params.underlyingConversionFactor, credit);
        feeAmount = StateLogic.convertDebtTokensToYield(
            params.myt, params.underlyingConversionFactor, earmarkedRepaid
        ) * params.protocolFee / params.bps;

        if (feeAmount > account.collateralBalance) revert IllegalState();

        (, newTotalDeposited) = SupplyLogic.subCollateralBalance(account, feeAmount, params.totalDeposited);
        (newTotalDebt, newCumulativeEarmarked) =
            subDebt(account, credit, params.totalDebt, newCumulativeEarmarked, checkpoint);
        account.lastRepayBlock = block.number;

        TokenUtils.safeTransferFrom(params.myt, params.caller, params.transmuter, creditToYield);
        if (feeAmount > 0) {
            TokenUtils.safeTransfer(params.myt, params.protocolFeeReceiver, feeAmount);
        }
    }

    function capDebtCredit(uint256 requested, uint256 accountDebt, uint256 totalDebt)
        internal
        pure
        returns (uint256 credit)
    {
        credit = requested > accountDebt ? accountDebt : requested;
        if (credit > totalDebt) credit = totalDebt;
    }

    function clearableDebt(uint256 accountDebt, uint256 totalDebt) internal pure returns (uint256) {
        return accountDebt > totalDebt ? totalDebt : accountDebt;
    }

    function subEarmarkedDebt(Account storage account, uint256 amountInDebtTokens, uint256 cumulativeEarmarked)
        internal
        returns (uint256 earmarkToRemove, uint256 newCumulativeEarmarked)
    {
        uint256 debt = account.debt;
        uint256 earmarkedDebt = account.earmarked;

        uint256 credit = amountInDebtTokens > debt ? debt : amountInDebtTokens;
        earmarkToRemove = credit > earmarkedDebt ? earmarkedDebt : credit;

        account.earmarked = earmarkedDebt - earmarkToRemove;

        uint256 remove = earmarkToRemove > cumulativeEarmarked ? cumulativeEarmarked : earmarkToRemove;
        newCumulativeEarmarked = cumulativeEarmarked - remove;
    }

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

    function _executeMint(
        mapping(uint256 => Account) storage accounts,
        MintParams memory params,
        uint256 collateralValue
    ) private returns (uint256 newTotalDebt, uint256 newTotalSyntheticsIssued) {
        Account storage account = accounts[params.tokenId];
        if (block.number == account.lastRepayBlock) revert IAlchemistV3Errors.CannotMintOnRepayBlock();

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

        TokenUtils.safeMint(params.debtToken, params.recipient, params.amount);
    }
}

