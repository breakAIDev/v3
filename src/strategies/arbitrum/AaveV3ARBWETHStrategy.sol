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
}

interface IRewardsController {
    function claimAllRewardsToSelf(address[] calldata assets) external returns (address[] memory rewardsList, uint256[] memory claimedAmounts);
}

/**
 * @title AaveV3ARBWETHStrategy
 * @notice This strategy is used to allocate and deallocate weth to the Aave v3 WETH pool on ARB
 */
contract AaveV3ARBWETHStrategy is MYTStrategy {
    IERC20 public immutable weth; // ARB WETH
    IPoolAddressProvider public immutable poolProvider;
    IAaveAToken public immutable aWETH; // aToken for WETH on ARB
    IRewardsController public immutable rewardsController;
    IERC20 public constant ARB = IERC20(0x912CE59144191C1204E64559FE8253a0e49E6548);
    
    constructor(address _myt, StrategyParams memory _params, address _aWETH, address _weth, address _poolProvider)
        MYTStrategy(_myt, _params)
    {
        weth = IERC20(_weth);
        poolProvider = IPoolAddressProvider(_poolProvider);
        aWETH = IAaveAToken(_aWETH);
        rewardsController = IRewardsController(0x929EC64c34a17401F460460D4B9390518E5B473e);
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        IAavePool pool = IAavePool(poolProvider.getPool());
        require(TokenUtils.safeBalanceOf(address(weth), address(this)) >= amount, "Strategy balance is less than amount");
        TokenUtils.safeApprove(address(weth), address(pool), amount);
        pool.supply(address(weth), amount, address(this), 0);
        return amount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        IAavePool pool = IAavePool(poolProvider.getPool());
        uint256 idleBalance = _idleAssets();
        uint256 withdrawnAmount = amount;
        if (idleBalance < amount) {
            uint256 shortfall = amount - idleBalance;
            uint256 balanceBefore = TokenUtils.safeBalanceOf(address(weth), address(this));
            withdrawnAmount = pool.withdraw(address(weth), shortfall, address(this));
            uint256 balanceAfter = TokenUtils.safeBalanceOf(address(weth), address(this));
            require(withdrawnAmount >= shortfall, "Withdraw amount insufficient");
            require(balanceAfter >= balanceBefore + shortfall, "Withdraw balance delta insufficient");
        }
        //require(TokenUtils.safeBalanceOf(address(weth), address(this)) >= amount, "Strategy balance is less than the amount needed");
        TokenUtils.safeApprove(address(weth), msg.sender, amount);
        return withdrawnAmount;
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        // Aave doesn't charge withdrawal fees, so we just apply slippage
        return amount - (amount * params.slippageBPS / 10_000);
    }

    function _totalValue() internal view override returns (uint256) {
        uint256 idleUnderlying = _idleAssets();
        // aToken balance reflects principal + interest in underlying units
        return aWETH.balanceOf(address(this)) + idleUnderlying;
    }

    function _idleAssets() internal view override returns (uint256) {
        return TokenUtils.safeBalanceOf(address(weth), address(this));
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
        uint256 wethReceived = dexSwap(address(MYT.asset()), address(ARB), arbReceived, minAmountOut, quote);
        emit RewardsClaimed(address(ARB), arbReceived);
        TokenUtils.safeTransfer(address(MYT.asset()), address(MYT), wethReceived);
        return wethReceived;
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == MYT.asset() || token == address(aWETH);
    }
}
