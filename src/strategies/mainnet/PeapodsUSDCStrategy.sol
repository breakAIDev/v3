pragma solidity 0.8.28;

import {ERC4626Strategy} from "../ERC4626Strategy.sol";

contract PeapodsUSDCStrategy is ERC4626Strategy {
    constructor(address _myt, StrategyParams memory _params, address _peapodsUSDC)
        ERC4626Strategy(_myt, _params, _peapodsUSDC)
    {}
}
