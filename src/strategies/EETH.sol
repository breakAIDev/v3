// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "forge-std/console.sol";
import {MYTStrategy} from "../MYTStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

interface DepositAdapter {
    function depositWETHForWeETH(uint256 amount, address referal) external returns (uint256);
}

interface RedemptionManager {
    function redeemWeEth(uint256 amount, address receiver) external returns (uint256);
    function canRedeem(uint256 amount) external returns (bool);
    function liquidityPool() external returns (address);
}

interface IWETH {
    function approve(address spender, uint256 amount) external;
    function deposit() external payable;
}

/**
 * TODO: Incomplete, Need to fully implement this strategy
 * @title EETHMYTStrategy
 * @notice This strategy is used to allocate and deallocate EETH to the EETH vault on Mainnet
 */
contract EETHMYTStrategy is MYTStrategy {
    DepositAdapter public immutable depositAdapter;
    RedemptionManager public immutable redemptionManager;
    IWETH public immutable weth;

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _weeth, // we explicitly store the receipt token 0x35fA164735182de50811E8e2E824cFb9B6118ac2
        address _weth,
        address _depositAdapter,
        address _redemptionManager,
        address _permit2Address
    ) MYTStrategy(_myt, _params, _permit2Address, _weeth) {
        require(_depositAdapter != address(0));
        require(_redemptionManager != address(0));
        require(_weeth != address(0));
        require(_weth != address(0));
        require(_permit2Address != address(0));

        depositAdapter = DepositAdapter(_depositAdapter);
        redemptionManager = RedemptionManager(_redemptionManager);
        weth = IWETH(_weth);
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        weth.approve(address(depositAdapter), amount);
        depositReturn = depositAdapter.depositWETHForWeETH(amount, address(0));
        //require(depositReturn == amount, "IA");
        //TokenUtils.safeTransfer(address(receiptToken), address(MYT), depositReturn);
        weth.approve(address(depositAdapter), 0);
        address lp = redemptionManager.liquidityPool();
        console.log(lp.balance);
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        address lp = redemptionManager.liquidityPool();

        uint256 weethBalance = TokenUtils.safeBalanceOf(address(receiptToken), address(this));
        require(amount <= weethBalance, "Insufficient weETH balance");

        // Check if redemption is possible
        require(redemptionManager.canRedeem(amount), "Cannot redeem");

        // Approve redemption manager to spend weETH
        TokenUtils.safeApprove(address(receiptToken), address(redemptionManager), amount);

        uint256 redemptionAmount = redemptionManager.redeemWeEth(amount, address(this));
        // FIXME unspecified revert right after redeemWeEth returns ?

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            weth.deposit{value: ethBalance}();
            TokenUtils.safeTransfer(address(weth), address(MYT), ethBalance);
        }

        // Reset approval to zero
        TokenUtils.safeApprove(address(receiptToken), address(redemptionManager), 0);

        return redemptionAmount;
    }

    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 dt = lastSnapshotTime == 0 ? 0 : block.timestamp - lastSnapshotTime;

        uint256 currentPPS = MYT.convertToAssets(1e18);
        newIndex = currentPPS;

        if (lastIndex == 0 || dt == 0 || currentPPS <= lastIndex) return (0, newIndex);
        uint256 growth = (currentPPS - lastIndex) * FIXED_POINT_SCALAR / lastIndex;
        ratePerSec = growth / dt;
        return (ratePerSec, newIndex);
    }

    function realAssets() external view override returns (uint256) {
        uint256 totalAssets = 0;
        
        // Add ETH balance
        totalAssets += address(this).balance;
        
        // Add weETH balance (assuming 1:1 peg with ETH) FIXME
        uint256 weethBalance = TokenUtils.safeBalanceOf(address(receiptToken), address(this));
        totalAssets += weethBalance;
        
        return totalAssets;
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        // Apply slippage to the amount of assets (ETH)
        // slippageBPS is stored in params.slippageBPS
        return amount - (amount * params.slippageBPS / 10_000);
    }

    receive() external payable {
        require(msg.sender == address(redemptionManager), "Only EETH redemption");
    }
}
