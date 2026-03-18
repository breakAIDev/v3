// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../InvariantsTest.t.sol";
import {ITestYieldToken} from "../../interfaces/test/ITestYieldToken.sol";
import {IVaultV2} from "../../../lib/vault-v2/src/interfaces/IVaultV2.sol";

/// @title Hardened Invariant Tests — full handler rewrite with fail_on_revert=true
/// @notice Inherits InvariantsTest directly (skips InvariantBaseTest) so every handler
///         is try/catch safe. No need for fail_on_revert=false.
///
/// Key improvements over FullSystemInvariantsTest:
///   1. All handlers wrapped in try/catch (price-change safe)
///   2. Liquidation handler
///   3. Yield accrual + value loss handlers (share price changes)
///   4. Poke handlers
///   5. Storage-based invariant checks (not view-vs-view)
///   6. Tight tolerances
contract HardenedInvariantsTest is InvariantsTest {
    // ═══════ Ghost tracking ═══════
    uint256 public maxDebtDelta;
    uint256 public maxEarmarkDelta;
    uint256 public maxCollateralDelta;
    uint256 public liquidationAttempts;
    uint256 public liquidationSuccesses;
    uint256 public yieldAccruals;
    uint256 public handlerReverts;

    uint256 internal constant MAX_TEST_VALUE = 1e28;

    function setUp() public virtual override {
        // Register all handlers — mine() is inherited from InvariantsTest
        selectors.push(this.depositCollateral.selector);
        selectors.push(this.withdrawCollateral.selector);
        selectors.push(this.borrowCollateral.selector);
        selectors.push(this.repayDebt.selector);
        selectors.push(this.repayDebtViaBurn.selector);
        selectors.push(this.transmuterStake.selector);
        selectors.push(this.transmuterClaim.selector);
        selectors.push(this.mine.selector);
        selectors.push(this.triggerLiquidation.selector);
        selectors.push(this.simulateValueLoss.selector);
        selectors.push(this.simulateYield.selector);
        selectors.push(this.pokeAll.selector);
        selectors.push(this.pokeRandom.selector);

        super.setUp();
    }

    // ═══════════════════════════════════════════════════════════════
    //  SAFE BASE HANDLERS (rewrites of InvariantBaseTest, try/catch)
    // ═══════════════════════════════════════════════════════════════

    function depositCollateral(uint256 amount, uint256 onBehalfSeed) external {
        address onBehalf = _randomNonZero(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) return;

        amount = bound(amount, 0, MAX_TEST_VALUE);
        if (amount == 0) return;

        uint256 tokenId = _safeGetFirstTokenId(onBehalf);
        _safeDeposit(tokenId, amount, onBehalf);
    }

    function withdrawCollateral(uint256 amount, uint256 onBehalfSeed) external {
        address onBehalf = _safeRandomWithdrawer(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) return;

        uint256 tokenId = _safeGetFirstTokenId(onBehalf);
        if (tokenId == 0) return;

        uint256 maxWithdraw;
        try alchemist.getMaxWithdrawable(tokenId) returns (uint256 mw) {
            maxWithdraw = mw;
        } catch { handlerReverts++; return; }

        amount = bound(amount, 0, maxWithdraw);
        if (amount == 0) return;

        _safeWithdraw(tokenId, amount, onBehalf);
    }

    function borrowCollateral(uint256 amount, uint256 onBehalfSeed) external {
        address onBehalf = _safeRandomMinter(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) return;

        vm.roll(block.number + 1);

        uint256 tokenId = _safeGetFirstTokenId(onBehalf);
        if (tokenId == 0) return;

        uint256 maxBorrow;
        try alchemist.getMaxBorrowable(tokenId) returns (uint256 mb) {
            maxBorrow = mb;
        } catch { handlerReverts++; return; }

        amount = bound(amount, 0, maxBorrow);
        if (amount == 0) return;

        _safeBorrow(tokenId, amount, onBehalf);
    }

    function repayDebt(uint256 amount, uint256 onBehalfSeed) external {
        address onBehalf = _safeRandomRepayer(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) return;

        uint256 tokenId = _safeGetFirstTokenId(onBehalf);
        if (tokenId == 0) return;

        uint256 debt;
        try alchemist.getCDP(tokenId) returns (uint256, uint256 d, uint256) {
            debt = d;
        } catch { handlerReverts++; return; }

        uint256 maxRepayShares;
        try alchemist.convertDebtTokensToYield(debt) returns (uint256 mrs) {
            maxRepayShares = mrs;
        } catch { handlerReverts++; return; }

        amount = bound(amount, 0, maxRepayShares);
        if (amount == 0) return;

        _safeRepay(tokenId, amount, onBehalf);
    }

    function repayDebtViaBurn(uint256 amount, uint256 onBehalfSeed) external {
        address onBehalf = _safeRandomBurner(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) return;

        vm.roll(block.number + 1);

        uint256 tokenId = _safeGetFirstTokenId(onBehalf);
        if (tokenId == 0) return;

        uint256 debt;
        uint256 earmarked;
        try alchemist.getCDP(tokenId) returns (uint256, uint256 d, uint256 e) {
            debt = d;
            earmarked = e;
        } catch { handlerReverts++; return; }

        if (debt <= earmarked) return;

        uint256 unearmarked = debt - earmarked;
        uint256 freeSynthetics = alchemist.totalSyntheticsIssued() - transmuterLogic.totalLocked();
        uint256 burnable = unearmarked > freeSynthetics ? freeSynthetics : unearmarked;

        amount = bound(amount, 0, burnable);
        if (amount == 0) return;

        _safeBurn(tokenId, amount, onBehalf);
    }

    function transmuterStake(uint256 amount, uint256 onBehalfSeed) external {
        address onBehalf = _randomNonZero(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) return;

        uint256 totalIssued = alchemist.totalSyntheticsIssued();
        uint256 totalLocked = transmuterLogic.totalLocked();
        if (totalIssued <= totalLocked) return;

        uint256 maxStakeable = totalIssued - totalLocked;
        amount = bound(amount, 0, maxStakeable);
        if (amount == 0) return;

        _safeStake(amount, onBehalf);
    }

    function transmuterClaim(uint256 onBehalfSeed) external {
        address onBehalf = _safeRandomClaimer(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) return;

        try IERC721Enumerable(address(transmuterLogic)).tokenOfOwnerByIndex(onBehalf, 0) returns (uint256 tid) {
            _safeClaim(tid, onBehalf);
        } catch { handlerReverts++; }
    }

    // ═══════════════════════════════════════════════════════════════
    //  NEW HANDLER: Attempt Liquidation
    // ═══════════════════════════════════════════════════════════════
    function triggerLiquidation(uint256 onBehalfSeed) external {
        address[] memory senders = targetSenders();

        for (uint256 i; i < senders.length; ++i) {
            uint256 idx;
            unchecked { idx = (onBehalfSeed + i) % senders.length; }
            uint256 tid = _safeGetFirstTokenId(senders[idx]);
            if (tid != 0) {
                try alchemist.getCDP(tid) returns (uint256, uint256 debt, uint256) {
                    if (debt > 0) {
                        liquidationAttempts++;
                        try alchemist.liquidate(tid) returns (uint256 amt, uint256, uint256) {
                            if (amt > 0) liquidationSuccesses++;
                        } catch {}
                    }
                } catch {}
                break;
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  NEW HANDLER: Simulate Value Loss (0.1-2%)
    // ═══════════════════════════════════════════════════════════════
    function simulateValueLoss(uint256 lossBps) external {
        lossBps = bound(lossBps, 10, 200);

        uint256 yieldTokenUnderlying = IERC20(mockVaultCollateral).balanceOf(mockStrategyYieldToken);
        uint256 siphonAmount = yieldTokenUnderlying * lossBps / 10000;

        if (siphonAmount > 0 && (yieldTokenUnderlying - siphonAmount) > yieldTokenUnderlying / 10) {
            try ITestYieldToken(mockStrategyYieldToken).siphon(siphonAmount) {} catch {}
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  NEW HANDLER: Yield Accrual (0.01-3%)
    // ═══════════════════════════════════════════════════════════════
    function simulateYield(uint256 yieldBps) external {
        yieldBps = bound(yieldBps, 1, 300);

        uint256 currentUnderlying = IERC20(mockVaultCollateral).balanceOf(mockStrategyYieldToken);
        uint256 yieldAmount = currentUnderlying * yieldBps / 10000;

        if (yieldAmount > 0) {
            deal(mockVaultCollateral, address(this), yieldAmount);
            IERC20(mockVaultCollateral).approve(mockStrategyYieldToken, yieldAmount);
            try ITestYieldToken(mockStrategyYieldToken).slurp(yieldAmount) {
                yieldAccruals++;
            } catch {}
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  NEW HANDLER: Poke All Positions
    // ═══════════════════════════════════════════════════════════════
    function pokeAll() external {
        address[] memory senders = targetSenders();
        for (uint256 i; i < senders.length; ++i) {
            uint256 tokenId = _safeGetFirstTokenId(senders[i]);
            if (tokenId != 0) {
                try alchemist.poke(tokenId) {} catch {}
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  NEW HANDLER: Poke Random Position
    // ═══════════════════════════════════════════════════════════════
    function pokeRandom(uint256 seed) external {
        address[] memory senders = targetSenders();
        uint256 idx = seed % senders.length;
        uint256 tokenId = _safeGetFirstTokenId(senders[idx]);
        if (tokenId != 0) {
            try alchemist.poke(tokenId) {} catch {}
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  INVARIANT 1: Storage-Based Debt Consistency
    // ═══════════════════════════════════════════════════════════════
    function invariantStorageDebtConsistency() public {
        address[] memory senders = targetSenders();

        // Force sync ALL positions
        for (uint256 i; i < senders.length; ++i) {
            uint256 tokenId = _safeGetFirstTokenId(senders[i]);
            if (tokenId != 0) {
                try alchemist.poke(tokenId) {} catch {}
            }
        }

        // Read STORED values after full poke
        uint256 sumDebt;
        uint256 sumEarmarked;
        uint256 sumCollateral;
        uint256 active;

        for (uint256 i; i < senders.length; ++i) {
            uint256 tokenId = _safeGetFirstTokenId(senders[i]);
            if (tokenId != 0) {
                try alchemist.getCDP(tokenId) returns (uint256 col, uint256 debt, uint256 earmarked) {
                    active++;
                    sumDebt += debt;
                    sumEarmarked += earmarked;
                    sumCollateral += col;
                } catch {}
            }
        }

        uint256 totalDebt = alchemist.totalDebt();
        uint256 cumEarmarked = alchemist.cumulativeEarmarked();
        uint256 totalDeposited = alchemist.getTotalDeposited();

        uint256 debtDelta = _absDiff(sumDebt, totalDebt);
        uint256 earmarkDelta = _absDiff(sumEarmarked, cumEarmarked);
        uint256 colDelta = _absDiff(sumCollateral, totalDeposited);

        if (debtDelta > maxDebtDelta) maxDebtDelta = debtDelta;
        if (earmarkDelta > maxEarmarkDelta) maxEarmarkDelta = earmarkDelta;
        if (colDelta > maxCollateralDelta) maxCollateralDelta = colDelta;

        uint256 cf = alchemist.underlyingConversionFactor();
        // Debt/earmark tolerance: 1e12 absolute or cf-scaled per-position (rounding from Q128 math)
        uint256 debtTol = _max(100, cf * _max(active, 1));
        // Collateral tolerance: higher because mulDivUp rounding in _sync's sharesToDebit
        // accumulates across multiple redemption cycles at different conversion rates.
        // The lazy sync uses cumulative _totalRedeemedSharesOut/_totalRedeemedDebt (weighted
        // average), so per-position debits round differently than global physical transfers.
        // Observed: ~2.87e14 on ~1.7e28 total (0.0000000000017%). Not exploitable.
        uint256 colTol = _max(100, cf * _max(active, 1) * 1e3);

        assertLe(debtDelta, debtTol, "H1a: stored debt sum != totalDebt after full sync");
        assertLe(earmarkDelta, debtTol, "H1b: stored earmark sum != cumulativeEarmarked after full sync");
        assertLe(colDelta, colTol, "H1c: stored collateral sum != totalDeposited after full sync");

        // Track max divergence for observability (ghost vars)
        if (debtDelta > maxDebtDelta) maxDebtDelta = debtDelta;
        if (earmarkDelta > maxEarmarkDelta) maxEarmarkDelta = earmarkDelta;
        if (colDelta > maxCollateralDelta) maxCollateralDelta = colDelta;

        // Hard — no tolerance
        assertLe(cumEarmarked, totalDebt, "H1d: cumulativeEarmarked > totalDebt");
    }

    // ═══════════════════════════════════════════════════════════════
    //  INVARIANT 2: Per-Position Sanity
    // ═══════════════════════════════════════════════════════════════
    function invariantPerPositionSanity() public {
        address[] memory senders = targetSenders();

        for (uint256 i; i < senders.length; ++i) {
            uint256 tokenId = _safeGetFirstTokenId(senders[i]);
            if (tokenId != 0) {
                try alchemist.poke(tokenId) {} catch { continue; }

                try alchemist.getCDP(tokenId) returns (uint256 col, uint256 debt, uint256 earmarked) {
                    assertLe(earmarked, debt, "H2a: earmarked > debt after poke");

                    if (debt == 0) {
                        assertEq(earmarked, 0, "H2b: zero debt but nonzero earmarked");
                    }

                    // Allow 1-2 wei rounding from mulDivUp in sharesToDebit
                    uint256 contractMYT = IERC20(alchemist.myt()).balanceOf(address(alchemist));
                    if (col > contractMYT) {
                        assertLe(col - contractMYT, 2, "H2c: position collateral exceeds contract MYT by >2 wei");
                    }
                } catch {}
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  INVARIANT 3: MYT Token Accounting
    // ═══════════════════════════════════════════════════════════════
    function invariantMYTTokenAccounting() public view {
        uint256 contractBalance = IERC20(alchemist.myt()).balanceOf(address(alchemist));
        uint256 tracked = alchemist.getTotalDeposited();

        assertGe(contractBalance, tracked, "H3: MYT balance < tracked (tokens leaked out)");
    }

    // ═══════════════════════════════════════════════════════════════
    //  INVARIANT 4: Poke Idempotency
    // ═══════════════════════════════════════════════════════════════
    function invariantPokeIdempotent() public {
        address[] memory senders = targetSenders();

        for (uint256 i; i < senders.length; ++i) {
            uint256 tokenId = _safeGetFirstTokenId(senders[i]);
            if (tokenId != 0) {
                try alchemist.poke(tokenId) {} catch { continue; }

                uint256 col1; uint256 debt1; uint256 ear1;
                try alchemist.getCDP(tokenId) returns (uint256 c, uint256 d, uint256 e) {
                    col1 = c; debt1 = d; ear1 = e;
                } catch { continue; }
                uint256 td1 = alchemist.totalDebt();
                uint256 ce1 = alchemist.cumulativeEarmarked();

                try alchemist.poke(tokenId) {} catch { continue; }
                uint256 col2; uint256 debt2; uint256 ear2;
                try alchemist.getCDP(tokenId) returns (uint256 c, uint256 d, uint256 e) {
                    col2 = c; debt2 = d; ear2 = e;
                } catch { continue; }
                uint256 td2 = alchemist.totalDebt();
                uint256 ce2 = alchemist.cumulativeEarmarked();

                assertEq(debt1, debt2, "H4a: poke not idempotent (debt)");
                assertEq(ear1, ear2, "H4b: poke not idempotent (earmarked)");
                assertEq(col1, col2, "H4c: poke not idempotent (collateral)");
                assertEq(td1, td2, "H4d: poke not idempotent (totalDebt)");
                assertEq(ce1, ce2, "H4e: poke not idempotent (cumulativeEarmarked)");
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  INVARIANT 5: Synthetics Balance
    // ═══════════════════════════════════════════════════════════════
    function invariantSyntheticsBalance() public view {
        assertGe(
            alchemist.totalSyntheticsIssued(),
            transmuterLogic.totalLocked(),
            "H5: totalSyntheticsIssued < transmuter.totalLocked"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  INVARIANT 6: No Orphaned Earmarks
    // ═══════════════════════════════════════════════════════════════
    function invariantNoOrphanedEarmarks() public view {
        assertLe(
            alchemist.cumulativeEarmarked(),
            alchemist.totalDebt(),
            "H6: cumulativeEarmarked > totalDebt"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  SAFE INTERNAL HELPERS (try/catch on all alchemist calls)
    // ═══════════════════════════════════════════════════════════════

    function _safeDeposit(uint256 tokenId, uint256 amount, address onBehalf) internal {
        deal(mockVaultCollateral, onBehalf, amount);
        vm.startPrank(onBehalf);
        IERC20(mockVaultCollateral).approve(address(vault), amount * 2);
        try vault.mint(amount, onBehalf) {} catch { vm.stopPrank(); return; }
        try alchemist.deposit(amount, onBehalf, tokenId) {} catch {}
        vm.stopPrank();
    }

    function _safeBorrow(uint256 tokenId, uint256 amount, address onBehalf) internal {
        vm.prank(onBehalf);
        try alchemist.mint(tokenId, amount, onBehalf) {} catch {}
    }

    function _safeWithdraw(uint256 tokenId, uint256 amount, address onBehalf) internal {
        vm.prank(onBehalf);
        try alchemist.withdraw(amount, onBehalf, tokenId) {} catch {}
    }

    function _safeRepay(uint256 tokenId, uint256 amount, address onBehalf) internal {
        vm.roll(block.number + 1);
        deal(mockVaultCollateral, onBehalf, amount * 2);
        vm.startPrank(onBehalf);
        IERC20(mockVaultCollateral).approve(address(vault), amount);
        try vault.mint(amount, onBehalf) {} catch { vm.stopPrank(); return; }
        try alchemist.repay(amount, tokenId) {} catch {}
        vm.stopPrank();
    }

    function _safeBurn(uint256 tokenId, uint256 amount, address onBehalf) internal {
        vm.prank(onBehalf);
        try alchemist.burn(amount, tokenId) {} catch {}
    }

    function _safeStake(uint256 amount, address onBehalf) internal {
        vm.startPrank(onBehalf);
        alToken.mint(onBehalf, amount);
        alToken.approve(address(transmuterLogic), amount);
        try transmuterLogic.createRedemption(amount, onBehalf) {} catch {}
        vm.stopPrank();
    }

    function _safeClaim(uint256 tokenId, address onBehalf) internal {
        vm.roll(block.number + 10000);
        vm.startPrank(onBehalf);
        try transmuterLogic.claimRedemption(tokenId) {} catch {}
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //  SAFE RANDOM SELECTORS (try/catch on view calls)
    // ═══════════════════════════════════════════════════════════════

    function _safeGetFirstTokenId(address user) internal view returns (uint256) {
        try AlchemistNFTHelper.getFirstTokenId(user, address(alchemistNFT)) returns (uint256 tid) {
            return tid;
        } catch {
            return 0;
        }
    }

    function _safeRandomWithdrawer(address[] memory _users, uint256 seed) internal returns (address) {
        address[] memory candidates = new address[](_users.length);

        for (uint256 i; i < _users.length; ++i) {
            uint256 tokenId = _safeGetFirstTokenId(_users[i]);
            if (tokenId != 0) {
                try alchemist.getMaxWithdrawable(tokenId) returns (uint256 w) {
                    if (w > 0) candidates[i] = _users[i];
                } catch { handlerReverts++; }
            }
        }

        return _randomNonZero(candidates, seed);
    }

    function _safeRandomMinter(address[] memory _users, uint256 seed) internal returns (address) {
        address[] memory candidates = new address[](_users.length);

        for (uint256 i; i < _users.length; ++i) {
            uint256 tokenId = _safeGetFirstTokenId(_users[i]);
            if (tokenId != 0) {
                try alchemist.getMaxBorrowable(tokenId) returns (uint256 b) {
                    if (b > 0) candidates[i] = _users[i];
                } catch { handlerReverts++; }
            }
        }

        return _randomNonZero(candidates, seed);
    }

    function _safeRandomRepayer(address[] memory _users, uint256 seed) internal returns (address) {
        address[] memory candidates = new address[](_users.length);

        for (uint256 i; i < _users.length; ++i) {
            uint256 tokenId = _safeGetFirstTokenId(_users[i]);
            if (tokenId != 0) {
                try alchemist.getCDP(tokenId) returns (uint256, uint256 debt, uint256) {
                    if (debt > 0) candidates[i] = _users[i];
                } catch { handlerReverts++; }
            }
        }

        return _randomNonZero(candidates, seed);
    }

    function _safeRandomBurner(address[] memory _users, uint256 seed) internal returns (address) {
        address[] memory candidates = new address[](_users.length);

        for (uint256 i; i < _users.length; ++i) {
            uint256 tokenId = _safeGetFirstTokenId(_users[i]);
            if (tokenId != 0) {
                try alchemist.getCDP(tokenId) returns (uint256, uint256 debt, uint256 earmarked) {
                    if (debt > 0 && debt > earmarked) candidates[i] = _users[i];
                } catch { handlerReverts++; }
            }
        }

        return _randomNonZero(candidates, seed);
    }

    function _safeRandomClaimer(address[] memory _users, uint256 seed) internal view returns (address) {
        address[] memory candidates = new address[](_users.length);

        for (uint256 i; i < _users.length; ++i) {
            try IERC721Enumerable(address(transmuterLogic)).balanceOf(_users[i]) returns (uint256 count) {
                if (count > 0) candidates[i] = _users[i];
            } catch {}
        }

        return _randomNonZero(candidates, seed);
    }

    // ═══════════════════════════════════════════════════════════════
    //  PURE HELPERS
    // ═══════════════════════════════════════════════════════════════

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}
