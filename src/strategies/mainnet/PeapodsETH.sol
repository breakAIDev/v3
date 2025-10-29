// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {MYTStrategy} from "../../MYTStrategy.sol";
import {IERC4626} from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";

interface WETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/**
 * @title PeapodsETHStrategy
 * @notice This strategy is used to allocate and deallocate weth to the Peapods ETH vault on Mainnet
 */
contract PeapodsETHStrategy is MYTStrategy {
    IERC4626 public immutable vault;
    WETH public immutable weth;

    constructor(address _myt, StrategyParams memory _params, address _peapodsEth, address _weth, address _permit2Address)
        MYTStrategy(_myt, _params, _permit2Address, _peapodsEth)
    {
        vault = IERC4626(_peapodsEth);
        weth = WETH(_weth);
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(address(weth), address(this)) >= amount, "Strategy balance is less than amount");
        TokenUtils.safeApprove(address(weth), address(vault), amount);
        vault.deposit(amount, address(this));
        return amount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 wethBalanceBefore = TokenUtils.safeBalanceOf(address(weth), address(this));
        vault.withdraw(amount, address(this), address(this));
        uint256 wethBalanceAfter = TokenUtils.safeBalanceOf(address(weth), address(this));
        uint256 wethRedeemed = wethBalanceAfter - wethBalanceBefore;
        if (wethRedeemed < amount) {
            emit StrategyDeallocationLoss("Strategy deallocation loss.", amount, wethRedeemed);
        }
        require(TokenUtils.safeBalanceOf(address(weth), address(this)) >= amount, "Strategy balance is less than the amount needed");
        TokenUtils.safeApprove(address(weth), msg.sender, amount);
        return amount;
    }

    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 dt = lastSnapshotTime == 0 ? 0 : block.timestamp - lastSnapshotTime;

        uint256 currentPPS = vault.convertToAssets(1e18);
        newIndex = currentPPS;

        if (lastIndex == 0 || dt == 0 || currentPPS <= lastIndex) return (0, newIndex);
        uint256 growth = (currentPPS - lastIndex) * FIXED_POINT_SCALAR / lastIndex;
        ratePerSec = growth / dt;
        return (ratePerSec, newIndex);
    }

    function realAssets() external view override returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(address(this)));
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        uint256 shares = vault.previewWithdraw(amount);
        uint256 assets = vault.convertToAssets(shares);
        return assets - (assets * slippageBPS / 10_000);
    }
}
