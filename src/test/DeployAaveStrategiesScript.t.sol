// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployAaveStrategiesScript} from "../../script/DeployAaveStrategies.s.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../AlchemistCurator.sol";
import {AaveStrategy} from "../strategies/AaveStrategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";

contract MockMYTForAaveDeployTest {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }

    fallback() external payable {}
}

contract DeployAaveStrategiesScriptTest is Test {
    DeployAaveStrategiesScript internal deployScript;
    AlchemistCurator internal curator;
    TestERC20 internal assetToken;
    MockMYTForAaveDeployTest internal myt;

    address internal newOwner;
    address internal aTokenA;
    address internal aTokenB;
    address internal poolProviderA;
    address internal poolProviderB;
    address internal rewardsController;
    address internal rewardTokenA;
    address internal rewardTokenB;

    function setUp() public {
        deployScript = new DeployAaveStrategiesScript();
        curator = new AlchemistCurator(address(deployScript), address(deployScript));

        assetToken = new TestERC20(1_000_000e18, 18);
        myt = new MockMYTForAaveDeployTest(address(assetToken));

        newOwner = makeAddr("newOwner");
        aTokenA = makeAddr("aTokenA");
        aTokenB = makeAddr("aTokenB");
        poolProviderA = makeAddr("poolProviderA");
        poolProviderB = makeAddr("poolProviderB");
        rewardsController = makeAddr("rewardsController");
        rewardTokenA = makeAddr("rewardTokenA");
        rewardTokenB = makeAddr("rewardTokenB");
    }

    function test_deployAaveStrategy_setsCoreAddressesAndName() public {
        DeployAaveStrategiesScript.AaveDeployConfig memory config = DeployAaveStrategiesScript.AaveDeployConfig({
            myt: address(myt),
            mytAsset: address(assetToken),
            aToken: aTokenA,
            poolProvider: poolProviderA,
            rewardsController: rewardsController,
            rewardToken: rewardTokenA,
            params: _buildParams("Aave Arbitrum USDC", "AaveV3")
        });

        address strategyAddr = deployScript.deployAaveStrategy(curator, newOwner, config);
        AaveStrategy strategy = AaveStrategy(strategyAddr);

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT address");
        assertEq(address(strategy.mytAsset()), address(assetToken), "unexpected strategy asset");
        assertEq(address(strategy.aToken()), aTokenA, "unexpected aToken");
        assertEq(address(strategy.poolProvider()), poolProviderA, "unexpected pool provider");
        assertEq(address(strategy.rewardsController()), rewardsController, "unexpected rewards controller");
        assertEq(address(strategy.rewardToken()), rewardTokenA, "unexpected reward token");
        (, string memory strategyName,,,,,,,) = strategy.params();
        assertEq(strategyName, "Aave Arbitrum USDC", "unexpected strategy name");
    }

    function test_deployBatch_deploysAllConfigsWithExpectedValues() public {
        DeployAaveStrategiesScript.AaveDeployConfig[] memory configs =
            new DeployAaveStrategiesScript.AaveDeployConfig[](2);

        configs[0] = DeployAaveStrategiesScript.AaveDeployConfig({
            myt: address(myt),
            mytAsset: address(assetToken),
            aToken: aTokenA,
            poolProvider: poolProviderA,
            rewardsController: rewardsController,
            rewardToken: rewardTokenA,
            params: _buildParams("Aave Arbitrum USDC", "AaveV3")
        });

        configs[1] = DeployAaveStrategiesScript.AaveDeployConfig({
            myt: address(myt),
            mytAsset: address(assetToken),
            aToken: aTokenB,
            poolProvider: poolProviderB,
            rewardsController: rewardsController,
            rewardToken: rewardTokenB,
            params: _buildParams("Aave Optimism USDC", "AaveV3")
        });

        address[] memory deployed = deployScript.deployBatch(curator, newOwner, configs);
        assertEq(deployed.length, 2, "unexpected deployed strategies length");

        AaveStrategy strategy0 = AaveStrategy(deployed[0]);
        assertEq(address(strategy0.MYT()), address(myt), "strategy0 unexpected MYT");
        assertEq(address(strategy0.aToken()), aTokenA, "strategy0 unexpected aToken");
        assertEq(address(strategy0.poolProvider()), poolProviderA, "strategy0 unexpected pool provider");
        (, string memory name0,,,,,,,) = strategy0.params();
        assertEq(name0, "Aave Arbitrum USDC", "strategy0 unexpected name");

        AaveStrategy strategy1 = AaveStrategy(deployed[1]);
        assertEq(address(strategy1.MYT()), address(myt), "strategy1 unexpected MYT");
        assertEq(address(strategy1.aToken()), aTokenB, "strategy1 unexpected aToken");
        assertEq(address(strategy1.poolProvider()), poolProviderB, "strategy1 unexpected pool provider");
        (, string memory name1,,,,,,,) = strategy1.params();
        assertEq(name1, "Aave Optimism USDC", "strategy1 unexpected name");
    }

    function _buildParams(string memory name, string memory protocol)
        internal
        view
        returns (IMYTStrategy.StrategyParams memory)
    {
        return IMYTStrategy.StrategyParams({
            owner: address(deployScript),
            name: name,
            protocol: protocol,
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 1_000e18,
            globalCap: 0.5e18,
            estimatedYield: 500,
            additionalIncentives: false,
            slippageBPS: 50
        });
    }
}
