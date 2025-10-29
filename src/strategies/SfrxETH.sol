// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IWETH} from "../interfaces/IWETH.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {MYTStrategy} from "../MYTStrategy.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

interface FraxMinter {
    function submitAndDeposit(address recipient) external payable returns (uint256);
}

interface FraxRedemptionQueue {
    function enterRedemptionQueueViaSfrxEth(address _recipient, uint120 _sfrxEthAmount) external returns (uint256 _nftId);
    function burnRedemptionTicketNft(uint256 nftId, address recipient) external;
}

interface StakedFraxEth {
    function convertToAssets(uint256 shares) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * TODO: Incomplete, Need to fully implement this strategy
 * @title SfrxETHStrategy
 * @notice This strategy is used to allocate and deallocate WETH to the SfrxETH vault on Mainnet
 */
contract SfrxETHStrategy is MYTStrategy, IERC721Receiver {
    FraxMinter public immutable minter;
    FraxRedemptionQueue public immutable redemptionQueue;
    StakedFraxEth public immutable sfrxEth;
    address public immutable WETH = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    constructor(address _myt, StrategyParams memory _params, address _sfrxEth, address _fraxMinter, address _redemptionQueue, address _permit2Address)
        MYTStrategy(_myt, _params, _permit2Address, _sfrxEth)
    {
        require(_redemptionQueue != address(0), "Zero redemption queue address");
        minter = FraxMinter(_fraxMinter);
        redemptionQueue = FraxRedemptionQueue(_redemptionQueue);
        sfrxEth = StakedFraxEth(_sfrxEth);

        // Approve redemption queue to spend sfrxEth
        sfrxEth.approve(_redemptionQueue, type(uint256).max);
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        // need to unwrap ether since this strategy only recieves weth (morpho v2 vault cannot hold native eth by default)
        IWETH(WETH).withdraw(amount);
        // check that eth balance is equal to amount
        require(address(this).balance >= amount, "ETH balance is less than amount");
        depositReturn = minter.submitAndDeposit{value: amount}(address(this));
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        // protection for uint120 requirement
        require(amount <= type(uint120).max, "Amount exceeds uint120 max");

        uint256 sfrxEthBalance = sfrxEth.balanceOf(address(this));
        uint256 amountToRedeem = amount > sfrxEthBalance ? sfrxEthBalance : amount;

        require(amountToRedeem > 0, "No sfrxEth to redeem");

        // Enter redemption queue and immediately claim the ETH
        uint256 nftId = redemptionQueue.enterRedemptionQueueViaSfrxEth(address(this), uint120(amountToRedeem));
        return nftId;
    }

    function _claimWithdrawalQueue(uint256 positionId) internal override returns (uint256 ethOut) {
        uint256 balanceBefore = address(this).balance;
        redemptionQueue.burnRedemptionTicketNft(positionId, address(this));
        ethOut = address(this).balance - balanceBefore;

        // Wrap the received ETH into WETH
        IWETH(WETH).deposit{value: ethOut}();

        // Approve vault to spend the WETH
        IWETH(WETH).approve(address(MYT), ethOut);
    }

    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 dt = lastSnapshotTime == 0 ? 0 : block.timestamp - lastSnapshotTime;

        uint256 currentPPS = sfrxEth.convertToAssets(1e18);

        newIndex = currentPPS;
        if (lastIndex == 0 || dt == 0 || currentPPS <= lastIndex) return (0, newIndex);
        uint256 growth = (currentPPS - lastIndex) * FIXED_POINT_SCALAR / lastIndex;
        ratePerSec = growth / dt;
        return (ratePerSec, newIndex);
    }

    function realAssets() external view override returns (uint256) {
        return sfrxEth.convertToAssets(sfrxEth.balanceOf(address(this)));
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        // Apply slippage to the amount of assets (ETH)
        // slippageBPS is stored in params.slippageBPS
        return amount - (amount * params.slippageBPS / 10_000);
    }

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {
        require(msg.sender == WETH, "Only WETH unwrap");
    }
}
