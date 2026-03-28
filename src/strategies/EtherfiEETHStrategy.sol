// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OraclePricedSwapStrategy} from "./OraclePricedSwapStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "../interfaces/IWETH.sol";

interface IDepositAdapter {
    function depositWETHForWeETH(uint256 amount, address referral) external returns (uint256);
}

interface IRedemptionManager {
    function canRedeem(uint256 amount, address token) external view returns (bool);
    function redeemWeEth(uint256 amount, address receiver, address outputToken) external returns (uint256);
}

interface IWeETH {
    function balanceOf(address account) external view returns (uint256);
    function getEETHByWeETH(uint256 weETHAmount) external view returns (uint256);
    function getWeETHByeETH(uint256 eETHAmount) external view returns (uint256);
}

/**
 * @title EtherfiEETHMYTStrategy
 * @notice Allocates WETH into weETH via Ether.fi DepositAdapter and supports
 *         deallocation via Ether.fi instant redemption.
 *         instant redemption through the RedemptionManager.
 *         Also supports dex swaps for both allocation and deallocation.
 *
 */
contract EtherfiEETHMYTStrategy is OraclePricedSwapStrategy {
    IDepositAdapter public immutable depositAdapter;
    IRedemptionManager public immutable redemptionManager;
    IWeETH public immutable weETH;
    IERC20 public immutable eETH;
    // address used to request native ETH instead of an ERC20 token.
    address public constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _eETH,
        address _weETH,
        address _depositAdapter,
        address _redemptionManager,
        address _weEthEthOracle
    ) OraclePricedSwapStrategy(_myt, _params, _weEthEthOracle) {
        require(_eETH != address(0), "Zero eETH address");
        require(_weETH != address(0), "Zero weETH address");
        require(_depositAdapter != address(0), "Zero deposit adapter address");
        require(_redemptionManager != address(0), "Zero redemption manager address");

        eETH = IERC20(_eETH);
        weETH = IWeETH(_weETH);
        depositAdapter = IDepositAdapter(_depositAdapter);
        redemptionManager = IRedemptionManager(_redemptionManager);
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        _ensureIdleBalance(_asset(), amount);
        TokenUtils.safeApprove(_asset(), address(depositAdapter), amount);
        depositAdapter.depositWETHForWeETH(amount, address(0));
        TokenUtils.safeApprove(_asset(), address(depositAdapter), 0);
        return amount;
    }

    /// @notice Deallocate via Ether.fi instant redemption (no queue delay).
    /// @dev This path is liquidity-dependent and reverts when `canRedeem(amount, address(eETH))` is false.
    /// @param amount WETH amount expected to be returned to vault.
    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 idleBalance = _idleAssets();
        if (idleBalance >= amount) {
            TokenUtils.safeApprove(_asset(), msg.sender, amount);
            return amount;
        }

        uint256 shortfall = amount - idleBalance;
        require(
            redemptionManager.canRedeem(shortfall, address(eETH)),
            "Cannot redeem. Instant redemption path is not available."
        );

        uint256 weETHBalance = weETH.balanceOf(address(this));
        require(weETHBalance > 0, "No weETH available");
        uint256 weETHToRedeem = weETH.getWeETHByeETH(shortfall);
        if (weETHToRedeem > weETHBalance) weETHToRedeem = weETHBalance;
        require(weETHToRedeem > 0, "No weETH to redeem");

        TokenUtils.safeApprove(address(weETH), address(redemptionManager), weETHToRedeem);
        uint256 ethBefore = address(this).balance;
        redemptionManager.redeemWeEth(weETHToRedeem, address(this), ETH);
        uint256 ethReceived = address(this).balance - ethBefore;
        TokenUtils.safeApprove(address(weETH), address(redemptionManager), 0);

        require(ethReceived >= shortfall, "Insufficient ETH redeemed");
        IWETH(MYT.asset()).deposit{value: ethReceived}();
        require(_idleAssets() >= amount, "Insufficient WETH available");
        TokenUtils.safeApprove(_asset(), msg.sender, amount);
        return amount;
    }

    function _pricedToken() internal view override returns (address) {
        return address(weETH);
    }

    function _positionBalance() internal view override returns (uint256) {
        return weETH.balanceOf(address(this));
    }

    function _positionToPriced(uint256 positionAmount) internal view override returns (uint256) {
        return positionAmount;
    }

    function _afterAllocateSwap(uint256) internal override {}

    function _preparePricedForSwap(uint256 maxPricedIn) internal override returns (uint256) {
        uint256 weETHBalance = weETH.balanceOf(address(this));
        return maxPricedIn > weETHBalance ? weETHBalance : maxPricedIn;
    }

    receive() external payable {}
}
