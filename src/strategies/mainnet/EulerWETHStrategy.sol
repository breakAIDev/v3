pragma solidity 0.8.28;

import {ERC4626BaseStrategy} from "../ERC4626BaseStrategy.sol";

/**
 * @title EulerWETHStrategy
 * @notice This strategy is used to allocate and deallocate weth to the Euler WETH vault on Mainnet
 */
contract EulerWETHStrategy is ERC4626BaseStrategy {
    constructor(address _myt, StrategyParams memory _params, address _eulerVault)
        ERC4626BaseStrategy(_myt, _params, _eulerVault)
    {}
}
