// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../libraries/BaseStrategyTest.sol";
import {AaveV3ARBUSDCStrategy} from "../../strategies/arbitrum/AaveV3ARBUSDCStrategy.sol";

contract MockAaveV3ARBUSDCStrategy is AaveV3ARBUSDCStrategy {
    constructor(address _myt, StrategyParams memory _params, address _usdc, address _aUSDC, address _pool, address _permit2Address)
        AaveV3ARBUSDCStrategy(_myt, _params, _usdc, _aUSDC, _pool, _permit2Address)
    {}
}

contract AaveV3ARBUSDCStrategyTest is BaseStrategyTest {
    address public constant AAVE_V3_USDC_ATOKEN = 0x724dc807b04555b71ed48a6896b6F41593b8C637;
    address public constant AAVE_V3_USDC_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address public constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address public constant OPTIMISM_PERMIT2 = 0x000000000022d473030f1dF7Fa9381e04776c7c5;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "AaveV3ARBUSDC",
            protocol: "AaveV3ARBUSDC",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 10_000e6,
            globalCap: 1e18,
            estimatedYield: 100e6,
            additionalIncentives: false,
            slippageBPS: 1
        });
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        return TestConfig({vaultAsset: USDC, vaultInitialDeposit: 1000e6, absoluteCap: 10_000e6, relativeCap: 1e18, decimals: 6});
    }

    function createStrategy(address vault, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new MockAaveV3ARBUSDCStrategy(vault, params, USDC, AAVE_V3_USDC_ATOKEN, AAVE_V3_USDC_POOL, OPTIMISM_PERMIT2));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 387_030_683;
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
