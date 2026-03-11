// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MYTStrategy} from "../../MYTStrategy.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";

interface WETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IERC4626 {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assetsOut);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function balanceOf(address account) external view returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
}

/**
 * @title MorphoYearnOGWETHStrategy
 * @notice This strategy is used to allocate and deallocate weth to the Morpho Yearn OG WETH vault on Mainnet
 */
contract MorphoYearnOGWETHStrategy is MYTStrategy {
    WETH public immutable weth;
    IERC4626 public immutable vault;

    constructor(address _myt, StrategyParams memory _params, address _vault, address _weth)
        MYTStrategy(_myt, _params)
    {
        weth = WETH(_weth);
        vault = IERC4626(_vault);
        require(vault.asset() == _weth, "Vault asset != WETH");
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(address(weth), address(this)) >= amount, "Strategy balance is less than amount");
        TokenUtils.safeApprove(address(weth), address(vault), amount);
        uint256 shares = vault.deposit(amount, address(this));
        uint256 estimatedAmount = vault.convertToAssets(shares);
        // check to ensure minimum amount has been deposited
        require( estimatedAmount >= (amount - (amount * params.slippageBPS / 10_000)), "Minimum amount has not been deposited");        
        return estimatedAmount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        vault.withdraw(amount, address(this), address(this));
        TokenUtils.safeApprove(address(weth), msg.sender, amount);
        return amount;
    }

    function _totalValue() internal view override returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(address(this)));
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        uint256 sharesNoFee = vault.convertToShares(amount);
        uint256 sharesWithFee = vault.previewWithdraw(amount);
        uint256 feeShares = sharesWithFee > sharesNoFee ? sharesWithFee - sharesNoFee : 0;
        uint256 feeAssets = vault.convertToAssets(feeShares);
        uint256 netAssets = amount - feeAssets;
        return netAssets - (netAssets * params.slippageBPS / 10_000);
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == MYT.asset() || token == address(vault);
    }
}
