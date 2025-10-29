// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../libraries/BaseStrategyTest.sol";
import {PeapodsETHStrategy} from "../../strategies/mainnet/PeapodsETH.sol";

contract MockPeapodsETHStrategy is PeapodsETHStrategy {
    constructor(address _myt, StrategyParams memory _params, address _vault, address _weth, address _permit2Address)
        PeapodsETHStrategy(_myt, _params, _vault, _weth, _permit2Address)
    {}
}

contract PeapodsETHStrategyTest is BaseStrategyTest {
    address public constant PEAPODS_ETH_VAULT = 0x9a42e1bEA03154c758BeC4866ec5AD214D4F2191;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant MAINNET_PERMIT2 = 0x000000000022d473030f1dF7Fa9381e04776c7c5;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "PeapodsETH",
            protocol: "PeapodsETH",
            riskClass: IMYTStrategy.RiskClass.HIGH,
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
        return address(new MockPeapodsETHStrategy(vault, params, PEAPODS_ETH_VAULT, WETH, MAINNET_PERMIT2));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 0;
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
