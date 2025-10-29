// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IERC4626} from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IMToken {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function balanceOfUnderlying(address owner) external returns (uint256); // Note: not view, changes state.
    function balanceOf(address owner) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function exchangeRateCurrent() external returns (uint256);
}

library MathExtra {
    // ceilDiv for uint256: ceil(a / b)
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : 1 + ((a - 1) / b);
    }
}

/**
 * @title MoonwellUSDCStrategy
 * @dev Strategy used to deposit USDC into Moonwell USDC pool on OP
 */
contract MoonwellUSDCStrategy is MYTStrategy {
    using MathExtra for uint256;

    IMToken public immutable mUSDC; // Moonwell market mUSDC (mToken) 0xd0670AEe3698F66e2D4dAf071EB9c690d978BFA8
    IERC20 public immutable usdc; // 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48

    event MoonwellUSDCStrategyDebugLog(string message, uint256 value);

    constructor(address _myt, StrategyParams memory _params, address _mUSDC, address _usdc, address _permit2Address)
        MYTStrategy(_myt, _params, _permit2Address, _usdc)
    {
        mUSDC = IMToken(_mUSDC);
        usdc = IERC20(_usdc);
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(address(usdc), address(this)) >= amount, "Strategy balance is less than amount");
        TokenUtils.safeApprove(address(usdc), address(mUSDC), amount);
        // Mint mUSDC with underlying USDC
        mUSDC.mint(amount);
        return amount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 usdcBalanceBefore = TokenUtils.safeBalanceOf(address(usdc), address(this));
        // Pull exact amount of underlying USDC out
        mUSDC.redeemUnderlying(amount);
        uint256 usdcBalanceAfter = TokenUtils.safeBalanceOf(address(usdc), address(this));
        uint256 usdcRedeemed = usdcBalanceAfter - usdcBalanceBefore;
        if (usdcRedeemed < amount) {
            emit StrategyDeallocationLoss("Strategy deallocation loss.", amount, usdcRedeemed);
        }
        require(TokenUtils.safeBalanceOf(address(usdc), address(this)) >= amount, "Strategy balance is less than the amount needed");
        TokenUtils.safeApprove(address(usdc), msg.sender, amount);
        return amount;
    }

    function realAssets() external view override returns (uint256) {
        // Use stored exchange rate and mToken balance to avoid state changes during static calls
        uint256 mTokenBalance = mUSDC.balanceOf(address(this));
        if (mTokenBalance == 0) return 0;
        uint256 exchangeRate = mUSDC.exchangeRateStored();
        // Exchange rate is scaled by 1e18, so we need to divide by 1e18
        return (mTokenBalance * exchangeRate) / 1e18;
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        uint256 mtokensNeeded = _previewMTokensForUnderlying(amount, false);
        uint256 usdcOut = _previewUnderlyingForMTokens(mtokensNeeded, false);
        return usdcOut - (usdcOut * slippageBPS / 10_000);
    }

    /// Preview mTokens required to withdraw a target amount of USDC
    /// mTokens_needed = ceil( USDC_target * 1e18 / exchangeRate )
    /// Use ceil to ensure enough mTokens given rounding.
    function _previewMTokensForUnderlying(uint256 usdcTarget, bool useCurrent) internal view returns (uint256 mTokensNeeded) {
        uint256 rate = _rate();
        mTokensNeeded = (usdcTarget * 1e18).ceilDiv(rate);
    }

    /// Preview USDC out for a given mToken amount
    /// USDC_out = mTokens * exchangeRate / 1e18
    function _previewUnderlyingForMTokens(uint256 mTokenAmount, bool useCurrent) internal view returns (uint256 usdcOut) {
        uint256 rate = _rate();
        // Exchange rate mantissa is scaled by 1e18 (and already accounts for token decimals)
        usdcOut = (mTokenAmount * rate) / 1e18;
    }

    /// @notice Choose which rate to use for preview:
    /// exchangeRateStored -> pure view, no state change (may slightly UNDERestimate since it doesn't accrue)
    function _rate() internal view returns (uint256) {
        return mUSDC.exchangeRateStored();
    }
}
