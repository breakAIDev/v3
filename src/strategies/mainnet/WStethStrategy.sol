// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;
import {OraclePricedSwapStrategy} from "./OraclePricedSwapStrategy.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {IWETH} from "../../interfaces/IWETH.sol";

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

contract WstethMainnetStrategy is OraclePricedSwapStrategy {
    stETH public immutable steth;
    wstETH public immutable wsteth;

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _stETH,
        address _wstETH,
        address _stEthEthOracle
    ) OraclePricedSwapStrategy(_myt, _params, _stEthEthOracle) {
        steth = stETH(_stETH);
        wsteth = wstETH(_wstETH);
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
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

    /// @notice Deallocate with intermediate unwrap step
    /// @param amount WETH amount expected to be returned to vault
    /// @param callData 0x swap calldata for stETH -> WETH
    /// @dev Pricing and sizing are derived from the oracle instead of trusting frontend sizing.
    function _deallocate(uint256 amount, bytes memory callData) internal override returns (uint256) {
        return _deallocateViaPricedSwap(amount, callData);
    }

    receive() external payable {
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == MYT.asset() || token == address(wsteth) || token == address(steth);
    }

    function _pricedToken() internal view override returns (address) {
        return address(steth);
    }

    function _positionBalance() internal view override returns (uint256) {
        return wsteth.balanceOf(address(this));
    }

    function _positionToPriced(uint256 positionAmount) internal view override returns (uint256) {
        return wsteth.getStETHByWstETH(positionAmount);
    }

    function _idlePricedAssets() internal view override returns (uint256) {
        return TokenUtils.safeBalanceOf(address(steth), address(this));
    }

    function _afterAllocateSwap(uint256 pricedReceived) internal override {
        TokenUtils.safeApprove(address(steth), address(wsteth), pricedReceived);
        wsteth.wrap(pricedReceived);
        TokenUtils.safeApprove(address(steth), address(wsteth), 0);
    }

    function _preparePricedForSwap(uint256 maxPricedIn) internal override returns (uint256) {
        uint256 currentStETHBalance = TokenUtils.safeBalanceOf(address(steth), address(this));
        if (currentStETHBalance < maxPricedIn) {
            uint256 additionalStETHNeeded = maxPricedIn - currentStETHBalance;
            uint256 wstETHBalance = wsteth.balanceOf(address(this));
            if (wstETHBalance > 0) {
                uint256 wstETHToUnwrap = wsteth.getWstETHByStETH(additionalStETHNeeded) + 1;
                if (wstETHToUnwrap > wstETHBalance) {
                    wstETHToUnwrap = wstETHBalance;
                }
                if (wstETHToUnwrap > 0) {
                    wsteth.unwrap(wstETHToUnwrap);
                }
                currentStETHBalance = TokenUtils.safeBalanceOf(address(steth), address(this));
            }
        }
        return currentStETHBalance > maxPricedIn ? maxPricedIn : currentStETHBalance;
    }
}
