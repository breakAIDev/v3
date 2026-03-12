pragma solidity 0.8.28;

import {ERC4626BaseStrategy} from "../ERC4626BaseStrategy.sol";

contract PeapodsUSDCStrategy is ERC4626BaseStrategy {
    constructor(address _myt, StrategyParams memory _params, address _peapodsUSDC)
        ERC4626BaseStrategy(_myt, _params, _peapodsUSDC)
    {}
}
