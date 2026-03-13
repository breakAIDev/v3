// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {MYTStrategy} from "../src/MYTStrategy.sol";
import {AaveStrategy} from "../src/strategies/AaveStrategy.sol";

/// @notice Reusable deploy helper for generic Aave strategies.
contract DeployAaveStrategiesScript is Script {
    struct AaveDeployConfig {
        address myt;
        address mytAsset;
        address aToken;
        address poolProvider;
        address rewardsController;
        address rewardToken;
        IMYTStrategy.StrategyParams params;
    }

    function deployAaveStrategy(
        AlchemistCurator curator,
        address newOwner,
        AaveDeployConfig memory config
    ) public returns (address strategyAddr) {
        AaveStrategy strategy = new AaveStrategy(
            config.myt,
            config.params,
            config.mytAsset,
            config.aToken,
            config.poolProvider,
            config.rewardsController,
            config.rewardToken
        );
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

    /// @notice Example batch entrypoint; caller prepares per-market configs.
    function deployBatch(
        AlchemistCurator curator,
        address newOwner,
        AaveDeployConfig[] memory configs
    ) public returns (address[] memory deployedStrategies) {
        deployedStrategies = new address[](configs.length);
        for (uint256 i = 0; i < configs.length; i++) {
            deployedStrategies[i] = deployAaveStrategy(curator, newOwner, configs[i]);
        }
    }
}
