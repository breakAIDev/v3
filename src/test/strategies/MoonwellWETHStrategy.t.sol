// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../libraries/BaseStrategyTest.sol";
import {MoonwellWETHStrategy} from "../../strategies/optimism/MoonwellWETHStrategy.sol";

contract MockMoonwellWETHStrategy is MoonwellWETHStrategy {
    constructor(address _myt, StrategyParams memory _params, address _mWETH, address _weth, address _permit2Address)
        MoonwellWETHStrategy(_myt, _params, _mWETH, _weth, _permit2Address)
    {}
}

contract MoonwellWETHStrategyTest is BaseStrategyTest {
    address public constant MOONWELL_WETH_MTOKEN = 0xb4104C02BBf4E9be85AAa41a62974E4e28D59A33;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant OPTIMISM_PERMIT2 = 0x000000000022d473030f1dF7Fa9381e04776c7c5;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "MoonwellWETH",
            protocol: "MoonwellWETH",
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
        return address(new MockMoonwellWETHStrategy(vault, params, MOONWELL_WETH_MTOKEN, WETH, OPTIMISM_PERMIT2));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 141_751_698;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("OPTIMISM_RPC_URL");
    }

    // Add any strategy-specific tests here
    function test_strategy_full_deallocate_does_not_revert_due_to_rounding(uint256 amountToAllocate, uint256 amountToDeallocate) public {
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
