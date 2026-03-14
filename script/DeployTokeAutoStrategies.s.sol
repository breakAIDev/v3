// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {MYTStrategy} from "../src/MYTStrategy.sol";
import {TokeAutoStrategy} from "../src/strategies/TokeAutoStrategy.sol";

/// @notice Reusable deploy helper for generic Tokemak auto-vault strategies.
contract DeployTokeAutoStrategiesScript is Script {
    struct TokeAutoDeployConfig {
        address myt;
        address mytAsset;
        address autoVault;
        address rewarder;
        address tokeRewardsToken;
        uint256 deallocShortfallBufferBPS;
        IMYTStrategy.StrategyParams params;
    }

    function deployTokeAutoStrategy(
        AlchemistCurator curator,
        address newOwner,
        TokeAutoDeployConfig memory config
    ) public returns (address strategyAddr) {
        TokeAutoStrategy strategy = new TokeAutoStrategy(
            config.myt,
            config.params,
            config.mytAsset,
            config.autoVault,
            config.rewarder,
            config.tokeRewardsToken,
            config.deallocShortfallBufferBPS
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
        TokeAutoDeployConfig[] memory configs
    ) public returns (address[] memory deployedStrategies) {
        deployedStrategies = new address[](configs.length);
        for (uint256 i = 0; i < configs.length; i++) {
            deployedStrategies[i] = deployTokeAutoStrategy(curator, newOwner, configs[i]);
        }
    }
}
