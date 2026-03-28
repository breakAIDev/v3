// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;
import {OraclePricedSwapStrategy} from "./OraclePricedSwapStrategy.sol";
import {IWETH} from "../interfaces/IWETH.sol";

interface wstETH {
    function balanceOf(address account) external view returns (uint256);
}

contract WstethStrategy is OraclePricedSwapStrategy {
    wstETH public immutable wsteth;
    bool public immutable directDepositEnabled;

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _wstETH,
        address _pricedTokenEthOracle,
        bool _directDepositEnabled
    ) OraclePricedSwapStrategy(_myt, _params, _pricedTokenEthOracle) {
        wsteth = wstETH(_wstETH);
        directDepositEnabled = _directDepositEnabled;
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        if (!directDepositEnabled) revert ActionNotSupported();
        _ensureIdleBalance(_asset(), amount);

        uint256 wstETHBefore = wsteth.balanceOf(address(this));

        // Unwrap WETH -> ETH
        IWETH(MYT.asset()).withdraw(amount);

        // Send ETH to wstETH contract - triggers receive() which stakes and wraps in one call
        // See: https://github.com/lidofinance/core/blob/master/contracts/0.6.12/WstETH.sol
        (bool success, ) = address(wsteth).call{value: amount}("");
        require(success, "wstETH deposit failed");

        uint256 wstETHAfter = wsteth.balanceOf(address(this));
        uint256 wstETHReceived = wstETHAfter - wstETHBefore;
        require(wstETHReceived > 0, "No wstETH received");

        return amount;
    }

    function _allocate(uint256 amount, bytes memory callData) internal override returns (uint256) {
        _ensureIdleBalance(_asset(), amount);

        uint256 minWstEthOut = _assetToPricedDown((amount * (10_000 - params.slippageBPS)) / 10_000);
        if (minWstEthOut == 0) minWstEthOut = 1;

        dexSwap(address(wsteth), _asset(), amount, minWstEthOut, callData);
        return amount;
    }

    receive() external payable {}

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == MYT.asset() || token == address(wsteth);
    }

    function _pricedToken() internal view override returns (address) {
        return address(wsteth);
    }

    function _positionBalance() internal view override returns (uint256) {
        return wsteth.balanceOf(address(this));
    }

    function _positionToPriced(uint256 positionAmount) internal view override returns (uint256) {
        return positionAmount;
    }

    function _idlePricedAssets() internal view override returns (uint256) {
        return 0;
    }

    function _afterAllocateSwap(uint256) internal override {}

    function _preparePricedForSwap(uint256 maxPricedIn) internal view override returns (uint256) {
        uint256 wstETHBalance = wsteth.balanceOf(address(this));
        return maxPricedIn > wstETHBalance ? wstETHBalance : maxPricedIn;
    }
}
