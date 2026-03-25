// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;
import {MYTStrategy} from "../../MYTStrategy.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface stETH {
    function sharesOf(address account) external view returns (uint256);
    function getPooledEthByShares(uint256 sharesAmount) external view returns (uint256);
    function submit(address referral) external payable returns (uint256);
}

interface wstETH {
    function getWstETHByStETH(uint256 amount) external view returns (uint256);
    function getStETHByWstETH(uint256 amount) external view returns (uint256);
    function wrap(uint256 amount) external returns (uint256);
    function unwrap(uint256 amount) external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface WETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}


contract WstethMainnetStrategy is MYTStrategy {
    using Math for uint256;

    uint256 public constant MAX_ORACLE_STALENESS = 7 days;

    stETH public immutable steth;
    wstETH public immutable wsteth;

    WETH public immutable weth;
    AggregatorV3Interface public immutable stEthEthOracle;
    uint8 public immutable stEthEthOracleDecimals;

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _weth,
        address _stETH,
        address _wstETH,
        address _stEthEthOracle
    ) MYTStrategy(_myt, _params) {
        weth = WETH(_weth);
        steth = stETH(_stETH);
        wsteth = wstETH(_wstETH);
        stEthEthOracle = AggregatorV3Interface(_stEthEthOracle);
        stEthEthOracleDecimals = stEthEthOracle.decimals();
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        _ensureIdleBalance(address(weth), amount);
        
        uint256 wstETHBefore = wsteth.balanceOf(address(this));
        
        // Unwrap WETH -> ETH
        weth.withdraw(amount);
        
        // Send ETH to wstETH contract - triggers receive() which stakes and wraps in one call
        // See: https://github.com/lidofinance/core/blob/master/contracts/0.6.12/WstETH.sol
        (bool success, ) = address(wsteth).call{value: amount}("");
        require(success, "wstETH deposit failed");
        
        uint256 wstETHAfter = wsteth.balanceOf(address(this));
        uint256 wstETHReceived = wstETHAfter - wstETHBefore;
        require(wstETHReceived > 0, "No wstETH received");
        
        return amount;
    }

    function _allocate(uint256 amount, bytes memory callData) internal override returns (uint256 depositReturn) {
        _ensureIdleBalance(address(weth), amount);

        uint256 minStEthOut = (amount * (10_000 - params.slippageBPS)) / 10_000;
        uint256 stETHReceived = dexSwap(address(steth), address(weth), amount, minStEthOut, callData);
        require(stETHReceived > 0, "No stETH received");

        TokenUtils.safeApprove(address(steth), address(wsteth), stETHReceived);
        wsteth.wrap(stETHReceived);

        return stETHReceived;

    }

    
    /// @notice Deallocate with intermediate unwrap step
    /// @param amount WETH amount expected to be returned to vault
    /// @param callData 0x swap calldata for stETH -> WETH
    /// @param minIntermediateOut Minimum stETH to produce from unwrap (from quote's sellAmount)
    function _deallocate(uint256 amount, bytes memory callData, uint256 minIntermediateOut) internal override returns (uint256) {
        // Check idle WETH balance first - only unwrap+swap if there's a shortfall
        uint256 idleBalance = _idleAssets();
        if (idleBalance >= amount) {
            TokenUtils.safeApprove(address(weth), msg.sender, amount);
            return amount;
        }

        uint256 shortfall = amount - idleBalance;
        uint256 idleStEthEquivalent = _wethToStEth(idleBalance);
        uint256 stEthToSwap = minIntermediateOut > idleStEthEquivalent ? minIntermediateOut - idleStEthEquivalent : 0;

        if (stEthToSwap == 0) {
            TokenUtils.safeApprove(address(weth), msg.sender, amount);
            return amount;
        }

        uint256 wstETHToUnwrap = wsteth.getWstETHByStETH(stEthToSwap) + 1;
        
        // Cap at actual balance
        uint256 wstETHBalance = wsteth.balanceOf(address(this));
        if (wstETHToUnwrap > wstETHBalance) {
            wstETHToUnwrap = wstETHBalance;
        }
        
        // Unwrap wstETH -> stETH
        uint256 stETHBefore = TokenUtils.safeBalanceOf(address(steth), address(this));
        wsteth.unwrap(wstETHToUnwrap);
        uint256 stETHAfter = TokenUtils.safeBalanceOf(address(steth), address(this));
        uint256 stETHReceived = stETHAfter - stETHBefore;

        uint256 minWethOut = (shortfall * (10_000 - params.slippageBPS)) / 10_000;
        if (minWethOut == 0) minWethOut = 1;

        dexSwap(address(weth), address(steth), stEthToSwap, minWethOut, callData);
        uint256 wethBalance = IERC20(address(weth)).balanceOf(address(this));
        require(wethBalance >= amount, InvalidAmount(amount, wethBalance));
        TokenUtils.safeApprove(address(weth), msg.sender, amount);
        return amount;
    }

    function _totalValue() internal view override returns (uint256) {
        uint256 wstBal = wsteth.balanceOf(address(this));
        if (wstBal == 0) return _idleAssets();
        uint256 stEthNotional = wsteth.getStETHByWstETH(wstBal);
        return _idleAssets() + _stEthToWeth(stEthNotional);
    }
    function _previewAdjustedWithdraw(uint256 amount) 
        internal 
        view 
        override 
        returns (uint256) 
    {
        uint256 wstBal = wsteth.balanceOf(address(this));
        if (wstBal == 0) return 0;

        // Amount of steth that can be withdrawn from wsteth balance
        uint256 maxFundamentalWeth = _stEthToWeth(wsteth.getStETHByWstETH(wstBal));

        // Cap to available capacity
        uint256 fundable = amount <= maxFundamentalWeth 
            ? amount 
            : maxFundamentalWeth;

        return (fundable * (10_000 - params.slippageBPS)) / 10_000;
    }

    receive() external payable {
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == MYT.asset() || token == address(wsteth) || token == address(steth);
    }

    function _idleAssets() internal view override returns (uint256) {
        return IERC20(address(weth)).balanceOf(address(this));
    }

    function _stEthToWeth(uint256 stEthAmount) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = stEthEthOracle.latestRoundData();
        require(answer > 0 && updatedAt != 0, "Invalid oracle answer");
        require(updatedAt <= block.timestamp && block.timestamp - updatedAt <= MAX_ORACLE_STALENESS, "Stale oracle answer");
        return stEthAmount * uint256(answer) / (10 ** stEthEthOracleDecimals);
    }

    function _wethToStEth(uint256 wethAmount) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = stEthEthOracle.latestRoundData();
        require(answer > 0 && updatedAt != 0, "Invalid oracle answer");
        require(updatedAt <= block.timestamp && block.timestamp - updatedAt <= MAX_ORACLE_STALENESS, "Stale oracle answer");
        return Math.ceilDiv(wethAmount * (10 ** stEthEthOracleDecimals), uint256(answer));
    }
}
