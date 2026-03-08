pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract PeapodsUSDCStrategy is MYTStrategy {
    IERC20 public immutable usdc; // 0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48
    IERC4626 public immutable vault; // 0x3717e340140D30F3A077Dd21fAc39A86ACe873AA

    constructor(address _myt, StrategyParams memory _params, address _peapodsUSDC, address _usdc)
        MYTStrategy(_myt, _params)
    {
        vault = IERC4626(_peapodsUSDC);
        usdc = IERC20(_usdc);
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(address(usdc), address(this)) >= amount, "Strategy balance is less than amount");
        TokenUtils.safeApprove(address(usdc), address(vault), amount);
        vault.deposit(amount, address(this));
        return amount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        vault.withdraw(amount, address(this), address(this));
        require(TokenUtils.safeBalanceOf(address(usdc), address(this)) >= amount, "Strategy balance is less than the amount needed");
        TokenUtils.safeApprove(address(usdc), msg.sender, amount);
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
