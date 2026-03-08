// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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
interface IPoolAddressProvider {
    function getPool() external view returns (address);
}

interface IAaveAToken {
    function balanceOf(address) external view returns (uint256);
    function scaledBalanceOf(address) external view returns (uint256);
}

interface IRewardsController {
    function claimAllRewardsToSelf(address[] calldata assets) external returns (address[] memory rewardsList, uint256[] memory claimedAmounts);
}


/**
 * @title AaveV3ARBUSDCStrategy
 * @notice This strategy is used to allocate and deallocate usdc to the Aave v3 USDC pool on ARB
 */
contract AaveV3ARBUSDCStrategy is MYTStrategy {
    IERC20 public immutable usdc; // ARB USDC
    IAaveAToken public immutable aUSDC; // aToken for USDC on ARB
    IPoolAddressProvider public immutable poolProvider;
    IRewardsController public immutable rewardsController;
    IERC20 public constant ARB = IERC20(0x912CE59144191C1204E64559FE8253a0e49E6548);
    
    constructor(address _myt, StrategyParams memory _params, address _usdc, address _aUSDC, address _poolProvider)
        MYTStrategy(_myt, _params)
    {
        usdc = IERC20(_usdc);
        aUSDC = IAaveAToken(_aUSDC);
        poolProvider = IPoolAddressProvider(_poolProvider);
        rewardsController = IRewardsController(0x929EC64c34a17401F460460D4B9390518E5B473e);
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        IAavePool pool = IAavePool(poolProvider.getPool());
        require(TokenUtils.safeBalanceOf(address(usdc), address(this)) >= amount, "Strategy balance is less than amount");
        TokenUtils.safeApprove(address(usdc), address(pool), amount);
        pool.supply(address(usdc), amount, address(this), 0);
        return amount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        IAavePool pool = IAavePool(poolProvider.getPool());
        uint256 usdcBalanceBefore = TokenUtils.safeBalanceOf(address(usdc), address(this));
        // withdraw exact underlying amount back to this adapter
        pool.withdraw(address(usdc), amount, address(this));
        require(TokenUtils.safeBalanceOf(address(usdc), address(this)) >= amount, "Strategy balance is less than the amount needed");
        TokenUtils.safeApprove(address(usdc), msg.sender, amount);
        return amount;
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        // Aave doesn't charge withdrawal fees, so we just apply slippage
        return amount - (amount * params.slippageBPS / 10_000);
    }

    function _totalValue() internal view override returns (uint256) {
        // aToken balance reflects principal + interest in underlying units
        return aUSDC.scaledBalanceOf(address(this));
    }

    function _claimRewards(address token, bytes memory quote, uint256 minAmountOut) internal override returns (uint256) {
        address[] memory assets = new address[](1);
        assets[0] = token;
        uint256 arbBefore = ARB.balanceOf(address(this));
        rewardsController.claimAllRewardsToSelf(assets);
        uint256 arbReceived = ARB.balanceOf(address(this)) - arbBefore;

        // note: 0x912CE59144191C1204E64559FE8253a0e49E6548 (arb)
        // is the only current supported reward token in the aave
        // incentive controller, but this can change in the future
        if (arbReceived == 0) return 0;
        emit RewardsClaimed(address(ARB), arbReceived);
        uint256 usdcReceived = dexSwap(address(MYT.asset()), address(ARB), arbReceived, minAmountOut, quote);
        TokenUtils.safeTransfer(address(MYT.asset()), address(MYT), usdcReceived);
        return usdcReceived;
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == MYT.asset() || token == address(aUSDC);
    }
}
