// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC4626Strategy} from "../ERC4626Strategy.sol";

/**
 * @title MorphoYearnOGWETHStrategy
 * @notice This strategy is used to allocate and deallocate weth to the Morpho Yearn OG WETH vault on Mainnet
 */
contract MorphoYearnOGWETHStrategy is ERC4626Strategy {
    constructor(address _myt, StrategyParams memory _params, address _vault)
        ERC4626Strategy(_myt, _params, _vault)
    {}
}
