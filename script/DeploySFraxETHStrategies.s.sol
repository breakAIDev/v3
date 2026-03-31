// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {MYTStrategy} from "../src/MYTStrategy.sol";
import {FrxEthEthDualOracleAggregatorAdapter} from "../src/FrxEthEthDualOracleAggregatorAdapter.sol";
import {SFraxETHStrategy} from "../src/strategies/SFraxETHStrategy.sol";

/// @notice Reusable deploy helper for sfrxETH strategies.
contract DeploySFraxETHStrategiesScript is Script {
    struct SFraxETHDeployConfig {
        address myt;
        address minter;
        address frxETH;
        address sfrxETH;
        address frxEthEthDualOracle;
        uint256 minAllocationOutBps;
        IMYTStrategy.StrategyParams params;
    }

    function deploySFraxETHStrategy(
        AlchemistCurator curator,
        address newOwner,
        SFraxETHDeployConfig memory config
    ) public returns (address strategyAddr, address adapterAddr) {
        FrxEthEthDualOracleAggregatorAdapter adapter =
            new FrxEthEthDualOracleAggregatorAdapter(config.frxEthEthDualOracle);
        adapterAddr = address(adapter);

        SFraxETHStrategy strategy = new SFraxETHStrategy(
            config.myt,
            config.params,
            config.minter,
            config.frxETH,
            config.sfrxETH,
            adapterAddr,
            config.minAllocationOutBps
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

    function deployBatch(
        AlchemistCurator curator,
        address newOwner,
        SFraxETHDeployConfig[] memory configs
    ) public returns (address[] memory deployedStrategies, address[] memory deployedAdapters) {
        deployedStrategies = new address[](configs.length);
        deployedAdapters = new address[](configs.length);

        for (uint256 i = 0; i < configs.length; i++) {
            (deployedStrategies[i], deployedAdapters[i]) = deploySFraxETHStrategy(curator, newOwner, configs[i]);
        }
    }
}
