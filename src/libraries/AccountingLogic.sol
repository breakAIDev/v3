// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

library AccountingLogic {
    /// @dev Caps a debt-denominated credit against account debt and global debt.
    function capDebtCredit(
        uint256 requested,
        uint256 accountDebt,
        uint256 globalDebt
    ) internal pure returns (uint256) {
        uint256 credit = requested > accountDebt ? accountDebt : requested;
        if (credit > globalDebt) credit = globalDebt;
        return credit;
    }

    /// @dev Returns debt that can be safely cleared against global debt accounting.
    function clearableDebt(uint256 accountDebt, uint256 globalDebt) internal pure returns (uint256) {
        return accountDebt > globalDebt ? globalDebt : accountDebt;
    }
}
