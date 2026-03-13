pragma solidity 0.8.28;

import {ERC4626Strategy} from "../ERC4626Strategy.sol";

/**
 * @title FluidARBUSDCStrategy
 * @notice This strategy is used to allocate and deallocate usdc to the Fluid USDC vault on ARB
 */
contract FluidARBUSDCStrategy is ERC4626Strategy {
    constructor(address _myt, StrategyParams memory _params, address _fluidVault)
        ERC4626Strategy(_myt, _params, _fluidVault)
    {}
}
