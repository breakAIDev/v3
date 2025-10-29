// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../libraries/BaseStrategyTest.sol";
import {EulerUSDCStrategy} from "../../strategies/mainnet/EulerUSDCStrategy.sol";

contract MockEulerUSDCStrategy is EulerUSDCStrategy {
    constructor(address _myt, StrategyParams memory _params, address _vault, address _usdc, address _permit2Address)
        EulerUSDCStrategy(_myt, _params, _vault, _usdc, _permit2Address)
    {}
}

contract EulerUSDCStrategyTest is BaseStrategyTest {
    address public constant EULER_USDC_VAULT = 0xe0a80d35bB6618CBA260120b279d357978c42BCE;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant MAINNET_PERMIT2 = 0x000000000022d473030f1dF7Fa9381e04776c7c5;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "EulerUSDC",
            protocol: "EulerUSDC",
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
        return address(new MockEulerUSDCStrategy(vault, params, USDC, EULER_USDC_VAULT, MAINNET_PERMIT2));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 22_089_302;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("MAINNET_RPC_URL");
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
