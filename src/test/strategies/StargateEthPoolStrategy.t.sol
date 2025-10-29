// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../libraries/BaseStrategyTest.sol";
import {StargateEthPoolStrategy} from "../../strategies/optimism/StargateEthPoolStrategy.sol";

contract MockStargateEthPoolStrategy is StargateEthPoolStrategy {
    constructor(address _myt, StrategyParams memory _params, address _weth, address _pool, address _permit2Address)
        StargateEthPoolStrategy(_myt, _params, _weth, _pool, _permit2Address)
    {}
}

contract StargateEthPoolStrategyTest is BaseStrategyTest {
    address public constant STARGATE_ETH_POOL = 0xe8CDF27AcD73a434D661C84887215F7598e7d0d3;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant OPTIMISM_PERMIT2 = 0x000000000022d473030f1dF7Fa9381e04776c7c5;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "StargateEthPool",
            protocol: "StargateEthPool",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: 10_000e18,
            globalCap: 1e18,
            estimatedYield: 100e18,
            additionalIncentives: false,
            slippageBPS: 1
        });
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        return TestConfig({vaultAsset: WETH, vaultInitialDeposit: 10e18, absoluteCap: 10_000e18, relativeCap: 1e18, decimals: 18});
    }

    function createStrategy(address vault, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new MockStargateEthPoolStrategy(vault, params, WETH, STARGATE_ETH_POOL, OPTIMISM_PERMIT2));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 141_751_698;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("OPTIMISM_RPC_URL");
    }

    function test_strategy_deallocate_reverts_due_to_rounding(uint256 amountToAllocate, uint256 amountToDeallocate) public {
        amountToAllocate = bound(amountToAllocate, 1e18, testConfig.vaultInitialDeposit);
        // Ensure there's dust by adding a non-zero remainder
        // This makes the amount not fully divisible by 1e12
        uint256 dust = amountToAllocate % 1e12;
        if (dust == 0) {
            // If by chance it's divisible, add some dust
            amountToAllocate += 1; // or any value < 1e12
        }
        amountToDeallocate = amountToAllocate;
        vm.startPrank(vault);
        deal(WETH, strategy, amountToAllocate);
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
