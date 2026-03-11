pragma solidity 0.8.28;

import {ERC4626BaseStrategy} from "../ERC4626BaseStrategy.sol";

/**
 * @title EulerARBUSDCStrategy
 * @notice This strategy is used to allocate and deallocate usdc to the Euler USDC vault on ARB
 */
contract EulerARBUSDCStrategy is ERC4626BaseStrategy {
    constructor(address _myt, StrategyParams memory _params, address _usdc, address _eulerVault)
        ERC4626BaseStrategy(_myt, _params, _usdc, _eulerVault)
    {}

    function usdc() external view returns (address) {
        return address(assetToken);
    }
}
