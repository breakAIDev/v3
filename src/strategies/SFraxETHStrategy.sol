// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {OraclePricedSwapStrategy} from "./OraclePricedSwapStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

interface IFraxMinter {
    function submitAndDeposit(address recipient) external payable returns (uint256 shares);
}

interface ISfrxETH {
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
}

contract SFraxETHStrategy is OraclePricedSwapStrategy {
    IFraxMinter public immutable minter;
    IERC20 public immutable frxETH;
    ISfrxETH public immutable sfrxETH;

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _minter,
        address _frxETH,
        address _sfrxETH,
        address _pricedTokenEthOracle,
        uint256 _minAllocationOutBps
    ) OraclePricedSwapStrategy(_myt, _params, _pricedTokenEthOracle, _minAllocationOutBps) {
        require(_minter != address(0), "Zero minter address");
        require(_frxETH != address(0), "Zero frxETH address");
        require(_sfrxETH != address(0), "Zero sfrxETH address");

        minter = IFraxMinter(_minter);
        frxETH = IERC20(_frxETH);
        sfrxETH = ISfrxETH(_sfrxETH);
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        _ensureIdleBalance(_asset(), amount);

        IWETH(_asset()).withdraw(amount);
        uint256 sharesReceived = minter.submitAndDeposit{value: amount}(address(this));
        require(sharesReceived > 0, "No sfrxETH received");
        return amount;
    }

    function _afterAllocationSwap(uint256 oracleTokenReceived) internal override {
        TokenUtils.safeApprove(address(frxETH), address(sfrxETH), oracleTokenReceived);
        uint256 sharesReceived = sfrxETH.deposit(oracleTokenReceived, address(this));
        TokenUtils.safeApprove(address(frxETH), address(sfrxETH), 0);
        require(sharesReceived > 0, "No sfrxETH received");
    }

    function _deallocate(uint256, bytes memory) internal pure override returns (uint256) {
        revert ActionNotSupported();
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == MYT.asset() || token == address(sfrxETH) || token == address(frxETH);
    }

    function _oracleToken() internal view override returns (address) {
        return address(frxETH);
    }

    function _positionBalance() internal view override returns (uint256) {
        return sfrxETH.convertToAssets(sfrxETH.balanceOf(address(this)));
    }

    function _prepareOracleTokenForSwap(uint256) internal pure override returns (uint256) {
        revert ActionNotSupported();
    }

    function _prepareIntermediateForSwap(uint256 maxOracleTokenIn, uint256 minIntermediateOutAmount)
        internal
        override
        returns (address sellToken, uint256 sellAmount)
    {
        require(minIntermediateOutAmount > 0, "Invalid intermediate amount");

        uint256 sharesNeeded = sfrxETH.previewWithdraw(minIntermediateOutAmount);
        uint256 sharesBalance = sfrxETH.balanceOf(address(this));
        require(sharesNeeded > 0, "No sfrxETH to unwrap");
        require(sharesNeeded <= sharesBalance, "Insufficient sfrxETH balance");
        require(minIntermediateOutAmount <= maxOracleTokenIn, "Intermediate exceeds max oracle token in");

        uint256 frxETHBefore = frxETH.balanceOf(address(this));
        sfrxETH.withdraw(minIntermediateOutAmount, address(this), address(this));
        sellAmount = frxETH.balanceOf(address(this)) - frxETHBefore;
        require(sellAmount >= minIntermediateOutAmount, "Insufficient intermediate out");

        sellToken = address(frxETH);
    }

    receive() external payable {}
}
