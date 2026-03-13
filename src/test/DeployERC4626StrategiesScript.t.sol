// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployERC4626StrategiesScript} from "../../script/DeployERC4626Strategies.s.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {AlchemistCurator} from "../AlchemistCurator.sol";
import {ERC4626Strategy} from "../strategies/ERC4626Strategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";

contract MockMYTForDeployTest {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }

    fallback() external payable {}
}

contract MockERC4626VaultForDeployTest {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }
}

contract DeployERC4626StrategiesScriptTest is Test {
    DeployERC4626StrategiesScript internal deployScript;
    AlchemistCurator internal curator;
    TestERC20 internal assetToken;
    MockMYTForDeployTest internal myt;
    MockERC4626VaultForDeployTest internal vaultA;
    MockERC4626VaultForDeployTest internal vaultB;

    address internal newOwner;

    function setUp() public {
        deployScript = new DeployERC4626StrategiesScript();
        curator = new AlchemistCurator(address(deployScript), address(deployScript));

        assetToken = new TestERC20(1_000_000e18, 18);
        myt = new MockMYTForDeployTest(address(assetToken));
        vaultA = new MockERC4626VaultForDeployTest(address(assetToken));
        vaultB = new MockERC4626VaultForDeployTest(address(assetToken));

        newOwner = makeAddr("newOwner");
    }

    function test_deployERC4626Strategy_setsMytVaultAndName() public {
        DeployERC4626StrategiesScript.ERC4626DeployConfig memory config = DeployERC4626StrategiesScript.ERC4626DeployConfig({
            myt: address(myt),
            vault4626: address(vaultA),
            params: _buildParams("Euler Mainnet USDC", "Euler")
        });

        address strategyAddr = deployScript.deployERC4626Strategy(curator, newOwner, config);
        ERC4626Strategy strategy = ERC4626Strategy(strategyAddr);

        assertEq(address(strategy.MYT()), address(myt), "unexpected MYT address");
        assertEq(address(strategy.vault()), address(vaultA), "unexpected vault address");
        (, string memory strategyName,,,,,,,) = strategy.params();
        assertEq(strategyName, "Euler Mainnet USDC", "unexpected strategy name");
    }

    function test_deployBatch_deploysAllConfigsWithExpectedValues() public {
        DeployERC4626StrategiesScript.ERC4626DeployConfig[] memory configs =
            new DeployERC4626StrategiesScript.ERC4626DeployConfig[](2);

        configs[0] = DeployERC4626StrategiesScript.ERC4626DeployConfig({
            myt: address(myt),
            vault4626: address(vaultA),
            params: _buildParams("Euler Mainnet USDC", "Euler")
        });

        configs[1] = DeployERC4626StrategiesScript.ERC4626DeployConfig({
            myt: address(myt),
            vault4626: address(vaultB),
            params: _buildParams("Peapods Mainnet USDC", "Peapods")
        });

        address[] memory deployed = deployScript.deployBatch(curator, newOwner, configs);
        assertEq(deployed.length, 2, "unexpected deployed strategies length");

        ERC4626Strategy strategy0 = ERC4626Strategy(deployed[0]);
        assertEq(address(strategy0.MYT()), address(myt), "strategy0 unexpected MYT");
        assertEq(address(strategy0.vault()), address(vaultA), "strategy0 unexpected vault");
        (, string memory name0,,,,,,,) = strategy0.params();
        assertEq(name0, "Euler Mainnet USDC", "strategy0 unexpected name");

        ERC4626Strategy strategy1 = ERC4626Strategy(deployed[1]);
        assertEq(address(strategy1.MYT()), address(myt), "strategy1 unexpected MYT");
        assertEq(address(strategy1.vault()), address(vaultB), "strategy1 unexpected vault");
        (, string memory name1,,,,,,,) = strategy1.params();
        assertEq(name1, "Peapods Mainnet USDC", "strategy1 unexpected name");
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
