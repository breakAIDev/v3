pragma solidity 0.8.28;

import {ERC4626BaseStrategy} from "../ERC4626BaseStrategy.sol";

/**
 * @title EulerUSDCStrategy
 * @notice This strategy is used to allocate and deallocate usdc to the Euler USDC vault on Mainnet
 */
contract EulerUSDCStrategy is ERC4626BaseStrategy {
    constructor(address _myt, StrategyParams memory _params, address _eulerVault)
        ERC4626BaseStrategy(_myt, _params, _eulerVault)
    {}
}
