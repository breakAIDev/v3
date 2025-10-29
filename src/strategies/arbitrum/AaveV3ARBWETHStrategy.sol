// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAaveAToken {
    function balanceOf(address) external view returns (uint256);
}

/**
 * @title AaveV3ARBWETHStrategy
 * @notice This strategy is used to allocate and deallocate weth to the Aave v3 WETH pool on ARB
 */
contract AaveV3ARBWETHStrategy is MYTStrategy {
    IERC20 public immutable weth; // ARB WETH
    IAavePool public immutable pool; // Aave v3 Pool on ARB
    IAaveAToken public immutable aWETH; // aToken for WETH on ARB

    constructor(address _myt, StrategyParams memory _params, address _aWETH, address _weth, address _pool, address _permit2Address)
        MYTStrategy(_myt, _params, _permit2Address, _weth)
    {
        weth = IERC20(_weth);
        pool = IAavePool(_pool);
        aWETH = IAaveAToken(_aWETH);
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(address(weth), address(this)) >= amount, "Strategy balance is less than amount");
        TokenUtils.safeApprove(address(weth), address(pool), amount);
        pool.supply(address(weth), amount, address(this), 0);
        return amount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 wethBalanceBefore = TokenUtils.safeBalanceOf(address(weth), address(this));
        // withdraw exact underlying amount back to this adapter
        pool.withdraw(address(weth), amount, address(this));
        uint256 wethBalanceAfter = TokenUtils.safeBalanceOf(address(weth), address(this));
        uint256 wethRedeemed = wethBalanceAfter - wethBalanceBefore;
        if (wethRedeemed < amount) {
            emit StrategyDeallocationLoss("Strategy deallocation loss.", amount, wethRedeemed);
        }
        require(TokenUtils.safeBalanceOf(address(weth), address(this)) >= amount, "Strategy balance is less than the amount needed");
        TokenUtils.safeApprove(address(weth), msg.sender, amount);
        return amount;
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        // amount in WETH is 1:1 with aWETH.
        // which differs from actual balance of aWETH which includes interest.
        return amount - (amount * slippageBPS / 10_000);
    }

    function realAssets() external view override returns (uint256) {
        // aToken balance reflects principal + interest in underlying units
        return aWETH.balanceOf(address(this));
    }
}
