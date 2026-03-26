// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployWstethStrategiesScript} from "../../script/DeployWstethStrategies.s.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../AlchemistCurator.sol";
import {WstethStrategy} from "../strategies/mainnet/WStethStrategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";

contract MockMYTForWstethDeployTest {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }

    fallback() external payable {}
}

contract MockOracleForWstethDeployTest {
    uint8 public immutable decimals;

    constructor(uint8 _decimals) {
        decimals = _decimals;
    }

    function latestRoundData()
        external
        pure
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, 1e18, 1, 1, 1);
    }
}

contract DeployWstethStrategiesScriptTest is Test {
    DeployWstethStrategiesScript internal deployScript;
    AlchemistCurator internal curator;
    TestERC20 internal assetToken;
    MockMYTForWstethDeployTest internal myt;

    address internal newOwner;
    address internal wstethMainnet;
    address internal wstethOptimism;
    MockOracleForWstethDeployTest internal oracleMainnet;
    MockOracleForWstethDeployTest internal oracleOptimism;

    function setUp() public {
        deployScript = new DeployWstethStrategiesScript();
        curator = new AlchemistCurator(address(deployScript), address(deployScript));

        assetToken = new TestERC20(1_000_000e18, 18);
        myt = new MockMYTForWstethDeployTest(address(assetToken));

        newOwner = makeAddr("newOwner");
        wstethMainnet = makeAddr("wstethMainnet");
        wstethOptimism = makeAddr("wstethOptimism");
        oracleMainnet = new MockOracleForWstethDeployTest(18);
        oracleOptimism = new MockOracleForWstethDeployTest(18);
    }

    function test_deployWstethStrategy_setsOracleFlagAndName() public {
        DeployWstethStrategiesScript.WstethDeployConfig memory config = DeployWstethStrategiesScript.WstethDeployConfig({
            myt: address(myt),
            wstETH: wstethMainnet,
            pricedTokenEthOracle: address(oracleMainnet),
            directDepositEnabled: true,
            params: _buildParams("wstETH Mainnet", "Wsteth")
        });

        address strategyAddr = deployScript.deployWstethStrategy(curator, newOwner, config);
        WstethStrategy strategy = WstethStrategy(payable(strategyAddr));

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT address");
        assertEq(address(strategy.wsteth()), wstethMainnet, "unexpected wstETH address");
        assertEq(address(strategy.pricedTokenEthOracle()), address(oracleMainnet), "unexpected oracle");
        assertEq(strategy.directDepositEnabled(), true, "unexpected directDepositEnabled");
        (, string memory strategyName,,,,,,,) = strategy.params();
        assertEq(strategyName, "wstETH Mainnet", "unexpected strategy name");
    }

    function test_deployBatch_deploysMainnetAndOpConfigsWithExpectedValues() public {
        DeployWstethStrategiesScript.WstethDeployConfig[] memory configs =
            new DeployWstethStrategiesScript.WstethDeployConfig[](2);

        configs[0] = DeployWstethStrategiesScript.WstethDeployConfig({
            myt: address(myt),
            wstETH: wstethMainnet,
            pricedTokenEthOracle: address(oracleMainnet),
            directDepositEnabled: true,
            params: _buildParams("wstETH Mainnet", "Wsteth")
        });

        configs[1] = DeployWstethStrategiesScript.WstethDeployConfig({
            myt: address(myt),
            wstETH: wstethOptimism,
            pricedTokenEthOracle: address(oracleOptimism),
            directDepositEnabled: false,
            params: _buildParams("wstETH Optimism", "Wsteth")
        });

        address[] memory deployed = deployScript.deployBatch(curator, newOwner, configs);
        assertEq(deployed.length, 2, "unexpected deployed strategies length");

        WstethStrategy strategy0 = WstethStrategy(payable(deployed[0]));
        assertEq(address(strategy0.MYT()), address(myt), "strategy0 unexpected MYT");
        assertEq(address(strategy0.wsteth()), wstethMainnet, "strategy0 unexpected wstETH");
        assertEq(address(strategy0.pricedTokenEthOracle()), address(oracleMainnet), "strategy0 unexpected oracle");
        assertEq(strategy0.directDepositEnabled(), true, "strategy0 unexpected directDepositEnabled");
        (, string memory name0,,,,,,,) = strategy0.params();
        assertEq(name0, "wstETH Mainnet", "strategy0 unexpected name");

        WstethStrategy strategy1 = WstethStrategy(payable(deployed[1]));
        assertEq(address(strategy1.MYT()), address(myt), "strategy1 unexpected MYT");
        assertEq(address(strategy1.wsteth()), wstethOptimism, "strategy1 unexpected wstETH");
        assertEq(address(strategy1.pricedTokenEthOracle()), address(oracleOptimism), "strategy1 unexpected oracle");
        assertEq(strategy1.directDepositEnabled(), false, "strategy1 unexpected directDepositEnabled");
        (, string memory name1,,,,,,,) = strategy1.params();
        assertEq(name1, "wstETH Optimism", "strategy1 unexpected name");
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
