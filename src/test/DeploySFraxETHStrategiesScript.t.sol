// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeploySFraxETHStrategiesScript} from "../../script/DeploySFraxETHStrategies.s.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../AlchemistCurator.sol";
import {FrxEthEthDualOracleAggregatorAdapter} from "../FrxEthEthDualOracleAggregatorAdapter.sol";
import {SFraxETHStrategy} from "../strategies/SFraxETHStrategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";

contract MockMYTForSFraxETHDeployTest {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }

    fallback() external payable {}
}

contract DeploySFraxETHStrategiesScriptTest is Test {
    DeploySFraxETHStrategiesScript internal deployScript;
    AlchemistCurator internal curator;
    TestERC20 internal assetToken;
    MockMYTForSFraxETHDeployTest internal myt;

    address internal newOwner;
    address internal minter;
    address internal frxETH;
    address internal sfrxETH;
    address internal dualOracleA;
    address internal dualOracleB;

    function setUp() public {
        deployScript = new DeploySFraxETHStrategiesScript();
        curator = new AlchemistCurator(address(deployScript), address(deployScript));

        assetToken = new TestERC20(1_000_000e18, 18);
        myt = new MockMYTForSFraxETHDeployTest(address(assetToken));

        newOwner = makeAddr("newOwner");
        minter = makeAddr("minter");
        frxETH = makeAddr("frxETH");
        sfrxETH = makeAddr("sfrxETH");
        dualOracleA = makeAddr("dualOracleA");
        dualOracleB = makeAddr("dualOracleB");
    }

    function test_deploySFraxETHStrategy_setsCoreAddressesAndName() public {
        DeploySFraxETHStrategiesScript.SFraxETHDeployConfig memory config = DeploySFraxETHStrategiesScript
            .SFraxETHDeployConfig({
            myt: address(myt),
            minter: minter,
            frxETH: frxETH,
            sfrxETH: sfrxETH,
            frxEthEthDualOracle: dualOracleA,
            minAllocationOutBps: 7000,
            params: _buildParams("sfrxETH Mainnet", "Frax")
        });

        (address strategyAddr, address adapterAddr) = deployScript.deploySFraxETHStrategy(curator, newOwner, config);
        SFraxETHStrategy strategy = SFraxETHStrategy(payable(strategyAddr));
        FrxEthEthDualOracleAggregatorAdapter adapter = FrxEthEthDualOracleAggregatorAdapter(adapterAddr);

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT address");
        assertEq(address(strategy.minter()), minter, "unexpected minter");
        assertEq(address(strategy.frxETH()), frxETH, "unexpected frxETH");
        assertEq(address(strategy.sfrxETH()), sfrxETH, "unexpected sfrxETH");
        assertEq(address(strategy.pricedTokenEthOracle()), adapterAddr, "unexpected oracle adapter");
        assertEq(address(adapter.dualOracle()), dualOracleA, "unexpected dual oracle");
        assertEq(strategy.minAllocationOutBps(), 7000, "unexpected minAllocationOutBps");
        (, string memory strategyName,,,,,,,) = strategy.params();
        assertEq(strategyName, "sfrxETH Mainnet", "unexpected strategy name");
    }

    function test_deployBatch_deploysAllConfigsWithExpectedValues() public {
        DeploySFraxETHStrategiesScript.SFraxETHDeployConfig[] memory configs =
            new DeploySFraxETHStrategiesScript.SFraxETHDeployConfig[](2);

        configs[0] = DeploySFraxETHStrategiesScript.SFraxETHDeployConfig({
            myt: address(myt),
            minter: minter,
            frxETH: frxETH,
            sfrxETH: sfrxETH,
            frxEthEthDualOracle: dualOracleA,
            minAllocationOutBps: 7000,
            params: _buildParams("sfrxETH Mainnet", "Frax")
        });

        configs[1] = DeploySFraxETHStrategiesScript.SFraxETHDeployConfig({
            myt: address(myt),
            minter: minter,
            frxETH: makeAddr("frxETHB"),
            sfrxETH: makeAddr("sfrxETHB"),
            frxEthEthDualOracle: dualOracleB,
            minAllocationOutBps: 8000,
            params: _buildParams("sfrxETH Alternate", "Frax")
        });

        (address[] memory deployedStrategies, address[] memory deployedAdapters) =
            deployScript.deployBatch(curator, newOwner, configs);
        assertEq(deployedStrategies.length, 2, "unexpected deployed strategies length");
        assertEq(deployedAdapters.length, 2, "unexpected deployed adapters length");

        SFraxETHStrategy strategy0 = SFraxETHStrategy(payable(deployedStrategies[0]));
        FrxEthEthDualOracleAggregatorAdapter adapter0 = FrxEthEthDualOracleAggregatorAdapter(deployedAdapters[0]);
        assertEq(address(strategy0.MYT()), address(myt), "strategy0 unexpected MYT");
        assertEq(address(strategy0.minter()), minter, "strategy0 unexpected minter");
        assertEq(address(strategy0.frxETH()), frxETH, "strategy0 unexpected frxETH");
        assertEq(address(strategy0.sfrxETH()), sfrxETH, "strategy0 unexpected sfrxETH");
        assertEq(address(strategy0.pricedTokenEthOracle()), deployedAdapters[0], "strategy0 unexpected adapter");
        assertEq(address(adapter0.dualOracle()), dualOracleA, "strategy0 unexpected dual oracle");
        assertEq(strategy0.minAllocationOutBps(), 7000, "strategy0 unexpected minAllocationOutBps");
        (, string memory name0,,,,,,,) = strategy0.params();
        assertEq(name0, "sfrxETH Mainnet", "strategy0 unexpected name");

        SFraxETHStrategy strategy1 = SFraxETHStrategy(payable(deployedStrategies[1]));
        FrxEthEthDualOracleAggregatorAdapter adapter1 = FrxEthEthDualOracleAggregatorAdapter(deployedAdapters[1]);
        assertEq(address(strategy1.MYT()), address(myt), "strategy1 unexpected MYT");
        assertEq(address(strategy1.minter()), minter, "strategy1 unexpected minter");
        assertEq(address(strategy1.frxETH()), configs[1].frxETH, "strategy1 unexpected frxETH");
        assertEq(address(strategy1.sfrxETH()), configs[1].sfrxETH, "strategy1 unexpected sfrxETH");
        assertEq(address(strategy1.pricedTokenEthOracle()), deployedAdapters[1], "strategy1 unexpected adapter");
        assertEq(address(adapter1.dualOracle()), dualOracleB, "strategy1 unexpected dual oracle");
        assertEq(strategy1.minAllocationOutBps(), 8000, "strategy1 unexpected minAllocationOutBps");
        (, string memory name1,,,,,,,) = strategy1.params();
        assertEq(name1, "sfrxETH Alternate", "strategy1 unexpected name");
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
