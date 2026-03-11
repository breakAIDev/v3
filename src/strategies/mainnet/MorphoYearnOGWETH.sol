// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC4626BaseStrategy} from "../ERC4626BaseStrategy.sol";

/**
 * @title MorphoYearnOGWETHStrategy
 * @notice This strategy is used to allocate and deallocate weth to the Morpho Yearn OG WETH vault on Mainnet
 */
contract MorphoYearnOGWETHStrategy is ERC4626BaseStrategy {
    constructor(address _myt, StrategyParams memory _params, address _vault, address _weth)
        ERC4626BaseStrategy(_myt, _params, _weth, _vault)
    {}

    function weth() external view returns (address) {
        return address(assetToken);
    }
}
