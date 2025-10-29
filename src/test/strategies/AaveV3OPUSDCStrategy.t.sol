// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../libraries/BaseStrategyTest.sol";
import {AaveV3OPUSDCStrategy} from "../../strategies/optimism/AaveV3OPUSDCStrategy.sol";

contract MockAaveV3OPUSDCStrategy is AaveV3OPUSDCStrategy {
    constructor(address _myt, StrategyParams memory _params, address _usdc, address _mUSDC, address _pool, address _permit2Address)
        AaveV3OPUSDCStrategy(_myt, _params, _usdc, _mUSDC, _pool, _permit2Address)
    {}
}

contract AaveV3OPUSDCStrategyTest is BaseStrategyTest {
    address public constant AAVE_V3_USDC_ATOKEN = 0x38d693cE1dF5AaDF7bC62595A37D667aD57922e5;
    address public constant AAVE_V3_USDC_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address public constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address public constant OPTIMISM_PERMIT2 = 0x000000000022d473030f1dF7Fa9381e04776c7c5;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "AaveV3OPUSDC",
            protocol: "AaveV3OPUSDC",
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
        return address(new MockAaveV3OPUSDCStrategy(vault, params, USDC, AAVE_V3_USDC_ATOKEN, AAVE_V3_USDC_POOL, OPTIMISM_PERMIT2));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 141_751_698;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("OPTIMISM_RPC_URL");
    }

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
