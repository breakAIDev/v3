// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {MYTStrategy} from "../src/MYTStrategy.sol";
import {MoonwellStrategy} from "../src/strategies/MoonwellStrategy.sol";

/// @notice Reusable deploy helper for generic Moonwell strategies.
contract DeployMoonwellStrategiesScript is Script {
    struct MoonwellDeployConfig {
        address myt;
        address mytAsset;
        address mToken;
        address comptroller;
        address rewardToken;
        bool usePostRedeemETHWrap;
        IMYTStrategy.StrategyParams params;
    }

    function deployMoonwellStrategy(
        AlchemistCurator curator,
        address newOwner,
        MoonwellDeployConfig memory config
    ) public returns (address strategyAddr) {
        MoonwellStrategy strategy = new MoonwellStrategy(
            config.myt,
            config.params,
            config.mytAsset,
            config.mToken,
            config.comptroller,
            config.rewardToken,
            config.usePostRedeemETHWrap
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
        MoonwellDeployConfig[] memory configs
    ) public returns (address[] memory deployedStrategies) {
        deployedStrategies = new address[](configs.length);
        for (uint256 i = 0; i < configs.length; i++) {
            deployedStrategies[i] = deployMoonwellStrategy(curator, newOwner, configs[i]);
        }
    }
}
