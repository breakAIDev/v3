// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployMoonwellStrategiesScript} from "../../script/DeployMoonwellStrategies.s.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../AlchemistCurator.sol";
import {MoonwellStrategy} from "../strategies/MoonwellStrategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";

contract MockMYTForMoonwellDeployTest {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }

    fallback() external payable {}
}

contract DeployMoonwellStrategiesScriptTest is Test {
    DeployMoonwellStrategiesScript internal deployScript;
    AlchemistCurator internal curator;
    TestERC20 internal assetToken;
    MockMYTForMoonwellDeployTest internal myt;

    address internal newOwner;
    address internal mTokenA;
    address internal mTokenB;
    address internal comptroller;
    address internal rewardToken;

    function setUp() public {
        deployScript = new DeployMoonwellStrategiesScript();
        curator = new AlchemistCurator(address(deployScript), address(deployScript));

        assetToken = new TestERC20(1_000_000e18, 18);
        myt = new MockMYTForMoonwellDeployTest(address(assetToken));

        newOwner = makeAddr("newOwner");
        mTokenA = makeAddr("mTokenA");
        mTokenB = makeAddr("mTokenB");
        comptroller = makeAddr("comptroller");
        rewardToken = makeAddr("rewardToken");
    }

    function test_deployMoonwellStrategy_setsCoreAddressesAndName() public {
        DeployMoonwellStrategiesScript.MoonwellDeployConfig memory config = DeployMoonwellStrategiesScript
            .MoonwellDeployConfig({
            myt: address(myt),
            mytAsset: address(assetToken),
            mToken: mTokenA,
            comptroller: comptroller,
            rewardToken: rewardToken,
            usePostRedeemETHWrap: false,
            params: _buildParams("Moonwell OP USDC", "Moonwell")
        });

        address strategyAddr = deployScript.deployMoonwellStrategy(curator, newOwner, config);
        MoonwellStrategy strategy = MoonwellStrategy(payable(strategyAddr));

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT address");
        assertEq(address(strategy.mytAsset()), address(assetToken), "unexpected strategy asset");
        assertEq(address(strategy.mToken()), mTokenA, "unexpected mToken");
        assertEq(address(strategy.comptroller()), comptroller, "unexpected comptroller");
        assertEq(address(strategy.rewardToken()), rewardToken, "unexpected reward token");
        assertEq(strategy.usePostRedeemETHWrap(), false, "unexpected wrap flag");
        (, string memory strategyName,,,,,,,) = strategy.params();
        assertEq(strategyName, "Moonwell OP USDC", "unexpected strategy name");
    }

    function test_deployBatch_deploysAllConfigsWithExpectedValues() public {
        DeployMoonwellStrategiesScript.MoonwellDeployConfig[] memory configs =
            new DeployMoonwellStrategiesScript.MoonwellDeployConfig[](2);

        configs[0] = DeployMoonwellStrategiesScript.MoonwellDeployConfig({
            myt: address(myt),
            mytAsset: address(assetToken),
            mToken: mTokenA,
            comptroller: comptroller,
            rewardToken: rewardToken,
            usePostRedeemETHWrap: false,
            params: _buildParams("Moonwell OP USDC", "Moonwell")
        });

        configs[1] = DeployMoonwellStrategiesScript.MoonwellDeployConfig({
            myt: address(myt),
            mytAsset: address(assetToken),
            mToken: mTokenB,
            comptroller: comptroller,
            rewardToken: rewardToken,
            usePostRedeemETHWrap: true,
            params: _buildParams("Moonwell OP WETH", "Moonwell")
        });

        address[] memory deployed = deployScript.deployBatch(curator, newOwner, configs);
        assertEq(deployed.length, 2, "unexpected deployed strategies length");

        MoonwellStrategy strategy0 = MoonwellStrategy(payable(deployed[0]));
        assertEq(address(strategy0.MYT()), address(myt), "strategy0 unexpected MYT");
        assertEq(address(strategy0.mToken()), mTokenA, "strategy0 unexpected mToken");
        assertEq(strategy0.usePostRedeemETHWrap(), false, "strategy0 unexpected wrap flag");
        (, string memory name0,,,,,,,) = strategy0.params();
        assertEq(name0, "Moonwell OP USDC", "strategy0 unexpected name");

        MoonwellStrategy strategy1 = MoonwellStrategy(payable(deployed[1]));
        assertEq(address(strategy1.MYT()), address(myt), "strategy1 unexpected MYT");
        assertEq(address(strategy1.mToken()), mTokenB, "strategy1 unexpected mToken");
        assertEq(strategy1.usePostRedeemETHWrap(), true, "strategy1 unexpected wrap flag");
        (, string memory name1,,,,,,,) = strategy1.params();
        assertEq(name1, "Moonwell OP WETH", "strategy1 unexpected name");
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
