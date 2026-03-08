// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MYTStrategy} from "../../MYTStrategy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IMainRewarder} from "../interfaces/ITokemac.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface WETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface RootOracle {
    function getPriceInEth(address token) external returns (uint256 price);
}

interface IERC4626Like is IERC4626 {
    function convertToShares(uint256 assets, uint256 totalAssetsForPurpose, uint256 supply, Rounding rounding) external view returns (uint256 shares);
    function convertToAssets(
    uint256 shares,
    uint256 totalAssetsForPurpose,
    uint256 supply,
    Rounding rounding
    ) external view returns (uint256 assets);

    function totalAssets(TotalAssetPurpose purpose) external view returns (uint256);

    enum Rounding {
        Down, // Toward negative infinity
        Up, // Toward infinity
        Zero // Toward zero
    }

    enum TotalAssetPurpose {
        Global,
        Deposit,
        Withdraw
    }
}

/**
 * @title TokeAutoEthStrategy
 * @notice This strategy is used to allocate and deallocate autoEth to the TokeAutoEth vault on Mainnet
 * @notice Also stakes all amounts allocated to the shares in the rewarder
 */
contract TokeAutoEthStrategy is MYTStrategy {
    IERC4626Like public immutable autoEth;
    IMainRewarder public immutable rewarder;
    WETH public immutable weth;
    RootOracle public immutable oracle;

    event TokeAutoETHStrategyTestLog(string message, uint256 value);

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _autoEth,
        address _rewarder,
        address _weth,
        address _oracle
    ) MYTStrategy(_myt, _params) {
        autoEth = IERC4626Like(_autoEth);
        rewarder = IMainRewarder(_rewarder);
        weth = WETH(_weth);
        oracle = RootOracle(_oracle);
    }
    
    // Deposit weth into the autoEth vault, stake the shares in the rewarder
    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(address(weth), address(this)) >= amount, "Strategy balance is less than amount");
        
        TokenUtils.safeApprove(address(weth), address(autoEth), amount);
        uint256 shares = autoEth.deposit(amount, address(this));
        
        // Verify the asset value of shares received is >= amount deposited (with slippage tolerance)
        uint256 assetsReceived = autoEth.convertToAssets(
            shares,
            autoEth.totalAssets(IERC4626Like.TotalAssetPurpose.Withdraw),
            autoEth.totalSupply(),
            IERC4626Like.Rounding.Down
        );
        require(assetsReceived >= amount * (10_000 - params.slippageBPS) / 10_000, "Deposit value below minimum");
        
        TokenUtils.safeApprove(address(autoEth), address(rewarder), shares);
        rewarder.stake(address(this), shares);
        return assetsReceived;
    }

    // Withdraws auto eth shares from the rewarder
    // redeems same amount of shares from auto eth vault to weth
    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 sharesNeeded = autoEth.convertToShares(amount,
            autoEth.totalAssets(IERC4626Like.TotalAssetPurpose.Withdraw),
            autoEth.totalSupply(),
            IERC4626Like.Rounding.Up  // Round UP when calculating shares to withdraw
        );
        
        // Cap to actual balance (handles rounding)
        uint256 actualShares = rewarder.balanceOf(address(this));
        if (sharesNeeded > actualShares) sharesNeeded = actualShares;
        
        // Withdraw shares from rewarder
        rewarder.withdraw(address(this), sharesNeeded, false);
        
        autoEth.redeem(sharesNeeded, address(this), address(this));
        uint256 wethBalance = TokenUtils.safeBalanceOf(address(weth), address(this));
        
        require(wethBalance >= amount, "Withdraw amount insufficient");
        TokenUtils.safeApprove(address(weth), msg.sender, amount);
        return amount;
    }

    function _totalValue() internal view override returns (uint256) {
            uint256 shares = rewarder.balanceOf(address(this));
            uint256 assets = autoEth.convertToAssets(
            shares,
            autoEth.totalAssets(IERC4626Like.TotalAssetPurpose.Withdraw),
            autoEth.totalSupply(),
            IERC4626Like.Rounding.Down
        );
        return assets;
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        uint256 sharesNeeded = autoEth.convertToShares(
            amount,
            autoEth.totalAssets(IERC4626Like.TotalAssetPurpose.Withdraw),
            autoEth.totalSupply(),
            IERC4626Like.Rounding.Up
        );
        uint256 assets = autoEth.convertToAssets(
            sharesNeeded,
            autoEth.totalAssets(IERC4626Like.TotalAssetPurpose.Withdraw),
            autoEth.totalSupply(),
            IERC4626Like.Rounding.Down
        );
        return assets - (assets * params.slippageBPS / 10_000);
    }

    // usually 0x2e9d63788249371f1DFC918a52f8d799F4a38C94 - TOKE reward token
    function _claimRewards(address token, bytes memory quote, uint256 minAmountOut) internal override returns (uint256 rewardsClaimed) {
        require(token == 0x2e9d63788249371f1DFC918a52f8d799F4a38C94 && quote.length > 0, "params");
        uint256 rewardsBalanceBefore = TokenUtils.safeBalanceOf(token, address(this));
        bool claimExtra = rewarder.allowExtraRewards();
        rewarder.getReward(address(this), address(this), claimExtra);
        uint256 rewardsReceived = TokenUtils.safeBalanceOf(token, address(this)) - rewardsBalanceBefore;
        if(rewardsReceived == 0) return 0;
        // https://etherscan.io/address/0x60882D6f70857606Cdd37729ccCe882015d1755E#code#F14#L317
        bool stakingDisabled = rewarder.rewardToken() != 0x2e9d63788249371f1DFC918a52f8d799F4a38C94 || rewarder.tokeLockDuration() == 0;
        if (!stakingDisabled) return 0;
        emit RewardsClaimed(address(token), rewardsReceived);
        uint256 amountOut = dexSwap(MYT.asset(), token, IERC20(token).balanceOf(address(this)), minAmountOut, quote);
        TokenUtils.safeTransfer(address(MYT.asset()), address(MYT), amountOut);
        return amountOut;
    }

    function _unwrapWETH(uint256 amount, address to) internal {
        weth.withdraw(amount);
        (bool ok,) = to.call{value: amount}("");
        require(ok, "ETH send failed");
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == MYT.asset() || token == address(autoEth);
    }
}
