// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MYTStrategy} from "../../MYTStrategy.sol";
import {IERC4626} from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IMainRewarder, IAutopilotRouter} from "../interfaces/ITokemac.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";

interface IERC4626Like is IERC4626 {
    function balanceOfActual(address account) external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
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

    event TokeAutoUSDStrategyTestLog(string message, uint256 value);

    constructor(address _myt, StrategyParams memory _params, address _usdc, address _autoUSD, address _router, address _rewarder, address _permit2Address)
        MYTStrategy(_myt, _params, _permit2Address, _autoUSD)
    {
        autoUSD = IERC4626Like(_autoUSD);
        router = IAutopilotRouter(_router);
        rewarder = IMainRewarder(_rewarder);
        usdc = IERC20(_usdc);
    }

    // @dev Implementation can alternatively make use of a multicall
    // Deposit usdc into the autoUSD vault, stake the shares in the rewarder
    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(address(usdc), address(this)) >= amount, "Strategy balance is less than amount");
        TokenUtils.safeApprove(address(usdc), address(router), amount);
        uint256 shares = router.depositMax(autoUSD, address(this), 0);
        TokenUtils.safeApprove(address(autoUSD), address(rewarder), shares);
        rewarder.stake(address(this), shares);
        return amount;
    }

    // Withdraws auto usdc shares from the rewarder with any claims
    // redeems same amount of shares from auto eth vault to usdc
    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 sharesNeeded = autoUSD.convertToShares(amount);
        uint256 actualSharesHeld = rewarder.balanceOf(address(this));
        uint256 shareDiff = actualSharesHeld - sharesNeeded;
        if (shareDiff <= 1e18) {
            // account for vault rounding up
            sharesNeeded = actualSharesHeld;
        }
        // withdraw shares, claim any rewards
        rewarder.withdraw(address(this), sharesNeeded, true);
        uint256 usdcBalanceBefore = TokenUtils.safeBalanceOf(address(usdc), address(this));
        autoUSD.redeem(sharesNeeded, address(this), address(this));
        uint256 usdcBalanceAfter = TokenUtils.safeBalanceOf(address(usdc), address(this));
        uint256 usdcRedeemed = usdcBalanceAfter - usdcBalanceBefore;
        if (usdcRedeemed < amount) {
            emit StrategyDeallocationLoss("Strategy deallocation loss.", amount, usdcRedeemed);
        }
        require(TokenUtils.safeBalanceOf(address(usdc), address(this)) >= amount, "Strategy balance is less than the amount needed");
        TokenUtils.safeApprove(address(usdc), msg.sender, amount);
        return amount;
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        uint256 sharesNeeded = autoUSD.convertToShares(amount);
        uint256 assets = autoUSD.convertToAssets(sharesNeeded);
        return assets - (assets * slippageBPS / 10_000);
    }

    function realAssets() external view override returns (uint256) {
        uint256 shares = rewarder.balanceOf(address(this));
        uint256 assets = autoUSD.convertToAssets(shares);
        return assets;
    }
}
