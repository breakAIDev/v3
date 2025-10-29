// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../libraries/BaseStrategyTest.sol";
import {MoonwellUSDCStrategy} from "../../strategies/optimism/MoonwellUSDCStrategy.sol";

contract MockMoonwellUSDCStrategy is MoonwellUSDCStrategy {
    constructor(address _myt, StrategyParams memory _params, address _mUSDC, address _usdc, address _permit2Address)
        MoonwellUSDCStrategy(_myt, _params, _mUSDC, _usdc, _permit2Address)
    {}
}

contract MoonwellUSDCStrategyTest is BaseStrategyTest {
    address public constant MOONWELL_USDC_MTOKEN = 0x8E08617b0d66359D73Aa11E11017834C29155525;
    address public constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address public constant OPTIMISM_PERMIT2 = 0x000000000022d473030f1dF7Fa9381e04776c7c5;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "MoonwellUSDC",
            protocol: "MoonwellUSDC",
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
        return address(new MockMoonwellUSDCStrategy(vault, params, MOONWELL_USDC_MTOKEN, USDC, OPTIMISM_PERMIT2));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 141_751_698;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("OPTIMISM_RPC_URL");
    }

    // Add any strategy-specific tests here
    function test_strategy_full_deallocate_doe_not_revert_due_to_rounding(uint256 amountToAllocate, uint256 amountToDeallocate) public {
        amountToAllocate = bound(amountToAllocate, 1 * 10 ** testConfig.decimals, testConfig.vaultInitialDeposit);
        amountToDeallocate = amountToAllocate;
        vm.startPrank(vault);
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        bytes memory prevAllocationAmount = abi.encode(0);
        IMYTStrategy(strategy).allocate(prevAllocationAmount, amountToAllocate, "", address(vault));
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();
        require(initialRealAssets > 0, "Initial real assets is 0");
        bytes memory prevAllocationAmount2 = abi.encode(amountToAllocate);
        (bytes32[] memory strategyIds, int256 change) = IMYTStrategy(strategy).deallocate(prevAllocationAmount2, amountToDeallocate, "", address(vault));
        assertApproxEqAbs(change, -int256(amountToDeallocate), 1 * 10 ** testConfig.decimals);
        assertGt(strategyIds.length, 0, "strategyIds is empty");
        assertEq(strategyIds[0], IMYTStrategy(strategy).adapterId(), "adapter id not in strategyIds");
        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        require(finalRealAssets < initialRealAssets, "Final real assets is not less than initial real assets");
        vm.stopPrank();
    }
}
