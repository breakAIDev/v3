// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MYTStrategy} from "../MYTStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

abstract contract ERC4626BaseStrategy is MYTStrategy {
    IERC20 public immutable assetToken;
    IERC4626 public immutable vault;

    constructor(address _myt, StrategyParams memory _params, address _asset, address _vault)
        MYTStrategy(_myt, _params)
    {
        assetToken = IERC20(_asset);
        vault = IERC4626(_vault);
        require(vault.asset() == _asset, "Vault asset != strategy asset");
    }

    function _allocate(uint256 amount) internal virtual override returns (uint256) {
        require(TokenUtils.safeBalanceOf(address(assetToken), address(this)) >= amount, "Strategy balance is less than amount");
        TokenUtils.safeApprove(address(assetToken), address(vault), amount);
        uint256 shares = vault.deposit(amount, address(this));
        return amount;
    }

    function _deallocate(uint256 amount) internal virtual override returns (uint256) {
        uint256 idleBalance = _idleAssets();

        if (idleBalance < amount) {
            uint256 shortfall = amount - idleBalance;
            vault.withdraw(shortfall, address(this), address(this));
        }

        require(
            TokenUtils.safeBalanceOf(address(assetToken), address(this)) >= amount,
            "Strategy balance is less than the amount needed"
        );

        TokenUtils.safeApprove(address(assetToken), msg.sender, amount);
        return amount;
    }

    function _totalValue() internal view virtual override returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(address(this))) + _idleAssets();
    }

    function _idleAssets() internal view virtual override returns (uint256) {
        return TokenUtils.safeBalanceOf(address(assetToken), address(this));
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view virtual override returns (uint256) {
        uint256 sharesNoFee = vault.convertToShares(amount);
        uint256 sharesWithFee = vault.previewWithdraw(amount);
        uint256 feeShares = sharesWithFee > sharesNoFee ? sharesWithFee - sharesNoFee : 0;
        uint256 feeAssets = vault.convertToAssets(feeShares);
        uint256 netAssets = amount - feeAssets;
        return netAssets * (10_000 - params.slippageBPS) / 10_000;
    }

    function _isProtectedToken(address token) internal view virtual override returns (bool) {
        return token == MYT.asset() || token == address(vault);
    }
}
