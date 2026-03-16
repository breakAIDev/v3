// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../interfaces/IAlchemistV3.sol";

library AccountControlLogic {
    function approveMint(
        mapping(uint256 => Account) storage accounts,
        uint256 ownerTokenId,
        address spender,
        uint256 amount
    ) internal {
        Account storage account = accounts[ownerTokenId];
        account.mintAllowances[account.allowancesVersion][spender] = amount;
    }

    function resetMintAllowances(mapping(uint256 => Account) storage accounts, uint256 tokenId) internal {
        accounts[tokenId].allowancesVersion += 1;
    }
}
