pragma solidity 0.8.28;

import {ERC4626BaseStrategy} from "../ERC4626BaseStrategy.sol";

contract PeapodsUSDCStrategy is ERC4626BaseStrategy {
    constructor(address _myt, StrategyParams memory _params, address _peapodsUSDC, address _usdc)
        ERC4626BaseStrategy(_myt, _params, _usdc, _peapodsUSDC)
    {}

    function usdc() external view returns (address) {
        return address(assetToken);
    }
}
