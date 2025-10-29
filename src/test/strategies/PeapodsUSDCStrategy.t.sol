// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../libraries/BaseStrategyTest.sol";
import {PeapodsUSDCStrategy} from "../../strategies/mainnet/PeapodsUSDC.sol";

contract MockPeapodsUSDCStrategy is PeapodsUSDCStrategy {
    constructor(address _myt, StrategyParams memory _params, address _vault, address _usdc, address _permit2Address)
        PeapodsUSDCStrategy(_myt, _params, _vault, _usdc, _permit2Address)
    {}
}

contract PeapodsUSDCStrategyTest is BaseStrategyTest {
    address public constant PEAPODS_USDC_VAULT = 0x3717e340140D30F3A077Dd21fAc39A86ACe873AA;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant MAINNET_PERMIT2 = 0x000000000022d473030f1dF7Fa9381e04776c7c5;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "PeapodsUSDC",
            protocol: "PeapodsUSDC",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: 10_000_000e6,
            globalCap: 1e18,
            estimatedYield: 100e6,
            additionalIncentives: false,
            slippageBPS: 1
        });
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        return TestConfig({decimals: 6, vaultAsset: USDC, vaultInitialDeposit: 1_000_000e6, absoluteCap: 10_000_000e6, relativeCap: 1e18});
    }

    function createStrategy(address vault, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new MockPeapodsUSDCStrategy(vault, params, PEAPODS_USDC_VAULT, USDC, MAINNET_PERMIT2));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 22_089_302;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("MAINNET_RPC_URL");
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
