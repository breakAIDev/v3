// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../libraries/BaseStrategyTest.sol";
import {AaveV3ARBWETHStrategy} from "../../strategies/arbitrum/AaveV3ARBWETHStrategy.sol";

contract MockAaveV3ARBWETHStrategy is AaveV3ARBWETHStrategy {
    constructor(address _myt, StrategyParams memory _params, address _aWETH, address _weth, address _pool, address _permit2Address)
        AaveV3ARBWETHStrategy(_myt, _params, _aWETH, _weth, _pool, _permit2Address)
    {}
}

contract AaveV3ARBWETHStrategyTest is BaseStrategyTest {
    address public constant AAVE_V3_ARB_WETH_ATOKEN = 0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8;
    address public constant AAVE_V3_ARB_WETH_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address public constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address public constant ARBITRUM_PERMIT2 = 0x000000000022d473030f1dF7Fa9381e04776c7c5;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "AaveV3ARBWETH",
            protocol: "AaveV3ARBWETH",
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
        return address(new MockAaveV3ARBWETHStrategy(vault, params, AAVE_V3_ARB_WETH_ATOKEN, WETH, AAVE_V3_ARB_WETH_POOL, ARBITRUM_PERMIT2));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 0;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("ARBITRUM_RPC_URL");
    }

    // Add any strategy-specific tests here
    function test_strategy_deallocate_reverts_due_to_slippage(uint256 amountToAllocate, uint256 amountToDeallocate) public {
        amountToAllocate = bound(amountToAllocate, 1 * 10 ** testConfig.decimals, testConfig.vaultInitialDeposit);
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
