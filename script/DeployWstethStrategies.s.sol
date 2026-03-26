// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {MYTStrategy} from "../src/MYTStrategy.sol";
import {WstethStrategy} from "../src/strategies/mainnet/WStethStrategy.sol";

/// @notice Reusable deploy helper for generic wstETH strategies.
contract DeployWstethStrategiesScript is Script {
    struct WstethDeployConfig {
        address myt;
        address wstETH;
        address pricedTokenEthOracle;
        bool directDepositEnabled;
        IMYTStrategy.StrategyParams params;
    }

    function deployWstethStrategy(
        AlchemistCurator curator,
        address newOwner,
        WstethDeployConfig memory config
    ) public returns (address strategyAddr) {
        WstethStrategy strategy = new WstethStrategy(
            config.myt,
            config.params,
            config.wstETH,
            config.pricedTokenEthOracle,
            config.directDepositEnabled
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

    /// @notice Example batch entrypoint; caller prepares per-chain configs.
    function deployBatch(
        AlchemistCurator curator,
        address newOwner,
        WstethDeployConfig[] memory configs
    ) public returns (address[] memory deployedStrategies) {
        deployedStrategies = new address[](configs.length);
        for (uint256 i = 0; i < configs.length; i++) {
            deployedStrategies[i] = deployWstethStrategy(curator, newOwner, configs[i]);
        }
    }
}
