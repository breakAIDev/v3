// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IERC4626} from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
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
 * @title MoonwellWETHStrategy
 * @dev Strategy used to deposit WETH into Moonwell WETH pool on OP
 */
contract MoonwellWETHStrategy is MYTStrategy {
    using MathExtra for uint256;

    IMToken public immutable mWETH; // Moonwell market (mToken) 0xb4104C02BBf4E9be85AAa41a62974E4e28D59A33
    IWETH public immutable weth; // 0x4200000000000000000000000000000000000006

    constructor(address _myt, StrategyParams memory _params, address _mWETH, address _weth, address _permit2Address)
        MYTStrategy(_myt, _params, _permit2Address, _weth)
    {
        mWETH = IMToken(_mWETH);
        weth = IWETH(_weth);
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(address(weth), address(this)) >= amount, "Strategy balance is less than amount");
        TokenUtils.safeApprove(address(weth), address(mWETH), amount);
        // Mint mWETH with underlying WETH
        mWETH.mint(amount);
        return amount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 ethBalanceBefore = address(this).balance;
        // Pull exact amount of underlying WETH out
        mWETH.redeemUnderlying(amount);
        // wrap any ETH received (Moonwell redeems to ETH for WETH markets)
        uint256 ethBalanceAfter = address(this).balance;
        uint256 ethRedeemed = ethBalanceAfter - ethBalanceBefore;
        if (ethRedeemed < amount) {
            emit StrategyDeallocationLoss("Strategy deallocation loss.", amount, ethRedeemed);
        }
        if (ethRedeemed + ethBalanceBefore >= amount) {
            weth.deposit{value: ethRedeemed}();
        }
        require(TokenUtils.safeBalanceOf(address(weth), address(this)) >= amount, "Strategy balance is less than the amount needed");
        TokenUtils.safeApprove(address(weth), msg.sender, amount);
        return amount;
    }

    function realAssets() external view override returns (uint256) {
        // Use stored exchange rate and mToken balance to avoid state changes during static calls
        uint256 mTokenBalance = mWETH.balanceOf(address(this));
        if (mTokenBalance == 0) return 0;
        uint256 exchangeRate = mWETH.exchangeRateStored();
        // Exchange rate is scaled by 1e18, so we need to divide by 1e18
        return (mTokenBalance * exchangeRate) / 1e18;
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        uint256 mtokensNeeded = _previewMTokensForUnderlying(amount, false);
        uint256 wethOut = _previewUnderlyingForMTokens(mtokensNeeded, false);
        return wethOut - (wethOut * slippageBPS / 10_000);
    }

    /// Preview mTokens required to withdraw a target amount of WETH
    /// mTokens_needed = ceil( WETH_target * 1e18 / exchangeRate )
    /// Use ceil to ensure enough mTokens given rounding.
    function _previewMTokensForUnderlying(uint256 wethTarget, bool useCurrent) internal view returns (uint256 mTokensNeeded) {
        uint256 rate = _rate();
        mTokensNeeded = (wethTarget * 1e18).ceilDiv(rate);
    }

    /// Preview WETH out for a given mToken amount
    /// WETH_out = mTokens * exchangeRate / 1e18
    function _previewUnderlyingForMTokens(uint256 mTokenAmount, bool useCurrent) internal view returns (uint256 wethOut) {
        uint256 rate = _rate();
        // Exchange rate mantissa is scaled by 1e18 (and already accounts for token decimals)
        wethOut = (mTokenAmount * rate) / 1e18;
    }

    /// exchangeRateStored -> pure view, no state change (may slightly UNDERestimate since it doesn't accrue)
    function _rate() internal view returns (uint256) {
        return mWETH.exchangeRateStored();
    }

    receive() external payable {}
}
