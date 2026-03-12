pragma solidity 0.8.28;

import {ERC4626BaseStrategy} from "../ERC4626BaseStrategy.sol";

/**
 * @title FluidARBUSDCStrategy
 * @notice This strategy is used to allocate and deallocate usdc to the Fluid USDC vault on ARB
 */
contract FluidARBUSDCStrategy is ERC4626BaseStrategy {
    constructor(address _myt, StrategyParams memory _params, address _fluidVault)
        ERC4626BaseStrategy(_myt, _params, _fluidVault)
    {}
}
