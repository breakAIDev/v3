pragma solidity ^0.8.21;

import {MYTStrategy} from "../../MYTStrategy.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";

interface IStargatePool {
    function deposit(address receiver, uint256 amountLD) external payable returns (uint256 amountLDOut);
    function redeem(uint256 lpAmount, address receiver) external returns (uint256 amountLDOut);
    function redeemable(address owner) external view returns (uint256 amountLD); // underlying denom
    function lpToken() external view returns (address);
    function tvl() external view returns (uint256);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IERC20Minimal {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/**
 * @title StargateEthPoolStrategy
 * @dev Strategy used to deposit WETH into Stargate ETH pool on OP
 */
contract StargateEthPoolStrategy is MYTStrategy {
    IWETH public immutable weth;
    IStargatePool public immutable pool;
    IERC20Minimal public immutable lp;

    constructor(address _myt, StrategyParams memory _params, address _weth, address _pool, address _permit2Address)
        MYTStrategy(_myt, _params, _permit2Address, _weth)
    {
        weth = IWETH(_weth);
        pool = IStargatePool(_pool);
        lp = IERC20Minimal(IStargatePool(_pool).lpToken());
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(address(weth), address(this)) >= amount, "not enough WETH");
        // unwrap to native ETH for Pool Native
        weth.withdraw(amount);
        uint256 amountToDeposit = (amount / 1e12) * 1e12;
        uint256 dust = amount - amountToDeposit;
        if (dust > 0) {
            emit StrategyAllocationLoss("Strategy allocation loss due to rounding.", amount, amountToDeposit);
        }
        pool.deposit{value: amountToDeposit}(address(this), amountToDeposit);
        return amount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        // Compute LP needed ∝ TVL to withdraw `amount` underlying
        // For Stargate, LP tokens are 1:1 with underlying
        // So we can just redeem the amount directly
        uint256 lpBalance = lp.balanceOf(address(this));
        uint256 lpNeeded = amount; // 1:1 ratio

        // Cap at available LP balance
        if (lpNeeded > lpBalance) {
            lpNeeded = lpBalance;
        }

        // Redeem LP to native ETH, then wrap back to WETH
        lp.approve(address(pool), lpNeeded);
        uint256 ethBalanceBefore = address(this).balance;
        pool.redeem(lpNeeded, address(this));
        uint256 ethBalanceAfter = address(this).balance;
        uint256 ethRedeemed = ethBalanceAfter - ethBalanceBefore;
        if (ethRedeemed < amount) {
            emit StrategyDeallocationLoss("Strategy deallocation loss which includes rounding loss.", amount, ethRedeemed);
        }
        if (ethRedeemed + ethBalanceBefore >= amount) {
            weth.deposit{value: ethRedeemed}();
        }
        require(TokenUtils.safeBalanceOf(address(weth), address(this)) >= amount, "Strategy balance is less than the amount needed");
        TokenUtils.safeApprove(address(weth), msg.sender, amount);
        return amount;
    }

    function realAssets() external view override returns (uint256) {
        // Best available helper: “how much underlying can we redeem right now”
        return pool.redeemable(address(this));
    }

    /// @notice Preview the amount of underlying that can be withdrawn with slippage protection
    /// For Stargate, account for:
    /// 1. LP conversion slippage
    /// 2. 1e12 dust rounding
    /// Round down to nearest 1e12 to match _allocate behavior
    /// @param amount The amount of underlying to withdraw
    /// @return The amount of underlying that can be withdrawn with slippage protection
    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        uint256 withSlippage = amount - (amount * slippageBPS / 10_000);
        uint256 divisibleAmount = (withSlippage / 1e12) * 1e12;
        return divisibleAmount;
    }

    receive() external payable {}
}
