// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MYTStrategy} from "../MYTStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

interface IMintController {
    function assetToReceipt(uint256 assetAmount) external view returns (uint256);
}

interface ISIUSD {
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
}

interface IRedeemController {
    function receiptToAsset(uint256 receiptAmount) external view returns (uint256);
}

interface IInfiniFiGateway {
    function mintAndStake(address to, uint256 amount) external returns (uint256);
    function unstake(address to, uint256 stakedTokens) external returns (uint256);
    function redeem(address to, uint256 amount, uint256 minAssetsOut) external returns (uint256);
}

/**
 * @title SiUSDStrategy
 * @notice Allocates USDC into staked InfiniFi siUSD shares and deallocates back to USDC.
 */
contract SiUSDStrategy is MYTStrategy {
    // Small receipt-token cushion to absorb controller rounding on deallocation previews.
    uint256 internal constant REDEEM_DUST_BUFFER = 1;

    IERC20 public immutable usdc;
    IERC20 public immutable iUSD;
    ISIUSD public immutable siUSD;
    IMintController public immutable mintController;
    IRedeemController public immutable redeemController;
    IInfiniFiGateway public immutable gateway;

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _usdc,
        address _iUSD,
        address _siUSD,
        address _gateway,
        address _mintController,
        address _redeemController
    ) MYTStrategy(_myt, _params) {
        require(_usdc != address(0), "Zero USDC address");
        require(_iUSD != address(0), "Zero iUSD address");
        require(_siUSD != address(0), "Zero siUSD address");
        require(_gateway != address(0), "Zero gateway address");
        require(_mintController != address(0), "Zero mint controller address");
        require(_redeemController != address(0), "Zero redeem controller address");
        require(_usdc == MYT.asset(), "Vault asset != MYT asset");

        usdc = IERC20(_usdc);
        iUSD = IERC20(_iUSD);
        siUSD = ISIUSD(_siUSD);
        gateway = IInfiniFiGateway(_gateway);
        mintController = IMintController(_mintController);
        redeemController = IRedeemController(_redeemController);
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        _ensureIdleBalance(address(usdc), amount);

        TokenUtils.safeApprove(address(usdc), address(gateway), 0);
        TokenUtils.safeApprove(address(usdc), address(gateway), amount);
        uint256 sharesReceived = gateway.mintAndStake(address(this), amount);
        TokenUtils.safeApprove(address(usdc), address(gateway), 0);
        require(sharesReceived > 0, "No siUSD received");
        return amount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 idleBalance = _idleAssets();
        if (idleBalance < amount) {
            uint256 shortfall = amount - idleBalance;
            uint256 iUsdNeeded = mintController.assetToReceipt(shortfall);

            uint256 sharesToUnstake = siUSD.previewWithdraw(iUsdNeeded);
            uint256 siUsdBalance = siUSD.balanceOf(address(this));
            if (sharesToUnstake > siUsdBalance) sharesToUnstake = siUsdBalance;
            require(sharesToUnstake > 0, "No siUSD to unstake");

            TokenUtils.safeApprove(address(siUSD), address(gateway), 0);
            TokenUtils.safeApprove(address(siUSD), address(gateway), sharesToUnstake);
            gateway.unstake(address(this), sharesToUnstake);
            TokenUtils.safeApprove(address(siUSD), address(gateway), 0);

            uint256 iUsdBalance = TokenUtils.safeBalanceOf(address(iUSD), address(this));
            uint256 iUsdToRedeem = iUsdNeeded > iUsdBalance ? iUsdBalance : iUsdNeeded;
            require(iUsdToRedeem > 0, "No iUSD to redeem");

            TokenUtils.safeApprove(address(iUSD), address(gateway), 0);
            TokenUtils.safeApprove(address(iUSD), address(gateway), iUsdToRedeem);
            gateway.redeem(address(this), iUsdToRedeem, shortfall);
            TokenUtils.safeApprove(address(iUSD), address(gateway), 0);

            idleBalance = _idleAssets();
            if (idleBalance < amount) revert InsufficientBalance(amount, idleBalance);
        }

        TokenUtils.safeApprove(address(usdc), msg.sender, amount);
        return amount;
    }

    function _totalValue() internal view override returns (uint256) {
        uint256 idleUsdc = _idleAssets();
        uint256 totalReceiptBalance = TokenUtils.safeBalanceOf(address(iUSD), address(this))
            + siUSD.convertToAssets(siUSD.balanceOf(address(this)));

        if (totalReceiptBalance == 0) return idleUsdc;
        return idleUsdc + redeemController.receiptToAsset(totalReceiptBalance);
    }

    function _idleAssets() internal view override returns (uint256) {
        return TokenUtils.safeBalanceOf(address(usdc), address(this));
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        uint256 iUsdNeeded = mintController.assetToReceipt(amount);
        uint256 sharesToUnstake = siUSD.previewWithdraw(iUsdNeeded);
        uint256 iUsdRedeemable = siUSD.convertToAssets(sharesToUnstake);
        uint256 expectedAssets = redeemController.receiptToAsset(iUsdRedeemable);
        if (expectedAssets == 0) return 0;

        uint256 adjustedAssets = expectedAssets - (expectedAssets * params.slippageBPS / 10_000);
        return adjustedAssets;
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == MYT.asset() || token == address(iUSD) || token == address(siUSD);
    }
}
