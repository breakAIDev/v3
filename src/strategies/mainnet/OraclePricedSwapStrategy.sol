// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MYTStrategy} from "../../MYTStrategy.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

abstract contract OraclePricedSwapStrategy is MYTStrategy {
    uint256 public constant MAX_ORACLE_STALENESS = 7 days;

    AggregatorV3Interface public immutable pricedTokenEthOracle;
    uint8 public immutable pricedTokenEthOracleDecimals;

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _pricedTokenEthOracle
    ) MYTStrategy(_myt, _params) {
        require(_pricedTokenEthOracle != address(0), "Zero oracle address");

        pricedTokenEthOracle = AggregatorV3Interface(_pricedTokenEthOracle);
        pricedTokenEthOracleDecimals = pricedTokenEthOracle.decimals();
    }

    function _allocate(uint256 amount, bytes memory callData) internal virtual override returns (uint256) {
        _ensureIdleBalance(_asset(), amount);

        uint256 minPricedOut = _assetToPricedDown((amount * (10_000 - params.slippageBPS)) / 10_000);
        if (minPricedOut == 0) minPricedOut = 1;

        uint256 pricedReceived = dexSwap(_pricedToken(), _asset(), amount, minPricedOut, callData);
        _afterAllocateSwap(pricedReceived);
        return amount;
    }

    function _deallocate(uint256 amount, bytes memory callData) internal virtual override returns (uint256) {
        return _deallocateViaPricedSwap(amount, callData);
    }

    function _deallocateViaPricedSwap(uint256 amount, bytes memory callData) internal returns (uint256) {
        uint256 idleBalance = _idleAssets();
        if (idleBalance >= amount) {
            TokenUtils.safeApprove(_asset(), msg.sender, amount);
            return amount;
        }

        uint256 shortfall = amount - idleBalance;
        uint256 maxAssetIn = _roundUpMulDiv(shortfall, 10_000, 10_000 - params.slippageBPS);
        uint256 maxPricedIn = _assetToPricedUp(maxAssetIn);
        if (maxPricedIn == 0) maxPricedIn = 1;

        uint256 pricedToSwap = _preparePricedForSwap(maxPricedIn);
        require(pricedToSwap > 0, "No priced token to swap");

        dexSwap(_asset(), _pricedToken(), pricedToSwap, shortfall, callData);
        uint256 receivedAssets = _idleAssets();
        if (receivedAssets < amount) revert InsufficientBalance(amount, receivedAssets);
        TokenUtils.safeApprove(_asset(), msg.sender, amount);
        return amount;
    }

    function _totalValue() internal view virtual override returns (uint256) {
        uint256 pricedExposure = _positionToPriced(_positionBalance()) + _idlePricedAssets();
        return _idleAssets() + _pricedToAsset(pricedExposure);
    }

    function _idleAssets() internal view virtual override returns (uint256) {
        return TokenUtils.safeBalanceOf(_asset(), address(this));
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view virtual override returns (uint256) {
        uint256 maxAsset = _pricedToAsset(_positionToPriced(_positionBalance()) + _idlePricedAssets());
        uint256 fundable = amount <= maxAsset ? amount : maxAsset;
        return (fundable * (10_000 - params.slippageBPS)) / 10_000;
    }

    function _pricedToAsset(uint256 pricedAmount) internal view returns (uint256) {
        return pricedAmount * _oracleAnswer() / (10 ** pricedTokenEthOracleDecimals);
    }

    function _assetToPricedDown(uint256 assetAmount) internal view returns (uint256) {
        return assetAmount * (10 ** pricedTokenEthOracleDecimals) / _oracleAnswer();
    }

    function _assetToPricedUp(uint256 assetAmount) internal view returns (uint256) {
        uint256 scale = 10 ** pricedTokenEthOracleDecimals;
        uint256 answer = _oracleAnswer();
        return (assetAmount * scale + answer - 1) / answer;
    }

    function _oracleAnswer() internal view returns (uint256 answer) {
        (, int256 raw,, uint256 updatedAt,) = pricedTokenEthOracle.latestRoundData();
        require(raw > 0 && updatedAt != 0, "Invalid oracle answer");
        require(updatedAt <= block.timestamp && block.timestamp - updatedAt <= MAX_ORACLE_STALENESS, "Stale oracle answer");
        answer = uint256(raw);
    }

    function _roundUpMulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        return (x * y + denominator - 1) / denominator;
    }

    function _idlePricedAssets() internal view virtual returns (uint256) {
        return 0;
    }

    function _asset() internal view returns (address) {
        return MYT.asset();
    }

    function _pricedToken() internal view virtual returns (address);

    function _positionBalance() internal view virtual returns (uint256);

    function _positionToPriced(uint256 positionAmount) internal view virtual returns (uint256);

    function _afterAllocateSwap(uint256 pricedReceived) internal virtual;

    function _preparePricedForSwap(uint256 maxPricedIn) internal virtual returns (uint256);
}
