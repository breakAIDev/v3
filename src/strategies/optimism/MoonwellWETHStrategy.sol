// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IMToken {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function balanceOfUnderlying(address owner) external returns (uint256); // Note: not view, changes state.
    function balanceOf(address owner) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function exchangeRateCurrent() external returns (uint256);
}

interface IComptroller {
 function claimReward() external;    
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
    IERC20 public constant WELL = IERC20(0xA88594D404727625A9437C3f886C7643872296AE);
    IComptroller public immutable comptroller;
    
    error MoonwellWETHStrategyMintFailed(uint256 errorCode);
    error MoonwellWETHStrategyRedeemUnderlyingFailed(uint256 errorCode);

    constructor(address _myt, StrategyParams memory _params, address _mWETH, address _weth)
        MYTStrategy(_myt, _params)
    {
        mWETH = IMToken(_mWETH);
        weth = IWETH(_weth);
        comptroller = IComptroller(0xCa889f40aae37FFf165BccF69aeF1E82b5C511B9);
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(address(weth), address(this)) >= amount, "Strategy balance is less than amount");
        TokenUtils.safeApprove(address(weth), address(mWETH), amount);
        // Mint mWETH with underlying WETH
        uint256 errorCode = mWETH.mint(amount);
        if (errorCode != 0) {
            revert MoonwellWETHStrategyMintFailed(errorCode);
        }
        // Return actual assets received (mToken balance converted to underlying units)
        uint256 mTokenBalance = mWETH.balanceOf(address(this));
        uint256 exchangeRate = mWETH.exchangeRateStored();
        return (mTokenBalance * exchangeRate) / 1e18;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        // Calculate mTokens needed: ceil(amount * 1e18 / exchangeRate)
        uint256 mTokensNeeded = (amount * 1e18).ceilDiv(mWETH.exchangeRateStored());
        
        // Redeem mTokens for underlying WETH
        uint256 errorCode = mWETH.redeem(mTokensNeeded);
        if (errorCode != 0) {
            revert MoonwellWETHStrategyRedeemUnderlyingFailed(errorCode);
        }
        
        // Wrap any native ETH received to WETH
        if (address(this).balance > 0) {
            weth.deposit{value: address(this).balance}();
        }
        
        require(TokenUtils.safeBalanceOf(address(weth), address(this)) >= amount, "Strategy balance is less than the amount needed");
        TokenUtils.safeApprove(address(weth), msg.sender, amount);
        return amount;
    }

    function _totalValue() internal view override returns (uint256) {
        // Use stored exchange rate and mToken balance to avoid state changes during static calls
        uint256 mTokenBalance = mWETH.balanceOf(address(this));
        if (mTokenBalance == 0) return 0;
        uint256 exchangeRate = mWETH.exchangeRateStored();
        // Exchange rate is scaled by 1e18, so we need to divide by 1e18
        return (mTokenBalance * exchangeRate) / 1e18;
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        uint256 sharesNoFee = (amount * 1e18) / _rate();
        uint256 sharesWithFee = _previewMTokensForUnderlying(amount, false);
        uint256 feeShares = sharesWithFee > sharesNoFee ? sharesWithFee - sharesNoFee : 0;
        uint256 feeAssets = (feeShares * _rate()) / 1e18;
        uint256 netAssets = amount > feeAssets ? amount - feeAssets : 0;
        // Apply slippage using ceilDiv to avoid returning 0 for small amounts
        uint256 slippage = (netAssets * params.slippageBPS).ceilDiv(10_000);
        return netAssets > slippage ? netAssets - slippage : 0;
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

    // moonwell extra rewards only arrive in WELL token
    function _claimRewards(address token, bytes memory quote, uint256 minAmountOut) internal override returns (uint256) {
        require(token == address(WELL), "Invalid Token");
        uint256 wellBefore = WELL.balanceOf(address(this));
        comptroller.claimReward();
        uint256 wellAfter = WELL.balanceOf(address(this));
        uint256 wellReceived = wellAfter - wellBefore;
        if (wellReceived == 0) return 0;
        emit RewardsClaimed(address(WELL), wellReceived);
        uint256 wethReceived = dexSwap(address(MYT.asset()), address(WELL), wellReceived, minAmountOut, quote);
        TokenUtils.safeTransfer(address(MYT.asset()), address(MYT), wethReceived);
        return wethReceived;
    }
    
    receive() external payable {}
}
