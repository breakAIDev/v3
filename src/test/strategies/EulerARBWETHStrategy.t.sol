// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../libraries/BaseStrategyTest.sol";
import {EulerARBWETHStrategy} from "../../strategies/arbitrum/EulerARBWETHStrategy.sol";

contract MockEulerARBWETHStrategy is EulerARBWETHStrategy {
    constructor(address _myt, StrategyParams memory _params, address _weth, address _eulerVault, address _permit2Address)
        EulerARBWETHStrategy(_myt, _params, _weth, _eulerVault, _permit2Address)
    {}
}

contract EulerARBWETHStrategyTest is BaseStrategyTest {
    address public constant EULER_WETH_VAULT = 0x78E3E051D32157AACD550fBB78458762d8f7edFF;
    address public constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address public constant ARBITRUM_PERMIT2 = 0x000000000022d473030f1dF7Fa9381e04776c7c5;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "EulerARBWETH",
            protocol: "EulerARBWETH",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 10_000e18,
            globalCap: 1e18,
            estimatedYield: 100e18,
            additionalIncentives: false,
            slippageBPS: 1
        });
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        return TestConfig({vaultAsset: WETH, vaultInitialDeposit: 1000e18, absoluteCap: 10_000e18, relativeCap: 1e18, decimals: 18});
    }

    function createStrategy(address vault, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new MockEulerARBWETHStrategy(vault, params, WETH, EULER_WETH_VAULT, ARBITRUM_PERMIT2));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 0;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("ARBITRUM_RPC_URL");
    }

    // Add any strategy-specific tests here
    function test_strategy_deallocate_reverts_due_to_slippage(uint256 amountToAllocate, uint256 amountToDeallocate) public {
        amountToAllocate = bound(amountToAllocate, 1e6, testConfig.vaultInitialDeposit);
        amountToDeallocate = amountToAllocate;
        vm.startPrank(vault);
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        bytes memory prevAllocationAmount = abi.encode(0);
        IMYTStrategy(strategy).allocate(prevAllocationAmount, amountToAllocate, "", address(vault));
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();
        require(initialRealAssets > 0, "Initial real assets is 0");
        bytes memory prevAllocationAmount2 = abi.encode(amountToAllocate);
        vm.expectRevert();
        IMYTStrategy(strategy).deallocate(prevAllocationAmount2, amountToDeallocate, "", address(vault));
        vm.stopPrank();
    }
}
