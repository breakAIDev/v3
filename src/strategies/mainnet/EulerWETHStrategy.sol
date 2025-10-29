pragma solidity ^0.8.21;

import {IERC4626} from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/**
 * @title EulerWETHStrategy
 * @notice This strategy is used to allocate and deallocate weth to the Euler WETH vault on Mainnet
 */
contract EulerWETHStrategy is MYTStrategy {
    IERC20 public immutable weth; // Mainnet WETH
    IERC4626 public immutable vault;

    constructor(address _myt, StrategyParams memory _params, address _weth, address _eulerVault, address _permit2Address)
        MYTStrategy(_myt, _params, _permit2Address, _weth)
    {
        weth = IERC20(_weth);
        vault = IERC4626(_eulerVault);
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
        require(TokenUtils.safeBalanceOf(address(weth), address(this)) >= amount, "Strategy balance is less than the amount needed");
        TokenUtils.safeApprove(address(weth), msg.sender, amount);
        uint256 wethBalanceAfter = TokenUtils.safeBalanceOf(address(weth), address(this));
        uint256 wethRedeemed = wethBalanceAfter - wethBalanceBefore;
        if (wethRedeemed < amount) {
            emit StrategyDeallocationLoss("Strategy deallocation loss.", amount, wethRedeemed);
        }
        require(TokenUtils.safeBalanceOf(address(weth), address(this)) >= amount, "Strategy balance is less than the amount needed");
        return amount;
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
