pragma solidity 0.8.28;

import {ERC4626BaseStrategy} from "../ERC4626BaseStrategy.sol";

/**
 * @title EulerARBWETHStrategy
 * @notice This strategy is used to allocate and deallocate weth to the Euler WETH vault on ARB
 */
contract EulerARBWETHStrategy is ERC4626BaseStrategy {
    constructor(address _myt, StrategyParams memory _params, address _weth, address _eulerVault)
        ERC4626BaseStrategy(_myt, _params, _weth, _eulerVault)
    {}

    function weth() external view returns (address) {
        return address(assetToken);
    }
}
