// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IPoolAddressProvider {
    function getPool() external view returns (address);
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAaveAToken {
    function balanceOf(address) external view returns (uint256);
}

interface IRewardsController {
    function claimAllRewardsToSelf(address[] calldata assets) external returns (address[] memory rewardsList, uint256[] memory claimedAmounts);
}

/**
 * @title AaveV3OPUSDCStrategy
 * @dev Strategy used to deposit USDC into Aave v3 USDC pool on OP
 */
contract AaveV3OPUSDCStrategy is MYTStrategy {
    IERC20 public immutable usdc; // OP USDC
    IPoolAddressProvider public immutable poolProvider; // Aave v3 Pool Address Provider on OP
    IAaveAToken public immutable aUSDC; // aToken for USDC on OP
    IRewardsController public immutable rewardsController;
    IERC20 public constant OP = IERC20(0x4200000000000000000000000000000000000042);
    
    constructor(address _myt, StrategyParams memory _params, address _usdc, address _aUSDC, address _poolProvider)
        MYTStrategy(_myt, _params)
    {
        usdc = IERC20(_usdc);
        poolProvider = IPoolAddressProvider(_poolProvider);
        aUSDC = IAaveAToken(_aUSDC);
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
        require(
            TokenUtils.safeBalanceOf(address(usdc), address(this)) >= usdcBalanceBefore + amount,
            "Strategy balance is less than the amount needed"
        );
        TokenUtils.safeApprove(address(usdc), msg.sender, amount);
        return amount;
    }

    function _totalValue() internal view override returns (uint256) {
        // aToken balance reflects principal + interest in underlying units
        return aUSDC.balanceOf(address(this));
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        // Aave doesn't charge withdrawal fees, so we just apply slippage
        return amount - (amount * params.slippageBPS / 10_000);
    }

    function _claimRewards(address token, bytes memory quote, uint256 minAmountOut) internal override returns (uint256) {
        address[] memory assets = new address[](1);
        assets[0] = token;
        uint256 opBefore = OP.balanceOf(address(this));
        rewardsController.claimAllRewardsToSelf(assets);
        uint256 opReceived = OP.balanceOf(address(this)) - opBefore;

        // note: 0x4200000000000000000000000000000000000042 (op)
        // is the only current supported reward token in the aave
        // incentive controller, but this can change in the future
        if (opReceived == 0) return 0;
        emit RewardsClaimed(address(OP), opReceived);
        uint256 usdcReceived = dexSwap(address(MYT.asset()), address(OP), opReceived, minAmountOut, quote);
        TokenUtils.safeTransfer(address(MYT.asset()), address(MYT), usdcReceived);
        return usdcReceived;
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == MYT.asset() || token == address(aUSDC);
    }
}
