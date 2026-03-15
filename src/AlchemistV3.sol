// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./interfaces/IAlchemistV3.sol";
import {AlchemistV3ActionsModule} from "./modules/AlchemistV3ActionsModule.sol";

/// @title  AlchemistV3
/// @author Alchemix Finance
///
/// For Juris, Graham, and Marcus
contract AlchemistV3 is AlchemistV3ActionsModule {
    function initialize(AlchemistInitializationParams memory params) external initializer {
        _initialize(params);
    }
}
