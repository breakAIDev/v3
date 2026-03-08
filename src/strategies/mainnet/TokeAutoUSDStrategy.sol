// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MYTStrategy} from "../../MYTStrategy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IMainRewarder, IAutopilotRouter} from "../interfaces/ITokemac.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
 * @title TokeAutoUSDStrategy
 * @notice This strategy is used to allocate and deallocate usdc to the TokeAutoUSD vault on Mainnet
 * @notice Also stakes all amounts allocated to the shares in the rewarder
 */
contract TokeAutoUSDStrategy is MYTStrategy {
    IERC4626Like public immutable autoUSD;
    IAutopilotRouter public immutable router;
    IMainRewarder public immutable rewarder;
    IERC20 public immutable usdc;
    constructor(
        address _myt,
        StrategyParams memory _params,
        address _usdc,
        address _autoUSD,
        address _router,
        address _rewarder
    ) MYTStrategy(_myt, _params) {
        autoUSD = IERC4626Like(_autoUSD);
        router = IAutopilotRouter(_router);
        rewarder = IMainRewarder(_rewarder);
        usdc = IERC20(_usdc);
    }

    // Deposit usdc into the autoUSD vault, stake the shares in the rewarder
    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(address(usdc), address(this)) >= amount, "Strategy balance is less than amount");
        // Approve vault directly
        TokenUtils.safeApprove(address(usdc), address(autoUSD), amount);
        uint256 shares = autoUSD.deposit(amount, address(this));
        
        // Verify the asset value of shares received is >= amount deposited (with slippage tolerance)
        uint256 assetsReceived = autoUSD.convertToAssets(
            shares,
            autoUSD.totalAssets(IERC4626Like.TotalAssetPurpose.Withdraw),
            autoUSD.totalSupply(),
            IERC4626Like.Rounding.Down
        );
        require(assetsReceived >= amount * (10_000 - params.slippageBPS) / 10_000, "Deposit value below minimum");
        
        TokenUtils.safeApprove(address(autoUSD), address(rewarder), shares);
        rewarder.stake(address(this), shares);
        return assetsReceived;
    }

    // Withdraws auto usdc shares from the rewarder
    // redeems same amount of shares from auto usd vault to usdc
    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 sharesNeeded = autoUSD.convertToShares(
            amount,
            autoUSD.totalAssets(IERC4626Like.TotalAssetPurpose.Withdraw),
            autoUSD.totalSupply(),
            IERC4626Like.Rounding.Up  // Round UP when calculating shares to withdraw
        );
        
        // Cap to actual balance (handles rounding)
        uint256 actualShares = rewarder.balanceOf(address(this));
        if (sharesNeeded > actualShares) sharesNeeded = actualShares;
        
        // Withdraw shares from rewarder
        rewarder.withdraw(address(this), sharesNeeded, false);
        
        autoUSD.redeem(sharesNeeded, address(this), address(this));
        uint256 usdcBalance = TokenUtils.safeBalanceOf(address(usdc), address(this));   
        
        require(usdcBalance >= amount, "Withdraw amount insufficient");
        TokenUtils.safeApprove(address(usdc), msg.sender, amount);
        return amount;
    }

    function _totalValue() internal view override returns (uint256) {
        uint256 shares = rewarder.balanceOf(address(this));
        uint256 assets = autoUSD.convertToAssets(
            shares,
            autoUSD.totalAssets(IERC4626Like.TotalAssetPurpose.Withdraw),
            autoUSD.totalSupply(),
            IERC4626Like.Rounding.Down
        );
        return assets;
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        uint256 sharesNeeded = autoUSD.convertToShares(
            amount,
            autoUSD.totalAssets(IERC4626Like.TotalAssetPurpose.Withdraw),
            autoUSD.totalSupply(),
            IERC4626Like.Rounding.Up
        );
        uint256 assets = autoUSD.convertToAssets(
            sharesNeeded,
            autoUSD.totalAssets(IERC4626Like.TotalAssetPurpose.Withdraw),
            autoUSD.totalSupply(),
            IERC4626Like.Rounding.Down
        );
        return assets - (assets * params.slippageBPS / 10_000);
    }

    // usually 0x2e9d63788249371f1DFC918a52f8d799F4a38C94 - TOKE reward token
    function _claimRewards(address token, bytes memory quote, uint256 minAmountOut) internal override returns (uint256 rewardsClaimed) {
        require(token == 0x2e9d63788249371f1DFC918a52f8d799F4a38C94 && quote.length > 0, "params");
        bool claimExtra = rewarder.allowExtraRewards();
        uint256 rewardsBalanceBefore = TokenUtils.safeBalanceOf(token, address(this));

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

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == MYT.asset() || token == address(autoUSD);
    }
}
