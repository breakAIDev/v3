// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./InvariantBaseTest.t.sol";

contract FullSystemInvariantsTest is InvariantBaseTest {
    uint256 public maxDebtDeltaSeen;
    uint256 public maxEarmarkDeltaSeen;

    function setUp() public virtual override {
        super.setUp();
    }

    /* INVARIANTS */

    // // Total deposited equals the sum of all individual CDPs
    // // This uses getCDP which calculates balances/debts without updating storage
    // function invariantConsistentCollateral() public view {
    //     address[] memory users = targetSenders();

    //     uint256 totalDeposited;

    //     for (uint256 i; i < users.length; ++i) {
    //         // a single position nft would have been minted to address(0xbeef)
    //         uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(users[i], address(alchemistNFT));
    //         (uint256 collateral,,) = alchemist.getCDP(tokenId);

    //         totalDeposited += collateral;
    //     }

    //     assertApproxEqAbs(totalDeposited, alchemist.getTotalDeposited(), 7);
    // }

    // // Underlying value of collateral equals sum of all user accounts
    // // This test uses poke() to perform an actual storage update to the user account
    // function invariantConsistentCollateralwithPoke() public {
    //     address[] memory users = targetSenders();

    //     uint256 totalDeposited;

    //     for (uint256 i; i < users.length; ++i) {
    //         // a single position nft would have been minted to address(0xbeef)
    //         uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(users[i], address(alchemistNFT));

    //         if (tokenId != 0) {
    //             alchemist.poke(tokenId);

    //             totalDeposited += alchemist.totalValue(tokenId);
    //         }
    //     }

    //     assertApproxEqAbs(totalDeposited, alchemist.convertYieldTokensToDebt(alchemist.getTotalDeposited()), 7);
    // }

    // Total debt in the system is equal to sum of all user debts
    function invariantConsistentDebtAndEarmark() public {
        address[] memory users = targetSenders();

        uint256 sumDebt;
        uint256 sumEarmarked;
        uint256 active;

        for (uint256 i; i < users.length; ++i) {
            uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(users[i], address(alchemistNFT));
            if (tokenId != 0) {
                active++;
                (, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);
                sumDebt += debt;
                sumEarmarked += earmarked;
            }
        }

        uint256 totalDebt = alchemist.totalDebt();
        uint256 cumEarmarked = alchemist.getUnrealizedCumulativeEarmarked();

        uint256 debtDelta = _absDiff(sumDebt, totalDebt);
        uint256 earmarkDelta = _absDiff(sumEarmarked, cumEarmarked);

        if (debtDelta > maxDebtDeltaSeen) maxDebtDeltaSeen = debtDelta;
        if (earmarkDelta > maxEarmarkDeltaSeen) maxEarmarkDeltaSeen = earmarkDelta;

        // Tolerance:
        // - base: 1e12 (your original)
        // - plus: conversionFactor * active positions (covers underlying/share rounding showing up in debt units)
        uint256 cf = alchemist.underlyingConversionFactor();
        uint256 tol = _max(1e12, cf * _max(active, 1));

        assertLe(debtDelta, tol);
        assertLe(earmarkDelta, tol);

        // Sanity invariants that should ALWAYS hold
        assertLe(cumEarmarked, totalDebt);
        assertLe(sumEarmarked, sumDebt);
    }

    // // Amount stakes in the transmuter cannot exceed the total debt in the alchemist plus the debt value of yield tokens in the transmuter
    // function invariantTransmuterStakeLessThanTotalDebt() public view {
    //     uint256 totalLocked = transmuterLogic.totalLocked() > alchemist.convertYieldTokensToDebt(fakeYieldToken.balanceOf(address(transmuterLogic)))
    //         ? transmuterLogic.totalLocked() - alchemist.convertYieldTokensToDebt(fakeYieldToken.balanceOf(address(transmuterLogic)))
    //         : 0;
    //     assertLe(totalLocked, alchemist.totalDebt());
    // }

    // // Earmarked can never be more than total debt
    // function invariantEarmarkedLessThanTotalDebt() public view {
    //     assertLe(alchemist.cumulativeEarmarked(), alchemist.totalDebt());
    // }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}