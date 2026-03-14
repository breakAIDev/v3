// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployTokeAutoStrategiesScript} from "../../script/DeployTokeAutoStrategies.s.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../AlchemistCurator.sol";
import {TokeAutoStrategy} from "../strategies/TokeAutoStrategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";

contract MockMYTForTokeAutoDeployTest {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }

    fallback() external payable {}
}

contract DeployTokeAutoStrategiesScriptTest is Test {
    DeployTokeAutoStrategiesScript internal deployScript;
    AlchemistCurator internal curator;
    TestERC20 internal assetToken;
    TestERC20 internal rewardsToken;
    MockMYTForTokeAutoDeployTest internal myt;

    address internal newOwner;
    address internal autoVaultA;
    address internal autoVaultB;
    address internal rewarderA;
    address internal rewarderB;

    function setUp() public {
        deployScript = new DeployTokeAutoStrategiesScript();
        curator = new AlchemistCurator(address(deployScript), address(deployScript));

        assetToken = new TestERC20(1_000_000e18, 18);
        rewardsToken = new TestERC20(1_000_000e18, 18);
        myt = new MockMYTForTokeAutoDeployTest(address(assetToken));

        newOwner = makeAddr("newOwner");
        autoVaultA = makeAddr("autoVaultA");
        autoVaultB = makeAddr("autoVaultB");
        rewarderA = makeAddr("rewarderA");
        rewarderB = makeAddr("rewarderB");
    }

    function test_deployTokeAutoStrategy_setsCoreAddressesAndName() public {
        DeployTokeAutoStrategiesScript.TokeAutoDeployConfig memory config = DeployTokeAutoStrategiesScript
            .TokeAutoDeployConfig({
            myt: address(myt),
            mytAsset: address(assetToken),
            autoVault: autoVaultA,
            rewarder: rewarderA,
            tokeRewardsToken: address(rewardsToken),
            deallocShortfallBufferBPS: 105,
            params: _buildParams("Tokemak AutoETH", "TokeAuto")
        });

        address strategyAddr = deployScript.deployTokeAutoStrategy(curator, newOwner, config);
        TokeAutoStrategy strategy = TokeAutoStrategy(strategyAddr);

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT address");
        assertEq(address(strategy.mytAsset()), address(assetToken), "unexpected strategy asset");
        assertEq(address(strategy.autoVault()), autoVaultA, "unexpected auto vault");
        assertEq(address(strategy.rewarder()), rewarderA, "unexpected rewarder");
        assertEq(address(strategy.tokeRewardsToken()), address(rewardsToken), "unexpected rewards token");
        assertEq(strategy.deallocShortfallBufferBPS(), 105, "unexpected dealloc shortfall buffer");
        assertEq(strategy.killSwitch(), true, "kill switch should be enabled");
        assertEq(strategy.owner(), newOwner, "ownership not transferred");

        (, string memory strategyName,,,,,,,) = strategy.params();
        assertEq(strategyName, "Tokemak AutoETH", "unexpected strategy name");
    }

    function test_deployBatch_deploysAllConfigsWithExpectedValues() public {
        DeployTokeAutoStrategiesScript.TokeAutoDeployConfig[] memory configs =
            new DeployTokeAutoStrategiesScript.TokeAutoDeployConfig[](2);

        configs[0] = DeployTokeAutoStrategiesScript.TokeAutoDeployConfig({
            myt: address(myt),
            mytAsset: address(assetToken),
            autoVault: autoVaultA,
            rewarder: rewarderA,
            tokeRewardsToken: address(rewardsToken),
            deallocShortfallBufferBPS: 105,
            params: _buildParams("Tokemak AutoETH", "TokeAuto")
        });

        configs[1] = DeployTokeAutoStrategiesScript.TokeAutoDeployConfig({
            myt: address(myt),
            mytAsset: address(assetToken),
            autoVault: autoVaultB,
            rewarder: rewarderB,
            tokeRewardsToken: address(rewardsToken),
            deallocShortfallBufferBPS: 0,
            params: _buildParams("Tokemak AutoUSD", "TokeAuto")
        });

        address[] memory deployed = deployScript.deployBatch(curator, newOwner, configs);
        assertEq(deployed.length, 2, "unexpected deployed strategies length");

        TokeAutoStrategy strategy0 = TokeAutoStrategy(deployed[0]);
        assertEq(address(strategy0.MYT()), address(myt), "strategy0 unexpected MYT");
        assertEq(address(strategy0.autoVault()), autoVaultA, "strategy0 unexpected auto vault");
        assertEq(address(strategy0.rewarder()), rewarderA, "strategy0 unexpected rewarder");
        assertEq(strategy0.deallocShortfallBufferBPS(), 105, "strategy0 unexpected dealloc shortfall buffer");
        assertEq(strategy0.owner(), newOwner, "strategy0 ownership not transferred");
        (, string memory name0,,,,,,,) = strategy0.params();
        assertEq(name0, "Tokemak AutoETH", "strategy0 unexpected name");

        TokeAutoStrategy strategy1 = TokeAutoStrategy(deployed[1]);
        assertEq(address(strategy1.MYT()), address(myt), "strategy1 unexpected MYT");
        assertEq(address(strategy1.autoVault()), autoVaultB, "strategy1 unexpected auto vault");
        assertEq(address(strategy1.rewarder()), rewarderB, "strategy1 unexpected rewarder");
        assertEq(strategy1.deallocShortfallBufferBPS(), 0, "strategy1 unexpected dealloc shortfall buffer");
        assertEq(strategy1.owner(), newOwner, "strategy1 ownership not transferred");
        (, string memory name1,,,,,,,) = strategy1.params();
        assertEq(name1, "Tokemak AutoUSD", "strategy1 unexpected name");
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
