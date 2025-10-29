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
 * @title AaveV3OPUSDCStrategy
 * @dev Strategy used to deposit USDC into Aave v3 USDC pool on OP
 */
contract AaveV3OPUSDCStrategy is MYTStrategy {
    IERC20 public immutable usdc; // OP USDC
    IAavePool public immutable pool; // Aave v3 Pool on OP
    IAaveAToken public immutable aUSDC; // aToken for USDC on OP

    constructor(address _myt, StrategyParams memory _params, address _usdc, address _aUSDC, address _pool, address _permit2Address)
        MYTStrategy(_myt, _params, _permit2Address, _usdc)
    {
        usdc = IERC20(_usdc);
        pool = IAavePool(_pool);
        aUSDC = IAaveAToken(_aUSDC);
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(address(usdc), address(this)) >= amount, "Strategy balance is less than amount");
        TokenUtils.safeApprove(address(usdc), address(pool), amount);
        pool.supply(address(usdc), amount, address(this), 0);
        return amount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        // withdraw exact underlying amount back to this adapter
        pool.withdraw(address(usdc), amount, address(this));
        require(TokenUtils.safeBalanceOf(address(usdc), address(this)) >= amount, "Strategy balance is less than the amount needed");
        TokenUtils.safeApprove(address(usdc), msg.sender, amount);
        return amount;
    }

    function realAssets() external view override returns (uint256) {
        // aToken balance reflects principal + interest in underlying units
        return aUSDC.balanceOf(address(this));
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        // amount in USDC is 1:1 with aUSDC.
        // which differs from actual balance of aUSDC which includes interest.
        return amount - (amount * slippageBPS / 10_000);
    }
}
