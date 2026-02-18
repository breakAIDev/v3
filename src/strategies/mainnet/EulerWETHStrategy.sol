pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
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

    constructor(address _myt, StrategyParams memory _params, address _weth, address _eulerVault)
        MYTStrategy(_myt, _params)
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
        vault.withdraw(amount, address(this), address(this));
        require(TokenUtils.safeBalanceOf(address(weth), address(this)) >= amount, "Strategy balance is less than the amount needed");
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
}
