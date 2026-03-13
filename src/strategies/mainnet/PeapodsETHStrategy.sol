// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ERC4626Strategy} from "../ERC4626Strategy.sol";

/**
 * @title PeapodsETHStrategy
 * @notice This strategy is used to allocate and deallocate weth to the Peapods ETH vault on Mainnet
 */
contract PeapodsETHStrategy is ERC4626Strategy {
    constructor(address _myt, StrategyParams memory _params, address _peapodsEth)
        ERC4626Strategy(_myt, _params, _peapodsEth)
    {}
}
