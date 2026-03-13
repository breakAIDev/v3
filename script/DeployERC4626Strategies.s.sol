// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {MYTStrategy} from "../src/MYTStrategy.sol";
import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";

/// @notice Reusable deploy helper for generic ERC4626 strategies.
contract DeployERC4626StrategiesScript is Script {
    struct ERC4626DeployConfig {
        address myt;
        address vault4626;
        IMYTStrategy.StrategyParams params;
    }

    function deployERC4626Strategy(
        AlchemistCurator curator,
        address newOwner,
        ERC4626DeployConfig memory config
    ) public returns (address strategyAddr) {
        ERC4626Strategy strategy = new ERC4626Strategy(config.myt, config.params, config.vault4626);
        strategyAddr = address(strategy);

        curator.submitSetStrategy(strategyAddr, config.myt);
        curator.setStrategy(strategyAddr, config.myt);
        curator.submitIncreaseAbsoluteCap(strategyAddr, config.params.cap);
        curator.increaseAbsoluteCap(strategyAddr, config.params.cap);
        curator.submitIncreaseRelativeCap(strategyAddr, config.params.globalCap);
        curator.increaseRelativeCap(strategyAddr, config.params.globalCap);

        MYTStrategy(strategyAddr).setKillSwitch(true);
        MYTStrategy(strategyAddr).transferOwnership(newOwner);
    }

    /// @notice Example batch entrypoint; caller prepares per-vault configs.
    function deployBatch(
        AlchemistCurator curator,
        address newOwner,
        ERC4626DeployConfig[] memory configs
    ) public returns (address[] memory deployedStrategies) {
        deployedStrategies = new address[](configs.length);
        for (uint256 i = 0; i < configs.length; i++) {
            deployedStrategies[i] = deployERC4626Strategy(curator, newOwner, configs[i]);
        }
    }
}
