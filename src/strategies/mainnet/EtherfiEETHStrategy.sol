// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MYTStrategy} from "../../MYTStrategy.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "../../interfaces/IWETH.sol";

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
 * @notice Allocates WETH into weETH via Ether.fi DepositAdapter and deallocates
 *         by directly swapping weETH -> WETH through 0x.
 */
contract EtherfiEETHMYTStrategy is MYTStrategy {
    uint256 public constant MAX_ORACLE_STALENESS = 7 days;

    IDepositAdapter public immutable depositAdapter;
    IRedemptionManager public immutable redemptionManager;
    IWeETH public immutable weETH;
    IERC20 public immutable eETH;
    IWETH public immutable weth;
    AggregatorV3Interface public immutable weEthEthOracle;
    uint8 public immutable weEthEthOracleDecimals;
    address public constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    constructor(
        address _myt,
        StrategyParams memory _params,
        address _eETH,
        address _weETH,
        address _weth,
        address _depositAdapter,
        address _redemptionManager,
        address _weEthEthOracle
    ) MYTStrategy(_myt, _params) {
        require(_eETH != address(0), "Zero eETH address");
        require(_weETH != address(0), "Zero weETH address");
        require(_weth != address(0), "Zero WETH address");
        require(_depositAdapter != address(0), "Zero deposit adapter address");
        require(_redemptionManager != address(0), "Zero redemption manager address");
        require(_weEthEthOracle != address(0), "Zero oracle address");

        eETH = IERC20(_eETH);
        weETH = IWeETH(_weETH);
        weth = IWETH(_weth);
        depositAdapter = IDepositAdapter(_depositAdapter);
        redemptionManager = IRedemptionManager(_redemptionManager);
        weEthEthOracle = AggregatorV3Interface(_weEthEthOracle);
        weEthEthOracleDecimals = weEthEthOracle.decimals();
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(address(weth), address(this)) >= amount, "Strategy balance is less than amount");
        TokenUtils.safeApprove(address(weth), address(depositAdapter), amount);
        depositAdapter.depositWETHForWeETH(amount, address(0));
        TokenUtils.safeApprove(address(weth), address(depositAdapter), 0);
        return amount;
    }

    /// @notice Allocate via direct WETH -> weETH swap through 0x.
    /// @param amount WETH amount to sell.
    /// @param callData 0x swap calldata for WETH -> weETH.
    function _allocate(uint256 amount, bytes memory callData) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(address(weth), address(this)) >= amount, "Strategy balance is less than amount");
        uint256 minWeETHOut = _wethToWeEth((amount * (10_000 - params.slippageBPS)) / 10_000);
        if (minWeETHOut == 0) minWeETHOut = 1;
        dexSwap(address(weETH), address(weth), amount, minWeETHOut, callData);
        return amount;
    }

    /// @notice Deallocate via Ether.fi instant redemption (no queue delay).
    /// @dev This path is liquidity-dependent and reverts when `canRedeem(amount, address(eETH))` is false.
    /// @param amount WETH amount expected to be returned to vault.
    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 idleBalance = _idleAssets();
        if (idleBalance >= amount) {
            TokenUtils.safeApprove(address(weth), msg.sender, amount);
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
        weth.deposit{value: ethReceived}();
        require(_idleAssets() >= amount, "Insufficient WETH available");
        TokenUtils.safeApprove(address(weth), msg.sender, amount);
        return amount;
    }

    /// @notice Deallocate via direct weETH -> WETH swap.
    /// @param amount WETH amount expected to be returned to vault.
    /// @param callData 0x swap calldata for weETH -> WETH.
    function _deallocate(uint256 amount, bytes memory callData) internal override returns (uint256) {
        uint256 idleBalance = _idleAssets();
        if (idleBalance >= amount) {
            TokenUtils.safeApprove(address(weth), msg.sender, amount);
            return amount;
        }
        uint256 shortfall = amount - idleBalance;

        uint256 weETHBalance = weETH.balanceOf(address(this));
        require(weETHBalance > 0, "No weETH available");

        uint256 maxWETHIn = (shortfall * 10_000 + (10_000 - params.slippageBPS) - 1) / (10_000 - params.slippageBPS);
        uint256 quotedWeETH = _wethToWeEthUp(maxWETHIn);
        if (quotedWeETH == 0 && weETHBalance > 0) {
            // Avoid dust-size deallocations reverting due to floor rounding to zero.
            quotedWeETH = 1;
        }
        uint256 weETHToSwap = quotedWeETH > weETHBalance ? weETHBalance : quotedWeETH;
        require(weETHToSwap > 0, "No weETH to swap");

        dexSwap(address(weth), address(weETH), weETHToSwap, shortfall, callData);
        require(_idleAssets() >= amount, "Insufficient WETH received");
        TokenUtils.safeApprove(address(weth), msg.sender, amount);
        return amount;
    }

    function _totalValue() internal view override returns (uint256) {
        return _weEthToWeth(weETH.balanceOf(address(this))) + _idleAssets();
    }

    function _idleAssets() internal view virtual override returns (uint256) {
        return TokenUtils.safeBalanceOf(address(weth), address(this));
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        uint256 maxWETH = _weEthToWeth(weETH.balanceOf(address(this)));
        uint256 fundable = amount <= maxWETH ? amount : maxWETH;
        return (fundable * (10_000 - params.slippageBPS)) / 10_000;
    }

    function _weEthToWeth(uint256 weEthAmount) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = weEthEthOracle.latestRoundData();
        require(answer > 0 && updatedAt != 0, "Invalid oracle answer");
        require(updatedAt <= block.timestamp && block.timestamp - updatedAt <= MAX_ORACLE_STALENESS, "Stale oracle answer");
        return weEthAmount * uint256(answer) / (10 ** weEthEthOracleDecimals);
    }

    function _wethToWeEth(uint256 wethAmount) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = weEthEthOracle.latestRoundData();
        require(answer > 0 && updatedAt != 0, "Invalid oracle answer");
        require(updatedAt <= block.timestamp && block.timestamp - updatedAt <= MAX_ORACLE_STALENESS, "Stale oracle answer");
        return wethAmount * (10 ** weEthEthOracleDecimals) / uint256(answer);
    }

    function _wethToWeEthUp(uint256 wethAmount) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = weEthEthOracle.latestRoundData();
        require(answer > 0 && updatedAt != 0, "Invalid oracle answer");
        require(updatedAt <= block.timestamp && block.timestamp - updatedAt <= MAX_ORACLE_STALENESS, "Stale oracle answer");
        uint256 scale = 10 ** weEthEthOracleDecimals;
        return (wethAmount * scale + uint256(answer) - 1) / uint256(answer);
    }

    receive() external payable {}
}
