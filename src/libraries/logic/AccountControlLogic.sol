// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../interfaces/IAlchemistV3.sol";

/// @dev Helpers for per-position mint approval bookkeeping.
library AccountControlLogic {
    /// @dev Sets the current mint allowance for `spender` on `ownerTokenId`.
    function approveMint(
        mapping(uint256 => Account) storage accounts,
        uint256 ownerTokenId,
        address spender,
        uint256 amount
    ) internal {
        Account storage account = accounts[ownerTokenId];
        account.mintAllowances[account.allowancesVersion][spender] = amount;
    }

    /// @dev Invalidates all prior mint allowances by bumping the allowance version.
    function resetMintAllowances(mapping(uint256 => Account) storage accounts, uint256 tokenId) internal {
        accounts[tokenId].allowancesVersion += 1;
    }
}
